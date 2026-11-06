package market

import (
	"crypto/ed25519"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"pantheon/internal/beacon"
	"pantheon/internal/gitx"
)

var names = []string{"claude", "codex", "grok", "muse"}

type harness struct {
	t         *testing.T
	m         *Machine
	keys      map[string]ed25519.PrivateKey
	shares    []beacon.Share
	nonce     map[string]uint64
	wrk       *gitx.Repo // a bidder-side repo for building bundles
	genesis   *Genesis
	firstSeed []byte
}

func newHarness(t *testing.T, mutate ...func(*Params)) *harness {
	t.Helper()
	src := t.TempDir()
	os.WriteFile(filepath.Join(src, "a.txt"), []byte("1\n"), 0o644)
	os.WriteFile(filepath.Join(src, "b.txt"), []byte("1\n"), 0o644)
	bundle, commit, err := gitx.Snapshot(src, 1000)
	if err != nil {
		t.Fatal(err)
	}
	group, shares, err := beacon.TrustedDeal(4, 3)
	if err != nil {
		t.Fatal(err)
	}
	h := &harness{t: t, keys: map[string]ed25519.PrivateKey{}, nonce: map[string]uint64{}, shares: shares}
	var agents []Agent
	for i, n := range names {
		pub, priv, _ := ed25519.GenerateKey(nil)
		h.keys[n] = priv
		agents = append(agents, Agent{ID: n, AppPubKey: pub, ValidatorAddr: fmt.Sprintf("v%d", i), BLSIndex: i})
	}
	gv, err := gitx.Version()
	if err != nil {
		t.Fatal(err)
	}
	p := DefaultParams()
	p.GitVersion = gv
	p.BidCooldownBlocks = 0
	for _, f := range mutate {
		f(&p)
	}
	m, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := m.InitGenesis("test", &Genesis{Agents: agents, Group: group, Params: p, InitialBundle: bundle, InitialCommit: commit}); err != nil {
		t.Fatal(err)
	}
	h.m = m
	h.genesis = &Genesis{Agents: agents, Group: group, Params: p, InitialBundle: bundle, InitialCommit: commit}
	h.wrk, err = gitx.Open(filepath.Join(t.TempDir(), "w.git"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.wrk.ImportTrusted(bundle); err != nil {
		t.Fatal(err)
	}
	h.finishTerm() // the chain starts between terms: draw term 1
	return h
}

// block advances one empty block.
func (h *harness) block() {
	h.t.Helper()
	h.commit()
	h.m.BeginBlock(h.m.S.Height+1, 1000+h.m.S.Height+1)
	if err := h.m.EndBlock(); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) commit() {
	h.t.Helper()
	if err := h.m.CommitBlock(); err != nil {
		h.t.Fatal(err)
	}
}

// send applies a transaction in its own block step, tracking nonces.
func (h *harness) send(b Body) error {
	h.t.Helper()
	h.nonce[b.Agent]++
	b.Nonce = h.nonce[b.Agent]
	raw, err := Sign("test", h.keys[b.Agent], &b)
	if err != nil {
		h.t.Fatal(err)
	}
	return h.m.DeliverTx(raw)
}

func (h *harness) must(b Body) {
	h.t.Helper()
	if err := h.send(b); err != nil {
		h.t.Fatalf("%s by %s: %v", b.Type, b.Agent, err)
	}
}

func (h *harness) refuse(b Body, want string) {
	h.t.Helper()
	err := h.send(b)
	if err == nil || !strings.Contains(err.Error(), want) {
		h.t.Fatalf("%s by %s: want error containing %q, got %v", b.Type, b.Agent, want, err)
	}
}

// roles returns the leader and the other three in stable order.
func (h *harness) roles() (string, []string) {
	var rest []string
	for _, n := range names {
		if n != h.m.S.TermLeader {
			rest = append(rest, n)
		}
	}
	return h.m.S.TermLeader, rest
}

// bundle builds a bid on the machine's current head.
func (h *harness) bundle(agent string, edits map[string]string) []byte {
	h.t.Helper()
	h.commit()
	head := h.m.S.RepoHead
	all, err := h.m.Repo.BundleAll()
	if err != nil {
		h.t.Fatal(err)
	}
	if _, err := h.wrk.ImportTrusted(all); err != nil {
		h.t.Fatal(err)
	}
	wt, err := h.wrk.AddWorktree(h.t.TempDir(), head)
	if err != nil {
		h.t.Fatal(err)
	}
	defer wt.Remove()
	for p, c := range edits {
		if err := os.WriteFile(filepath.Join(wt.Dir, p), []byte(c), 0o644); err != nil {
			h.t.Fatal(err)
		}
	}
	c, err := wt.CommitAll(agent, "bid")
	if err != nil || c == "" {
		h.t.Fatalf("commit: %v %q", err, c)
	}
	b, err := h.wrk.BundleBid(c, head)
	if err != nil {
		h.t.Fatal(err)
	}
	return b
}

func (h *harness) postTask(leader string) uint64 {
	h.t.Helper()
	h.must(Body{Agent: leader, Type: TxPostTask, Spec: "do it", BaseCommit: h.m.S.RepoHead})
	return h.m.S.NextTaskID - 1
}

func (h *harness) bid(agent string, task uint64, edits map[string]string) uint64 {
	h.t.Helper()
	h.must(Body{Agent: agent, Type: TxSubmitBid, TaskID: task, Bundle: h.bundle(agent, edits)})
	return h.m.S.NextBidID - 1
}

func (h *harness) attest(agent string, bid uint64, ok bool) {
	h.t.Helper()
	h.must(Body{Agent: agent, Type: TxAttest, BidID: bid, OK: ok, CIDigest: "d", Tree: h.m.S.PendingMerge.Tree})
}

func TestHappyPathMergeAndConflictClearing(t *testing.T) {
	h := newHarness(t)
	leader, r := h.roles()
	task := h.postTask(leader)
	win := h.bid(r[0], task, map[string]string{"a.txt": "winner\n"})
	conflict := h.bid(r[1], task, map[string]string{"a.txt": "loser\n"})
	clean := h.bid(r[2], task, map[string]string{"b.txt": "other\n"})

	before := h.m.S.RepoHead
	h.must(Body{Agent: leader, Type: TxMerge, BidID: win})
	if h.m.S.RepoHead != before {
		t.Fatal("head moved before quorum")
	}
	h.attest(r[1], win, true)
	if h.m.S.RepoHead != before {
		t.Fatal("head moved on a single attestation")
	}
	h.attest(r[2], win, true)
	if h.m.S.RepoHead == before {
		t.Fatal("head did not move at quorum")
	}
	s := h.m.S
	if s.Bids[win].Status != BidMerged {
		t.Fatalf("winner: %s", s.Bids[win].Status)
	}
	if s.Bids[conflict].Status != BidCleared || s.Reputation[r[1]].Cleared != 1 {
		t.Fatalf("conflicting bid: %+v", s.Bids[conflict])
	}
	if s.Bids[clean].Status != BidPending || !s.Bids[clean].Stale {
		t.Fatalf("clean bid: %+v", s.Bids[clean])
	}
	if got, _ := h.m.Repo.ReadFile(s.RepoHead, "a.txt"); got != "winner\n" {
		t.Fatalf("merged content %q", got)
	}
	// The stale but clean bid still merges against the new head.
	h.must(Body{Agent: leader, Type: TxMerge, BidID: clean})
	h.attest(r[0], clean, true)
	h.attest(r[1], clean, true)
	if s.Bids[clean].Status != BidMerged {
		t.Fatal("stale clean bid did not merge")
	}
	if got, _ := h.m.Repo.ReadFile(s.RepoHead, "b.txt"); got != "other\n" {
		t.Fatalf("merged content %q", got)
	}
	if s.Reputation[r[0]].Merges != 1 || s.Reputation[r[2]].Merges != 1 {
		t.Fatalf("reputation %+v %+v", s.Reputation[r[0]], s.Reputation[r[2]])
	}
}

func TestRoleRules(t *testing.T) {
	h := newHarness(t)
	leader, r := h.roles()
	h.refuse(Body{Agent: r[0], Type: TxPostTask, Spec: "x", BaseCommit: h.m.S.RepoHead}, "only term leader")
	h.refuse(Body{Agent: leader, Type: TxPostTask, Spec: "x", BaseCommit: "bad"}, "not repo_head")
	h.refuse(Body{Agent: leader, Type: TxPostTask, BaseCommit: h.m.S.RepoHead}, "empty")
	task := h.postTask(leader)
	h.refuse(Body{Agent: leader, Type: TxSubmitBid, TaskID: task, Bundle: h.bundle(leader, map[string]string{"a.txt": "x\n"})}, "may not bid")
	id := h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
	h.refuse(Body{Agent: r[1], Type: TxWithdraw, BidID: id}, "belongs to")
	h.refuse(Body{Agent: r[1], Type: TxMerge, BidID: id}, "only term leader")
	h.refuse(Body{Agent: r[1], Type: TxAttest, BidID: id, OK: true}, "no merge is pending")
	h.must(Body{Agent: leader, Type: TxMerge, BidID: id})
	h.refuse(Body{Agent: leader, Type: TxMerge, BidID: id}, "already pending")
	tree := h.m.S.PendingMerge.Tree
	h.refuse(Body{Agent: leader, Type: TxAttest, BidID: id, OK: true, Tree: tree}, "already approved")
	h.refuse(Body{Agent: r[0], Type: TxAttest, BidID: id, OK: true, Tree: tree}, "own bid")
	h.refuse(Body{Agent: r[1], Type: TxAttest, BidID: id, OK: true, Tree: "wrong"}, "pending merge produces")
	h.refuse(Body{Agent: r[0], Type: TxWithdraw, BidID: id}, "being merged")
	h.refuse(Body{Agent: leader, Type: TxReject, BidID: id}, "being merged")
	h.refuse(Body{Agent: leader, Type: TxCloseTask, TaskID: task}, "merge in progress")
	h.attest(r[1], id, true)
	h.refuse(Body{Agent: r[1], Type: TxAttest, BidID: id, OK: true, Tree: tree}, "already attested")
}

func TestSignatureNonceAndReplay(t *testing.T) {
	h := newHarness(t)
	leader, r := h.roles()
	// Forged: leader's name, another agent's key.
	raw, _ := Sign("test", h.keys[r[0]], &Body{Agent: leader, Nonce: 1, Type: TxPostTask, Spec: "x", BaseCommit: h.m.S.RepoHead})
	if err := h.m.DeliverTx(raw); err == nil || !strings.Contains(err.Error(), "bad signature") {
		t.Fatalf("forged: %v", err)
	}
	// Cross-chain: right key, wrong chain.
	raw, _ = Sign("other", h.keys[leader], &Body{Agent: leader, Nonce: 1, Type: TxPostTask, Spec: "x", BaseCommit: h.m.S.RepoHead})
	if err := h.m.DeliverTx(raw); err == nil {
		t.Fatal("cross-chain replay accepted")
	}
	// Tampered body.
	raw, _ = Sign("test", h.keys[leader], &Body{Agent: leader, Nonce: 1, Type: TxPostTask, Spec: "x", BaseCommit: h.m.S.RepoHead})
	bad := append([]byte{}, raw...)
	bad[len(bad)-3] ^= 1
	if err := h.m.DeliverTx(bad); err == nil {
		t.Fatal("tampered body accepted")
	}
	if err := h.m.DeliverTx(raw); err != nil {
		t.Fatal(err)
	}
	h.nonce[leader] = 1
	if err := h.m.DeliverTx(raw); err == nil || !strings.Contains(err.Error(), "nonce") {
		t.Fatalf("replay: %v", err)
	}
	if err := h.m.CheckTx(raw); err == nil {
		t.Fatal("CheckTx accepted a replay")
	}
	// A failed transaction burns its nonce, so it can't be replayed once it would pass.
	h.nonce[r[0]]++
	raw, _ = Sign("test", h.keys[r[0]], &Body{Agent: r[0], Nonce: h.nonce[r[0]], Type: TxPostTask, Spec: "x", BaseCommit: h.m.S.RepoHead})
	if err := h.m.DeliverTx(raw); err == nil {
		t.Fatal("non-leader post should fail")
	}
	if err := h.m.DeliverTx(raw); err == nil || !strings.Contains(err.Error(), "nonce") {
		t.Fatalf("failed tx must burn its nonce: %v", err)
	}
	if err := h.m.CheckTx(EncodeSeed([]byte("x"))); err == nil {
		t.Fatal("seed must not enter the mempool")
	}
	if err := h.m.CheckTx([]byte("garbage")); err == nil {
		t.Fatal("garbage must not enter the mempool")
	}
}

func TestLeaderMayNotMergeOwnBidAfterRotation(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.TermBlocks = 3 })
	leader, r := h.roles()
	task := h.postTask(leader)
	var ids = map[string]uint64{}
	for i, a := range r {
		ids[a] = h.bid(a, task, map[string]string{fmt.Sprintf("f%d.txt", i): "x\n"})
	}
	h.finishTerm()
	nl := h.m.S.TermLeader
	h.refuse(Body{Agent: nl, Type: TxMerge, BidID: ids[nl]}, "own bid")
}

// finishTerm advances to the next term using real threshold shares.
func (h *harness) finishTerm() {
	h.t.Helper()
	for i := 0; !h.m.S.AwaitingSeed; i++ {
		if i > 1000 {
			h.t.Fatal("term never ended")
		}
		h.block()
	}
	h.block() // share height
	s := h.m.S
	msg := s.NextTermMessage()
	var sigs [][]byte
	for _, sh := range h.shares[:3] {
		sig, err := sh.Sign(msg)
		if err != nil {
			h.t.Fatal(err)
		}
		sigs = append(sigs, sig)
	}
	seed, err := s.Group.Recover(msg, sigs)
	if err != nil {
		h.t.Fatal(err)
	}
	if h.firstSeed == nil {
		h.firstSeed = seed
	}
	h.commit()
	h.m.BeginBlock(s.Height+1, 1000+s.Height+1)
	if err := h.m.ApplySeed(seed); err != nil {
		h.t.Fatal(err)
	}
	if err := h.m.EndBlock(); err != nil {
		h.t.Fatal(err)
	}
}

func TestRotationWindowHoldsAcrossManyTerms(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.TermBlocks = 2 })
	seen := map[string]int{}
	var hist []string
	for i := 0; i < 60; i++ {
		l := h.m.S.TermLeader
		hist = append(hist, l)
		seen[l]++
		h.finishTerm()
	}
	for i := 2; i < len(hist); i++ {
		if hist[i] == hist[i-1] || hist[i] == hist[i-2] || hist[i-1] == hist[i-2] {
			t.Fatalf("3-window violated at %d: %v", i, hist[i-2:i+1])
		}
	}
	for _, n := range names {
		if seen[n] == 0 {
			t.Fatalf("%s never led in 60 terms: %v", n, seen)
		}
	}
}

func TestDrawDependsOnSeedNotOnProposer(t *testing.T) {
	counts := map[int]int{}
	for i := 0; i < 1000; i++ {
		counts[Draw([]byte{byte(i), byte(i >> 8)}, 5, 2)]++
	}
	if counts[0] < 400 || counts[1] < 400 {
		t.Fatalf("draw looks biased: %v", counts)
	}
}

func TestSeedRules(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.TermBlocks = 2 })
	h.block()
	if err := h.m.ApplySeed([]byte("x")); err == nil {
		t.Fatal("seed accepted outside the seed height")
	}
	for !h.m.S.AwaitingSeed {
		h.block()
	}
	since := h.m.S.AwaitingSince
	if !h.m.S.ShareHeight(since+1) || h.m.S.ShareHeight(since+2) || h.m.S.SeedRequired(since+1) || !h.m.S.SeedRequired(since+2) {
		t.Fatal("share and seed heights wrong")
	}
	h.block()
	h.commit()
	h.m.BeginBlock(h.m.S.Height+1, 5000)
	if err := h.m.ApplySeed(make([]byte, 96)); err == nil {
		t.Fatal("garbage seed accepted")
	}
	// A valid signature for the wrong term must not work either.
	msg := beacon.Message("test", h.m.S.Term+5)
	var sigs [][]byte
	for _, sh := range h.shares[:3] {
		sig, _ := sh.Sign(msg)
		sigs = append(sigs, sig)
	}
	wrong, _ := h.m.S.Group.Recover(msg, sigs)
	if err := h.m.ApplySeed(wrong); err == nil {
		t.Fatal("seed for another term accepted")
	}
}

func TestStallEndsTermAndCounts(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.StallBlocks = 5; p.TermBlocks = 1000 })
	leader, r := h.roles()
	task := h.postTask(leader)
	h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
	for i := 0; i < 10 && !h.m.S.AwaitingSeed; i++ {
		h.block()
	}
	if !h.m.S.AwaitingSeed {
		t.Fatal("stall did not end the term")
	}
	if h.m.S.Reputation[leader].Stalls != 1 {
		t.Fatalf("stalls=%d", h.m.S.Reputation[leader].Stalls)
	}
	if h.m.S.TermLeader != "" {
		t.Fatal("no leader may act between terms")
	}
	h.refuse(Body{Agent: leader, Type: TxPostTask, Spec: "x", BaseCommit: h.m.S.RepoHead}, "no term leader")
}

func TestMaxMergesEndsTerm(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.MaxMergesPerTerm = 1 })
	leader, r := h.roles()
	task := h.postTask(leader)
	id := h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
	h.must(Body{Agent: leader, Type: TxMerge, BidID: id})
	h.attest(r[1], id, true)
	h.attest(r[2], id, true)
	h.block()
	if !h.m.S.AwaitingSeed {
		t.Fatal("term did not end at max merges")
	}
}

func TestPendingMergeOutlivesTermBoundary(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.TermBlocks = 3; p.AttestWindow = 6; p.BidderFallbackBlocks = 0 })
	leader, r := h.roles()
	task := h.postTask(leader)
	id := h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
	h.must(Body{Agent: leader, Type: TxMerge, BidID: id})
	for i := 0; i < 5; i++ {
		h.block()
		if h.m.S.AwaitingSeed {
			t.Fatal("term ended under a pending merge")
		}
	}
	for i := 0; i < 3 && !h.m.S.AwaitingSeed; i++ {
		h.block()
	}
	if !h.m.S.AwaitingSeed || h.m.S.PendingMerge != nil {
		t.Fatalf("expected expiry then term end: %+v", h.m.S.PendingMerge)
	}
	if h.m.S.Bids[id].Status != BidPending {
		t.Fatalf("expired bid should stay pending, got %s", h.m.S.Bids[id].Status)
	}
}

func TestTwoNoVotesReject(t *testing.T) {
	h := newHarness(t)
	leader, r := h.roles()
	task := h.postTask(leader)
	id := h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
	head := h.m.S.RepoHead
	h.must(Body{Agent: leader, Type: TxMerge, BidID: id})
	h.attest(r[1], id, false)
	h.attest(r[2], id, false)
	if h.m.S.Bids[id].Status != BidRejected || h.m.S.RepoHead != head {
		t.Fatalf("%+v", h.m.S.Bids[id])
	}
}

// With fallback off, one quiet attestor blocks every honest merge. This is the
// plan's literal rule, and it's why the fallback exists.
func TestLiteralRuleLetsOneAttestorBlockForever(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.BidderFallbackBlocks = 0; p.AttestWindow = 5 })
	leader, r := h.roles()
	task := h.postTask(leader)
	id := h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
	h.must(Body{Agent: leader, Type: TxMerge, BidID: id})
	h.attest(r[1], id, true) // r[2] is the compromised agent and stays quiet
	for i := 0; i < 8; i++ {
		h.block()
	}
	if h.m.S.Bids[id].Status == BidMerged {
		t.Fatal("expected the literal rule to stall")
	}
}

func TestFallbackDefeatsWithholdingAndNoVetoAttestor(t *testing.T) {
	for name, malicious := range map[string]func(h *harness, id uint64, mal string){
		"withhold": func(*harness, uint64, string) {},
		"vote-no":  func(h *harness, id uint64, mal string) { h.attest(mal, id, false) },
	} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t, func(p *Params) { p.AttestWindow = 10; p.BidderFallbackBlocks = 4 })
			leader, r := h.roles()
			task := h.postTask(leader)
			id := h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
			h.must(Body{Agent: leader, Type: TxMerge, BidID: id})
			h.attest(r[1], id, true)
			malicious(h, id, r[2])
			if h.m.S.Bids[id].Status == BidMerged {
				t.Fatal("fallback fired early")
			}
			for i := 0; i < 5; i++ {
				h.block()
			}
			if h.m.S.Bids[id].Status != BidMerged {
				t.Fatalf("honest merge was blocked by one agent: %+v", h.m.S.Bids[id])
			}
		})
	}
}

// A bad bid from a compromised bidder must not pass on its own vote: without a
// second attestor, leader plus bidder is only two of four.
func TestFallbackNeedsAnAttestorSoBidderPlusLeaderIsNotEnough(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.AttestWindow = 6; p.BidderFallbackBlocks = 2 })
	leader, r := h.roles()
	task := h.postTask(leader)
	id := h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
	head := h.m.S.RepoHead
	h.must(Body{Agent: leader, Type: TxMerge, BidID: id})
	for i := 0; i < 8; i++ {
		h.block()
	}
	if h.m.S.RepoHead != head || h.m.S.Bids[id].Status == BidMerged {
		t.Fatal("merged with only leader and bidder")
	}
}

func TestBidLimitsAndBundleValidation(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.MaxPendingBidsAgent = 2; p.BidCooldownBlocks = 3 })
	leader, r := h.roles()
	task := h.postTask(leader)
	h.bid(r[0], task, map[string]string{"a.txt": "1\n2\n"})
	h.refuse(Body{Agent: r[0], Type: TxSubmitBid, TaskID: task, Bundle: h.bundle(r[0], map[string]string{"a.txt": "3\n"})}, "cooldown")
	for i := 0; i < 3; i++ {
		h.block()
	}
	h.bid(r[0], task, map[string]string{"a.txt": "4\n"})
	for i := 0; i < 3; i++ {
		h.block()
	}
	h.refuse(Body{Agent: r[0], Type: TxSubmitBid, TaskID: task, Bundle: h.bundle(r[0], map[string]string{"a.txt": "5\n"})}, "pending bids")
	h.refuse(Body{Agent: r[1], Type: TxSubmitBid, TaskID: 99, Bundle: []byte("x")}, "no task")
	h.refuse(Body{Agent: r[1], Type: TxSubmitBid, TaskID: task, Bundle: []byte("not a bundle")}, "bundle")
	if n := h.m.S.NextBidID; n != 3 {
		t.Fatalf("junk created bids: next id %d", n)
	}
}

func TestBidOnStaleHeadRejectedCloseClearsPending(t *testing.T) {
	h := newHarness(t)
	leader, r := h.roles()
	task := h.postTask(leader)
	staleBundle := h.bundle(r[1], map[string]string{"b.txt": "late\n"})
	id := h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
	h.must(Body{Agent: leader, Type: TxMerge, BidID: id})
	h.attest(r[1], id, true)
	h.attest(r[2], id, true)
	h.refuse(Body{Agent: r[1], Type: TxSubmitBid, TaskID: task, Bundle: staleBundle}, "does not descend")
	other := h.bid(r[1], task, map[string]string{"b.txt": "fresh\n"})
	h.must(Body{Agent: leader, Type: TxCloseTask, TaskID: task})
	if h.m.S.Bids[other].Status != BidCleared || h.m.S.Tasks[task].Status != TaskClosed {
		t.Fatalf("close: %+v", h.m.S.Bids[other])
	}
	h.refuse(Body{Agent: r[1], Type: TxSubmitBid, TaskID: task, Bundle: h.bundle(r[1], map[string]string{"b.txt": "again\n"})}, "closed")
}

func TestStateHashStableAndSensitive(t *testing.T) {
	h := newHarness(t)
	a, _, _ := h.m.S.Hash()
	b, _, _ := h.m.S.Hash()
	if string(a) != string(b) {
		t.Fatal("hash not stable")
	}
	leader, _ := h.roles()
	h.postTask(leader)
	c, _, _ := h.m.S.Hash()
	if string(a) == string(c) {
		t.Fatal("hash ignored a state change")
	}
}

// Two nodes that see the same transactions must produce identical hashes and
// identical merge commits, including when one replays the block after a crash.
func TestTwoReplicasAgreeAndReplayIsIdempotent(t *testing.T) {
	h := newHarness(t)
	h.block() // settle the harness at a known height before replicating

	m2, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := m2.InitGenesis("test", h.genesis); err != nil {
		t.Fatal(err)
	}
	// Same seed block at the same height.
	m2.BeginBlock(1, 1001)
	if err := m2.EndBlock(); err != nil {
		t.Fatal(err)
	}
	if err := m2.CommitBlock(); err != nil {
		t.Fatal(err)
	}
	m2.BeginBlock(2, 1002)
	if err := m2.ApplySeed(h.firstSeed); err != nil {
		t.Fatal(err)
	}
	if err := m2.EndBlock(); err != nil {
		t.Fatal(err)
	}
	if err := m2.CommitBlock(); err != nil {
		t.Fatal(err)
	}
	for m2.S.Height < h.m.S.Height {
		m2.BeginBlock(m2.S.Height+1, 1000+m2.S.Height+1)
		if err := m2.EndBlock(); err != nil {
			t.Fatal(err)
		}
		if err := m2.CommitBlock(); err != nil {
			t.Fatal(err)
		}
	}
	if m2.S.TermLeader != h.m.S.TermLeader {
		t.Fatalf("leaders differ: %s %s", m2.S.TermLeader, h.m.S.TermLeader)
	}
	ha, _, _ := h.m.S.Hash()
	hb, _, _ := m2.S.Hash()
	if string(ha) != string(hb) {
		t.Fatal("replicas differ before the script even starts")
	}

	leader, r := h.roles()
	sign := func(b Body) []byte {
		h.nonce[b.Agent]++
		b.Nonce = h.nonce[b.Agent]
		raw, err := Sign("test", h.keys[b.Agent], &b)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	apply := func(m *Machine, height int64, txs [][]byte, commit bool) {
		m.BeginBlock(height, 2000+height)
		for _, tx := range txs {
			_ = m.DeliverTx(tx)
		}
		if err := m.EndBlock(); err != nil {
			t.Fatal(err)
		}
		if commit {
			if err := m.CommitBlock(); err != nil {
				t.Fatal(err)
			}
		}
	}
	both := func(txs ...[]byte) {
		h.commit()
		height := h.m.S.Height + 1
		apply(h.m, height, txs, true)
		apply(m2, height, txs, true)
		ha, _, _ := h.m.S.Hash()
		hb, _, _ := m2.S.Hash()
		if string(ha) != string(hb) {
			t.Fatalf("replicas diverged at height %d", height)
		}
	}
	both(sign(Body{Agent: leader, Type: TxPostTask, Spec: "t", BaseCommit: h.m.S.RepoHead}))
	both(sign(Body{Agent: r[0], Type: TxSubmitBid, TaskID: 1, Bundle: h.bundle(r[0], map[string]string{"a.txt": "w\n"})}))
	both(sign(Body{Agent: r[1], Type: TxSubmitBid, TaskID: 1, Bundle: h.bundle(r[1], map[string]string{"a.txt": "l\n"})}))
	both(sign(Body{Agent: leader, Type: TxMerge, BidID: 1}))
	tree := h.m.S.PendingMerge.Tree
	mergeTxs := [][]byte{
		sign(Body{Agent: r[1], Type: TxAttest, BidID: 1, OK: true, Tree: tree}),
		sign(Body{Agent: r[2], Type: TxAttest, BidID: 1, OK: true, Tree: tree}),
	}
	// Run the merge block on m2 without committing, then crash and replay it.
	_, snap, _ := m2.S.Hash()
	snapCopy := append([]byte{}, snap...)
	height := m2.S.Height + 1
	apply(m2, height, mergeTxs, false)
	wantHash, _, _ := m2.S.Hash()
	if err := m2.Restore(snapCopy); err != nil {
		t.Fatal(err)
	}
	if err := m2.Repo.DiscardStage(); err != nil {
		t.Fatal(err)
	}
	apply(m2, height, mergeTxs, true)
	gotHash, _, _ := m2.S.Hash()
	if string(gotHash) != string(wantHash) {
		t.Fatal("replay after crash produced a different state")
	}
	h.commit()
	apply(h.m, height, mergeTxs, true)
	if h.m.S.RepoHead != m2.S.RepoHead {
		t.Fatal("replay produced a different merge commit")
	}
	if h.m.S.Bids[2].Status != BidCleared {
		t.Fatalf("bid 2 should be cleared: %+v", h.m.S.Bids[2])
	}
	if got, err := m2.Repo.ReadFile(m2.S.RepoHead, "a.txt"); err != nil || got != "w\n" {
		t.Fatalf("merged content after replay: %q %v", got, err)
	}
}

// The chain starts with no leader, so term 1 can't be ground from genesis data.
func TestTerm1ComesFromAThresholdSignature(t *testing.T) {
	h := newHarness(t)
	if h.m.S.Term != 1 || h.m.S.TermLeader == "" || h.m.S.Height != 2 {
		t.Fatalf("term %d leader %q height %d", h.m.S.Term, h.m.S.TermLeader, h.m.S.Height)
	}
	m2, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := m2.InitGenesis("test", h.genesis); err != nil {
		t.Fatal(err)
	}
	if m2.S.TermLeader != "" || !m2.S.ShareHeight(1) || !m2.S.SeedRequired(2) {
		t.Fatalf("a fresh chain must wait for a seed: %+v", m2.S.TermLeader)
	}
}

func TestFailedBidStillCostsTheCooldown(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.BidCooldownBlocks = 5 })
	leader, r := h.roles()
	task := h.postTask(leader)
	h.refuse(Body{Agent: r[0], Type: TxSubmitBid, TaskID: task, Bundle: []byte("junk")}, "bundle")
	h.refuse(Body{Agent: r[0], Type: TxSubmitBid, TaskID: task, Bundle: []byte("junk")}, "cooldown")
}

func TestStaleBundleRefusedBeforeGit(t *testing.T) {
	h := newHarness(t)
	leader, r := h.roles()
	task := h.postTask(leader)
	stale := h.bundle(r[1], map[string]string{"b.txt": "late\n"})
	id := h.bid(r[0], task, map[string]string{"a.txt": "x\n"})
	h.must(Body{Agent: leader, Type: TxMerge, BidID: id})
	h.attest(r[1], id, true)
	h.attest(r[2], id, true)
	body := Body{Agent: r[1], Nonce: h.nonce[r[1]] + 1, Type: TxSubmitBid, TaskID: task, Bundle: stale}
	raw, err := Sign("test", h.keys[r[1]], &body)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.m.CheckTx(raw); err == nil || !strings.Contains(err.Error(), "descend") {
		t.Fatalf("CheckTx should refuse a stale bundle cheaply: %v", err)
	}
}

// A bid-and-withdraw loop must not grow what every node hashes each block.
func TestStateStaysBounded(t *testing.T) {
	h := newHarness(t, func(p *Params) { p.KeepSettled = 3 })
	leader, r := h.roles()
	task := h.postTask(leader)
	bundle := h.bundle(r[0], map[string]string{"a.txt": "x\n"})
	for i := 0; i < 12; i++ {
		h.must(Body{Agent: r[0], Type: TxSubmitBid, TaskID: task, Bundle: bundle})
		h.must(Body{Agent: r[0], Type: TxWithdraw, BidID: h.m.S.NextBidID - 1})
	}
	h.must(Body{Agent: leader, Type: TxCloseTask, TaskID: task})
	h.block()
	if n := len(h.m.S.Bids); n != 3 {
		t.Fatalf("%d settled bids kept, want 3", n)
	}
	// Closed tasks with no bids left get pruned as well.
	for i := 0; i < 8; i++ {
		t2 := h.postTask(leader)
		h.must(Body{Agent: leader, Type: TxCloseTask, TaskID: t2})
		h.block()
	}
	if n := len(h.m.S.Tasks); n > 4 {
		t.Fatalf("%d tasks kept", n)
	}
	h.refuse(Body{Agent: r[1], Type: TxSubmitBid, TaskID: 99, Note: strings.Repeat("x", 3000)}, "no task")
}

func TestAdmitToBlockLimitsSenders(t *testing.T) {
	h := newHarness(t)
	leader, _ := h.roles()
	seen := map[string]bool{}
	if err := h.m.S.AdmitToBlock(&Body{Agent: leader, Nonce: 1}, seen); err != nil {
		t.Fatal(err)
	}
	if err := h.m.S.AdmitToBlock(&Body{Agent: leader, Nonce: 1}, seen); err == nil {
		t.Fatal("second transaction from one sender admitted")
	}
	if err := h.m.S.AdmitToBlock(&Body{Agent: "grok", Nonce: 9}, map[string]bool{}); err == nil {
		t.Fatal("future nonce admitted")
	}
}

func TestGenesisValidation(t *testing.T) {
	group, _, err := beacon.TrustedDeal(4, 3)
	if err != nil {
		t.Fatal(err)
	}
	p := DefaultParams()
	p.GitVersion = "x"
	bundle, commit, err := gitx.Snapshot("", 1)
	if err != nil {
		t.Fatal(err)
	}
	good := func() []Agent {
		var out []Agent
		for i, n := range names {
			out = append(out, Agent{ID: n, ValidatorAddr: fmt.Sprintf("v%d", i), BLSIndex: i})
		}
		return out
	}
	for name, mutate := range map[string]func(*Genesis){
		"three agents":   func(g *Genesis) { g.Agents = g.Agents[:3] },
		"duplicate id":   func(g *Genesis) { g.Agents[1].ID = g.Agents[0].ID },
		"duplicate bls":  func(g *Genesis) { g.Agents[1].BLSIndex = 0 },
		"duplicate addr": func(g *Genesis) { g.Agents[1].ValidatorAddr = "v0" },
		"bls range":      func(g *Genesis) { g.Agents[1].BLSIndex = 9 },
		"no group":       func(g *Genesis) { g.Group = nil },
		"wrong commit":   func(g *Genesis) { g.InitialCommit = "ab" },
		"unpinned git":   func(g *Genesis) { g.Params.GitVersion = "" },
	} {
		m, err := New(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		g := &Genesis{Agents: good(), Group: group, Params: p, InitialBundle: bundle, InitialCommit: commit}
		mutate(g)
		if err := m.InitGenesis("c", g); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
