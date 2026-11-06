package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"path/filepath"
	"time"

	"pantheon/internal/agent"
	"pantheon/internal/devnet"
	"pantheon/internal/market"
)

const deployUsage = `usage: pantheon deploy <keygen|deal|finish> [flags]

Run each step on all four hosts, sharing the public files between steps. All
inputs to finish must match, and every host prints a genesis hash to compare.

  keygen   Make this host's keys and identity-<agent>.json
  deal     With all 4 identities in --shared, write deal-<agent>.json there
  finish   With all 4 deals in --shared, write the BLS share, genesis and config
`

func cmdDeploy(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("%s", deployUsage)
	}
	switch args[0] {
	case "keygen":
		fs := flag.NewFlagSet("deploy keygen", flag.ExitOnError)
		home := fs.String("home", "", "this host's node home")
		name := fs.String("agent", "", "claude | codex | grok | muse")
		p2p := fs.String("p2p-addr", "", "host:port peers dial to reach this node, normally its tailnet name")
		chain := fs.String("chain-id", "pantheon", "chain id")
		fs.Parse(args[1:])
		if *home == "" || *name == "" || *p2p == "" {
			return fmt.Errorf("--home, --agent and --p2p-addr are required")
		}
		out, err := devnet.Keygen(*home, *name, *p2p, *chain)
		if err != nil {
			return err
		}
		fmt.Printf("wrote %s\nnext: copy it to the shared directory on every host, then run `pantheon deploy deal`\n", out)
		return nil
	case "deal":
		fs := flag.NewFlagSet("deploy deal", flag.ExitOnError)
		home := fs.String("home", "", "this host's node home")
		shared := fs.String("shared", "", "directory holding all 4 identity files")
		fs.Parse(args[1:])
		if *home == "" || *shared == "" {
			return fmt.Errorf("--home and --shared are required")
		}
		out, err := devnet.MakeDeal(*home, *shared)
		if err != nil {
			return err
		}
		fmt.Printf("wrote %s\nnext: share it with every host, then run `pantheon deploy finish`\n", out)
		return nil
	case "finish":
		fs := flag.NewFlagSet("deploy finish", flag.ExitOnError)
		home := fs.String("home", "", "this host's node home")
		shared := fs.String("shared", "", "directory holding all 4 identity and deal files")
		chain := fs.String("chain-id", "pantheon", "chain id")
		start := fs.String("genesis-time", "", "RFC3339 time, the same on every host")
		seed := fs.String("seed-dir", "", "directory to snapshot as the genesis repo, identical on every host")
		params := fs.String("params", "", "JSON overriding market params; git_version is required")
		agentCfg := fs.String("agent-config", "", "JSON merged into this host's wrapper/agent.json")
		blockMS := fs.Int("block-ms", 1000, "pause between blocks in milliseconds")
		p2p := fs.String("p2p-listen", "tcp://0.0.0.0:26656", "p2p bind address")
		rpc := fs.String("rpc-listen", "tcp://127.0.0.1:26657", "RPC bind address; keep it local, the wrapper is on this host")
		metrics := fs.String("metrics-listen", "127.0.0.1:26660", "Prometheus bind address")
		fs.Parse(args[1:])
		if *home == "" || *shared == "" || *start == "" {
			return fmt.Errorf("--home, --shared and --genesis-time are required")
		}
		when, err := time.Parse(time.RFC3339, *start)
		if err != nil {
			return fmt.Errorf("--genesis-time: %w", err)
		}
		p := market.DefaultParams()
		if *params != "" {
			if err := json.Unmarshal([]byte(*params), &p); err != nil {
				return fmt.Errorf("--params: %w", err)
			}
		}
		sum, err := devnet.Finish(*home, *shared, devnet.GenesisOptions{
			ChainID: *chain, GenesisTime: when.UTC(), SeedDir: *seed, Params: p, BlockMS: *blockMS,
			P2PListen: *p2p, RPCListen: *rpc, Metrics: *metrics,
		})
		if err != nil {
			return err
		}
		k := filepath.Base(*home)
		if err := agent.WriteHome(*home, []byte(*agentCfg)); err != nil {
			return fmt.Errorf("%s: %w", k, err)
		}
		fmt.Printf("genesis sha256 %s\nCompare this on all 4 hosts: a mismatch means inputs differ, and that chain can't start.\n", sum)
		return nil
	}
	return fmt.Errorf("%s", deployUsage)
}
