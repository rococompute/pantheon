// Package e2e runs real CometBFT validators as separate processes and drives the
// market over RPC, the same way wrappers do.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"pantheon/internal/client"
	"pantheon/internal/devnet"
	"pantheon/internal/gitx"
	"pantheon/internal/market"
)

var binary string

var nextPort atomic.Int64

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "pantheon-e2e-*")
	if err != nil {
		panic(err)
	}
	binary = filepath.Join(dir, "pantheon")
	out, err := exec.Command("go", "build", "-o", binary, "pantheon/cmd/pantheon").CombinedOutput()
	if err != nil {
		panic(string(out))
	}
	nextPort.Store(20000 + int64(os.Getpid()%200)*100)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

type network struct {
	t       *testing.T
	dir     string
	port    int
	procs   map[string]*exec.Cmd
	senders map[string]*client.Sender
	byz     map[string]string
	work    *gitx.Repo
	stopped map[string]bool
}

type opts struct {
	params    func(*market.Params)
	byz       map[string]string
	seedFiles map[string]string
}

func start(t *testing.T, o opts) *network {
	t.Helper()
	port := int(nextPort.Add(100))
	dir := filepath.Join(t.TempDir(), "net")
	seed := t.TempDir()
	os.WriteFile(filepath.Join(seed, "a.txt"), []byte("1\n"), 0o644)
	os.WriteFile(filepath.Join(seed, "b.txt"), []byte("1\n"), 0o644)
	for name, content := range o.seedFiles {
		os.WriteFile(filepath.Join(seed, name), []byte(content), 0o755)
	}
	p := market.DefaultParams()
	p.BidCooldownBlocks = 0
	p.TermBlocks = 60
	p.StallBlocks = 400
	p.AttestWindow = 120
	p.BidderFallbackBlocks = 60
	if o.params != nil {
		o.params(&p)
	}
	raw, _ := json.Marshal(p)
	cmd := exec.Command(binary, "devnet", "init", "--dir", dir, "--seed-dir", seed, "--block-ms", "100", "--base-port", fmt.Sprint(port), "--params", string(raw))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("devnet init: %v\n%s", err, out)
	}
	n := &network{t: t, dir: dir, port: port, procs: map[string]*exec.Cmd{}, senders: map[string]*client.Sender{}, byz: o.byz, stopped: map[string]bool{}}
	for i, a := range devnet.DefaultAgents {
		n.startNode(a)
		s, err := client.LoadSender(devnet.AppKeyPath(filepath.Join(dir, a)), devnet.RPCAddr(port, i))
		if err != nil {
			t.Fatal(err)
		}
		n.senders[a] = s
	}
	t.Cleanup(n.stopAll)
	var err error
	if n.work, err = gitx.Open(filepath.Join(t.TempDir(), "work.git")); err != nil {
		t.Fatal(err)
	}
	n.waitFor("first block", 60*time.Second, func(s *market.State) bool { return s.Height >= 2 })
	return n
}

func (n *network) startNode(a string) {
	n.t.Helper()
	home := filepath.Join(n.dir, a)
	f, err := os.OpenFile(filepath.Join(home, "node.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		n.t.Fatal(err)
	}
	cmd := exec.Command(binary, "node", "--home", home)
	cmd.Stdout, cmd.Stderr = f, f
	cmd.Env = append(os.Environ(), "PANTHEON_TEST_DIE_WITH_PARENT=1")
	if m := n.byz[a]; m != "" {
		cmd.Env = append(cmd.Env, "PANTHEON_TEST_BYZ="+m, "PANTHEON_TEST_KEY="+devnet.AppKeyPath(home))
	}
	if err := cmd.Start(); err != nil {
		n.t.Fatal(err)
	}
	n.procs[a] = cmd
	delete(n.stopped, a)
}

func (n *network) kill(a string) {
	n.t.Helper()
	p := n.procs[a]
	_ = p.Process.Signal(syscall.SIGKILL)
	_, _ = p.Process.Wait()
	n.stopped[a] = true
}

func (n *network) stopAll() {
	for a, p := range n.procs {
		if !n.stopped[a] {
			_ = p.Process.Signal(syscall.SIGKILL)
			_, _ = p.Process.Wait()
		}
	}
	if n.t.Failed() {
		for a := range n.procs {
			raw, _ := os.ReadFile(filepath.Join(n.dir, a, "node.log"))
			if len(raw) > 3000 {
				raw = raw[len(raw)-3000:]
			}
			n.t.Logf("--- %s log tail ---\n%s", a, raw)
		}
	}
}

// live returns a running node's sender.
func (n *network) live() *client.Sender {
	for _, a := range devnet.DefaultAgents {
		if !n.stopped[a] {
			return n.senders[a]
		}
	}
	n.t.Fatal("no node is running")
	return nil
}

func ctx(t *testing.T, d time.Duration) context.Context {
	c, cancel := context.WithTimeout(context.Background(), d)
	t.Cleanup(cancel)
	return c
}

// state reads the most advanced running node, so a read right after a send can't
// see the world from before it.
func (n *network) state() *market.State {
	n.t.Helper()
	var best *market.State
	for a, sn := range n.senders {
		if n.stopped[a] {
			continue
		}
		s, err := sn.State(ctx(n.t, 10*time.Second))
		if err != nil {
			continue
		}
		if best == nil || s.Height > best.Height {
			best = s
		}
	}
	if best == nil {
		n.t.Fatal("no node answered")
	}
	return best
}

func (n *network) waitFor(what string, d time.Duration, f func(*market.State) bool) *market.State {
	n.t.Helper()
	deadline := time.Now().Add(d)
	var last *market.State
	for time.Now().Before(deadline) {
		for a, sn := range n.senders {
			if n.stopped[a] {
				continue
			}
			c, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			s, err := sn.State(c)
			cancel()
			if err == nil {
				last = s
				if f(s) {
					n.syncTo(s.Height)
					return s
				}
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	if last != nil {
		n.t.Fatalf("timed out waiting for %s; at height %d term %d leader %q", what, last.Height, last.Term, last.TermLeader)
	}
	n.t.Fatalf("timed out waiting for %s: no state", what)
	return nil
}

// roles waits for a leader and returns it with the other three.
func (n *network) roles() (string, []string) {
	n.t.Helper()
	s := n.waitFor("a term leader", 30*time.Second, func(s *market.State) bool { return s.TermLeader != "" })
	var rest []string
	for _, a := range devnet.DefaultAgents {
		if a != s.TermLeader {
			rest = append(rest, a)
		}
	}
	return s.TermLeader, rest
}

func (n *network) send(a string, b market.Body) *client.Result {
	n.t.Helper()
	res, err := n.senders[a].Send(ctx(n.t, 30*time.Second), b)
	if err != nil {
		n.t.Fatalf("%s from %s: %v", b.Type, a, err)
	}
	return res
}

func (n *network) must(a string, b market.Body) {
	n.t.Helper()
	if err := n.send(a, b).Err(); err != nil {
		n.t.Fatalf("%s from %s: %v", b.Type, a, err)
	}
}

// refused requires CheckTx to turn a transaction away.
func (n *network) refused(a string, b market.Body, want string) {
	n.t.Helper()
	_, err := n.senders[a].Send(ctx(n.t, 30*time.Second), b)
	if err == nil || !strings.Contains(err.Error(), want) {
		n.t.Fatalf("%s from %s: want refusal containing %q, got %v", b.Type, a, want, err)
	}
}

// bundle builds a bid on current head the way a wrapper does.
func (n *network) bundle(agent string, edits map[string]string) []byte {
	n.t.Helper()
	c := ctx(n.t, 30*time.Second)
	all, err := n.live().HeadBundle(c)
	if err != nil {
		n.t.Fatal(err)
	}
	head, err := n.work.Sync(all)
	if err != nil {
		n.t.Fatal(err)
	}
	wt, err := n.work.AddWorktree(n.t.TempDir(), head)
	if err != nil {
		n.t.Fatal(err)
	}
	defer wt.Remove()
	for p, content := range edits {
		if err := os.WriteFile(filepath.Join(wt.Dir, p), []byte(content), 0o644); err != nil {
			n.t.Fatal(err)
		}
	}
	commit, err := wt.CommitAll(agent, "bid")
	if err != nil || commit == "" {
		n.t.Fatalf("commit: %v %q", err, commit)
	}
	b, err := n.work.BundleBid(commit, head)
	if err != nil {
		n.t.Fatal(err)
	}
	return b
}

func (n *network) postTask(leader string) uint64 {
	n.t.Helper()
	s := n.state()
	id := s.NextTaskID
	n.must(leader, market.Body{Type: market.TxPostTask, Spec: "do something", BaseCommit: s.RepoHead})
	return id
}

func (n *network) bid(agent string, task uint64, edits map[string]string) uint64 {
	n.t.Helper()
	b := n.bundle(agent, edits)
	n.must(agent, market.Body{Type: market.TxSubmitBid, TaskID: task, Bundle: b})
	info, err := gitx.CheckBundle(b, gitx.Limits{})
	if err != nil {
		n.t.Fatal(err)
	}
	// Read from the sender's own node: others may be a block behind.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		st, err := n.senders[agent].State(ctx(n.t, 5*time.Second))
		if err == nil {
			for _, x := range st.Bids {
				if x.Bidder == agent && x.Commit == info.Commit {
					return x.ID
				}
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	n.t.Fatalf("bid from %s never appeared", agent)
	return 0
}

// attest refreshes the state so its signed tree is the pending merge's.
func (n *network) attest(agent string, bid uint64, ok bool) {
	n.t.Helper()
	s := n.waitFor("pending merge", 10*time.Second, func(s *market.State) bool { return s.PendingMerge != nil })
	n.must(agent, market.Body{Type: market.TxAttest, BidID: bid, OK: ok, CIDigest: "e2e", Tree: s.PendingMerge.Tree})
}

// agreeAll checks every running node has the same app hash and repo at a shared
// height, using a block they have all committed.
func (n *network) agreeAll() {
	n.t.Helper()
	c := ctx(n.t, 60*time.Second)
	var height int64
	for a, s := range n.senders {
		if n.stopped[a] {
			continue
		}
		st, err := s.RPC.Status(c)
		if err != nil {
			n.t.Fatalf("%s status: %v", a, err)
		}
		if height == 0 || st.SyncInfo.LatestBlockHeight < height {
			height = st.SyncInfo.LatestBlockHeight
		}
	}
	h := height
	var want []byte
	wantFrom := ""
	for a, s := range n.senders {
		if n.stopped[a] {
			continue
		}
		b, err := s.RPC.Block(c, &h)
		if err != nil {
			n.t.Fatalf("%s block %d: %v", a, h, err)
		}
		if want == nil {
			want, wantFrom = b.Block.AppHash, a
		} else if !bytes.Equal(want, b.Block.AppHash) {
			n.t.Fatalf("app hash at %d differs: %s=%X %s=%X", h, wantFrom, want, a, b.Block.AppHash)
		}
	}
	head := n.state().RepoHead
	n.waitFor("all nodes at this head", 20*time.Second, func(*market.State) bool {
		for a, s := range n.senders {
			if n.stopped[a] {
				continue
			}
			st, err := s.State(c)
			if err != nil || st.RepoHead != head {
				return false
			}
		}
		return true
	})
	for _, a := range devnet.DefaultAgents {
		if n.stopped[a] {
			continue
		}
		repo := filepath.Join(n.dir, a, "data", "market", "repo.git")
		out, err := gitx.Run(repo, nil, "rev-parse", gitx.MainRef)
		if err != nil {
			n.t.Fatalf("%s repo: %v", a, err)
		}
		if got := strings.TrimSpace(out); got != head {
			n.t.Fatalf("%s repo main %s, state head %s", a, got, head)
		}
		if _, err := gitx.Run(repo, nil, "fsck", "--no-dangling", "--connectivity-only", head); err != nil {
			n.t.Fatalf("%s fsck: %v", a, err)
		}
	}
}

// honestLogged reports whether some node other than except logged the text.
func (n *network) honestLogged(text, except string) bool {
	for _, a := range devnet.DefaultAgents {
		if a == except {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(n.dir, a, "node.log"))
		if err == nil && strings.Contains(string(raw), text) {
			return true
		}
	}
	return false
}

// syncTo waits for every running node to commit a height, so a following send
// can't be judged by a node that hasn't seen what the caller just observed.
func (n *network) syncTo(height int64) {
	n.t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for a, sn := range n.senders {
		for !n.stopped[a] && time.Now().Before(deadline) {
			c, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			s, err := sn.State(c)
			cancel()
			if err == nil && s.Height >= height {
				break
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
}

// bundleDeleting builds a bid that removes a file from head.
func (n *network) bundleDeleting(agent, path string) []byte {
	n.t.Helper()
	c := ctx(n.t, 30*time.Second)
	all, err := n.live().HeadBundle(c)
	if err != nil {
		n.t.Fatal(err)
	}
	head, err := n.work.Sync(all)
	if err != nil {
		n.t.Fatal(err)
	}
	wt, err := n.work.AddWorktree(n.t.TempDir(), head)
	if err != nil {
		n.t.Fatal(err)
	}
	defer wt.Remove()
	if err := os.Remove(filepath.Join(wt.Dir, path)); err != nil {
		n.t.Fatal(err)
	}
	commit, err := wt.CommitAll(agent, "delete")
	if err != nil || commit == "" {
		n.t.Fatalf("commit: %v %q", err, commit)
	}
	b, err := n.work.BundleBid(commit, head)
	if err != nil {
		n.t.Fatal(err)
	}
	return b
}

// treeBomb builds a bid whose tree stands for 10^12 paths in a few KiB.
func (n *network) treeBomb(agent string) []byte {
	n.t.Helper()
	all, err := n.live().HeadBundle(ctx(n.t, 30*time.Second))
	if err != nil {
		n.t.Fatal(err)
	}
	head, err := n.work.Sync(all)
	if err != nil {
		n.t.Fatal(err)
	}
	git := func(stdin string, args ...string) string {
		n.t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = n.work.Dir
		cmd.Env = gitx.Env()
		cmd.Stdin = strings.NewReader(stdin)
		out, err := cmd.Output()
		if err != nil {
			n.t.Fatalf("git %v: %v", args, err)
		}
		return strings.TrimSpace(string(out))
	}
	blob := git("x\n", "hash-object", "-w", "--stdin")
	var b strings.Builder
	for i := 0; i < 10; i++ {
		fmt.Fprintf(&b, "100644 blob %s\tf%d\n", blob, i)
	}
	tree := git(b.String(), "mktree")
	for d := 0; d < 11; d++ {
		b.Reset()
		for i := 0; i < 10; i++ {
			fmt.Fprintf(&b, "040000 tree %s\td%d\n", tree, i)
		}
		tree = git(b.String(), "mktree")
	}
	root := git(git("", "ls-tree", head)+"\n040000 tree "+tree+"\tbomb\n", "mktree")
	commit, err := n.work.CommitTreeAs(agent, root, []string{head}, "bomb", time.Now().Unix())
	if err != nil {
		n.t.Fatal(err)
	}
	bundle, err := n.work.BundleBid(commit, head)
	if err != nil {
		n.t.Fatal(err)
	}
	return bundle
}
