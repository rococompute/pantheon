// Package gitx wraps the pinned git binary for deterministic repository work.
//
// Everything here runs inside consensus (FinalizeBlock) unless noted, so it must
// be a pure function of its inputs: config is isolated from the host, dates and
// identities are supplied by the caller, and nothing touches the network. The
// object store only ever grows, so replaying a block after a crash is harmless.
package gitx

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// BidRef is the only ref name a market bundle may advertise.
const BidRef = "refs/heads/bid"

// MainRef tracks repo_head in the node's bare repo.
const MainRef = "refs/heads/main"

// Repo is a bare sha256 repository owned by one node or wrapper.
type Repo struct {
	Dir   string // absolute
	stage string // the current block's staging directory, or empty
}

// Env is the isolated environment every git invocation runs with.
func Env() []string {
	return []string{
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=" + os.DevNull,
		"GIT_ATTR_NOSYSTEM=1",
		"GIT_TERMINAL_PROMPT=0",
		"GIT_OPTIONAL_LOCKS=0",
		"HOME=" + os.TempDir(),
		"LC_ALL=C",
		"TZ=UTC",
		"PATH=" + os.Getenv("PATH"),
	}
}

// Run executes git in dir and returns stdout. Errors include stderr.
func Run(dir string, env []string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(Env(), env...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return out.String(), &Error{Args: args, Stderr: strings.TrimSpace(errb.String()), Err: err}
	}
	return out.String(), nil
}

// Error is a failed git invocation.
type Error struct {
	Args   []string
	Stderr string
	Err    error
}

func (e *Error) Error() string {
	return fmt.Sprintf("git %s: %v: %s", strings.Join(e.Args, " "), e.Err, e.Stderr)
}

// ExitCode returns the process exit code, or -1 when git did not run.
func (e *Error) ExitCode() int {
	var ee *exec.ExitError
	if errors.As(e.Err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// ErrInfra marks a failure of this machine rather than of the input: disk full,
// git missing, a process killed. It must never become a recorded market outcome,
// because other nodes won't share it.
var ErrInfra = errors.New("local infrastructure failure")

func infra(err error) error { return fmt.Errorf("%w: %v", ErrInfra, err) }

var versionRe = regexp.MustCompile(`git version (\d+\.\d+\.\d+)`)

// Version returns the installed git's x.y.z version.
func Version() (string, error) {
	out, err := Run("", nil, "version")
	if err != nil {
		return "", err
	}
	m := versionRe.FindStringSubmatch(out)
	if m == nil {
		return "", fmt.Errorf("cannot parse git version from %q", out)
	}
	return m[1], nil
}

// Open returns the repo at dir, creating a bare sha256 repo if it is missing.
func Open(dir string) (*Repo, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	dir = abs
	r := &Repo{Dir: dir}
	if _, err := os.Stat(filepath.Join(dir, "HEAD")); err == nil {
		return r, nil
	}
	if err := initBare(dir); err != nil {
		return nil, err
	}
	return r, nil
}

func initBare(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if _, err := Run(dir, nil, "init", "-q", "--bare", "--object-format=sha256", "--initial-branch=main", "--template=", "."); err != nil {
		return err
	}
	_, err := Run(dir, nil, "config", "gc.auto", "0")
	return err
}

func (r *Repo) git(env []string, args ...string) (string, error) {
	if r.stage != "" {
		env = append(env,
			"GIT_OBJECT_DIRECTORY="+filepath.Join(r.stage, "objects"),
			"GIT_ALTERNATE_OBJECT_DIRECTORIES="+filepath.Join(r.Dir, "objects"))
	}
	return Run(r.Dir, env, args...)
}

// fsckFlags reject malformed or path-traversing objects when fetching.
var fsckFlags = []string{"-c", "transfer.fsckObjects=true", "-c", "fetch.fsckObjects=true"}

// localFaultRe matches git failures caused by this machine, not by the input.
var localFaultRe = regexp.MustCompile(`(?i)no space left|too many open files|cannot allocate|out of memory|cannot fork|resource temporarily unavailable|read-only file system|input/output error|permission denied|disk quota`)

// classify turns a git failure on hostile input into either a verdict about that
// input (returned as is) or ErrInfra, which halts this node. Any node hitting a
// local fault must stop instead of recording a result the others won't share.
func classify(err error) error {
	var ge *Error
	if errors.As(err, &ge) && (ge.ExitCode() <= 0 || localFaultRe.MatchString(ge.Stderr)) {
		return infra(err)
	}
	return err
}

// ImportBundle validates a bundle and adds its objects to the repo, returning the
// bid commit. When head is set, the bundle's only prerequisite must be exactly
// head, and the bid must strictly descend from it. Pinning the prerequisite stops
// a bundle making git rehash arbitrary retained objects, and stops bids that only
// nodes can import because they rely on another bid's objects.
//
// Validation happens in a throwaway repo that borrows our objects via alternates,
// so a rejected bundle leaves no residue that could change the outcome of a later
// bundle on this node but not on another. The throwaway ignores our refs, so what
// it accepts depends only on the object store, which staging keeps identical on
// every node at every point in a block, even across a crash.
func (r *Repo) ImportBundle(bundle []byte, limits Limits, head string) (string, error) {
	info, err := CheckBundle(bundle, limits)
	if err != nil {
		return "", err
	}
	if head != "" && (len(info.Prerequisites) != 1 || info.Prerequisites[0] != head) {
		return "", fmt.Errorf("bid commit %s does not descend directly from current head %s: its bundle must have that head as its only prerequisite (found %d). Rebase and resubmit", info.Commit, head, len(info.Prerequisites))
	}
	parent := filepath.Join(r.Dir, "quarantine")
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return "", infra(err)
	}
	tmp, err := os.MkdirTemp(parent, "bundle-*")
	if err != nil {
		return "", infra(err)
	}
	defer os.RemoveAll(tmp)
	bundlePath := filepath.Join(tmp, "bid.bundle")
	if err := os.WriteFile(bundlePath, bundle, 0o644); err != nil {
		return "", infra(err)
	}
	q := filepath.Join(tmp, "q.git")
	if err := initBare(q); err != nil {
		return "", infra(err)
	}
	if err := os.MkdirAll(filepath.Join(q, "objects", "info"), 0o755); err != nil {
		return "", infra(err)
	}
	alternates := filepath.Join(r.Dir, "objects") + "\n"
	target := filepath.Join(r.Dir, "objects")
	if r.stage != "" {
		target = filepath.Join(r.stage, "objects")
		alternates = target + "\n" + alternates
	}
	if err := os.WriteFile(filepath.Join(q, "objects", "info", "alternates"), []byte(alternates), 0o644); err != nil {
		return "", infra(err)
	}
	if head != "" {
		if _, err := Run(q, nil, "update-ref", "refs/base", head); err != nil {
			return "", classify(fmt.Errorf("bundle's base: %w", err))
		}
	}
	args := append([]string{}, fsckFlags...)
	// Don't consult the main repo's refs: only the objects themselves may matter.
	args = append(args, "-c", "core.alternateRefsCommand=true", "fetch", "--quiet", "--no-tags", "--no-auto-maintenance", "--no-write-fetch-head", bundlePath, "+"+BidRef+":refs/quarantine/bid")
	if _, err := Run(q, nil, args...); err != nil {
		return "", fmt.Errorf("bundle rejected: %w", classify(err))
	}
	typ, err := Run(q, nil, "cat-file", "-t", info.Commit)
	if err != nil || strings.TrimSpace(typ) != "commit" {
		return "", errors.New("bundle head is not a commit")
	}
	if head != "" {
		if info.Commit == head {
			return "", errors.New("bundle adds nothing: commit equals head")
		}
		if _, err := Run(q, nil, "merge-base", "--is-ancestor", head, info.Commit); err != nil {
			if err := classify(err); errors.Is(err, ErrInfra) {
				return "", err
			}
			return "", fmt.Errorf("bid commit %s does not descend from current head %s; rebase and resubmit", info.Commit, head)
		}
	}
	if err := moveObjects(filepath.Join(q, "objects"), target); err != nil {
		return "", infra(err)
	}
	return info.Commit, nil
}

// moveObjects moves loose objects and packs between stores on one filesystem.
// It can safely rerun after a crash: anything already moved is simply skipped. A
// pack's .idx moves last, because that's the file that makes git see the pack.
func moveObjects(src, dst string) error {
	var files, idx []string
	err := filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if d.IsDir() {
			if rel == "info" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(d.Name(), "tmp_") {
			return nil
		}
		if strings.HasSuffix(rel, ".idx") {
			idx = append(idx, rel)
		} else {
			files = append(files, rel)
		}
		return nil
	})
	if err != nil {
		return err
	}
	for _, rel := range append(files, idx...) {
		to := filepath.Join(dst, rel)
		if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
			return err
		}
		if _, err := os.Stat(to); err == nil {
			continue
		}
		if err := os.Rename(filepath.Join(src, rel), to); err != nil {
			return err
		}
	}
	return nil
}

func (r *Repo) stageRoot() string { return filepath.Join(r.Dir, "stage") }

// BeginStage directs all new objects to a staging store for this block. Without
// it, a crash before Commit would leave objects behind for the replay to find: a
// bundle whose trees reference another transaction's objects could then be
// accepted on replay after being rejected the first time, forking this node.
func (r *Repo) BeginStage(height int64) error {
	if r.stage != "" {
		return fmt.Errorf("stage already open at block %d boundary: the last block was never committed", height)
	}
	root := r.stageRoot()
	if err := os.RemoveAll(root); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(root, "objects", "pack"), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "height"), []byte(strconv.FormatInt(height, 10)), 0o644); err != nil {
		return err
	}
	r.stage = root
	return nil
}

// Promote makes the staged objects permanent. Call it only after the state that
// names them is durable. RecoverStage finishes the job after a crash in between.
func (r *Repo) Promote() error {
	root := r.stageRoot()
	if _, err := os.Stat(root); os.IsNotExist(err) {
		r.stage = ""
		return nil
	}
	if err := moveObjects(filepath.Join(root, "objects"), filepath.Join(r.Dir, "objects")); err != nil {
		return err
	}
	r.stage = ""
	return os.RemoveAll(root)
}

// DiscardStage drops an unfinished block's objects.
func (r *Repo) DiscardStage() error {
	r.stage = ""
	return os.RemoveAll(r.stageRoot())
}

// RecoverStage runs at startup. A stage for a block the state already includes
// gets finished, and one for a later block gets dropped, to be replayed.
func (r *Repo) RecoverStage(committedHeight int64) error {
	if err := os.RemoveAll(filepath.Join(r.Dir, "quarantine")); err != nil {
		return err
	}
	raw, err := os.ReadFile(filepath.Join(r.stageRoot(), "height"))
	if os.IsNotExist(err) {
		return os.RemoveAll(r.stageRoot())
	}
	if err != nil {
		return err
	}
	h, err := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil {
		return r.DiscardStage()
	}
	if h <= committedHeight {
		return r.Promote()
	}
	return r.DiscardStage()
}

// MergeTree computes the merge of ours and theirs without a worktree.
//
// Any verdict git reaches counts as a result: exit 1 is a conflict, and an error
// exit means git refused these objects. Both give clean=false, so hostile objects
// that make git die can only lose their own bid. They can't halt the network, as
// they could if an error exit stopped the node on every host at once. err is only
// set when git did not reach a verdict at all, such as failing to start or being
// killed, which is a problem with this machine.
//
// Rename detection is off. It costs quadratic time in the number of changed files,
// which a bid could exploit during FinalizeBlock, and being conservative here just
// makes a bidder rebase now and then.
func (r *Repo) MergeTree(ours, theirs string) (tree string, clean bool, err error) {
	out, err := r.git(nil, "-c", "merge.renames=false", "merge-tree", "--write-tree", "--no-messages", ours, theirs)
	if err != nil {
		if err := classify(err); errors.Is(err, ErrInfra) {
			return "", false, err
		}
		return "", false, nil
	}
	line, _, _ := strings.Cut(out, "\n")
	return strings.TrimSpace(line), true, nil
}

// Identity is the fixed author and committer of chain-made commits.
const Identity = "pantheon-market"

// CommitTree writes a commit with identity and dates fixed by the caller, so
// every node gets the same hash. unixTime must come from consensus.
func (r *Repo) CommitTree(tree string, parents []string, message string, unixTime int64) (string, error) {
	date := fmt.Sprintf("@%d +0000", unixTime)
	env := []string{
		"GIT_AUTHOR_NAME=" + Identity, "GIT_AUTHOR_EMAIL=market@pantheon.invalid", "GIT_AUTHOR_DATE=" + date,
		"GIT_COMMITTER_NAME=" + Identity, "GIT_COMMITTER_EMAIL=market@pantheon.invalid", "GIT_COMMITTER_DATE=" + date,
	}
	args := []string{"commit-tree", tree}
	for _, p := range parents {
		args = append(args, "-p", p)
	}
	args = append(args, "-m", message)
	out, err := r.git(env, args...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

// UpdateMain points refs/heads/main at commit. Purely a convenience for humans
// and clones: state.repo_head is what consensus commits to.
func (r *Repo) UpdateMain(commit string) error {
	_, err := r.git(nil, "update-ref", MainRef, commit)
	return err
}

// BundleAll packs main into a standalone bundle. Used by Query, not consensus.
func (r *Repo) BundleAll() ([]byte, error) {
	f, err := os.CreateTemp("", "pantheon-all-*.bundle")
	if err != nil {
		return nil, err
	}
	name := f.Name()
	f.Close()
	defer os.Remove(name)
	if _, err := r.git(nil, "bundle", "create", "--quiet", name, MainRef); err != nil {
		return nil, err
	}
	return os.ReadFile(name)
}

// ImportTrusted fetches a standalone bundle into refs/heads/main. Used only for
// the genesis snapshot, which is itself part of the genesis file everyone signs.
func (r *Repo) ImportTrusted(bundle []byte) (string, error) {
	f, err := os.CreateTemp("", "pantheon-genesis-*.bundle")
	if err != nil {
		return "", err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err := f.Write(bundle); err != nil {
		f.Close()
		return "", err
	}
	f.Close()
	if _, err := r.git(nil, "fetch", "--quiet", "--no-tags", "--no-auto-maintenance", "--no-write-fetch-head", name, "+"+MainRef+":"+MainRef); err != nil {
		return "", err
	}
	out, err := r.git(nil, "rev-parse", MainRef)
	return strings.TrimSpace(out), err
}

// Snapshot builds a deterministic one-commit bundle from a directory (nil for an
// empty tree) and returns the bundle and commit. Used when creating a genesis.
func Snapshot(srcDir string, unixTime int64) ([]byte, string, error) {
	tmp, err := os.MkdirTemp("", "pantheon-snap-*")
	if err != nil {
		return nil, "", err
	}
	defer os.RemoveAll(tmp)
	if _, err := Run(tmp, nil, "init", "-q", "--object-format=sha256", "--initial-branch=main", "--template=", "."); err != nil {
		return nil, "", err
	}
	if srcDir != "" {
		abs, err := filepath.Abs(srcDir)
		if err != nil {
			return nil, "", err
		}
		if _, err := Run(tmp, []string{"GIT_WORK_TREE=" + abs, "GIT_DIR=" + filepath.Join(tmp, ".git")}, "add", "-A", "--", "."); err != nil {
			return nil, "", err
		}
	}
	treeOut, err := Run(tmp, nil, "write-tree")
	if err != nil {
		return nil, "", err
	}
	r := &Repo{Dir: tmp}
	commit, err := r.CommitTree(strings.TrimSpace(treeOut), nil, "genesis snapshot", unixTime)
	if err != nil {
		return nil, "", err
	}
	if err := r.UpdateMain(commit); err != nil {
		return nil, "", err
	}
	data, err := r.BundleAll()
	return data, commit, err
}
