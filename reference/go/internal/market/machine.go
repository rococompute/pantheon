package market

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"pantheon/internal/beacon"
	"pantheon/internal/gitx"
)

// historyKeep bounds leader_history. The draw only needs the last two entries;
// the rest is a convenience, since the full record is on the chain.
const historyKeep = 16

// Event is an audit record emitted while applying a block.
type Event struct {
	Type  string
	Attrs map[string]string
}

// Machine applies transactions to a State and keeps the local git repo in step.
type Machine struct {
	S      *State
	Repo   *gitx.Repo
	Dir    string // data dir: bundles live under here
	events []Event
}

// New builds an empty machine over a data directory.
func New(dir string) (*Machine, error) {
	repo, err := gitx.Open(filepath.Join(dir, "repo.git"))
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(dir, "bundles"), 0o755); err != nil {
		return nil, err
	}
	return &Machine{Repo: repo, Dir: dir}, nil
}

// InitGenesis builds the first state from the genesis file.
func (m *Machine) InitGenesis(chainID string, g *Genesis) error {
	if err := g.Params.Validate(); err != nil {
		return fmt.Errorf("genesis params: %w", err)
	}
	if len(g.Agents) != 4 {
		return fmt.Errorf("genesis has %d agents, the protocol is defined for exactly 4", len(g.Agents))
	}
	ids, idx, addrs := map[string]bool{}, map[int]bool{}, map[string]bool{}
	for _, a := range g.Agents {
		if a.ID == "" || ids[a.ID] || idx[a.BLSIndex] || addrs[a.ValidatorAddr] || a.BLSIndex < 0 || a.BLSIndex >= 4 {
			return fmt.Errorf("genesis agent %q repeats an id, BLS index or validator, or has an index outside 0-3", a.ID)
		}
		ids[a.ID], idx[a.BLSIndex], addrs[a.ValidatorAddr] = true, true, true
	}
	if g.Group == nil || g.Group.T != 3 || g.Group.N != 4 {
		return errors.New("genesis must carry a 3-of-4 BLS group")
	}
	got, err := m.Repo.ImportTrusted(g.InitialBundle)
	if err != nil {
		return fmt.Errorf("genesis repo: %w", err)
	}
	if got != g.InitialCommit {
		return fmt.Errorf("genesis bundle head %s does not match initial_commit %s", got, g.InitialCommit)
	}
	s := &State{
		ChainID:    chainID,
		RepoHead:   g.InitialCommit,
		NextTaskID: 1,
		NextBidID:  1,
		Tasks:      map[uint64]*Task{},
		Bids:       map[uint64]*Bid{},
		Nonces:     map[string]uint64{},
		LastBid:    map[string]int64{},
		Reputation: map[string]*Stats{},
		Agents:     g.Agents,
		Group:      g.Group,
		Params:     g.Params,
	}
	for _, a := range g.Agents {
		s.Nonces[a.ID] = 0
		s.Reputation[a.ID] = &Stats{}
	}
	// The chain starts between terms, so term 1's leader comes from a threshold
	// signature like every other. A seed derived from genesis data could be ground
	// by whichever party finished the ceremony last.
	s.AwaitingSeed = true
	s.AwaitingSince = 0
	m.S = s
	return nil
}

// BeginBlock records the block's height and time.
func (m *Machine) BeginBlock(height int64, unixTime int64) {
	if err := m.Repo.BeginStage(height); err != nil {
		panic(err)
	}
	m.S.Height = height
	m.S.Time = unixTime
	m.events = nil
}

// CommitBlock makes this block's repository changes permanent. Call it after the
// state that names them has been durably saved.
func (m *Machine) CommitBlock() error {
	if err := m.Repo.Promote(); err != nil {
		return err
	}
	return m.Repo.UpdateMain(m.S.RepoHead)
}

// Recover finishes or drops a block a crash interrupted. Call it at startup, after
// restoring state.
func (m *Machine) Recover() error {
	var height int64
	if m.S != nil {
		height = m.S.Height
	}
	if err := m.Repo.RecoverStage(height); err != nil {
		return err
	}
	if m.S != nil {
		return m.Repo.UpdateMain(m.S.RepoHead)
	}
	return nil
}

// Events returns and clears what the current block has emitted.
func (m *Machine) Events() []Event {
	e := m.events
	m.events = nil
	return e
}

func (m *Machine) emit(typ string, kv ...string) {
	attrs := map[string]string{}
	for i := 0; i+1 < len(kv); i += 2 {
		attrs[kv[i]] = kv[i+1]
	}
	m.events = append(m.events, Event{Type: typ, Attrs: attrs})
}

func u(v uint64) string { return strconv.FormatUint(v, 10) }

// AdmitToBlock reports whether a decoded transaction belongs in the next block:
// the sender's next nonce, and only one per sender per block. This is the block-space
// rate limit. Without it one agent could fill every block with same-nonce or
// failing bundles at everyone's expense. seen collects senders across a proposal.
func (s *State) AdmitToBlock(b *Body, seen map[string]bool) error {
	if seen[b.Agent] {
		return fmt.Errorf("second transaction from %s in one block", b.Agent)
	}
	if want := s.Nonces[b.Agent] + 1; b.Nonce != want {
		return fmt.Errorf("nonce %d from %s, want %d", b.Nonce, b.Agent, want)
	}
	seen[b.Agent] = true
	return nil
}

// CheckTx is the mempool filter, keeping junk out of blocks. It uses only
// committed state and never spawns git.
func (m *Machine) CheckTx(raw []byte) error {
	if IsSeed(raw) {
		return errors.New("seed transactions are added by proposers, not submitted")
	}
	b, err := m.S.Decode(raw)
	if err != nil {
		return err
	}
	if want := m.S.Nonces[b.Agent] + 1; b.Nonce != want {
		return fmt.Errorf("nonce %d, but agent %s's next nonce is %d: send one transaction at a time", b.Nonce, b.Agent, want)
	}
	if err := m.validate(b); err != nil {
		return err
	}
	if b.Type == TxSubmitBid {
		info, err := gitx.CheckBundle(b.Bundle, m.S.Params.BundleLimits)
		if err != nil {
			return err
		}
		if len(info.Prerequisites) != 1 || info.Prerequisites[0] != m.S.RepoHead {
			return fmt.Errorf("bid commit %s does not descend directly from current head %s: rebase and resubmit", info.Commit, m.S.RepoHead)
		}
	}
	return nil
}

// DeliverTx applies one signed transaction. A validly signed transaction always
// consumes its nonce, even when it fails. Otherwise a failed merge could be
// replayed later, once the state has changed, and succeed without its signer's
// intent. The returned error is the failure reason recorded on chain.
func (m *Machine) DeliverTx(raw []byte) error {
	b, err := m.S.Decode(raw)
	if err != nil {
		return err
	}
	if want := m.S.Nonces[b.Agent] + 1; b.Nonce != want {
		return fmt.Errorf("nonce %d, want %d", b.Nonce, want)
	}
	m.S.Nonces[b.Agent] = b.Nonce
	if err := m.apply(b); err != nil {
		m.S.Reputation[b.Agent].BadTxs++
		m.emit("tx_failed", "agent", b.Agent, "type", b.Type, "reason", err.Error())
		return err
	}
	if b.Agent == m.S.TermLeader {
		m.S.LastActivity = m.S.Height
	}
	return nil
}

func (m *Machine) requireLeader(b *Body) error {
	if m.S.TermLeader == "" {
		return errors.New("no term leader: waiting for the seed of the next term")
	}
	if b.Agent != m.S.TermLeader {
		return fmt.Errorf("only term leader %s may send %s; `pantheon status` shows who leads, and leadership rotates each term", m.S.TermLeader, b.Type)
	}
	return nil
}

// maxShortText caps notes and reasons, which every node hashes for as long as a
// settled bid stays in state.
const maxShortText = 2048

func shortText(s string) error {
	if len(s) > maxShortText {
		return fmt.Errorf("text is %d bytes, limit is %d", len(s), maxShortText)
	}
	return nil
}

func (m *Machine) textOK(fields ...string) error {
	for _, f := range fields {
		if len(f) > m.S.Params.MaxTextBytes {
			return fmt.Errorf("text is %d bytes, limit is %d", len(f), m.S.Params.MaxTextBytes)
		}
	}
	return nil
}

// validate holds every rule that doesn't need git. Both CheckTx and apply use
// it, so the mempool and the block can't disagree about roles.
func (m *Machine) validate(b *Body) error {
	s := m.S
	switch b.Type {
	case TxPostTask:
		if err := m.requireLeader(b); err != nil {
			return err
		}
		if b.Spec == "" {
			return errors.New("task spec is empty")
		}
		if b.BaseCommit != s.RepoHead {
			return fmt.Errorf("base_commit %s is not repo_head %s", b.BaseCommit, s.RepoHead)
		}
		if len(s.OpenTasks()) >= s.Params.MaxOpenTasks {
			return fmt.Errorf("already %d open tasks: close one first", s.Params.MaxOpenTasks)
		}
		return m.textOK(b.Spec)

	case TxSubmitBid:
		if b.Agent == s.TermLeader {
			return errors.New("the term leader may not bid")
		}
		t := s.Tasks[b.TaskID]
		if t == nil {
			return fmt.Errorf("no task %d", b.TaskID)
		}
		if t.Status != TaskOpen {
			return fmt.Errorf("task %d is %s", b.TaskID, t.Status)
		}
		n := 0
		for _, bid := range s.Bids {
			if bid.Bidder == b.Agent && bid.Status == BidPending {
				n++
			}
		}
		if n >= s.Params.MaxPendingBidsAgent {
			return fmt.Errorf("agent %s already has %d pending bids", b.Agent, n)
		}
		if last, ok := s.LastBid[b.Agent]; ok && s.Height-last < s.Params.BidCooldownBlocks {
			return fmt.Errorf("bid cooldown: last bid at height %d, wait %d blocks", last, s.Params.BidCooldownBlocks)
		}
		return shortText(b.Note)

	case TxWithdraw:
		bid := s.Bids[b.BidID]
		if bid == nil {
			return fmt.Errorf("no bid %d", b.BidID)
		}
		if bid.Bidder != b.Agent {
			return fmt.Errorf("bid %d belongs to %s", b.BidID, bid.Bidder)
		}
		if bid.Status != BidPending {
			return fmt.Errorf("bid %d is %s", b.BidID, bid.Status)
		}
		if s.PendingMerge != nil && s.PendingMerge.BidID == b.BidID {
			return fmt.Errorf("bid %d is being merged", b.BidID)
		}
		return nil

	case TxMerge:
		if err := m.requireLeader(b); err != nil {
			return err
		}
		if s.PendingMerge != nil {
			return fmt.Errorf("bid %d is already pending merge", s.PendingMerge.BidID)
		}
		if s.MergesThisTerm >= s.Params.MaxMergesPerTerm {
			return errors.New("merge limit for this term reached")
		}
		bid := s.Bids[b.BidID]
		if bid == nil {
			return fmt.Errorf("no bid %d", b.BidID)
		}
		if bid.Status != BidPending {
			return fmt.Errorf("bid %d is %s", b.BidID, bid.Status)
		}
		// A bid can outlive its author's non-leader status across a term change.
		if bid.Bidder == b.Agent {
			return errors.New("a leader may not merge its own bid")
		}
		return nil

	case TxAttest:
		p := s.PendingMerge
		if p == nil {
			return errors.New("no merge is pending")
		}
		if p.BidID != b.BidID {
			return fmt.Errorf("pending merge is for bid %d, not %d", p.BidID, b.BidID)
		}
		if b.Agent == p.Proposer {
			return errors.New("the leader already approved by proposing the merge")
		}
		if b.Agent == s.Bids[p.BidID].Bidder {
			return errors.New("a bidder may not attest its own bid")
		}
		if _, dup := p.Attestations[b.Agent]; dup {
			return fmt.Errorf("agent %s already attested", b.Agent)
		}
		if b.Tree != p.Tree {
			return fmt.Errorf("attestation is for tree %s, pending merge produces %s", b.Tree, p.Tree)
		}
		if len(b.CIDigest) > 128 {
			return errors.New("ci_digest is over 128 bytes")
		}
		return nil

	case TxReject:
		if err := m.requireLeader(b); err != nil {
			return err
		}
		bid := s.Bids[b.BidID]
		if bid == nil {
			return fmt.Errorf("no bid %d", b.BidID)
		}
		if bid.Status != BidPending {
			return fmt.Errorf("bid %d is %s", b.BidID, bid.Status)
		}
		if s.PendingMerge != nil && s.PendingMerge.BidID == b.BidID {
			return fmt.Errorf("bid %d is being merged", b.BidID)
		}
		return shortText(b.Reason)

	case TxCloseTask:
		if err := m.requireLeader(b); err != nil {
			return err
		}
		t := s.Tasks[b.TaskID]
		if t == nil {
			return fmt.Errorf("no task %d", b.TaskID)
		}
		if t.Status != TaskOpen {
			return fmt.Errorf("task %d is %s", b.TaskID, t.Status)
		}
		if p := s.PendingMerge; p != nil && s.Bids[p.BidID].TaskID == b.TaskID {
			return fmt.Errorf("task %d has a merge in progress", b.TaskID)
		}
		return nil
	}
	return fmt.Errorf("unknown transaction type %q", b.Type)
}

func (m *Machine) apply(b *Body) error {
	if err := m.validate(b); err != nil {
		return err
	}
	s := m.S
	switch b.Type {
	case TxPostTask:
		id := s.NextTaskID
		s.NextTaskID++
		s.Tasks[id] = &Task{ID: id, Spec: b.Spec, BaseCommit: b.BaseCommit, PostedBy: b.Agent, Term: s.Term, Height: s.Height, Status: TaskOpen}
		m.emit("task_posted", "task", u(id), "by", b.Agent)

	case TxSubmitBid:
		// A failed attempt still costs the cooldown: git has already done the work.
		s.LastBid[b.Agent] = s.Height
		commit, err := m.Repo.ImportBundle(b.Bundle, s.Params.BundleLimits, s.RepoHead)
		if errors.Is(err, gitx.ErrInfra) {
			panic(err) // halt this node: a local fault must not become a consensus result
		}
		if err != nil {
			return err
		}
		h := sha256.Sum256(b.Bundle)
		hash := hex.EncodeToString(h[:])
		if err := m.saveBundle(hash, b.Bundle); err != nil {
			panic(fmt.Sprintf("cannot persist bundle: %v", err)) // a local fault must not become a consensus result
		}
		id := s.NextBidID
		s.NextBidID++
		s.Bids[id] = &Bid{ID: id, TaskID: b.TaskID, Bidder: b.Agent, BundleHash: hash, Commit: commit, Note: b.Note, Height: s.Height, Status: BidPending}
		s.Reputation[b.Agent].BidsPosted++
		m.emit("bid_submitted", "bid", u(id), "task", u(b.TaskID), "by", b.Agent, "commit", commit)

	case TxWithdraw:
		s.Bids[b.BidID].Status = BidWithdrawn
		m.emit("bid_withdrawn", "bid", u(b.BidID))

	case TxMerge:
		bid := s.Bids[b.BidID]
		tree, clean, err := m.Repo.MergeTree(s.RepoHead, bid.Commit)
		if err != nil {
			panic(err) // only local faults get here: see MergeTree
		}
		if !clean {
			return fmt.Errorf("bid %d conflicts with head", b.BidID)
		}
		s.PendingMerge = &MergeProposal{BidID: b.BidID, Proposer: b.Agent, ProposedAt: s.Height, Tree: tree, Attestations: map[string]Attestation{}}
		m.emit("merge_proposed", "bid", u(b.BidID), "tree", tree)

	case TxAttest:
		p := s.PendingMerge
		p.Attestations[b.Agent] = Attestation{OK: b.OK, CIDigest: b.CIDigest}
		if b.OK {
			s.Reputation[b.Agent].AttestsOK++
		} else {
			s.Reputation[b.Agent].AttestsNo++
		}
		m.emit("attested", "bid", u(b.BidID), "by", b.Agent, "ok", strconv.FormatBool(b.OK))
		if err := m.settlePending(); err != nil {
			panic(err)
		}

	case TxReject:
		bid := s.Bids[b.BidID]
		bid.Status = BidRejected
		bid.Reason = b.Reason
		s.Reputation[bid.Bidder].Rejected++
		m.emit("bid_rejected", "bid", u(b.BidID), "reason", b.Reason)

	case TxCloseTask:
		s.Tasks[b.TaskID].Status = TaskClosed
		for _, bid := range s.PendingBids() {
			if bid.TaskID == b.TaskID {
				bid.Status = BidCleared
				bid.Reason = "task closed"
				s.Reputation[bid.Bidder].Cleared++
				m.emit("bid_cleared", "bid", u(bid.ID), "reason", bid.Reason)
			}
		}
		m.emit("task_closed", "task", u(b.TaskID))
	}
	return nil
}

func (m *Machine) saveBundle(hash string, data []byte) error {
	path := filepath.Join(m.Dir, "bundles", hash)
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Bundle returns a bid's stored bundle.
func (m *Machine) Bundle(bidID uint64) ([]byte, error) {
	bid := m.S.Bids[bidID]
	if bid == nil {
		return nil, fmt.Errorf("no bid %d", bidID)
	}
	return os.ReadFile(filepath.Join(m.Dir, "bundles", bid.BundleHash))
}

// settlePending resolves the pending merge if its votes already decide it.
//
// Three of four agents must approve. The leader approved by proposing, and two
// attestors make three without the bidder. Once BidderFallbackBlocks have passed,
// the bidder's own approval also counts. Without that, an attestor who just goes
// quiet could block every honest merge, since with four agents the bidder and
// leader leave only two attestors. Two explicit "no" votes can never reach three,
// so they reject at once.
func (m *Machine) settlePending() error {
	s := m.S
	p := s.PendingMerge
	if p == nil {
		return nil
	}
	yes, no := 1, 0 // the leader
	for _, a := range p.Attestations {
		if a.OK {
			yes++
		} else {
			no++
		}
	}
	age := s.Height - p.ProposedAt
	if f := s.Params.BidderFallbackBlocks; f > 0 && age >= f {
		yes++
	}
	switch {
	case yes >= 3:
		return m.finalizeMerge(p)
	case no >= 2:
		bid := s.Bids[p.BidID]
		bid.Status = BidRejected
		bid.Reason = "attestors voted no"
		bid.Attestations = p.Attestations
		s.Reputation[bid.Bidder].Rejected++
		s.PendingMerge = nil
		m.emit("merge_rejected", "bid", u(bid.ID))
	case age >= s.Params.AttestWindow:
		s.PendingMerge = nil // the bid stays pending and may be proposed again
		m.emit("merge_expired", "bid", u(p.BidID))
	}
	return nil
}

// finalizeMerge writes the merge commit, advances the head, and clears every
// pending bid that no longer merges cleanly. Git failing here is a local fault,
// not a market outcome, so the error halts this node instead of forking it.
func (m *Machine) finalizeMerge(p *MergeProposal) error {
	s := m.S
	bid := s.Bids[p.BidID]
	msg := fmt.Sprintf("market: merge bid %d for task %d by %s\n\nterm %d, leader %s, height %d", bid.ID, bid.TaskID, bid.Bidder, s.Term, p.Proposer, s.Height)
	head, err := m.Repo.CommitTree(p.Tree, []string{s.RepoHead, bid.Commit}, msg, s.Time)
	if err != nil {
		return fmt.Errorf("commit-tree: %w", err)
	}
	s.RepoHead = head
	bid.Status = BidMerged
	bid.Attestations = p.Attestations
	s.PendingMerge = nil
	s.MergesThisTerm++
	s.Reputation[bid.Bidder].Merges++
	m.emit("merged", "bid", u(bid.ID), "task", u(bid.TaskID), "head", head)
	for _, other := range s.PendingBids() {
		_, clean, err := m.Repo.MergeTree(head, other.Commit)
		if err != nil {
			return fmt.Errorf("merge-tree on bid %d: %w", other.ID, err)
		}
		if clean {
			other.Stale = true
			continue
		}
		other.Status = BidCleared
		other.Reason = "conflicts with bid " + u(bid.ID)
		s.Reputation[other.Bidder].Cleared++
		m.emit("bid_cleared", "bid", u(other.ID), "reason", other.Reason)
	}
	return nil
}

// EndBlock runs the block-boundary rules: merge deadlines and term endings.
func (m *Machine) EndBlock() error {
	if err := m.settlePending(); err != nil {
		return err
	}
	m.prune()
	s := m.S
	if s.AwaitingSeed || s.PendingMerge != nil {
		return nil // a pending merge finishes under its leader, bounded by attest_window
	}
	age := s.Height - s.TermStart
	idle := s.Height - s.LastActivity
	bids := len(s.PendingBids())
	stalled := idle >= s.Params.StallBlocks && (bids > 0 || len(s.OpenTasks()) == 0)
	if age < s.Params.TermBlocks && s.MergesThisTerm < s.Params.MaxMergesPerTerm && !stalled {
		return nil
	}
	reason := "term_blocks"
	switch {
	case s.MergesThisTerm >= s.Params.MaxMergesPerTerm:
		reason = "max_merges"
	case stalled:
		reason = "stall"
		if bids > 0 {
			s.Reputation[s.TermLeader].Stalls++
		}
	}
	m.emit("term_ended", "term", u(s.Term), "leader", s.TermLeader, "reason", reason)
	s.TermLeader = ""
	s.AwaitingSeed = true
	s.AwaitingSince = s.Height
	return nil
}

// prune drops the oldest settled records past keep_settled, so state stays bounded
// no matter how long a bid-and-withdraw loop runs. Anything still tied to live work
// stays: a bid on an open task, and a closed task with bids left.
func (m *Machine) prune() {
	s := m.S
	var settled []uint64
	for id, b := range s.Bids {
		if b.Status == BidPending {
			continue
		}
		if t := s.Tasks[b.TaskID]; t == nil || t.Status == TaskClosed {
			settled = append(settled, id)
		}
	}
	sort.Slice(settled, func(i, j int) bool { return settled[i] < settled[j] })
	for i := 0; i < len(settled)-s.Params.KeepSettled; i++ {
		delete(s.Bids, settled[i])
	}
	live := map[uint64]bool{}
	for _, b := range s.Bids {
		live[b.TaskID] = true
	}
	var closed []uint64
	for id, t := range s.Tasks {
		if t.Status == TaskClosed && !live[id] {
			closed = append(closed, id)
		}
	}
	sort.Slice(closed, func(i, j int) bool { return closed[i] < closed[j] })
	for i := 0; i < len(closed)-s.Params.KeepSettled; i++ {
		delete(s.Tasks, closed[i])
	}
}

// ShareHeight reports whether validators must attach a seed share to their votes
// at the given height. It is exactly the block after a term ended. Shares are
// only produced then, because signing earlier would reveal the next leader while
// the current term is still running, which is what makes alliances possible.
func (s *State) ShareHeight(height int64) bool {
	return s.AwaitingSeed && height == s.AwaitingSince+1
}

// SeedRequired reports whether a proposal at this height must carry the seed.
func (s *State) SeedRequired(height int64) bool {
	return s.AwaitingSeed && height >= s.AwaitingSince+2
}

// NextTermMessage is what validators sign to seed the next term.
func (s *State) NextTermMessage() []byte {
	return beacon.Message(s.ChainID, s.Term+1)
}

// VerifySeed checks a recovered signature for the next term.
func (s *State) VerifySeed(sig []byte) error {
	return s.Group.VerifySeed(s.NextTermMessage(), sig)
}

// ApplySeed starts the next term from a verified recovered signature.
func (m *Machine) ApplySeed(sig []byte) error {
	s := m.S
	if !s.SeedRequired(s.Height) {
		return fmt.Errorf("no seed expected at height %d", s.Height)
	}
	if err := s.VerifySeed(sig); err != nil {
		return err
	}
	m.startTerm(beacon.SeedValue(sig), s.Height)
	return nil
}

// Draw picks an index in [0,n) from a seed.
func Draw(seed []byte, term uint64, n int) int {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], term)
	h := sha256.Sum256(append(append([]byte("pantheon/draw/v1\x00"), seed...), b[:]...))
	v := new(big.Int).SetBytes(h[:])
	return int(v.Mod(v, big.NewInt(int64(n))).Int64())
}

func (m *Machine) startTerm(seed []byte, height int64) {
	s := m.S
	eligible := s.Eligible()
	s.Term++
	leader := eligible[Draw(seed, s.Term, len(eligible))]
	s.TermLeader = leader
	s.LeaderHistory = append(s.LeaderHistory, leader)
	if len(s.LeaderHistory) > historyKeep {
		s.LeaderHistory = s.LeaderHistory[len(s.LeaderHistory)-historyKeep:]
	}
	s.LastSeed = seed
	s.TermStart = height
	s.LastActivity = height
	s.MergesThisTerm = 0
	s.AwaitingSeed = false
	s.AwaitingSince = 0
	s.Reputation[leader].TermsLed++
	m.emit("term_started", "term", u(s.Term), "leader", leader)
}
