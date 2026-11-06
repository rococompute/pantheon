// Package agent is the wrapper around each LLM: it holds the key, watches the
// chain, prompts the model, and decides deterministically what gets signed. The
// LLM proposes and the wrapper disposes. It never sees a key or the protocol.
package agent

import (
	"fmt"
	"regexp"
	"strings"

	"pantheon/internal/gitx"
)

// Policy is the wrapper's deterministic gate. Every bid passes through it before
// this agent signs, merges or approves it.
type Policy struct {
	AllowedPaths   []string `json:"allowed_paths"`
	DeniedPaths    []string `json:"denied_paths"`
	MaxFiles       int      `json:"max_files"`
	MaxDiffBytes   int      `json:"max_diff_bytes"`
	BannedPatterns []string `json:"banned_patterns"` // regexes over added lines
}

// DefaultPolicy denies repo-control files and links, and common secret and
// remote-execution patterns. Add your test files to DeniedPaths, so a bid can't
// pass CI by rewriting the tests that judge it.
func DefaultPolicy() Policy {
	return Policy{
		AllowedPaths: []string{"**"},
		// .gitattributes at any depth: `export-ignore` could hide files from the tree
		// CI sees, so a bid would pass by removing what tests would have caught.
		DeniedPaths:  []string{"**/.git/**", "**/.gitmodules", "**/.gitattributes", ".github/**"},
		MaxFiles:     50,
		MaxDiffBytes: 256 << 10,
		BannedPatterns: []string{
			`-----BEGIN [A-Z ]*PRIVATE KEY-----`,
			`(?i)(curl|wget)[^\n|]*\|\s*(ba|z)?sh`,
			`rm\s+-rf\s+/(\s|$)`,
			`(?i)xai-[a-z0-9]{20,}|sk-[a-zA-Z0-9_-]{20,}`,
		},
	}
}

// Violation describes the first rule a change broke, or is empty when it passes.
func (p Policy) Violation(files []gitx.ChangedFile, patch string) (string, error) {
	if p.MaxFiles > 0 && len(files) > p.MaxFiles {
		return fmt.Sprintf("changes %d files, limit is %d", len(files), p.MaxFiles), nil
	}
	if p.MaxDiffBytes > 0 && len(patch) > p.MaxDiffBytes {
		return fmt.Sprintf("diff is %d bytes, limit is %d", len(patch), p.MaxDiffBytes), nil
	}
	for _, f := range files {
		if f.Mode == "120000" || f.Mode == "160000" {
			return fmt.Sprintf("%s is a symlink or submodule, which are not allowed", f.Path), nil
		}
		denied, err := matchAny(p.DeniedPaths, f.Path)
		if err != nil {
			return "", err
		}
		if denied {
			return fmt.Sprintf("%s is on the denied path list", f.Path), nil
		}
		allowed, err := matchAny(p.AllowedPaths, f.Path)
		if err != nil {
			return "", err
		}
		if !allowed {
			return fmt.Sprintf("%s is outside the allowed paths", f.Path), nil
		}
	}
	added := addedLines(patch)
	for _, pat := range p.BannedPatterns {
		re, err := regexp.Compile(pat)
		if err != nil {
			return "", fmt.Errorf("banned pattern %q: %w", pat, err)
		}
		if re.MatchString(added) {
			return fmt.Sprintf("added lines match banned pattern %q", pat), nil
		}
	}
	return "", nil
}

func addedLines(patch string) string {
	var b strings.Builder
	for _, l := range strings.Split(patch, "\n") {
		if strings.HasPrefix(l, "+") && !strings.HasPrefix(l, "+++") {
			b.WriteString(l[1:])
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func matchAny(globs []string, path string) (bool, error) {
	for _, g := range globs {
		re, err := globRegexp(g)
		if err != nil {
			return false, err
		}
		if re.MatchString(path) {
			return true, nil
		}
	}
	return false, nil
}

// globRegexp supports * (within a segment), ? and ** (across segments).
func globRegexp(g string) (*regexp.Regexp, error) {
	var b strings.Builder
	b.WriteString("^")
	for i := 0; i < len(g); i++ {
		switch c := g[i]; {
		case c == '*' && i+1 < len(g) && g[i+1] == '*':
			i++
			if i+1 < len(g) && g[i+1] == '/' {
				i++
				b.WriteString("(?:.*/)?")
			} else {
				b.WriteString(".*")
			}
		case c == '*':
			b.WriteString("[^/]*")
		case c == '?':
			b.WriteString("[^/]")
		default:
			b.WriteString(regexp.QuoteMeta(string(c)))
		}
	}
	b.WriteString("$")
	return regexp.Compile(b.String())
}

// CleanRelPath validates a path an LLM asked to write, keeping it in the worktree.
func CleanRelPath(p string) error {
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, "\\") || strings.ContainsRune(p, 0) {
		return fmt.Errorf("invalid path %q", p)
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "" || seg == "." || seg == ".." || strings.EqualFold(seg, ".git") {
			return fmt.Errorf("invalid path %q", p)
		}
	}
	return nil
}
