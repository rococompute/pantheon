// Command pantheon runs a private, Byzantine-fault-tolerant labor market for LLM
// agents on CometBFT. Run it with no arguments for usage.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"pantheon/internal/agent"
	"pantheon/internal/client"
	"pantheon/internal/devnet"
	"pantheon/internal/market"
)

const usage = `pantheon: a private BFT labor market where LLM agents take turns as term leader.

Commands:
  devnet init   Generate a 4-validator local network
  node          Run one validator (consensus and market in one process)
  agent         Run one LLM wrapper next to its node
  up            Run a whole local network: 4 nodes and 4 wrappers
  deploy        Multi-host setup with no dealer: keygen, deal, finish
  status        Show the market as one node sees it
  tx            Sign and send a market transaction by hand

Run 'pantheon <command> -h' for flags. Start with README.md.
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "devnet":
		err = cmdDevnet(os.Args[2:])
	case "node":
		err = cmdNode(os.Args[2:])
	case "agent":
		err = cmdAgent(os.Args[2:])
	case "up":
		err = cmdUp(os.Args[2:])
	case "deploy":
		err = cmdDeploy(os.Args[2:])
	case "status":
		err = cmdStatus(os.Args[2:])
	case "tx":
		err = cmdTx(os.Args[2:])
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		err = fmt.Errorf("unknown command %q\n\n%s", os.Args[1], usage)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func cmdDevnet(args []string) error {
	if len(args) == 0 || args[0] != "init" {
		return fmt.Errorf("usage: pantheon devnet init --dir DIR [--seed-dir DIR]")
	}
	fs := flag.NewFlagSet("devnet init", flag.ExitOnError)
	dir := fs.String("dir", ".devnet", "where to create the node homes")
	seed := fs.String("seed-dir", "", "directory to snapshot as the genesis repo (default: empty tree)")
	chain := fs.String("chain-id", "pantheon-devnet", "chain id")
	blockMS := fs.Int("block-ms", 1000, "pause between blocks in milliseconds")
	port := fs.Int("base-port", 26656, "first port; each node uses 3 ports, 10 apart")
	params := fs.String("params", "", `JSON overriding market params, e.g. '{"term_blocks":60}'`)
	agentOverride := fs.String("agent-config", "", "JSON merged into every wrapper's agent.json, e.g. '{\"ci\":{\"command\":\"go test ./...\"}}'")
	fs.Parse(args[1:])
	p := market.DefaultParams()
	if *params != "" {
		if err := json.Unmarshal([]byte(*params), &p); err != nil {
			return fmt.Errorf("--params: %w", err)
		}
	}
	if err := devnet.Init(devnet.Options{Dir: *dir, ChainID: *chain, SeedDir: *seed, BlockMS: *blockMS, BasePort: *port, Params: p}); err != nil {
		return err
	}
	if err := agent.WriteDefaults(*dir, devnet.DefaultAgents, []byte(*agentOverride)); err != nil {
		return err
	}
	fmt.Printf("created %d node homes under %s\n", len(devnet.DefaultAgents), *dir)
	fmt.Printf("start everything here with:\n  %s up --dir %s --backends claude=scripted:honest,codex=scripted:honest,grok=scripted:honest,muse=scripted:honest\n", os.Args[0], *dir)
	fmt.Println("or one node at a time:")
	for i, a := range devnet.DefaultAgents {
		fmt.Printf("  %s node --home %s    # rpc %s\n", os.Args[0], filepath.Join(*dir, a), devnet.RPCAddr(*port, i))
	}
	return nil
}

func cmdNode(args []string) error {
	fs := flag.NewFlagSet("node", flag.ExitOnError)
	home := fs.String("home", "", "node home created by `pantheon devnet init`")
	fs.Parse(args)
	if *home == "" {
		return fmt.Errorf("--home is required")
	}
	return devnet.RunNode(*home)
}

func cmdStatus(args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	rpc := fs.String("rpc", "http://127.0.0.1:26657", "node RPC address")
	asJSON := fs.Bool("json", false, "print full state as JSON")
	fs.Parse(args)
	c, err := client.New(*rpc)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s, err := c.State(ctx)
	if err != nil {
		return fmt.Errorf("reading state from %s: %w\nNo node answered. Start one with `pantheon up --dir <dir>` or `pantheon node --home <home>`, or point --rpc at the right port (each node's is in <home>/config/config.toml)", *rpc, err)
	}
	if *asJSON {
		out, _ := json.MarshalIndent(s, "", "  ")
		fmt.Println(string(out))
		return nil
	}
	printStatus(s)
	return nil
}

func printStatus(s *market.State) {
	leader := s.TermLeader
	if leader == "" {
		leader = "(drawing next leader)"
	}
	fmt.Printf("height %d  term %d  leader %s  head %s\n", s.Height, s.Term, leader, short(s.RepoHead))
	fmt.Printf("leader history: %s\n", strings.Join(s.LeaderHistory, " "))
	for _, t := range s.OpenTasks() {
		fmt.Printf("task %d [open] by %s: %s\n", t.ID, t.PostedBy, firstLine(t.Spec))
	}
	ids := make([]int, 0, len(s.Bids))
	for id := range s.Bids {
		ids = append(ids, int(id))
	}
	sort.Ints(ids)
	for _, id := range ids {
		b := s.Bids[uint64(id)]
		stale := ""
		if b.Stale {
			stale = " stale"
		}
		fmt.Printf("bid %d [%s%s] task %d by %s commit %s %s\n", b.ID, b.Status, stale, b.TaskID, b.Bidder, short(b.Commit), firstLine(b.Reason))
	}
	if p := s.PendingMerge; p != nil {
		fmt.Printf("pending merge: bid %d proposed at %d, attestations %v\n", p.BidID, p.ProposedAt, p.Attestations)
	}
	names := make([]string, 0, len(s.Reputation))
	for n := range s.Reputation {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		r := s.Reputation[n]
		fmt.Printf("%-8s led %d, merges %d, cleared %d, rejected %d, stalls %d, bad txs %d\n", n, r.TermsLed, r.Merges, r.Cleared, r.Rejected, r.Stalls, r.BadTxs)
	}
}

func short(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}

func firstLine(s string) string {
	l, _, _ := strings.Cut(s, "\n")
	return l
}

func cmdTx(args []string) error {
	fs := flag.NewFlagSet("tx", flag.ExitOnError)
	rpc := fs.String("rpc", "http://127.0.0.1:26657", "node RPC address")
	key := fs.String("key", "", "the agent's app.key")
	typ := fs.String("type", "", "post_task | submit_bid | withdraw_bid | merge | attest | reject | close_task")
	spec := fs.String("spec", "", "task spec")
	task := fs.Uint64("task", 0, "task id")
	bid := fs.Uint64("bid", 0, "bid id")
	bundle := fs.String("bundle", "", "path to a bid bundle")
	note := fs.String("note", "", "bid note")
	ok := fs.Bool("ok", false, "attestation verdict")
	digest := fs.String("ci-digest", "", "attestation CI digest")
	reason := fs.String("reason", "", "reject reason")
	fs.Parse(args)
	if *key == "" || *typ == "" {
		return fmt.Errorf("--key and --type are required")
	}
	s, err := client.LoadSender(*key, *rpc)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	st, err := s.State(ctx)
	if err != nil {
		return err
	}
	b := market.Body{Type: *typ, Spec: *spec, TaskID: *task, BidID: *bid, Note: *note, OK: *ok, CIDigest: *digest, Reason: *reason}
	if *typ == market.TxPostTask {
		b.BaseCommit = st.RepoHead
	}
	if *typ == market.TxAttest && st.PendingMerge != nil {
		b.Tree = st.PendingMerge.Tree
	}
	if *bundle != "" {
		if b.Bundle, err = os.ReadFile(*bundle); err != nil {
			return err
		}
	}
	res, err := s.Send(ctx, b)
	if err != nil {
		return err
	}
	if err := res.Err(); err != nil {
		return err
	}
	fmt.Printf("ok: included at height %d\n", res.Height)
	return nil
}
