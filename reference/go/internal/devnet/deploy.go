package devnet

import (
	stded25519 "crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	cfg "github.com/cometbft/cometbft/config"
	"github.com/cometbft/cometbft/crypto/ed25519"
	"github.com/cometbft/cometbft/p2p"
	"github.com/cometbft/cometbft/privval"
	"github.com/cometbft/cometbft/types"

	"pantheon/internal/beacon"
	"pantheon/internal/client"
	"pantheon/internal/gitx"
	"pantheon/internal/market"
)

// This file is the multi-host setup: each host generates its own secrets, and only
// public material moves between them. No machine ever holds another agent's keys.

// Identity is one host's public material, safe to pass around in the clear.
type Identity struct {
	Agent        string `json:"agent"`
	P2PAddr      string `json:"p2p_addr"` // host:port peers dial, normally a tailnet name
	NodeID       string `json:"node_id"`
	ValidatorPub []byte `json:"validator_pub"`
	AppPub       []byte `json:"app_pub"`
	BoxPub       []byte `json:"box_pub"`
}

// SignedDeal is a ceremony deal, signed by the dealer's app key. The signature
// stops anyone relaying files from swapping in their own polynomial.
type SignedDeal struct {
	Agent string       `json:"agent"`
	Deal  *beacon.Deal `json:"deal"`
	Sig   []byte       `json:"sig"`
}

func boxPath(home string) string { return filepath.Join(home, "config", "ceremony_box.json") }

// Keygen creates this host's secrets and returns its public identity file path.
func Keygen(home, agent, p2pAddr, chainID string) (string, error) {
	if !contains(DefaultAgents, agent) {
		return "", fmt.Errorf("unknown agent %q: use one of %s", agent, strings.Join(DefaultAgents, ", "))
	}
	if _, err := os.Stat(AppKeyPath(home)); err == nil {
		return "", fmt.Errorf("%s already has keys: refusing to overwrite them", home)
	}
	if err := MakeDirs(home); err != nil {
		return "", err
	}
	conf := cfg.DefaultConfig()
	conf.SetRoot(home)
	pv := privval.LoadOrGenFilePV(conf.PrivValidatorKeyFile(), conf.PrivValidatorStateFile())
	nk, err := p2p.LoadOrGenNodeKey(conf.NodeKeyFile())
	if err != nil {
		return "", err
	}
	pub, err := pv.GetPubKey()
	if err != nil {
		return "", err
	}
	appPub, err := WriteAppKey(home, agent, chainID)
	if err != nil {
		return "", err
	}
	keys, err := beacon.NewBoxKeys()
	if err != nil {
		return "", err
	}
	rawBox, err := json.Marshal(keys)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(boxPath(home), rawBox, 0o600); err != nil {
		return "", err
	}
	id := Identity{Agent: agent, P2PAddr: p2pAddr, NodeID: string(nk.ID()), ValidatorPub: pub.Bytes(), AppPub: appPub, BoxPub: keys.Public[:]}
	raw, err := json.MarshalIndent(id, "", "  ")
	if err != nil {
		return "", err
	}
	out := filepath.Join(home, "identity-"+agent+".json")
	return out, os.WriteFile(out, raw, 0o644)
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// LoadIdentities reads identity-*.json from a directory, in BLS index order.
func LoadIdentities(dir string) ([]Identity, error) {
	var out []Identity
	for _, a := range Sorted(DefaultAgents) {
		path := filepath.Join(dir, "identity-"+a+".json")
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("missing identity for %s: copy %s here from that host: %w", a, filepath.Base(path), err)
		}
		var id Identity
		if err := json.Unmarshal(raw, &id); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if id.Agent != a {
			return nil, fmt.Errorf("%s claims to be %s", path, id.Agent)
		}
		out = append(out, id)
	}
	return out, nil
}

func indexOf(ids []Identity, agent string) (int, error) {
	for i, id := range ids {
		if id.Agent == agent {
			return i, nil
		}
	}
	return -1, fmt.Errorf("agent %s is not in the identities", agent)
}

func loadKey(home string) (client.KeyFile, error) {
	var k client.KeyFile
	raw, err := os.ReadFile(AppKeyPath(home))
	if err != nil {
		return k, err
	}
	return k, json.Unmarshal(raw, &k)
}

// signingBytes domain-separates deal signatures from market transactions.
func dealBytes(d *beacon.Deal) ([]byte, error) {
	raw, err := json.Marshal(d)
	if err != nil {
		return nil, err
	}
	return append([]byte("pantheon/deal/v1\x00"), raw...), nil
}

// MakeDeal writes this host's signed ceremony deal into identities dir.
func MakeDeal(home, idDir string) (string, error) {
	k, err := loadKey(home)
	if err != nil {
		return "", err
	}
	ids, err := LoadIdentities(idDir)
	if err != nil {
		return "", err
	}
	self, err := indexOf(ids, k.Agent)
	if err != nil {
		return "", err
	}
	recipients := make([][32]byte, len(ids))
	for i, id := range ids {
		if len(id.BoxPub) != 32 {
			return "", fmt.Errorf("identity of %s has a bad box key", id.Agent)
		}
		copy(recipients[i][:], id.BoxPub)
	}
	d, err := beacon.NewDeal(self, len(ids), 3, recipients)
	if err != nil {
		return "", err
	}
	msg, err := dealBytes(d)
	if err != nil {
		return "", err
	}
	raw, err := json.MarshalIndent(SignedDeal{Agent: k.Agent, Deal: d, Sig: stded25519.Sign(k.PrivKey, msg)}, "", "  ")
	if err != nil {
		return "", err
	}
	out := filepath.Join(idDir, "deal-"+k.Agent+".json")
	return out, os.WriteFile(out, raw, 0o644)
}

func loadDeals(dir string, ids []Identity) ([]*beacon.Deal, error) {
	var deals []*beacon.Deal
	for i, id := range ids {
		path := filepath.Join(dir, "deal-"+id.Agent+".json")
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("missing deal from %s: run `pantheon deploy deal` on that host and copy the file here: %w", id.Agent, err)
		}
		var sd SignedDeal
		if err := json.Unmarshal(raw, &sd); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		msg, err := dealBytes(sd.Deal)
		if err != nil {
			return nil, err
		}
		if len(id.AppPub) != stded25519.PublicKeySize || !stded25519.Verify(id.AppPub, msg, sd.Sig) {
			return nil, fmt.Errorf("%s: signature doesn't verify against %s's identity", path, id.Agent)
		}
		if sd.Deal.Dealer != i {
			return nil, fmt.Errorf("%s: dealer index %d, want %d", path, sd.Deal.Dealer, i)
		}
		deals = append(deals, sd.Deal)
	}
	return deals, nil
}

// GenesisOptions are the public inputs every host must agree on. Identical
// inputs give a byte-identical genesis on every host.
type GenesisOptions struct {
	ChainID     string
	GenesisTime time.Time
	SeedDir     string
	Params      market.Params
	BlockMS     int
	P2PListen   string
	RPCListen   string
	Metrics     string
}

// Finish opens this host's shares, writes its BLS share, builds the genesis and
// config, and returns the genesis hash for hosts to compare out of band.
func Finish(home, idDir string, o GenesisOptions) (string, error) {
	k, err := loadKey(home)
	if err != nil {
		return "", err
	}
	if o.ChainID != k.ChainID {
		return "", fmt.Errorf("chain id %q, but this host's keys were made for %q", o.ChainID, k.ChainID)
	}
	ids, err := LoadIdentities(idDir)
	if err != nil {
		return "", err
	}
	self, err := indexOf(ids, k.Agent)
	if err != nil {
		return "", err
	}
	deals, err := loadDeals(idDir, ids)
	if err != nil {
		return "", err
	}
	rawBox, err := os.ReadFile(boxPath(home))
	if err != nil {
		return "", err
	}
	var keys beacon.BoxKeys
	if err := json.Unmarshal(rawBox, &keys); err != nil {
		return "", err
	}
	group, share, err := beacon.Combine(self, len(ids), 3, deals, &keys)
	if err != nil {
		return "", err
	}
	if err := WriteShare(home, *share); err != nil {
		return "", err
	}
	if o.Params.GitVersion == "" {
		return "", fmt.Errorf("params.git_version must be set explicitly so every host pins the same git")
	}
	if err := o.Params.Validate(); err != nil {
		return "", err
	}
	bundle, commit, err := gitx.Snapshot(o.SeedDir, o.GenesisTime.Unix())
	if err != nil {
		return "", err
	}
	gen := market.Genesis{Group: group, Params: o.Params, InitialBundle: bundle, InitialCommit: commit}
	doc := &types.GenesisDoc{GenesisTime: o.GenesisTime, ChainID: o.ChainID, ConsensusParams: ConsensusParams()}
	var peers []string
	for i, id := range ids {
		if len(id.ValidatorPub) != ed25519.PubKeySize {
			return "", fmt.Errorf("identity of %s has a bad validator key", id.Agent)
		}
		pub := ed25519.PubKey(id.ValidatorPub)
		doc.Validators = append(doc.Validators, validator(id.Agent, pub))
		gen.Agents = append(gen.Agents, market.Agent{ID: id.Agent, AppPubKey: id.AppPub, ValidatorAddr: hex.EncodeToString(pub.Address()), BLSIndex: i})
		if i != self {
			peers = append(peers, id.NodeID+"@"+id.P2PAddr)
		}
	}
	sort.Strings(peers)
	if doc.AppState, err = json.Marshal(gen); err != nil {
		return "", err
	}
	if err := doc.ValidateAndComplete(); err != nil {
		return "", err
	}
	conf := Config(home, o.BlockMS)
	conf.Moniker = k.Agent
	conf.P2P.PersistentPeers = strings.Join(peers, ",")
	conf.P2P.ListenAddress = o.P2PListen
	conf.P2P.ExternalAddress = ids[self].P2PAddr
	conf.RPC.ListenAddress = o.RPCListen
	conf.Instrumentation.PrometheusListenAddr = o.Metrics
	cfg.WriteConfigFile(filepath.Join(home, "config", "config.toml"), conf)
	if err := doc.SaveAs(conf.GenesisFile()); err != nil {
		return "", err
	}
	// The ceremony's secrets have served their purpose.
	if err := os.Remove(boxPath(home)); err != nil {
		return "", err
	}
	raw, err := os.ReadFile(conf.GenesisFile())
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}
