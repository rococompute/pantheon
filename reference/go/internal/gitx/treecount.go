package gitx

import (
	"bufio"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// MaxChangedPaths is the most paths a bid may touch before a wrapper will look at
// it with any tool that expands trees. Policy limits are far lower, so this only
// exists to keep hostile trees from reaching those tools at all.
const MaxChangedPaths = 100_000

// maxTreePairs bounds the distinct tree pairs walked, and so the reads.
const maxTreePairs = 200_000

type treeEntry struct {
	name string
	oid  string
	dir  bool
}

// treeCounter counts changed paths without expanding trees. Results are memoized
// by object id, so a nested-tree bomb standing for 10^12 paths costs a handful of
// reads. git's own diff can't be bounded this way: it queues every path in memory
// before printing the first one.
type treeCounter struct {
	in      io.Writer
	out     *bufio.Reader
	entries map[string][]treeEntry
	pairs   map[string]int
	limit   int
}

func (c *treeCounter) read(oid string) ([]treeEntry, error) {
	if e, ok := c.entries[oid]; ok {
		return e, nil
	}
	if _, err := fmt.Fprintln(c.in, oid); err != nil {
		return nil, err
	}
	header, err := c.out.ReadString('\n')
	if err != nil {
		return nil, err
	}
	f := strings.Fields(header)
	if len(f) != 3 || f[1] != "tree" {
		return nil, fmt.Errorf("object %s is not a readable tree: %q", oid, strings.TrimSpace(header))
	}
	size, err := strconv.Atoi(f[2])
	if err != nil {
		return nil, err
	}
	raw := make([]byte, size+1)
	if _, err := io.ReadFull(c.out, raw); err != nil {
		return nil, err
	}
	raw = raw[:size]
	var out []treeEntry
	for len(raw) > 0 {
		sp := strings.IndexByte(string(raw[:min(len(raw), 16)]), ' ')
		if sp < 0 {
			return nil, errors.New("malformed tree entry")
		}
		mode := string(raw[:sp])
		raw = raw[sp+1:]
		nul := -1
		for i, b := range raw {
			if b == 0 {
				nul = i
				break
			}
		}
		if nul < 0 || len(raw) < nul+1+32 {
			return nil, errors.New("malformed tree entry")
		}
		out = append(out, treeEntry{name: string(raw[:nul]), oid: hex.EncodeToString(raw[nul+1 : nul+33]), dir: mode == "40000"})
		raw = raw[nul+33:]
	}
	c.entries[oid] = out
	return out, nil
}

func (c *treeCounter) add(a, b int) int {
	if a+b > c.limit {
		return c.limit + 1
	}
	return a + b
}

// changed counts paths differing between two trees; "" stands for an absent tree.
func (c *treeCounter) changed(a, b string) (int, error) {
	if a == b {
		return 0, nil
	}
	key := a + ":" + b
	if n, ok := c.pairs[key]; ok {
		return n, nil
	}
	if len(c.pairs) >= maxTreePairs {
		return c.limit + 1, nil
	}
	sides := [2]map[string]treeEntry{{}, {}}
	for i, oid := range []string{a, b} {
		if oid == "" {
			continue
		}
		es, err := c.read(oid)
		if err != nil {
			return 0, err
		}
		for _, e := range es {
			sides[i][e.name] = e
		}
	}
	total := 0
	for name, ea := range sides[0] {
		eb, inB := sides[1][name]
		var n int
		var err error
		switch {
		case !inB && ea.dir:
			n, err = c.changed(ea.oid, "")
		case !inB:
			n = 1
		case ea.oid == eb.oid:
		case ea.dir && eb.dir:
			n, err = c.changed(ea.oid, eb.oid)
		case ea.dir:
			n, err = c.changed(ea.oid, "")
			n = c.add(n, 1)
		case eb.dir:
			n, err = c.changed("", eb.oid)
			n = c.add(n, 1)
		default:
			n = 1
		}
		if err != nil {
			return 0, err
		}
		total = c.add(total, n)
	}
	for name, eb := range sides[1] {
		if _, inA := sides[0][name]; inA {
			continue
		}
		n := 1
		if eb.dir {
			var err error
			if n, err = c.changed("", eb.oid); err != nil {
				return 0, err
			}
		}
		total = c.add(total, n)
	}
	c.pairs[key] = total
	return total, nil
}

// ChangedPaths counts the paths differing between two commits or trees, up to
// limit+1. It's safe to run on hostile trees.
func (r *Repo) ChangedPaths(from, to string, limit int) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "cat-file", "--batch")
	cmd.Dir = r.Dir
	cmd.Env = Env()
	in, err := cmd.StdinPipe()
	if err != nil {
		return 0, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return 0, err
	}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	defer func() {
		in.Close()
		cancel()
		_ = cmd.Wait()
	}()
	c := &treeCounter{in: in, out: bufio.NewReader(out), entries: map[string][]treeEntry{}, pairs: map[string]int{}, limit: limit}
	resolve := func(rev string) (string, error) {
		s, err := r.git(nil, "rev-parse", rev+"^{tree}")
		return strings.TrimSpace(s), err
	}
	a, err := resolve(from)
	if err != nil {
		return 0, err
	}
	b, err := resolve(to)
	if err != nil {
		return 0, err
	}
	return c.changed(a, b)
}
