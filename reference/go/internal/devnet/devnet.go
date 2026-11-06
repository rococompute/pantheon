// Package devnet generates complete node homes and runs a node process.
package devnet

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	cfg "github.com/cometbft/cometbft/config"
	"github.com/cometbft/cometbft/crypto"
	"github.com/cometbft/cometbft/p2p"
	"github.com/cometbft/cometbft/privval"
	"github.com/cometbft/cometbft/types"
	cmttime "github.com/cometbft/cometbft/types/time"

	"pantheon/internal/beacon"
	"pantheon/internal/client"
	"pantheon/internal/gitx"
	"pantheon/internal/market"
)

// DefaultAgents are the four market participants.
var DefaultAgents = []string{"claude", "codex", "grok", "muse"}

// Options configures a local 4-node network.
type Options struct {
	Dir      string
	ChainID  string
	SeedDir  string // files for the genesis repo; empty means an empty tree
	BlockMS  int
	BasePort int
	Params   market.Params
}

// RPCAddr is the local RPC address of the i-th node.
func RPCAddr(basePort, i int) string {
	return fmt.Sprintf("http://127.0.0.1:%d", basePort+1+10*i)
}

// Init writes one home per agent under opts.Dir.
func Init(o Options) error {
	if o.ChainID == "" {
		o.ChainID = "pantheon-devnet"
	}
	if o.BlockMS == 0 {
		o.BlockMS = 1000
	}
	if o.BasePort == 0 {
		o.BasePort = 26656
	}
	if o.Params.GitVersion == "" {
		v, err := gitx.Version()
		if err != nil {
			return err
		}
		o.Params.GitVersion = v
	}
	if err := o.Params.Validate(); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(o.Dir, DefaultAgents[0], "config", "genesis.json")); err == nil {
		return fmt.Errorf("%s already holds a network, including its keys. To discard it for good, stop its nodes and run `rm -rf %s`. To keep it, pick another --dir, and to run it, use `pantheon up --dir %s`", o.Dir, o.Dir, o.Dir)
	}
	now := cmttime.Now()
	bundle, commit, err := gitx.Snapshot(o.SeedDir, now.Unix())
	if err != nil {
		return fmt.Errorf("snapshotting seed repo: %w", err)
	}
	// A local devnet has one operator holding all four homes anyway, so a dealer
	// costs nothing here. Real hosts use `pantheon deploy`, which has no dealer.
	group, shares, err := beacon.TrustedDeal(len(DefaultAgents), 3)
	if err != nil {
		return err
	}
	gen := market.Genesis{Group: group, Params: o.Params, InitialBundle: bundle, InitialCommit: commit}
	doc := &types.GenesisDoc{GenesisTime: now, ChainID: o.ChainID, ConsensusParams: ConsensusParams()}

	var peers []string
	confs := make([]*cfg.Config, len(DefaultAgents))
	for i, name := range DefaultAgents {
		home := filepath.Join(o.Dir, name)
		if err := MakeDirs(home); err != nil {
			return err
		}
		conf := Config(home, o.BlockMS)
		conf.Moniker = name
		conf.P2P.ListenAddress = fmt.Sprintf("tcp://127.0.0.1:%d", o.BasePort+10*i)
		conf.RPC.ListenAddress = fmt.Sprintf("tcp://127.0.0.1:%d", o.BasePort+1+10*i)
		conf.Instrumentation.PrometheusListenAddr = fmt.Sprintf("127.0.0.1:%d", o.BasePort+2+10*i)
		confs[i] = conf

		pv := privval.LoadOrGenFilePV(conf.PrivValidatorKeyFile(), conf.PrivValidatorStateFile())
		nk, err := p2p.LoadOrGenNodeKey(conf.NodeKeyFile())
		if err != nil {
			return err
		}
		pub, err := pv.GetPubKey()
		if err != nil {
			return err
		}
		peers = append(peers, fmt.Sprintf("%s@127.0.0.1:%d", nk.ID(), o.BasePort+10*i))
		doc.Validators = append(doc.Validators, validator(name, pub))

		appPub, err := WriteAppKey(home, name, o.ChainID)
		if err != nil {
			return err
		}
		gen.Agents = append(gen.Agents, market.Agent{ID: name, AppPubKey: appPub, ValidatorAddr: hex.EncodeToString(pub.Address()), BLSIndex: i})
		if err := WriteShare(home, shares[i]); err != nil {
			return err
		}
	}
	doc.AppState, err = json.Marshal(gen)
	if err != nil {
		return err
	}
	if err := doc.ValidateAndComplete(); err != nil {
		return err
	}
	for i, name := range DefaultAgents {
		home := filepath.Join(o.Dir, name)
		var others []string
		for j, p := range peers {
			if j != i {
				others = append(others, p)
			}
		}
		confs[i].P2P.PersistentPeers = strings.Join(others, ",")
		cfg.WriteConfigFile(filepath.Join(home, "config", "config.toml"), confs[i])
		if err := doc.SaveAs(confs[i].GenesisFile()); err != nil {
			return err
		}
	}
	return nil
}

func validator(name string, pub crypto.PubKey) types.GenesisValidator {
	return types.GenesisValidator{Address: pub.Address(), PubKey: pub, Power: 10, Name: name}
}

// ConsensusParams enables vote extensions from the first block and makes room
// for bundles.
func ConsensusParams() *types.ConsensusParams {
	p := types.DefaultConsensusParams()
	p.ABCI.VoteExtensionsEnableHeight = 1
	p.Block.MaxBytes = 8 << 20
	return p
}

// MakeDirs creates a home's standard layout.
func MakeDirs(home string) error {
	for _, d := range []string{"config", "data", "wrapper"} {
		if err := os.MkdirAll(filepath.Join(home, d), 0o700); err != nil {
			return err
		}
	}
	return nil
}

// Config builds a node config. A bundle in base64 inside JSON grows by about a
// third, so tx and RPC limits are set generously over the default 512 KiB bundle.
func Config(home string, blockMS int) *cfg.Config {
	conf := cfg.DefaultConfig()
	conf.SetRoot(home)
	conf.LogLevel = "*:error"
	commit := time.Duration(blockMS) * time.Millisecond
	conf.Consensus.TimeoutCommit = commit
	conf.Consensus.TimeoutPropose = 3 * time.Second
	conf.Consensus.TimeoutProposeDelta = 500 * time.Millisecond
	conf.Consensus.TimeoutPrevote = time.Second
	conf.Consensus.TimeoutPrecommit = time.Second
	conf.Consensus.CreateEmptyBlocks = true
	conf.Mempool.MaxTxBytes = 2 << 20
	conf.Mempool.MaxTxsBytes = 64 << 20
	conf.RPC.MaxBodyBytes = 8 << 20
	conf.RPC.CORSAllowedOrigins = nil
	conf.P2P.AddrBookStrict = false
	conf.P2P.AllowDuplicateIP = true
	conf.P2P.PexReactor = false // the four validators are a fixed, private set
	conf.P2P.SendRate = 20 << 20
	conf.P2P.RecvRate = 20 << 20
	conf.Instrumentation.Prometheus = true
	return conf
}

// WriteAppKey generates the agent's market signing key under wrapper/.
func WriteAppKey(home, agent, chainID string) (ed25519.PublicKey, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	raw, err := json.MarshalIndent(client.KeyFile{Agent: agent, ChainID: chainID, PrivKey: priv}, "", "  ")
	if err != nil {
		return nil, err
	}
	return pub, os.WriteFile(AppKeyPath(home), raw, 0o600)
}

// AppKeyPath is where a home keeps the agent's market key.
func AppKeyPath(home string) string { return filepath.Join(home, "wrapper", "app.key") }

// SharePath is where a home keeps the validator's BLS share.
func SharePath(home string) string { return filepath.Join(home, "config", "bls_share.json") }

// WriteShare stores a BLS share readable only by this user.
func WriteShare(home string, s beacon.Share) error {
	raw, err := beacon.MarshalShare(s)
	if err != nil {
		return err
	}
	return os.WriteFile(SharePath(home), raw, 0o600)
}

// Sorted returns a sorted copy of names.
func Sorted(names []string) []string {
	out := append([]string{}, names...)
	sort.Strings(out)
	return out
}
