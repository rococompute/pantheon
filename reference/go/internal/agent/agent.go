package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"pantheon/internal/client"
	"pantheon/internal/gitx"
	"pantheon/internal/market"
)

// Config is a wrapper's settings, kept in wrapper/agent.json.
type Config struct {
	Policy          Policy      `json:"policy"`
	CI              CIConfig    `json:"ci"`
	Context         RepoContext `json:"context"`
	Perspective     string      `json:"perspective"`
	Goal            string      `json:"goal"`
	MaxLLMCalls     int64       `json:"max_llm_calls"`
	BidWindowBlocks int64       `json:"bid_window_blocks"` // how long a leader waits for bids
	ParallelTasks   int         `json:"parallel_tasks"`
	MaxBidAttempts  int         `json:"max_bid_attempts"`
	MaxDraftsPerRun int         `json:"max_draft_failures"`
	PollMS          int         `json:"poll_ms"`
	LLMTimeoutSec   int         `json:"llm_timeout_sec"`
}

// DefaultConfig suits one block per second and real models.
func DefaultConfig() Config {
	return Config{
		Policy:          DefaultPolicy(),
		CI:              CIConfig{Sandbox: "docker", Image: "alpine:3.20", TimeoutSec: 120},
		MaxLLMCalls:     200,
		BidWindowBlocks: 180,
		ParallelTasks:   1,
		MaxBidAttempts:  3,
		MaxDraftsPerRun: 5,
		PollMS:          1000,
		LLMTimeoutSec:   600,
	}
}

// LoadConfig reads a config file over the defaults. A missing file is fine.
func LoadConfig(path string) (Config, error) {
	c := DefaultConfig()
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		return c, fmt.Errorf("parsing %s: %w", path, err)
	}
	return c, nil
}

// Agent runs one market participant's duties.
type Agent struct {
	cfg     Config
	sender  *client.Sender
	llm     Backend
	repo    *gitx.Repo
	workDir string
	logf    func(string, ...any)

	sendMu sync.Mutex // one transaction at a time: nonces come from committed state
	repoMu sync.Mutex // serializes changes to the local repo

	mu           sync.Mutex
	bidAttempts  map[uint64]int
	picks        map[string]bool // task+bids+head combinations already reviewed
	proposed     map[string]bool // merge attempts already sent
	attested     map[string]bool
	draftFails   int
	goalDone     bool
	goalDoneTerm uint64
}

// New builds a wrapper. workDir holds its private repo and scratch space.
func New(cfg Config, sender *client.Sender, llm Backend, workDir string) (*Agent, error) {
	repo, err := gitx.Open(filepath.Join(workDir, "repo.git"))
	if err != nil {
		return nil, err
	}
	budgeted := llm
	if cfg.MaxLLMCalls > 0 {
		budgeted = &Budgeted{Backend: llm, Max: cfg.MaxLLMCalls}
	}
	return &Agent{
		cfg: cfg, sender: sender, llm: budgeted, repo: repo, workDir: workDir,
		logf:        log.New(os.Stdout, "["+sender.Agent+"] ", log.LstdFlags).Printf,
		bidAttempts: map[uint64]int{}, picks: map[string]bool{}, proposed: map[string]bool{}, attested: map[string]bool{},
	}, nil
}

// Run performs duties until ctx ends. Each duty has its own loop because LLM calls
// can take minutes, and a bidder's long think must not make it miss an attestation.
func (a *Agent) Run(ctx context.Context) error {
	a.logf("started: backend %s, ci sandbox %q", a.llm.Name(), a.cfg.CI.Sandbox)
	var wg sync.WaitGroup
	for name, duty := range map[string]func(context.Context, *market.State) error{
		"lead": a.leadDuty, "bid": a.bidDuty, "attest": a.attestDuty,
	} {
		wg.Add(1)
		go func(name string, duty func(context.Context, *market.State) error) {
			defer wg.Done()
			a.loop(ctx, name, duty)
		}(name, duty)
	}
	wg.Wait()
	return ctx.Err()
}

func (a *Agent) loop(ctx context.Context, name string, duty func(context.Context, *market.State) error) {
	poll := time.Duration(a.cfg.PollMS) * time.Millisecond
	if poll <= 0 {
		poll = time.Second
	}
	var lastErr string
	var lastHeight int64
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(poll):
		}
		s, err := a.sender.State(ctx)
		if err != nil {
			if msg := err.Error(); msg != lastErr && ctx.Err() == nil {
				a.logf("%s: reading state: %v", name, err)
				lastErr = msg
			}
			continue
		}
		if s.Height == lastHeight {
			continue
		}
		lastHeight = s.Height
		if err := duty(ctx, s); err != nil && ctx.Err() == nil {
			if msg := err.Error(); msg != lastErr {
				a.logf("%s: %v", name, err)
				lastErr = msg
			}
		}
	}
}

func (a *Agent) ask(ctx context.Context, r Request, into any) error {
	timeout := time.Duration(a.cfg.LLMTimeoutSec) * time.Second
	if timeout <= 0 {
		timeout = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	reply, err := a.llm.Complete(ctx, r)
	if err != nil {
		return fmt.Errorf("%s: %w", r.Kind, err)
	}
	if err := ParseJSON(reply, into); err != nil {
		return fmt.Errorf("%s: unusable reply: %w", r.Kind, err)
	}
	return nil
}

func (a *Agent) send(ctx context.Context, b market.Body) error {
	a.sendMu.Lock()
	defer a.sendMu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	res, err := a.sender.Send(ctx, b)
	if err != nil {
		return err
	}
	return res.Err()
}

// sync brings the local repo to the chain's head, returning it.
func (a *Agent) sync(ctx context.Context) (string, error) {
	all, err := a.sender.HeadBundle(ctx)
	if err != nil {
		return "", err
	}
	a.repoMu.Lock()
	defer a.repoMu.Unlock()
	return a.repo.Sync(all)
}

// inspect imports a bid and evaluates it against head: the merge's diff, our
// policy, and CI in the sandbox.
type inspection struct {
	Tree      string
	Patch     string
	Violation string
	CI        *CIResult
	Clean     bool
}

func (a *Agent) inspect(ctx context.Context, s *market.State, bid *market.Bid) (*inspection, error) {
	head, err := a.sync(ctx)
	if err != nil {
		return nil, err
	}
	if head != s.RepoHead {
		return nil, fmt.Errorf("local head %s has not caught up with %s yet", head, s.RepoHead)
	}
	bundle, err := a.sender.BidBundle(ctx, bid.ID)
	if err != nil {
		return nil, err
	}
	a.repoMu.Lock()
	_, err = a.repo.AddBid(bundle, s.Params.BundleLimits)
	var tree string
	var clean bool
	if err == nil {
		tree, clean, err = a.repo.MergeTree(head, bid.Commit)
	}
	a.repoMu.Unlock()
	// A bid this wrapper can't import or merge is a verdict on the bid. If it were
	// treated as trouble to retry, one strange bid could wedge every honest leader.
	if errors.Is(err, gitx.ErrInfra) {
		return nil, err
	}
	if err != nil {
		return &inspection{Clean: true, Violation: "bid cannot be imported: " + clip(err.Error(), 300)}, nil
	}
	in := &inspection{Tree: tree, Clean: clean}
	if !clean {
		return in, nil
	}
	limit := a.cfg.Policy.MaxDiffBytes * 2
	if limit <= 0 {
		limit = 1 << 20
	}
	files, patch, err := a.repo.Diff(head, tree, limit)
	if errors.Is(err, gitx.ErrDiffTooLarge) {
		in.Violation = err.Error()
		return in, nil
	}
	if err != nil {
		return nil, err
	}
	in.Patch = patch
	if in.Violation, err = a.cfg.Policy.Violation(files, patch); err != nil {
		return nil, err
	}
	if in.Violation != "" {
		return in, nil
	}
	dir, err := tempDirUnder(filepath.Join(a.workDir, "ci"), "tree-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	if err := a.repo.ExportTree(tree, dir); err != nil {
		in.Violation = "tree cannot be exported safely: " + err.Error()
		return in, nil
	}
	// MkdirTemp gives 0700, but the container runs as nobody. Docker Desktop's file
	// sharing hides the difference, and on Linux it would fail every bid.
	if err := os.Chmod(dir, 0o755); err != nil {
		return nil, err
	}
	in.CI, err = RunCI(ctx, a.cfg.CI, dir)
	if err != nil {
		return nil, err
	}
	return in, nil
}

// leadDuty is everything the term leader does, in priority order.
func (a *Agent) leadDuty(ctx context.Context, s *market.State) error {
	me := a.sender.Agent
	if s.TermLeader != me || s.PendingMerge != nil {
		return nil
	}
	if err := a.closeFinishedTasks(ctx, s); err != nil {
		return err
	}
	// Trouble with one task must not stop work on the others.
	var firstErr error
	for _, t := range s.OpenTasks() {
		acted, err := a.reviewTask(ctx, s, t)
		if err != nil && firstErr == nil {
			firstErr = fmt.Errorf("task %d: %w", t.ID, err)
		}
		if acted {
			return firstErr // state has moved: look again at the next block
		}
	}
	if err := a.maybeDraft(ctx, s); err != nil && firstErr == nil {
		firstErr = err
	}
	return firstErr
}

func (a *Agent) closeFinishedTasks(ctx context.Context, s *market.State) error {
	for _, t := range s.OpenTasks() {
		for _, b := range s.Bids {
			if b.TaskID == t.ID && b.Status == market.BidMerged {
				a.logf("closing task %d: bid %d merged", t.ID, b.ID)
				if err := a.send(ctx, market.Body{Type: market.TxCloseTask, TaskID: t.ID}); err != nil {
					return fmt.Errorf("closing task %d: %w", t.ID, err)
				}
				break
			}
		}
	}
	return nil
}

func pendingFor(s *market.State, task uint64) []*market.Bid {
	var out []*market.Bid
	for _, b := range s.PendingBids() {
		if b.TaskID == task {
			out = append(out, b)
		}
	}
	return out
}

// reviewTask examines a task's bids once the window has passed or everyone who
// can bid has. It returns true if it sent anything.
func (a *Agent) reviewTask(ctx context.Context, s *market.State, t *market.Task) (bool, error) {
	me := a.sender.Agent
	var bids []*market.Bid
	for _, b := range pendingFor(s, t.ID) {
		if b.Bidder != me { // a bid from before we led: rules forbid merging it
			bids = append(bids, b)
		}
	}
	if len(bids) == 0 {
		return false, nil
	}
	window := s.Height-t.Height >= a.cfg.BidWindowBlocks
	if len(bids) < 3 && !window {
		return false, nil
	}
	ids := make([]string, len(bids))
	for i, b := range bids {
		ids[i] = fmt.Sprint(b.ID)
	}
	key := fmt.Sprintf("%d/%s/%s", t.ID, strings.Join(ids, ","), s.RepoHead)
	a.mu.Lock()
	seen := a.picks[key]
	a.picks[key] = true
	a.mu.Unlock()
	if seen {
		return false, nil
	}

	var reviews []BidReview
	inspected := map[uint64]*inspection{}
	acted := false
	for _, b := range bids {
		in, err := a.inspect(ctx, s, b)
		if err != nil {
			a.forget(key)
			return acted, err
		}
		inspected[b.ID] = in
		switch {
		case !in.Clean:
			// Finalization should have cleared it: leave it alone.
			a.logf("bid %d conflicts with head; skipping", b.ID)
		case in.Violation != "":
			a.logf("rejecting bid %d: policy: %s", b.ID, in.Violation)
			if err := a.send(ctx, market.Body{Type: market.TxReject, BidID: b.ID, Reason: clip("policy: "+in.Violation, 1000)}); err != nil {
				return acted, err
			}
			acted = true
		default:
			reviews = append(reviews, BidReview{ID: b.ID, Bidder: b.Bidder, Note: b.Note, Patch: in.Patch, CIOK: in.CI.OK, CIOut: in.CI.Output})
		}
	}
	if len(reviews) == 0 {
		return acted, nil
	}
	f := newFence()
	var pick struct {
		Merge  uint64 `json:"merge"`
		Reject []struct {
			Bid    uint64 `json:"bid"`
			Reason string `json:"reason"`
		} `json:"reject"`
	}
	if err := a.ask(ctx, Request{Kind: KindPick, Prompt: pickPrompt(me, a.cfg.Perspective, t.Spec, reviews, f), Data: PickData{Bids: reviews}}, &pick); err != nil {
		a.forget(key)
		return acted, err
	}
	known := map[uint64]BidReview{}
	for _, r := range reviews {
		known[r.ID] = r
	}
	for _, r := range pick.Reject {
		if _, ok := known[r.Bid]; !ok || r.Bid == pick.Merge {
			continue
		}
		a.logf("rejecting bid %d: %s", r.Bid, clip(r.Reason, 200))
		if err := a.send(ctx, market.Body{Type: market.TxReject, BidID: r.Bid, Reason: clip(r.Reason, 1000)}); err != nil {
			return acted, err
		}
		acted = true
	}
	if pick.Merge == 0 {
		return acted, nil
	}
	r, ok := known[pick.Merge]
	if !ok {
		a.forget(key)
		return acted, fmt.Errorf("model picked bid %d, which is not under review", pick.Merge)
	}
	// The model can't talk the wrapper into proposing a failing bid.
	if !r.CIOK {
		return acted, fmt.Errorf("model picked bid %d, but its CI failed: refusing to propose", r.ID)
	}
	mergeKey := fmt.Sprintf("%d/%s", r.ID, s.RepoHead)
	a.mu.Lock()
	again := a.proposed[mergeKey]
	a.proposed[mergeKey] = true
	a.mu.Unlock()
	if again {
		return acted, nil // a proposal for this exact merge already expired
	}
	a.logf("proposing merge of bid %d (%s)", r.ID, r.Bidder)
	if err := a.send(ctx, market.Body{Type: market.TxMerge, BidID: r.ID}); err != nil {
		return acted, fmt.Errorf("merge bid %d: %w", r.ID, err)
	}
	return true, nil
}

func (a *Agent) forget(key string) {
	a.mu.Lock()
	delete(a.picks, key)
	a.mu.Unlock()
}

func (a *Agent) maybeDraft(ctx context.Context, s *market.State) error {
	if a.cfg.Goal == "" {
		return nil
	}
	if len(s.OpenTasks()) >= a.cfg.ParallelTasks {
		return nil
	}
	a.mu.Lock()
	skip := a.draftFails >= a.cfg.MaxDraftsPerRun || (a.goalDone && a.goalDoneTerm == s.Term)
	a.mu.Unlock()
	if skip {
		return nil
	}
	head, err := a.sync(ctx)
	if err != nil {
		return err
	}
	if head != s.RepoHead {
		return nil
	}
	var posted []string
	ids := make([]uint64, 0, len(s.Tasks))
	for id := range s.Tasks {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for _, id := range ids {
		posted = append(posted, s.Tasks[id].Spec)
	}
	f := newFence()
	repoText, err := a.cfg.Context.render(a.repo, head, f)
	if err != nil {
		return err
	}
	var draft struct {
		Task *string `json:"task"`
	}
	req := Request{Kind: KindDraft, Prompt: draftPrompt(a.sender.Agent, a.cfg.Perspective, a.cfg.Goal, posted, repoText, f),
		Data: DraftData{Agent: a.sender.Agent, Goal: a.cfg.Goal, Posted: posted}}
	if err := a.ask(ctx, req, &draft); err != nil {
		a.mu.Lock()
		a.draftFails++
		a.mu.Unlock()
		return err
	}
	if draft.Task == nil || strings.TrimSpace(*draft.Task) == "" {
		a.mu.Lock()
		a.goalDone, a.goalDoneTerm = true, s.Term
		a.mu.Unlock()
		a.logf("model says the goal is met; posting nothing this term")
		return nil
	}
	spec := strings.TrimSpace(*draft.Task)
	a.logf("posting task: %s", clip(spec, 200))
	return a.send(ctx, market.Body{Type: market.TxPostTask, Spec: clip(spec, s.Params.MaxTextBytes-64), BaseCommit: head})
}

// bidDuty writes a patch for each open task this agent has no live bid on.
func (a *Agent) bidDuty(ctx context.Context, s *market.State) error {
	me := a.sender.Agent
	if s.TermLeader == me || s.TermLeader == "" {
		return nil
	}
	// Don't spend a model call on a bid the chain would refuse.
	if last, ok := s.LastBid[me]; ok && s.Height-last < s.Params.BidCooldownBlocks {
		return nil
	}
	for _, t := range s.OpenTasks() {
		skip := false
		for _, b := range s.Bids {
			if b.TaskID == t.ID && (b.Status == market.BidMerged || (b.Bidder == me && b.Status == market.BidPending)) {
				skip = true
				break
			}
		}
		if skip {
			continue
		}
		a.mu.Lock()
		n := a.bidAttempts[t.ID]
		if n < a.cfg.MaxBidAttempts {
			a.bidAttempts[t.ID] = n + 1
		}
		a.mu.Unlock()
		if n >= a.cfg.MaxBidAttempts {
			continue
		}
		if err := a.bidOn(ctx, s, t); err != nil {
			return fmt.Errorf("bidding on task %d (attempt %d): %w", t.ID, n+1, err)
		}
	}
	return nil
}

func (a *Agent) bidOn(ctx context.Context, s *market.State, t *market.Task) error {
	me := a.sender.Agent
	head, err := a.sync(ctx)
	if err != nil {
		return err
	}
	f := newFence()
	repoText, err := a.cfg.Context.render(a.repo, head, f)
	if err != nil {
		return err
	}
	var reply struct {
		Files []struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		} `json:"files"`
		Delete []string `json:"delete"`
		Note   string   `json:"note"`
	}
	req := Request{Kind: KindPatch, Prompt: patchPrompt(me, a.cfg.Perspective, t.Spec, repoText, f),
		Data: PatchData{Agent: me, TaskID: t.ID, Spec: t.Spec}}
	if err := a.ask(ctx, req, &reply); err != nil {
		return err
	}
	if len(reply.Files)+len(reply.Delete) == 0 {
		return errors.New("model produced no changes")
	}
	scratch, err := tempDirUnder(filepath.Join(a.workDir, "wt"), "bid-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(scratch)
	a.repoMu.Lock()
	wt, err := a.repo.AddWorktree(scratch, head)
	a.repoMu.Unlock()
	if err != nil {
		return err
	}
	defer func() {
		a.repoMu.Lock()
		wt.Remove()
		a.repoMu.Unlock()
	}()
	for _, file := range reply.Files {
		if err := CleanRelPath(file.Path); err != nil {
			return fmt.Errorf("model output: %w", err)
		}
		if err := noSymlinkAlong(wt.Dir, file.Path); err != nil {
			return fmt.Errorf("model output: %w", err)
		}
		full := filepath.Join(wt.Dir, filepath.FromSlash(file.Path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(full, []byte(file.Content), 0o644); err != nil {
			return err
		}
	}
	for _, p := range reply.Delete {
		if err := CleanRelPath(p); err != nil {
			return fmt.Errorf("model output: %w", err)
		}
		if err := noSymlinkAlong(wt.Dir, p); err != nil {
			return fmt.Errorf("model output: %w", err)
		}
		_ = os.Remove(filepath.Join(wt.Dir, filepath.FromSlash(p)))
	}
	commit, err := wt.CommitAll(me, fmt.Sprintf("%s: task %d\n\n%s", me, t.ID, clip(reply.Note, 500)))
	if err != nil {
		return err
	}
	if commit == "" {
		return errors.New("model's patch changes nothing")
	}
	// Models are slow, and the head may have moved while this one was thinking.
	newHead, err := a.sync(ctx)
	if err != nil {
		return err
	}
	a.repoMu.Lock()
	defer a.repoMu.Unlock()
	if newHead != head {
		tree, clean, err := a.repo.MergeTree(newHead, commit)
		if err != nil {
			return err
		}
		if !clean {
			return fmt.Errorf("head moved to %s and this patch conflicts; will retry", short(newHead))
		}
		if commit, err = a.repo.CommitTreeAs(me, tree, []string{newHead}, fmt.Sprintf("%s: task %d (rebased)", me, t.ID), time.Now().Unix()); err != nil {
			return err
		}
		head = newHead
	}
	// The gate: nothing is signed unless the wrapper's policy passes it.
	files, patch, err := a.repo.Diff(head, commit, 16<<20)
	if err != nil {
		return err
	}
	v, err := a.cfg.Policy.Violation(files, patch)
	if err != nil {
		return err
	}
	if v != "" {
		return fmt.Errorf("policy blocked our own patch: %s", v)
	}
	bundle, err := a.repo.BundleBid(commit, head)
	if err != nil {
		return err
	}
	a.logf("submitting bid on task %d: %s", t.ID, clip(reply.Note, 120))
	return a.send(ctx, market.Body{Type: market.TxSubmitBid, TaskID: t.ID, Bundle: bundle, Note: clip(reply.Note, 1000)})
}

// noSymlinkAlong refuses a path that passes through a symlink, which would let a
// model's write land outside the worktree.
func noSymlinkAlong(root, rel string) error {
	cur := root
	for _, seg := range strings.Split(rel, "/") {
		cur = filepath.Join(cur, seg)
		info, err := os.Lstat(cur)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("path %q goes through a symlink", rel)
		}
	}
	return nil
}

func short(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}

// attestDuty judges a pending merge when this agent is one of its attestors.
func (a *Agent) attestDuty(ctx context.Context, s *market.State) error {
	me := a.sender.Agent
	p := s.PendingMerge
	if p == nil || p.Proposer == me {
		return nil
	}
	bid := s.Bids[p.BidID]
	if bid == nil || bid.Bidder == me {
		return nil
	}
	if _, done := p.Attestations[me]; done {
		return nil
	}
	key := fmt.Sprintf("%d/%d", p.BidID, p.ProposedAt)
	a.mu.Lock()
	seen := a.attested[key]
	a.attested[key] = true
	a.mu.Unlock()
	if seen {
		return nil
	}
	retry := func(err error) error {
		a.mu.Lock()
		delete(a.attested, key)
		a.mu.Unlock()
		return err
	}
	in, err := a.inspect(ctx, s, bid)
	if err != nil {
		// Infrastructure trouble says nothing about the bid. Not voting is the honest
		// answer, and the fallback keeps merges moving if this agent stays out.
		return retry(fmt.Errorf("cannot evaluate bid %d yet: %w", bid.ID, err))
	}
	vote := func(ok bool, digest, why string) error {
		a.logf("attesting bid %d: ok=%v (%s)", bid.ID, ok, clip(why, 200))
		return a.send(ctx, market.Body{Type: market.TxAttest, BidID: bid.ID, OK: ok, CIDigest: digest, Tree: p.Tree})
	}
	if !in.Clean {
		return vote(false, "merge-conflict", "bid conflicts with head")
	}
	if in.Tree != p.Tree {
		// Consensus said one tree, and our own git computed another. Refuse loudly.
		return vote(false, "tree-mismatch", fmt.Sprintf("local merge gives %s, proposal says %s", in.Tree, p.Tree))
	}
	if in.Violation != "" {
		return vote(false, "policy", in.Violation)
	}
	if !in.CI.OK {
		return vote(false, in.CI.Digest, "CI failed: "+clip(in.CI.Output, 300))
	}
	spec := ""
	if t := s.Tasks[bid.TaskID]; t != nil {
		spec = t.Spec
	}
	review := BidReview{ID: bid.ID, Bidder: bid.Bidder, Note: bid.Note, Patch: in.Patch, CIOK: true}
	var verdict struct {
		Approve bool   `json:"approve"`
		Reason  string `json:"reason"`
	}
	req := Request{Kind: KindAttest, Prompt: attestPrompt(me, a.cfg.Perspective, spec, review, newFence()), Data: AttestData{Bid: review}}
	if err := a.ask(ctx, req, &verdict); err != nil {
		return retry(err)
	}
	return vote(verdict.Approve, in.CI.Digest, verdict.Reason)
}
