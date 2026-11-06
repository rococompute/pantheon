// Package market is the deterministic state machine at the heart of Pantheon:
// who may post, bid, merge and attest, and what happens when they do. It has no
// clock, network or randomness of its own. Everything comes from the block.
package market

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"sort"

	"pantheon/internal/beacon"
	"pantheon/internal/gitx"
)

// Bid statuses.
const (
	BidPending   = "pending"
	BidMerged    = "merged"
	BidCleared   = "cleared"
	BidRejected  = "rejected"
	BidWithdrawn = "withdrawn"
)

// Task statuses.
const (
	TaskOpen   = "open"
	TaskClosed = "closed"
)

// Agent is one market participant, fixed at genesis.
type Agent struct {
	ID            string `json:"id"`
	AppPubKey     []byte `json:"app_pub_key"`
	ValidatorAddr string `json:"validator_addr"` // hex CometBFT address
	BLSIndex      int    `json:"bls_index"`
}

// Params are consensus parameters, fixed at genesis.
type Params struct {
	TermBlocks       int64 `json:"term_blocks"`
	MaxMergesPerTerm int   `json:"max_merges_per_term"`
	StallBlocks      int64 `json:"stall_blocks"`
	AttestWindow     int64 `json:"attest_window"`
	// BidderFallbackBlocks: once this many blocks have passed since merge, the
	// bidder's own approval counts toward 3-of-4. 0 disables it, in which case
	// one withholding attestor can block every merge it is asked to attest.
	BidderFallbackBlocks int64       `json:"bidder_fallback_blocks"`
	BundleLimits         gitx.Limits `json:"bundle_limits"`
	MaxPendingBidsAgent  int         `json:"max_pending_bids_per_agent"`
	BidCooldownBlocks    int64       `json:"bid_cooldown_blocks"`
	MaxOpenTasks         int         `json:"max_open_tasks"`
	MaxTextBytes         int         `json:"max_text_bytes"`
	// KeepSettled bounds settled bids and closed tasks kept in state, which every
	// node hashes each block. Older ones remain on the chain, the permanent record.
	KeepSettled int    `json:"keep_settled"`
	GitVersion  string `json:"git_version"`
}

// DefaultParams suit about one block per second and LLM-paced agents.
func DefaultParams() Params {
	return Params{
		TermBlocks:           900,
		MaxMergesPerTerm:     3,
		StallBlocks:          300,
		AttestWindow:         300,
		BidderFallbackBlocks: 150,
		BundleLimits:         gitx.Limits{MaxBundleBytes: 512 << 10, MaxUnpackedBytes: 16 << 20, MaxPackObjects: 8192},
		MaxPendingBidsAgent:  4,
		BidCooldownBlocks:    30,
		MaxOpenTasks:         4,
		MaxTextBytes:         8 << 10,
		KeepSettled:          256,
	}
}

// Validate rejects parameter sets that break the protocol's assumptions.
func (p Params) Validate() error {
	switch {
	case p.TermBlocks <= 0 || p.StallBlocks <= 0 || p.AttestWindow <= 0 || p.MaxMergesPerTerm <= 0:
		return fmt.Errorf("term_blocks, stall_blocks, attest_window and max_merges_per_term must be positive")
	case p.BidderFallbackBlocks < 0 || p.BidderFallbackBlocks >= p.AttestWindow && p.BidderFallbackBlocks != 0:
		return fmt.Errorf("bidder_fallback_blocks must be 0 or below attest_window (%d)", p.AttestWindow)
	case p.GitVersion == "":
		return fmt.Errorf("git_version must be pinned")
	case p.BundleLimits.MaxBundleBytes <= 0 || p.BundleLimits.MaxUnpackedBytes <= 0 || p.BundleLimits.MaxPackObjects <= 0:
		return fmt.Errorf("bundle_limits must all be positive")
	case p.MaxPendingBidsAgent <= 0 || p.MaxOpenTasks <= 0 || p.MaxTextBytes <= 0 || p.KeepSettled <= 0:
		return fmt.Errorf("max_pending_bids_per_agent, max_open_tasks, max_text_bytes and keep_settled must be positive")
	}
	return nil
}

// Task is a unit of work posted by a term leader.
type Task struct {
	ID         uint64 `json:"id"`
	Spec       string `json:"spec"`
	BaseCommit string `json:"base_commit"`
	PostedBy   string `json:"posted_by"`
	Term       uint64 `json:"term"`
	Height     int64  `json:"height"`
	Status     string `json:"status"`
}

// Bid is one agent's patch for a task. The bundle itself lives in the
// transaction and on disk, addressed by BundleHash.
type Bid struct {
	ID         uint64 `json:"id"`
	TaskID     uint64 `json:"task_id"`
	Bidder     string `json:"bidder"`
	BundleHash string `json:"bundle_hash"`
	Commit     string `json:"commit"`
	Note       string `json:"note"`
	Height     int64  `json:"height"`
	Status     string `json:"status"`
	Stale      bool   `json:"stale,omitempty"` // head moved since submission, still merges cleanly
	Reason     string `json:"reason,omitempty"`
	// Attestations are the votes from the proposal that settled this bid.
	Attestations map[string]Attestation `json:"attestations,omitempty"`
}

// Attestation is one agent's verdict on a pending merge.
type Attestation struct {
	OK       bool   `json:"ok"`
	CIDigest string `json:"ci_digest"`
}

// MergeProposal is a merge waiting for attestations.
type MergeProposal struct {
	BidID        uint64                 `json:"bid_id"`
	Proposer     string                 `json:"proposer"`
	ProposedAt   int64                  `json:"proposed_at"`
	Tree         string                 `json:"tree"` // the exact merge result being attested
	Attestations map[string]Attestation `json:"attestations"`
}

// Stats is an agent's public track record.
type Stats struct {
	Merges     uint64 `json:"merges"`
	Cleared    uint64 `json:"cleared"`
	Rejected   uint64 `json:"rejected"`
	Stalls     uint64 `json:"stalls"`
	TermsLed   uint64 `json:"terms_led"`
	AttestsOK  uint64 `json:"attests_ok"`
	AttestsNo  uint64 `json:"attests_no"`
	BadTxs     uint64 `json:"bad_txs"`
	BidsPosted uint64 `json:"bids_posted"`
}

// State is everything consensus agrees on. Its canonical JSON hashes to the app
// hash, and repo_head being in here commits every node to the same repository.
type State struct {
	ChainID        string            `json:"chain_id"`
	Height         int64             `json:"height"`
	Time           int64             `json:"time"`
	Term           uint64            `json:"term"`
	TermLeader     string            `json:"term_leader"` // empty between terms
	LeaderHistory  []string          `json:"leader_history"`
	TermStart      int64             `json:"term_start"`
	LastActivity   int64             `json:"last_activity"`
	MergesThisTerm int               `json:"merges_this_term"`
	AwaitingSeed   bool              `json:"awaiting_seed"`
	AwaitingSince  int64             `json:"awaiting_since"`
	LastSeed       []byte            `json:"last_seed,omitempty"`
	RepoHead       string            `json:"repo_head"`
	NextTaskID     uint64            `json:"next_task_id"`
	NextBidID      uint64            `json:"next_bid_id"`
	Tasks          map[uint64]*Task  `json:"tasks"`
	Bids           map[uint64]*Bid   `json:"bids"`
	PendingMerge   *MergeProposal    `json:"pending_merge"`
	Nonces         map[string]uint64 `json:"nonces"`
	LastBid        map[string]int64  `json:"last_bid"`
	Reputation     map[string]*Stats `json:"reputation"`
	Agents         []Agent           `json:"agents"`
	Group          *beacon.Group     `json:"group"`
	Params         Params            `json:"params"`
}

// Genesis is the app_state section of the CometBFT genesis file.
type Genesis struct {
	Agents        []Agent       `json:"agents"`
	Group         *beacon.Group `json:"group"`
	Params        Params        `json:"params"`
	InitialBundle []byte        `json:"initial_bundle"`
	InitialCommit string        `json:"initial_commit"`
}

// Hash is the app hash: sha256 of the canonical encoding. Go's encoding/json
// sorts map keys and struct fields are in declaration order, so every node
// running the same binary encodes identical bytes.
func (s *State) Hash() ([]byte, []byte, error) {
	raw, err := json.Marshal(s)
	if err != nil {
		return nil, nil, err
	}
	h := sha256.Sum256(raw)
	return h[:], raw, nil
}

// Agent returns the named agent or nil.
func (s *State) Agent(id string) *Agent {
	for i := range s.Agents {
		if s.Agents[i].ID == id {
			return &s.Agents[i]
		}
	}
	return nil
}

// AgentByValidator finds the agent running a validator address.
func (s *State) AgentByValidator(hexAddr string) *Agent {
	for i := range s.Agents {
		if s.Agents[i].ValidatorAddr == hexAddr {
			return &s.Agents[i]
		}
	}
	return nil
}

// PendingBids returns pending bids in id order.
func (s *State) PendingBids() []*Bid {
	var out []*Bid
	for _, b := range s.Bids {
		if b.Status == BidPending {
			out = append(out, b)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// OpenTasks returns open tasks in id order.
func (s *State) OpenTasks() []*Task {
	var out []*Task
	for _, t := range s.Tasks {
		if t.Status == TaskOpen {
			out = append(out, t)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Eligible returns the agents who may lead the next term, in sorted order: all
// agents minus those who led the last two terms.
func (s *State) Eligible() []string {
	recent := map[string]bool{}
	n := len(s.LeaderHistory)
	for i := n - 1; i >= 0 && i >= n-2; i-- {
		recent[s.LeaderHistory[i]] = true
	}
	var out []string
	for _, a := range s.Agents {
		if !recent[a.ID] {
			out = append(out, a.ID)
		}
	}
	sort.Strings(out)
	return out
}

// Restore replaces the machine's state from its canonical encoding.
func (m *Machine) Restore(raw []byte) error {
	var s State
	if err := json.Unmarshal(raw, &s); err != nil {
		return err
	}
	m.S = &s
	return nil
}
