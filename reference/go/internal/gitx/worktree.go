package gitx

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Everything in this file runs in wrappers, outside consensus.

// BidIdentity sets the author on commits a wrapper makes for its agent.
func BidIdentity(agent string) []string {
	mail := agent + "@pantheon.invalid"
	return []string{"GIT_AUTHOR_NAME=" + agent, "GIT_AUTHOR_EMAIL=" + mail, "GIT_COMMITTER_NAME=" + agent, "GIT_COMMITTER_EMAIL=" + mail}
}

// Sync makes the bare repo contain the given standalone bundle's main.
func (r *Repo) Sync(all []byte) (string, error) {
	return r.ImportTrusted(all)
}

// AddBid imports a bid bundle into refs/bids/<commit> without validation limits
// beyond those supplied; wrappers use it to inspect bids they have fetched.
func (r *Repo) AddBid(bundle []byte, lim Limits) (string, error) {
	return r.ImportBundle(bundle, lim, "")
}

// Worktree is a scratch checkout for building or testing a commit.
type Worktree struct {
	Dir  string
	repo *Repo
}

// AddWorktree checks commit out into a new detached worktree under parent.
func (r *Repo) AddWorktree(parent, commit string) (*Worktree, error) {
	dir, err := os.MkdirTemp(parent, "wt-*")
	if err != nil {
		return nil, err
	}
	if _, err := r.git(nil, "worktree", "add", "--quiet", "--detach", "--force", dir, commit); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	return &Worktree{Dir: dir, repo: r}, nil
}

// Remove deletes the worktree and its bookkeeping.
func (w *Worktree) Remove() {
	_, _ = w.repo.git(nil, "worktree", "remove", "--force", w.Dir)
	_ = os.RemoveAll(w.Dir)
}

// CommitAll commits every change in the worktree and returns the commit.
// Empty is reported as "" so callers can tell the LLM produced no change.
func (w *Worktree) CommitAll(agent, message string) (string, error) {
	if _, err := Run(w.Dir, nil, "add", "-A"); err != nil {
		return "", err
	}
	if _, err := Run(w.Dir, nil, "diff", "--cached", "--quiet"); err == nil {
		return "", nil
	}
	if _, err := Run(w.Dir, BidIdentity(agent), "commit", "-q", "--no-verify", "-m", message); err != nil {
		return "", err
	}
	out, err := Run(w.Dir, nil, "rev-parse", "HEAD")
	return strings.TrimSpace(out), err
}

// BundleBid packs base..commit into a market bundle (head named refs/heads/bid).
func (r *Repo) BundleBid(commit, base string) ([]byte, error) {
	if _, err := r.git(nil, "update-ref", BidRef, commit); err != nil {
		return nil, err
	}
	dir, err := os.MkdirTemp("", "pantheon-bid-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	name := filepath.Join(dir, "bid.bundle")
	if _, err := r.git(nil, "bundle", "create", "--quiet", name, BidRef, "^"+base); err != nil {
		return nil, err
	}
	return os.ReadFile(name)
}

// ChangedFile is one entry of a diff between two commits.
type ChangedFile struct {
	Status string // git's status letter: A, M, D, R, ...
	Mode   string // new mode
	Path   string
}

// ErrDiffTooLarge means a diff exceeded its bound, which is a verdict on the bid.
var ErrDiffTooLarge = errors.New("diff is too large to review")

// bounded runs git, stopping as soon as output passes limit. This covers large
// blobs in a patch. It doesn't cover tree bombs, because diff-tree queues every path
// before printing any: ChangedPaths has to run first, which Diff does.
func (r *Repo) bounded(limit int, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = r.Dir
	cmd.Env = Env()
	out, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	if err := cmd.Start(); err != nil {
		return "", err
	}
	raw, readErr := io.ReadAll(io.LimitReader(out, int64(limit)+1))
	if len(raw) > limit || readErr != nil {
		cancel()
		_ = cmd.Wait()
		return "", ErrDiffTooLarge
	}
	if err := cmd.Wait(); err != nil {
		if ctx.Err() != nil {
			return "", ErrDiffTooLarge
		}
		return "", err
	}
	return string(raw), nil
}

// Diff returns the changed files and unified patch between two trees or commits,
// with rename detection off so every touched path is visible. Each output is bound
// by limit, returning ErrDiffTooLarge past it. It reads hostile trees: use only this
// to look at a bid, before any other tool walks its tree.
func (r *Repo) Diff(from, to string, limit int) ([]ChangedFile, string, error) {
	n, err := r.ChangedPaths(from, to, MaxChangedPaths)
	if err != nil {
		return nil, "", err
	}
	if n > MaxChangedPaths {
		return nil, "", fmt.Errorf("%w: over %d changed paths", ErrDiffTooLarge, MaxChangedPaths)
	}
	raw, err := r.bounded(limit, "diff-tree", "-r", "--no-renames", "-z", "--raw", from, to)
	if err != nil {
		return nil, "", err
	}
	fields := strings.Split(strings.TrimSuffix(raw, "\x00"), "\x00")
	var files []ChangedFile
	for i := 0; i+1 < len(fields); i += 2 {
		meta := strings.Fields(strings.TrimPrefix(fields[i], ":"))
		if len(meta) < 5 {
			continue
		}
		files = append(files, ChangedFile{Status: meta[4], Mode: meta[1], Path: fields[i+1]})
	}
	patch, err := r.bounded(limit, "diff-tree", "-r", "--no-renames", "-p", from, to)
	if err != nil {
		return nil, "", err
	}
	return files, patch, nil
}

// ListFiles returns the paths tracked by a commit.
func (r *Repo) ListFiles(commit string) ([]string, error) {
	out, err := r.git(nil, "ls-tree", "-r", "-z", "--name-only", commit)
	if err != nil {
		return nil, err
	}
	out = strings.TrimSuffix(out, "\x00")
	if out == "" {
		return nil, nil
	}
	return strings.Split(out, "\x00"), nil
}

// ReadFile returns a file's bytes at a commit.
func (r *Repo) ReadFile(commit, path string) (string, error) {
	return r.git(nil, "cat-file", "blob", commit+":"+path)
}

// ExportTree writes a tree or commit's files into dir with no git metadata, so
// nothing from the repo (hooks, config) can reach a sandbox.
func (r *Repo) ExportTree(treeish, dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tar := filepath.Join(dir, ".export.tar")
	if _, err := r.git(nil, "archive", "--format=tar", "-o", tar, treeish); err != nil {
		return err
	}
	defer os.Remove(tar)
	return extractTar(tar, dir)
}

// CommitTreeAs writes a commit authored by an agent. Used in wrappers only: it
// may use wall-clock time because the result travels in a bundle, not by replay.
func (r *Repo) CommitTreeAs(agent, tree string, parents []string, message string, unixTime int64) (string, error) {
	date := "@" + strconv.FormatInt(unixTime, 10) + " +0000"
	env := append(BidIdentity(agent), "GIT_AUTHOR_DATE="+date, "GIT_COMMITTER_DATE="+date)
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
