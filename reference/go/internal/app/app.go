// Package app adapts the market state machine to CometBFT's ABCI 2.0 interface,
// including the vote extensions that carry threshold randomness.
package app

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	abci "github.com/cometbft/cometbft/abci/types"
	cryptoenc "github.com/cometbft/cometbft/crypto/encoding"
	cmtlog "github.com/cometbft/cometbft/libs/log"

	"pantheon/internal/beacon"
	"pantheon/internal/gitx"
	"pantheon/internal/market"
)

// Fault-injection modes for adversarial tests, selected by PANTHEON_TEST_BYZ.
// An honest deployment never sets this.
const (
	ByzWithholdShares = "withhold-shares" // vote with no seed share
	ByzBadShares      = "bad-shares"      // vote with a garbage seed share
	ByzOmitSeed       = "omit-seed"       // propose blocks without the required seed
	ByzGarbageSeed    = "garbage-seed"    // propose blocks with an invalid seed
	ByzJunkProposal   = "junk-proposal"   // stuff unsigned junk into proposals
	ByzDoubleTx       = "double-tx"       // include one sender's tx twice in a proposal
)

// App is one node's market application.
type App struct {
	abci.BaseApplication

	mu        sync.Mutex
	dir       string
	m         *market.Machine
	share     *beacon.Share
	byz       map[string]bool
	logger    cmtlog.Logger
	hash      []byte // app hash of the block being finalized
	raw       []byte // canonical state of the block being finalized
	committed []byte // canonical state last persisted: what Query serves
	lastHash  []byte
	lastH     int64
	seenNew   map[string]int // new mempool entries per agent since the last commit
}

// New opens an app over a data directory, resuming from any saved state.
func New(dir string, share *beacon.Share, logger cmtlog.Logger) (*App, error) {
	m, err := market.New(dir)
	if err != nil {
		return nil, err
	}
	a := &App{dir: dir, m: m, share: share, byz: map[string]bool{}, logger: logger, seenNew: map[string]int{}}
	for _, f := range strings.Split(os.Getenv("PANTHEON_TEST_BYZ"), ",") {
		if f != "" {
			a.byz[f] = true
			logger.Error("FAULT INJECTION ENABLED: this node is deliberately misbehaving", "mode", f)
		}
	}
	raw, err := os.ReadFile(a.statePath())
	if os.IsNotExist(err) {
		return a, m.Recover()
	}
	if err != nil {
		return nil, err
	}
	if err := m.Restore(raw); err != nil {
		return nil, fmt.Errorf("corrupt %s: %w", a.statePath(), err)
	}
	if err := m.Recover(); err != nil {
		return nil, fmt.Errorf("recovering repo after restart: %w", err)
	}
	h, canonical, err := m.S.Hash()
	if err != nil {
		return nil, err
	}
	if err := checkGit(m.S.Params.GitVersion); err != nil {
		return nil, err
	}
	a.lastHash, a.committed, a.lastH = h, canonical, m.S.Height
	return a, nil
}

func (a *App) statePath() string { return filepath.Join(a.dir, "state.json") }

func checkGit(want string) error {
	got, err := gitx.Version()
	if err != nil {
		return fmt.Errorf("git is required to run a node: %w", err)
	}
	if got != want {
		return fmt.Errorf("git version mismatch: this chain pins git %s (params.git_version) but this host has %s. "+
			"Different versions may merge differently and fork the chain. Install git %s, or put it first on PATH", want, got, want)
	}
	return nil
}

// Info tells CometBFT where the app is, so it replays only what's missing.
func (a *App) Info(context.Context, *abci.RequestInfo) (*abci.ResponseInfo, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return &abci.ResponseInfo{Data: "pantheon", Version: "1", AppVersion: 1, LastBlockHeight: a.lastH, LastBlockAppHash: a.lastHash}, nil
}

// InitChain loads the market from the genesis app_state.
func (a *App) InitChain(_ context.Context, req *abci.RequestInitChain) (*abci.ResponseInitChain, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	var g market.Genesis
	if err := json.Unmarshal(req.AppStateBytes, &g); err != nil {
		return nil, fmt.Errorf("genesis app_state: %w", err)
	}
	if err := checkGit(g.Params.GitVersion); err != nil {
		return nil, err
	}
	if err := checkValidators(&g, req.Validators); err != nil {
		return nil, err
	}
	if err := a.m.InitGenesis(req.ChainId, &g); err != nil {
		return nil, err
	}
	h, raw, err := a.m.S.Hash()
	if err != nil {
		return nil, err
	}
	a.committed = raw
	return &abci.ResponseInitChain{AppHash: h}, nil
}

// checkValidators ties market agents to CometBFT validators. A mismatch would
// otherwise only surface later, as shares nobody can attribute.
func checkValidators(g *market.Genesis, vals []abci.ValidatorUpdate) error {
	if len(vals) != len(g.Agents) {
		return fmt.Errorf("genesis has %d validators and %d agents: every agent runs exactly one validator", len(vals), len(g.Agents))
	}
	want := map[string]bool{}
	for _, ag := range g.Agents {
		want[ag.ValidatorAddr] = true
	}
	for _, v := range vals {
		pub, err := cryptoenc.PubKeyFromProto(v.PubKey)
		if err != nil {
			return err
		}
		if !want[hex.EncodeToString(pub.Address())] {
			return fmt.Errorf("validator %s matches no agent's validator_addr in app_state", pub.Address())
		}
		if v.Power != 10 {
			return fmt.Errorf("validator %s has power %d: all must be equal at 10 for 3-of-4 to hold", pub.Address(), v.Power)
		}
	}
	return nil
}

// maxUnconfirmedPerAgent is a local limit on new mempool entries per block. It
// isn't consensus, and it stops one agent crowding out everyone else's
// transactions with a flood of validly signed same-nonce bundles.
const maxUnconfirmedPerAgent = 4

// CheckTx filters the mempool.
func (a *App) CheckTx(_ context.Context, req *abci.RequestCheckTx) (*abci.ResponseCheckTx, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.m.CheckTx(req.Tx); err != nil {
		return &abci.ResponseCheckTx{Code: 1, Log: err.Error()}, nil
	}
	if req.Type == abci.CheckTxType_New {
		// CheckTx already verified this, so Decode can't fail here.
		if b, err := a.m.S.Decode(req.Tx); err == nil {
			if a.seenNew[b.Agent] >= maxUnconfirmedPerAgent {
				return &abci.ResponseCheckTx{Code: 1, Log: fmt.Sprintf("agent %s is over its limit of %d new transactions per block: wait for the next block", b.Agent, maxUnconfirmedPerAgent)}, nil
			}
			a.seenNew[b.Agent]++
		}
	}
	return &abci.ResponseCheckTx{Code: abci.CodeTypeOK}, nil
}

// PrepareProposal adds the combined seed when one is due and drops anything an
// honest validator's ProcessProposal would refuse.
func (a *App) PrepareProposal(_ context.Context, req *abci.RequestPrepareProposal) (*abci.ResponsePrepareProposal, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	s := a.m.S
	var out [][]byte
	used := int64(0)
	if s.SeedRequired(req.Height) && !a.byz[ByzOmitSeed] {
		if a.byz[ByzGarbageSeed] {
			out = append(out, market.EncodeSeed(bytes.Repeat([]byte{0xab}, 96)))
		} else if sig, err := a.combineSeed(req.LocalLastCommit); err != nil {
			// Others will refuse this proposal and the next round's proposer retries.
			a.logger.Error("cannot combine seed shares", "height", req.Height, "err", err)
		} else {
			out = append(out, market.EncodeSeed(sig))
		}
		for _, tx := range out {
			used += int64(len(tx))
		}
	}
	if a.byz[ByzJunkProposal] {
		out = append(out, []byte("junk that nobody signed"))
	}
	seen := map[string]bool{}
	for _, tx := range req.Txs {
		if market.IsSeed(tx) {
			continue
		}
		b, err := s.Decode(tx)
		if err != nil || s.AdmitToBlock(b, seen) != nil {
			continue
		}
		if used+int64(len(tx)) > req.MaxTxBytes {
			delete(seen, b.Agent)
			continue
		}
		used += int64(len(tx))
		out = append(out, tx)
	}
	if a.byz[ByzDoubleTx] {
		out = append(out, a.signedDuplicate()...)
	}
	return &abci.ResponsePrepareProposal{Txs: out}, nil
}

// signedDuplicate forges nothing: it uses this node's own agent key, if a test
// provided one, to offer two transactions with the same nonce.
func (a *App) signedDuplicate() [][]byte {
	raw, err := os.ReadFile(os.Getenv("PANTHEON_TEST_KEY"))
	if err != nil {
		return nil
	}
	var k struct {
		Agent   string `json:"agent"`
		ChainID string `json:"chain_id"`
		PrivKey []byte `json:"priv_key"`
	}
	if json.Unmarshal(raw, &k) != nil {
		return nil
	}
	body := &market.Body{Agent: k.Agent, Nonce: a.m.S.Nonces[k.Agent] + 1, Type: market.TxWithdraw, BidID: 1}
	one, err := market.Sign(k.ChainID, k.PrivKey, body)
	if err != nil {
		return nil
	}
	body.BidID = 2
	two, err := market.Sign(k.ChainID, k.PrivKey, body)
	if err != nil {
		return nil
	}
	return [][]byte{one, two}
}

func (a *App) combineSeed(c abci.ExtendedCommitInfo) ([]byte, error) {
	s := a.m.S
	msg := s.NextTermMessage()
	var shares [][]byte
	for _, v := range c.Votes {
		if len(v.VoteExtension) == 0 {
			continue
		}
		ag := s.AgentByValidator(hex.EncodeToString(v.Validator.Address))
		if ag == nil {
			continue
		}
		if err := s.Group.VerifyShare(msg, v.VoteExtension, ag.BLSIndex); err != nil {
			a.logger.Error("ignoring invalid seed share", "agent", ag.ID, "err", err)
			continue
		}
		shares = append(shares, v.VoteExtension)
	}
	if len(shares) < s.Group.T {
		return nil, fmt.Errorf("only %d valid shares, need %d", len(shares), s.Group.T)
	}
	return s.Group.Recover(msg, shares)
}

// ProcessProposal refuses blocks that skip a due seed, carry an invalid one, or
// contain transactions nobody signed. Semantic failures are fine: they are
// recorded on chain against their signer.
func (a *App) ProcessProposal(_ context.Context, req *abci.RequestProcessProposal) (*abci.ResponseProcessProposal, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	reject := &abci.ResponseProcessProposal{Status: abci.ResponseProcessProposal_REJECT}
	s := a.m.S
	txs := req.Txs
	if s.SeedRequired(req.Height) {
		if len(txs) == 0 || !market.IsSeed(txs[0]) {
			a.logger.Error("refusing proposal without the required seed", "height", req.Height)
			return reject, nil
		}
		if err := s.VerifySeed(market.SeedSig(txs[0])); err != nil {
			a.logger.Error("refusing proposal with invalid seed", "height", req.Height, "err", err)
			return reject, nil
		}
		txs = txs[1:]
	}
	seen := map[string]bool{}
	for _, tx := range txs {
		if market.IsSeed(tx) {
			a.logger.Error("refusing proposal with unexpected seed", "height", req.Height)
			return reject, nil
		}
		b, err := s.Decode(tx)
		if err != nil {
			a.logger.Error("refusing proposal with junk tx", "height", req.Height, "err", err)
			return reject, nil
		}
		if err := s.AdmitToBlock(b, seen); err != nil {
			a.logger.Error("refusing proposal over the block-space limit", "height", req.Height, "err", err)
			return reject, nil
		}
	}
	return &abci.ResponseProcessProposal{Status: abci.ResponseProcessProposal_ACCEPT}, nil
}

// ExtendVote attaches this validator's seed share, only on the one height after
// a term ended.
func (a *App) ExtendVote(_ context.Context, req *abci.RequestExtendVote) (*abci.ResponseExtendVote, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	s := a.m.S
	if !s.ShareHeight(req.Height) || a.share == nil || a.byz[ByzWithholdShares] {
		return &abci.ResponseExtendVote{}, nil
	}
	if a.byz[ByzBadShares] {
		return &abci.ResponseExtendVote{VoteExtension: bytes.Repeat([]byte{0xcd}, 98)}, nil
	}
	sig, err := a.share.Sign(s.NextTermMessage())
	if err != nil {
		return nil, err
	}
	return &abci.ResponseExtendVote{VoteExtension: sig}, nil
}

// VerifyVoteExtension requires a valid share from each voter at the share height
// and no extension otherwise. A vote with a missing or bad share is dropped, so
// any 3 votes that commit the block always hold 3 valid shares.
func (a *App) VerifyVoteExtension(_ context.Context, req *abci.RequestVerifyVoteExtension) (*abci.ResponseVerifyVoteExtension, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	accept := &abci.ResponseVerifyVoteExtension{Status: abci.ResponseVerifyVoteExtension_ACCEPT}
	reject := &abci.ResponseVerifyVoteExtension{Status: abci.ResponseVerifyVoteExtension_REJECT}
	s := a.m.S
	if !s.ShareHeight(req.Height) {
		if len(req.VoteExtension) != 0 {
			return reject, nil
		}
		return accept, nil
	}
	ag := s.AgentByValidator(hex.EncodeToString(req.ValidatorAddress))
	if ag == nil {
		return reject, nil
	}
	if err := s.Group.VerifyShare(s.NextTermMessage(), req.VoteExtension, ag.BLSIndex); err != nil {
		a.logger.Error("rejecting vote extension", "agent", ag.ID, "height", req.Height, "err", err)
		return reject, nil
	}
	return accept, nil
}

// FinalizeBlock applies the block. Any infrastructure failure panics: this node
// halts instead of recording a local fault as a market outcome.
func (a *App) FinalizeBlock(_ context.Context, req *abci.RequestFinalizeBlock) (*abci.ResponseFinalizeBlock, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	m := a.m
	m.BeginBlock(req.Height, req.Time.Unix())
	results := make([]*abci.ExecTxResult, len(req.Txs))
	for i, tx := range req.Txs {
		var err error
		if market.IsSeed(tx) {
			err = m.ApplySeed(market.SeedSig(tx))
		} else {
			err = m.DeliverTx(tx)
		}
		if err != nil {
			results[i] = &abci.ExecTxResult{Code: 1, Log: err.Error()}
			continue
		}
		results[i] = &abci.ExecTxResult{Code: abci.CodeTypeOK}
	}
	if err := m.EndBlock(); err != nil {
		return nil, fmt.Errorf("end of block %d: %w", req.Height, err)
	}
	h, raw, err := m.S.Hash()
	if err != nil {
		return nil, err
	}
	a.hash, a.raw = h, raw
	return &abci.ResponseFinalizeBlock{TxResults: results, AppHash: h, Events: toEvents(m.Events())}, nil
}

func toEvents(in []market.Event) []abci.Event {
	out := make([]abci.Event, 0, len(in))
	for _, e := range in {
		ev := abci.Event{Type: "market." + e.Type}
		keys := make([]string, 0, len(e.Attrs))
		for k := range e.Attrs {
			keys = append(keys, k)
		}
		sortStrings(keys)
		for _, k := range keys {
			ev.Attributes = append(ev.Attributes, abci.EventAttribute{Key: k, Value: e.Attrs[k], Index: true})
		}
		out = append(out, ev)
	}
	return out
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// Commit persists state atomically. The git object store is append-only, so a
// crash here is recovered by replaying the block.
func (a *App) Commit(context.Context, *abci.RequestCommit) (*abci.ResponseCommit, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	tmp := a.statePath() + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return nil, err
	}
	if _, err := f.Write(a.raw); err != nil {
		f.Close()
		return nil, err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, err
	}
	if err := f.Close(); err != nil {
		return nil, err
	}
	if err := os.Rename(tmp, a.statePath()); err != nil {
		return nil, err
	}
	// State first: a crash after this finishes the stage on restart, and a crash
	// before it discards the stage and replays the block.
	if err := a.m.CommitBlock(); err != nil {
		return nil, fmt.Errorf("committing repo: %w", err)
	}
	a.committed, a.lastHash, a.lastH = a.raw, a.hash, a.m.S.Height
	a.seenNew = map[string]int{}
	return &abci.ResponseCommit{}, nil
}

// Query serves read-only paths for wrappers and tools:
//
//	/state          canonical JSON of committed state
//	/bundle/<bid>   the bundle a bid was submitted with
//	/head-bundle    standalone bundle of the repo at head
func (a *App) Query(_ context.Context, req *abci.RequestQuery) (*abci.ResponseQuery, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	fail := func(err error) (*abci.ResponseQuery, error) {
		return &abci.ResponseQuery{Code: 1, Log: err.Error()}, nil
	}
	switch {
	case req.Path == "/state":
		return &abci.ResponseQuery{Value: a.committed, Height: a.lastH}, nil
	case req.Path == "/head-bundle":
		data, err := a.m.Repo.BundleAll()
		if err != nil {
			return fail(err)
		}
		return &abci.ResponseQuery{Value: data, Height: a.lastH}, nil
	case strings.HasPrefix(req.Path, "/bundle/"):
		id, err := strconv.ParseUint(strings.TrimPrefix(req.Path, "/bundle/"), 10, 64)
		if err != nil {
			return fail(fmt.Errorf("bad bid id: %v", err))
		}
		data, err := a.m.Bundle(id)
		if err != nil {
			return fail(err)
		}
		return &abci.ResponseQuery{Value: data, Height: a.lastH}, nil
	}
	return fail(fmt.Errorf("unknown query path %q; try /state, /head-bundle or /bundle/<bid>", req.Path))
}
