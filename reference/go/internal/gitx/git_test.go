package gitx

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var testLimits = Limits{MaxBundleBytes: 512 << 10, MaxUnpackedBytes: 8 << 20, MaxPackObjects: 4096}

func seed(t *testing.T, files map[string]string) (*Repo, string) {
	t.Helper()
	src := t.TempDir()
	for p, c := range files {
		full := filepath.Join(src, p)
		os.MkdirAll(filepath.Dir(full), 0o755)
		if err := os.WriteFile(full, []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	b, commit, err := Snapshot(src, 1000)
	if err != nil {
		t.Fatal(err)
	}
	r, err := Open(filepath.Join(t.TempDir(), "r.git"))
	if err != nil {
		t.Fatal(err)
	}
	if got, err := r.ImportTrusted(b); err != nil || got != commit {
		t.Fatalf("import: %v %s != %s", err, got, commit)
	}
	return r, commit
}

func bid(t *testing.T, r *Repo, base string, edits map[string]string) []byte {
	t.Helper()
	wt, err := r.AddWorktree(t.TempDir(), base)
	if err != nil {
		t.Fatal(err)
	}
	defer wt.Remove()
	for p, c := range edits {
		if err := os.WriteFile(filepath.Join(wt.Dir, p), []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	c, err := wt.CommitAll("alice", "edit")
	if err != nil || c == "" {
		t.Fatalf("commit: %v %q", err, c)
	}
	b, err := r.BundleBid(c, base)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestSnapshotDeterministic(t *testing.T) {
	src := t.TempDir()
	os.WriteFile(filepath.Join(src, "a"), []byte("x"), 0o644)
	_, c1, err := Snapshot(src, 5)
	if err != nil {
		t.Fatal(err)
	}
	_, c2, _ := Snapshot(src, 5)
	if c1 != c2 || len(c1) != 64 {
		t.Fatalf("not deterministic or not sha256: %s %s", c1, c2)
	}
}

func TestImportMergeCleanAndConflict(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n", "b.txt": "1\n"})
	one := bid(t, r, base, map[string]string{"a.txt": "one\n"})
	two := bid(t, r, base, map[string]string{"a.txt": "two\n"})
	three := bid(t, r, base, map[string]string{"b.txt": "three\n"})

	c1, err := r.ImportBundle(one, testLimits, base)
	if err != nil {
		t.Fatal(err)
	}
	tree, clean, err := r.MergeTree(base, c1)
	if err != nil || !clean {
		t.Fatalf("merge: %v %v", clean, err)
	}
	head, err := r.CommitTree(tree, []string{base, c1}, "m", 2000)
	if err != nil {
		t.Fatal(err)
	}
	head2, _ := r.CommitTree(tree, []string{base, c1}, "m", 2000)
	if head != head2 {
		t.Fatal("merge commit not deterministic")
	}
	c2, err := r.ImportBundle(two, testLimits, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, clean, err = r.MergeTree(head, c2); err != nil || clean {
		t.Fatalf("expected conflict: clean=%v err=%v", clean, err)
	}
	c3, err := r.ImportBundle(three, testLimits, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, clean, err = r.MergeTree(head, c3); err != nil || !clean {
		t.Fatalf("expected clean: clean=%v err=%v", clean, err)
	}
}

func TestImportRequiresDescent(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n"})
	one := bid(t, r, base, map[string]string{"a.txt": "one\n"})
	c1, err := r.ImportBundle(one, testLimits, base)
	if err != nil {
		t.Fatal(err)
	}
	tree, _, _ := r.MergeTree(base, c1)
	head, _ := r.CommitTree(tree, []string{base, c1}, "m", 2000)
	two := bid(t, r, base, map[string]string{"a.txt": "two\n"})
	if err := r.UpdateMain(head); err != nil {
		t.Fatal(err)
	}
	if _, err := r.ImportBundle(two, testLimits, head); err == nil || !strings.Contains(err.Error(), "does not descend") {
		t.Fatalf("want descent error, got %v", err)
	}
}

func TestRejectedBundleLeavesNoObjects(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n"})
	b := bid(t, r, base, map[string]string{"a.txt": "one\n"})
	info, err := CheckBundle(b, testLimits)
	if err != nil {
		t.Fatal(err)
	}
	// A clean repo that has the base but not the bid objects.
	bundleAll, _ := r.BundleAll()
	other, _ := Open(filepath.Join(t.TempDir(), "o.git"))
	other.ImportTrusted(bundleAll)
	if _, err := other.ImportBundle(b, testLimits, info.Commit); err == nil {
		t.Fatal("want rejection when commit equals base")
	}
	if _, err := Run(other.Dir, nil, "cat-file", "-e", info.Commit); err == nil {
		t.Fatal("rejected bundle left objects behind")
	}
}

func TestCheckBundleRejectsBadInput(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n"})
	good := bid(t, r, base, map[string]string{"a.txt": "one\n"})
	if _, err := CheckBundle(good, testLimits); err != nil {
		t.Fatalf("good bundle: %v", err)
	}
	cases := map[string][]byte{
		"empty":     nil,
		"garbage":   []byte("hello\nworld\n\n"),
		"truncated": good[:len(good)-10],
		"corrupt":   append(append([]byte{}, good[:len(good)-1]...), good[len(good)-1]^1),
		"wrongref":  bytes.Replace(good, []byte(BidRef), []byte("refs/heads/xxx"), 1),
		"v2":        bytes.Replace(good, []byte("# v3 git bundle"), []byte("# v2 git bundle"), 1),
	}
	for name, b := range cases {
		if _, err := CheckBundle(b, testLimits); err == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

func TestCheckBundleStopsDecompressionBomb(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n"})
	wt, err := r.AddWorktree(t.TempDir(), base)
	if err != nil {
		t.Fatal(err)
	}
	defer wt.Remove()
	// 64 MiB of zeros deflates to about 64 KiB, well under the byte limit.
	if err := os.WriteFile(filepath.Join(wt.Dir, "bomb"), make([]byte, 64<<20), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := wt.CommitAll("mallory", "bomb")
	if err != nil {
		t.Fatal(err)
	}
	b, err := r.BundleBid(c, base)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) > testLimits.MaxBundleBytes {
		t.Fatalf("test assumes small bundle, got %d", len(b))
	}
	if _, err := CheckBundle(b, testLimits); err == nil || !strings.Contains(err.Error(), "budget") {
		t.Fatalf("want budget rejection, got %v", err)
	}
}

func TestCheckBundleCountsDeltaResultSize(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n"})
	wt, err := r.AddWorktree(t.TempDir(), base)
	if err != nil {
		t.Fatal(err)
	}
	defer wt.Remove()
	big := bytes.Repeat([]byte("incompressible-ish line\n"), 200000) // 4.8 MiB
	os.WriteFile(filepath.Join(wt.Dir, "big"), big, 0o644)
	c1, _ := wt.CommitAll("m", "one")
	os.WriteFile(filepath.Join(wt.Dir, "big"), append(big, 'x'), 0o644)
	c2, _ := wt.CommitAll("m", "two")
	_ = c1
	b, err := r.BundleBid(c2, base)
	if err != nil {
		t.Fatal(err)
	}
	info, err := CheckBundle(b, Limits{MaxUnpackedBytes: 64 << 20})
	if err != nil {
		t.Fatal(err)
	}
	if info.UnpackedBytes < int64(2*len(big)) {
		t.Fatalf("delta result not counted: %d", info.UnpackedBytes)
	}
	if _, err := CheckBundle(b, Limits{MaxUnpackedBytes: int64(len(big)) + 1024}); err == nil {
		t.Fatal("want rejection when both versions exceed budget")
	}
}

func TestDiffAndExport(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n", "d/b.txt": "2\n"})
	b := bid(t, r, base, map[string]string{"a.txt": "one\n"})
	c, err := r.AddBid(b, testLimits)
	if err != nil {
		t.Fatal(err)
	}
	files, patch, err := r.Diff(base, c, 1<<20)
	if err != nil || len(files) != 1 || files[0].Path != "a.txt" || !strings.Contains(patch, "+one") {
		t.Fatalf("diff: %v %+v %q", err, files, patch)
	}
	dst := t.TempDir()
	if err := r.ExportTree(c, dst); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(dst, "a.txt"))
	if string(got) != "one\n" {
		t.Fatalf("export: %q", got)
	}
	if _, err := os.Stat(filepath.Join(dst, ".git")); err == nil {
		t.Fatal("export leaked .git")
	}
}

// A bid that makes git die must lose only itself. Treating it as a local fault
// would halt every node at once, which would let any bidder stop the network.
func TestMergeTreeRefusalIsAResultNotAFault(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n"})
	missing := strings.Repeat("ab", 32)
	tree, clean, err := r.MergeTree(base, missing)
	if err != nil {
		t.Fatalf("git refusing an object must not be an infrastructure error: %v", err)
	}
	if clean || tree != "" {
		t.Fatalf("clean=%v tree=%q", clean, tree)
	}
}

func TestMergeDoesNotFollowRenames(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "one\ntwo\nthree\nfour\nfive\n"})
	// One side renames, the other edits: with renames off this must be a conflict,
	// so its cost stays bounded no matter how many files a bid moves.
	wt, err := r.AddWorktree(t.TempDir(), base)
	if err != nil {
		t.Fatal(err)
	}
	defer wt.Remove()
	if err := os.Rename(filepath.Join(wt.Dir, "a.txt"), filepath.Join(wt.Dir, "moved.txt")); err != nil {
		t.Fatal(err)
	}
	renamed, err := wt.CommitAll("x", "rename")
	if err != nil {
		t.Fatal(err)
	}
	wt2, err := r.AddWorktree(t.TempDir(), base)
	if err != nil {
		t.Fatal(err)
	}
	defer wt2.Remove()
	os.WriteFile(filepath.Join(wt2.Dir, "a.txt"), []byte("one\ntwo\nthree\nfour\nsix\n"), 0o644)
	edited, err := wt2.CommitAll("y", "edit")
	if err != nil {
		t.Fatal(err)
	}
	if _, clean, err := r.MergeTree(renamed, edited); err != nil || clean {
		t.Fatalf("clean=%v err=%v", clean, err)
	}
}

// Only the current head may be a prerequisite. Anything else could make every node
// rehash retained objects at will, or be importable only by nodes.
func TestPrerequisiteMustBeExactlyHead(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n"})
	first := bid(t, r, base, map[string]string{"a.txt": "2\n"})
	p, err := r.ImportBundle(first, testLimits, base)
	if err != nil {
		t.Fatal(err)
	}
	child := bid(t, r, p, map[string]string{"a.txt": "3\n"})
	if _, err := r.ImportBundle(child, testLimits, base); err == nil || !strings.Contains(err.Error(), "only prerequisite") {
		t.Fatalf("child of a non-head commit: %v", err)
	}
	all, err := r.BundleAll()
	if err != nil {
		t.Fatal(err)
	}
	_ = all
	// A bundle with no prerequisites at all is refused too.
	full, err := r.BundleBid(p, strings.Repeat("0", 64))
	if err == nil {
		if _, err := r.ImportBundle(full, testLimits, base); err == nil {
			t.Fatal("bundle with no prerequisite accepted")
		}
	}
}

// bundleOmitting hand-assembles a bundle whose tree names a blob the pack doesn't
// carry. git bundle would always pack it, but an attacker isn't limited to git.
func bundleOmitting(t *testing.T, r *Repo, base, blob string) []byte {
	t.Helper()
	ls, err := Run(r.Dir, nil, "ls-tree", base)
	if err != nil {
		t.Fatal(err)
	}
	run := func(stdin string, args ...string) []byte {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = r.Dir
		cmd.Env = Env()
		cmd.Stdin = strings.NewReader(stdin)
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("git %v: %v", args, err)
		}
		return out
	}
	tree := strings.TrimSpace(string(run(ls+"100644 blob "+blob+"\tstolen.txt\n", "mktree", "--missing")))
	c, err := r.CommitTreeAs("m", tree, []string{base}, "m", 5000)
	if err != nil {
		t.Fatal(err)
	}
	pack := run(c+"\n"+tree+"\n", "pack-objects", "--stdout", "-q")
	header := "# v3 git bundle\n@object-format=sha256\n-" + base + " base\n" + c + " " + BidRef + "\n\n"
	return append([]byte(header), pack...)
}

// The crash-replay fork. A bundle naming objects from a later transaction in its
// block is rejected on the first pass. A crash must leave nothing behind that would
// let it pass on replay, or this node's state forks from the others.
func TestStagingMakesReplaySeeTheSameObjects(t *testing.T) {
	builder, base := seed(t, map[string]string{"a.txt": "1\n"})
	honest := bid(t, builder, base, map[string]string{"b.txt": "honest\n"})
	info, err := CheckBundle(honest, testLimits)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := builder.ImportBundle(honest, testLimits, base); err != nil {
		t.Fatal(err)
	}
	blobOut, err := Run(builder.Dir, nil, "rev-parse", info.Commit+":b.txt")
	if err != nil {
		t.Fatal(err)
	}
	mal := bundleOmitting(t, builder, base, strings.TrimSpace(blobOut))
	if _, err := CheckBundle(mal, testLimits); err != nil {
		t.Fatalf("the crafted bundle must pass structural checks: %v", err)
	}
	all, err := builder.BundleAll()
	if err != nil {
		t.Fatal(err)
	}
	fresh := func() *Repo {
		n, err := Open(filepath.Join(t.TempDir(), "n.git"))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := n.ImportTrusted(all); err != nil {
			t.Fatal(err)
		}
		return n
	}

	// First show the hazard is real: with no staging, objects from the first pass
	// survive the "crash" and replay reaches a different verdict.
	bare := fresh()
	if _, err := bare.ImportBundle(mal, testLimits, base); err == nil {
		t.Fatal("first pass: a bundle naming an absent object must be rejected")
	}
	if _, err := bare.ImportBundle(honest, testLimits, base); err != nil {
		t.Fatal(err)
	}
	if _, err := bare.ImportBundle(mal, testLimits, base); err != nil {
		t.Fatalf("expected the unstaged replay to accept it, or this test proves nothing: %v", err)
	}

	// With staging, a crash takes the block's objects with it.
	node := fresh()
	if err := node.BeginStage(7); err != nil {
		t.Fatal(err)
	}
	if _, err := node.ImportBundle(mal, testLimits, base); err == nil {
		t.Fatal("first pass: a bundle naming an absent object must be rejected")
	}
	if _, err := node.ImportBundle(honest, testLimits, base); err != nil {
		t.Fatalf("first pass: honest bid: %v", err)
	}
	restarted := &Repo{Dir: node.Dir}
	if err := restarted.RecoverStage(6); err != nil { // state still at height 6
		t.Fatal(err)
	}
	if err := restarted.BeginStage(7); err != nil {
		t.Fatal(err)
	}
	if _, err := restarted.ImportBundle(mal, testLimits, base); err == nil {
		t.Fatal("replay accepted what the first pass rejected: this node would fork")
	}
	if _, err := restarted.ImportBundle(honest, testLimits, base); err != nil {
		t.Fatalf("replay: honest bid: %v", err)
	}
	if err := restarted.Promote(); err != nil {
		t.Fatal(err)
	}
	if _, err := Run(restarted.Dir, nil, "cat-file", "-e", info.Commit); err != nil {
		t.Fatalf("promoted objects missing: %v", err)
	}
}

func TestRecoverStageFinishesACommittedBlock(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n"})
	builder, _ := seed(t, map[string]string{"a.txt": "1\n"})
	b := bid(t, builder, base, map[string]string{"a.txt": "2\n"})
	if err := r.BeginStage(3); err != nil {
		t.Fatal(err)
	}
	c, err := r.ImportBundle(b, testLimits, base)
	if err != nil {
		t.Fatal(err)
	}
	// State reached height 3 but the crash came before Promote.
	restarted := &Repo{Dir: r.Dir}
	if err := restarted.RecoverStage(3); err != nil {
		t.Fatal(err)
	}
	if _, err := Run(restarted.Dir, nil, "cat-file", "-e", c); err != nil {
		t.Fatalf("committed block's objects were lost: %v", err)
	}
}

// makeTreeBomb builds a commit whose tree stands for fanout^depth paths in a few KiB.
func makeTreeBomb(t *testing.T, r *Repo, base string, fanout, depth int) string {
	t.Helper()
	mktree := func(input string) string {
		cmd := exec.Command("git", "mktree")
		cmd.Dir = r.Dir
		cmd.Env = Env()
		cmd.Stdin = strings.NewReader(input)
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		return strings.TrimSpace(string(out))
	}
	cmd := exec.Command("git", "hash-object", "-w", "--stdin")
	cmd.Dir = r.Dir
	cmd.Env = Env()
	cmd.Stdin = strings.NewReader("x\n")
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	blob := strings.TrimSpace(string(out))
	var in strings.Builder
	for i := 0; i < fanout; i++ {
		fmt.Fprintf(&in, "100644 blob %s\tf%d\n", blob, i)
	}
	tree := mktree(in.String())
	for d := 0; d < depth; d++ {
		in.Reset()
		for i := 0; i < fanout; i++ {
			fmt.Fprintf(&in, "040000 tree %s\td%d\n", tree, i)
		}
		tree = mktree(in.String())
	}
	ls, err := Run(r.Dir, nil, "ls-tree", base)
	if err != nil {
		t.Fatal(err)
	}
	root := mktree(ls + "040000 tree " + tree + "\tbomb\n")
	c, err := r.CommitTreeAs("m", root, []string{base}, "bomb", 5000)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestDiffIsBoundedAgainstTreeBombs(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n"})
	c := makeTreeBomb(t, r, base, 10, 11) // 10^12 paths
	b, err := r.BundleBid(c, base)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) > 8<<10 {
		t.Fatalf("expected a tiny bundle, got %d bytes", len(b))
	}
	if _, err := CheckBundle(b, testLimits); err != nil {
		t.Fatalf("the bomb should pass structural limits, or this test proves nothing: %v", err)
	}
	// Merge-tree must stay cheap, since it runs in consensus.
	start := time.Now()
	if _, clean, err := r.MergeTree(base, c); err != nil || !clean {
		t.Fatalf("merge-tree: clean=%v err=%v", clean, err)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("merge-tree took %v on a tree bomb", d)
	}
	start = time.Now()
	if _, _, err := r.Diff(base, c, 1<<20); !errors.Is(err, ErrDiffTooLarge) {
		t.Fatalf("want ErrDiffTooLarge, got %v", err)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("rejecting a tree bomb took %v: it must not expand the tree", d)
	}
}

func TestChangedPathsCountsCorrectly(t *testing.T) {
	r, base := seed(t, map[string]string{"a.txt": "1\n", "d/b.txt": "2\n", "d/e/c.txt": "3\n", "keep.txt": "4\n"})
	wt, err := r.AddWorktree(t.TempDir(), base)
	if err != nil {
		t.Fatal(err)
	}
	defer wt.Remove()
	os.WriteFile(filepath.Join(wt.Dir, "a.txt"), []byte("changed\n"), 0o644)        // modified: 1
	os.Remove(filepath.Join(wt.Dir, "d", "b.txt"))                                  // deleted: 1
	os.MkdirAll(filepath.Join(wt.Dir, "new", "deep"), 0o755)                        //
	os.WriteFile(filepath.Join(wt.Dir, "new", "deep", "x.txt"), []byte("x"), 0o644) // added: 1
	os.WriteFile(filepath.Join(wt.Dir, "new", "y.txt"), []byte("y"), 0o644)         // added: 1
	c, err := wt.CommitAll("m", "edits")
	if err != nil {
		t.Fatal(err)
	}
	n, err := r.ChangedPaths(base, c, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if n != 4 {
		t.Fatalf("counted %d changed paths, want 4", n)
	}
	files, _, err := r.Diff(base, c, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != n {
		t.Fatalf("diff saw %d files, counter saw %d", len(files), n)
	}
	if n, err := r.ChangedPaths(base, base, 1000); err != nil || n != 0 {
		t.Fatalf("no change: %d %v", n, err)
	}
}
