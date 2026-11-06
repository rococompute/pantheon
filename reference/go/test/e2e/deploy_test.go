package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"pantheon/internal/client"
	"pantheon/internal/devnet"
	"pantheon/internal/gitx"
	"pantheon/internal/market"
)

// The multi-host path with four separate homes and only public files shared: no
// dealer, a chain that starts, and threshold randomness from the DKG's shares.
func TestDeployCeremonyStartsAWorkingChain(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	shared := filepath.Join(root, "shared")
	os.MkdirAll(shared, 0o755)
	seed := t.TempDir()
	os.WriteFile(filepath.Join(seed, "a.txt"), []byte("1\n"), 0o644)
	base := int(nextPort.Add(100))
	run := func(args ...string) string {
		t.Helper()
		out, err := exec.Command(binary, args...).CombinedOutput()
		if err != nil {
			t.Fatalf("pantheon %v: %v\n%s", args, err, out)
		}
		return string(out)
	}
	home := func(a string) string { return filepath.Join(root, a) }
	for i, a := range devnet.DefaultAgents {
		run("deploy", "keygen", "--home", home(a), "--agent", a, "--p2p-addr", fmt.Sprintf("127.0.0.1:%d", base+10*i), "--chain-id", "pantheon-test")
		raw, err := os.ReadFile(filepath.Join(home(a), "identity-"+a+".json"))
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(shared, "identity-"+a+".json"), raw, 0o644)
	}
	for _, a := range devnet.DefaultAgents {
		run("deploy", "deal", "--home", home(a), "--shared", shared)
	}
	gv, err := gitx.Version()
	if err != nil {
		t.Fatal(err)
	}
	p := market.DefaultParams()
	p.GitVersion = gv
	p.TermBlocks = 7
	raw, _ := json.Marshal(p)
	hashRe := regexp.MustCompile(`genesis sha256 ([0-9a-f]{64})`)
	when := time.Now().UTC().Format(time.RFC3339)
	var want string
	for i, a := range devnet.DefaultAgents {
		out := run("deploy", "finish", "--home", home(a), "--shared", shared, "--chain-id", "pantheon-test",
			"--genesis-time", when, "--seed-dir", seed, "--params", string(raw), "--block-ms", "100",
			"--p2p-listen", fmt.Sprintf("tcp://127.0.0.1:%d", base+10*i),
			"--rpc-listen", fmt.Sprintf("tcp://127.0.0.1:%d", base+1+10*i),
			"--metrics-listen", fmt.Sprintf("127.0.0.1:%d", base+2+10*i))
		m := hashRe.FindStringSubmatch(out)
		if m == nil {
			t.Fatalf("no genesis hash in %q", out)
		}
		if want == "" {
			want = m[1]
		} else if m[1] != want {
			t.Fatalf("%s computed a different genesis: %s vs %s", a, m[1], want)
		}
		if _, err := os.Stat(filepath.Join(home(a), "config", "ceremony_box.json")); err == nil {
			t.Fatal("ceremony secret was left on disk")
		}
		// No home may hold another agent's secrets.
		share, _ := os.ReadFile(devnet.SharePath(home(a)))
		for _, b := range devnet.DefaultAgents {
			if b == a {
				continue
			}
			other, _ := os.ReadFile(devnet.SharePath(home(b)))
			if len(other) > 0 && string(other) == string(share) {
				t.Fatal("two hosts share a BLS share")
			}
		}
	}
	n := &network{t: t, dir: root, port: base, procs: map[string]*exec.Cmd{}, senders: map[string]*client.Sender{}, stopped: map[string]bool{}}
	for i, a := range devnet.DefaultAgents {
		n.startNode(a)
		s, err := client.LoadSender(devnet.AppKeyPath(home(a)), devnet.RPCAddr(base, i))
		if err != nil {
			t.Fatal(err)
		}
		n.senders[a] = s
	}
	t.Cleanup(n.stopAll)
	n.work, err = gitx.Open(filepath.Join(t.TempDir(), "w.git"))
	if err != nil {
		t.Fatal(err)
	}
	s := n.waitFor("BLS-seeded rotation", 120*time.Second, func(s *market.State) bool { return s.Term >= 4 })
	if !strings.Contains(strings.Join(devnet.DefaultAgents, " "), s.LeaderHistory[len(s.LeaderHistory)-1]) {
		t.Fatalf("history %v", s.LeaderHistory)
	}
	n.waitFor("a task lands", 60*time.Second, func(st *market.State) bool {
		if st.TermLeader == "" {
			return false
		}
		res, err := n.senders[st.TermLeader].Send(ctx(t, 20*time.Second), market.Body{Type: market.TxPostTask, Spec: "works", BaseCommit: st.RepoHead})
		return err == nil && res.Err() == nil
	})
	n.agreeAll()
}
