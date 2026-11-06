package e2e

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pantheon/internal/devnet"
	"pantheon/internal/gitx"
	"pantheon/internal/market"
)

// The minimal deliverable: task, three bids, merge with quorum, conflict
// clearing, all over real consensus with all four nodes agreeing.
func TestTaskToMergeOverConsensus(t *testing.T) {
	t.Parallel()
	n := start(t, opts{params: func(p *market.Params) { p.TermBlocks = 2000 }})
	leader, r := n.roles()
	task := n.postTask(leader)
	win := n.bid(r[0], task, map[string]string{"a.txt": "winner\n"})
	lose := n.bid(r[1], task, map[string]string{"a.txt": "loser\n"})
	other := n.bid(r[2], task, map[string]string{"b.txt": "other\n"})

	before := n.state().RepoHead
	n.must(leader, market.Body{Type: market.TxMerge, BidID: win})
	n.attest(r[1], win, true)
	if n.state().RepoHead != before {
		t.Fatal("head moved before quorum")
	}
	n.attest(r[2], win, true)
	s := n.waitFor("merge", 10*time.Second, func(s *market.State) bool { return s.RepoHead != before })
	if s.Bids[win].Status != market.BidMerged {
		t.Fatalf("winner %+v", s.Bids[win])
	}
	if s.Bids[lose].Status != market.BidCleared {
		t.Fatalf("conflicting bid should be cleared: %+v", s.Bids[lose])
	}
	if s.Bids[other].Status != market.BidPending || !s.Bids[other].Stale {
		t.Fatalf("clean bid should stay pending and stale: %+v", s.Bids[other])
	}
	n.agreeAll()

	// All four repos must contain the merged content at the same commit.
	for _, a := range devnet.DefaultAgents {
		repo := &gitx.Repo{Dir: filepath.Join(n.dir, a, "data", "market", "repo.git")}
		got, err := repo.ReadFile(s.RepoHead, "a.txt")
		if err != nil || got != "winner\n" {
			t.Fatalf("%s: content %q err %v", a, got, err)
		}
	}
	// A cleared bidder can resubmit on the new head.
	n.must(r[1], market.Body{Type: market.TxSubmitBid, TaskID: task, Bundle: n.bundle(r[1], map[string]string{"a.txt": "loser rebased\n"})})
	n.agreeAll()
}

// Terms must rotate on real BLS seeds with the 3-window rule intact, with shares
// flowing through vote extensions.
func TestLeaderRotationOverConsensus(t *testing.T) {
	t.Parallel()
	n := start(t, opts{params: func(p *market.Params) { p.TermBlocks = 8 }})
	seen := map[uint64]string{}
	var seeds = map[string]bool{}
	s := n.waitFor("six terms", 120*time.Second, func(s *market.State) bool {
		if s.TermLeader != "" && seen[s.Term] == "" {
			seen[s.Term] = s.TermLeader
			seeds[string(s.LastSeed)] = true
		}
		return s.Term >= 7
	})
	h := s.LeaderHistory
	for i := 2; i < len(h); i++ {
		if h[i] == h[i-1] || h[i] == h[i-2] {
			t.Fatalf("3-window broken: %v", h)
		}
	}
	if len(seeds) < 5 {
		t.Fatalf("seeds repeated, randomness is not advancing: %d", len(seeds))
	}
	n.agreeAll()
}

// f=1 crash: the network keeps deciding with 3 of 4, including merges and term
// changes, and the dead node catches up to the same hash afterward.
func TestOneNodeDownThenCatchUp(t *testing.T) {
	t.Parallel()
	n := start(t, opts{params: func(p *market.Params) {
		p.TermBlocks = 1000
		p.StallBlocks = 30
		p.AttestWindow = 60
		p.BidderFallbackBlocks = 10
	}})
	victim := n.state().TermLeader
	n.kill(victim)

	// A term that still has the dead leader has to time out, then the rest go on.
	termAtKill := n.state().Term
	s := n.waitFor("rotation past the dead leader", 90*time.Second, func(s *market.State) bool {
		return s.Term > termAtKill && s.TermLeader != "" && s.TermLeader != victim
	})
	leader := s.TermLeader
	var rest []string
	for _, a := range devnet.DefaultAgents {
		if a != leader && a != victim {
			rest = append(rest, a)
		}
	}
	task := n.postTask(leader)
	id := n.bid(rest[0], task, map[string]string{"a.txt": "while one node is down\n"})
	n.must(leader, market.Body{Type: market.TxMerge, BidID: id})
	n.attest(rest[1], id, true)
	// The dead agent can't attest. The fallback is what lets this merge finish.
	s = n.waitFor("merge without the dead agent", 60*time.Second, func(s *market.State) bool { return s.Bids[id].Status == market.BidMerged })

	n.startNode(victim)
	n.waitFor("victim to catch up", 90*time.Second, func(*market.State) bool {
		st, err := n.senders[victim].State(ctx(t, 5*time.Second))
		return err == nil && st.Height >= s.Height
	})
	n.agreeAll()
}

// A compromised agent can only do damage through transactions, and each attempt
// must bounce off the mempool or the state machine while honest work proceeds.
func TestCompromisedAgentCannotForceMerges(t *testing.T) {
	t.Parallel()
	n := start(t, opts{params: func(p *market.Params) { p.TermBlocks = 3000 }})
	leader, r := n.roles()
	mal := r[2]
	task := n.postTask(leader)

	bomb := n.bundle(mal, map[string]string{"a.txt": strings.Repeat("0", 40<<20)})
	n.refused(mal, market.Body{Type: market.TxSubmitBid, TaskID: task, Bundle: bomb}, "budget")
	n.refused(mal, market.Body{Type: market.TxSubmitBid, TaskID: task, Bundle: []byte("garbage")}, "bundle")
	n.refused(mal, market.Body{Type: market.TxPostTask, Spec: "evil", BaseCommit: n.state().RepoHead}, "only term leader")
	n.refused(mal, market.Body{Type: market.TxMerge, BidID: 1}, "only term leader")

	evil := n.bid(mal, task, map[string]string{"a.txt": "backdoor\n"})
	good := n.bid(r[0], task, map[string]string{"b.txt": "good\n"})
	n.refused(mal, market.Body{Type: market.TxMerge, BidID: evil}, "only term leader")
	n.refused(mal, market.Body{Type: market.TxAttest, BidID: evil, OK: true, Tree: "x"}, "no merge is pending")

	// Honest leader proposes the evil bid, honest attestors refuse: rejected.
	head := n.state().RepoHead
	n.must(leader, market.Body{Type: market.TxMerge, BidID: evil})
	n.refused(mal, market.Body{Type: market.TxAttest, BidID: evil, OK: true, Tree: n.state().PendingMerge.Tree}, "own bid")
	n.attest(r[0], evil, false)
	n.attest(r[1], evil, false)
	s := n.waitFor("rejection", 10*time.Second, func(s *market.State) bool { return s.Bids[evil].Status == market.BidRejected })
	if s.RepoHead != head {
		t.Fatal("evil bid changed the head")
	}
	// Good work still merges: the compromised attestor's "no" is not a veto.
	n.must(leader, market.Body{Type: market.TxMerge, BidID: good})
	n.attest(r[1], good, true)
	n.attest(mal, good, false)
	n.waitFor("fallback merge past the malicious no", 60*time.Second, func(s *market.State) bool { return s.Bids[good].Status == market.BidMerged })
	n.agreeAll()
}

// One validator misbehaving at the consensus layer must not stop rotation, and
// its behavior must not change what honest nodes agree on.
func TestByzantineValidatorModes(t *testing.T) {
	// What honest nodes must log, proving the fault really fired and was refused.
	// A test that passes because the fault never happened would prove nothing.
	evidence := map[string]string{
		"withhold-shares": "rejecting vote extension",
		"bad-shares":      "rejecting vote extension",
		"omit-seed":       "refusing proposal without the required seed",
		"garbage-seed":    "refusing proposal with invalid seed",
		"junk-proposal":   "refusing proposal with junk tx",
		"double-tx":       "refusing proposal over the block-space limit",
	}
	for mode, want := range evidence {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			n := start(t, opts{
				// Term period is term_blocks+2. Keep it coprime with the 4-validator
				// proposer rotation, or the same validator proposes every seed block
				// and the seed faults under test never fire.
				params: func(p *market.Params) { p.TermBlocks = 7 },
				byz:    map[string]string{"muse": mode},
			})
			// Seed faults only bite when muse is proposer at a seed height, so keep
			// rotating until the evidence shows up.
			n.waitFor("evidence of "+mode, 240*time.Second, func(*market.State) bool { return n.honestLogged(want, "muse") })
			s := n.waitFor("four more terms", 180*time.Second, func(s *market.State) bool { return s.Term >= 5 })
			h := s.LeaderHistory
			for i := 2; i < len(h); i++ {
				if h[i] == h[i-1] || h[i] == h[i-2] {
					t.Fatalf("3-window broken: %v", h)
				}
			}
			n.waitFor("market still takes transactions", 60*time.Second, func(st *market.State) bool {
				if st.TermLeader == "" {
					return false
				}
				res, err := n.senders[st.TermLeader].Send(ctx(t, 20*time.Second), market.Body{Type: market.TxPostTask, Spec: "still alive", BaseCommit: st.RepoHead})
				return err == nil && res.Err() == nil // the term may turn over mid-send: just retry
			})
			n.agreeAll()
		})
	}
}
