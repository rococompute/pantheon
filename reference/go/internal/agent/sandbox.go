package agent

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// CIConfig says how to test a candidate tree.
type CIConfig struct {
	Command    string `json:"command"` // empty means this repo has no CI
	Sandbox    string `json:"sandbox"` // "docker", or "none" for your own trusted test runs
	Image      string `json:"image"`   // must already be present locally: CI has no network
	TimeoutSec int    `json:"timeout_sec"`
}

// CIResult is the outcome of one CI run.
type CIResult struct {
	OK     bool
	Digest string
	Output string
}

// ErrSandboxUnavailable means CI couldn't run at all. That says nothing about the
// bid, so callers must not turn it into a "no" vote.
var ErrSandboxUnavailable = errors.New("CI sandbox unavailable")

// tailBuffer keeps only the last max bytes written.
type tailBuffer struct {
	mu  sync.Mutex
	max int
	buf []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > 2*t.max {
		t.buf = append(t.buf[:0], t.buf[len(t.buf)-t.max:]...)
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.buf) > t.max {
		return string(t.buf[len(t.buf)-t.max:])
	}
	return string(t.buf)
}

func randomHex() string {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// RunCI tests an exported tree in an isolated container with no network and no
// secrets. Bid code is hostile by assumption, including its build scripts.
func RunCI(ctx context.Context, c CIConfig, treeDir string) (*CIResult, error) {
	if c.Command == "" {
		return &CIResult{OK: true, Digest: "no-ci"}, nil
	}
	timeout := time.Duration(c.TimeoutSec) * time.Second
	if timeout <= 0 {
		timeout = 2 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	var cmd *exec.Cmd
	switch c.Sandbox {
	case "docker":
		if c.Image == "" {
			return nil, fmt.Errorf("%w: ci.image is empty", ErrSandboxUnavailable)
		}
		abs, err := filepath.Abs(treeDir)
		if err != nil {
			return nil, err
		}
		if out, err := exec.CommandContext(ctx, "docker", "image", "inspect", c.Image).CombinedOutput(); err != nil {
			return nil, fmt.Errorf("%w: image %s is not available locally (run `docker pull %s` once): %s",
				ErrSandboxUnavailable, c.Image, c.Image, strings.TrimSpace(string(out)))
		}
		// The timeout only kills the docker CLI, so name the container to stop it too.
		name := "pantheon-ci-" + randomHex()
		defer func() {
			if ctx.Err() != nil {
				_ = exec.Command("docker", "rm", "-f", name).Run()
			}
		}()
		cmd = exec.CommandContext(ctx, "docker", "run", "--rm", "--name", name,
			"--network=none", "--read-only", "--tmpfs", "/tmp:rw,size=256m",
			"--cap-drop=ALL", "--security-opt=no-new-privileges",
			"--pids-limit=256", "--memory=1g", "--cpus=2",
			"--user=65534:65534", "-e", "HOME=/tmp",
			"-v", abs+":/work:ro", "-w", "/work",
			c.Image, "sh", "-c", c.Command)
	case "none":
		cmd = exec.CommandContext(ctx, "sh", "-c", c.Command)
		cmd.Dir = treeDir
		cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + treeDir, "LC_ALL=C"}
	default:
		return nil, fmt.Errorf("%w: unknown ci.sandbox %q, use \"docker\"", ErrSandboxUnavailable, c.Sandbox)
	}
	// A bid's test may print forever. WaitDelay stops a stray child keeping the pipes
	// open, so a timeout really ends the wait.
	out := &tailBuffer{max: 32 << 10}
	cmd.Stdout, cmd.Stderr = out, out
	cmd.WaitDelay = 5 * time.Second
	runErr := cmd.Run()
	code := 0
	if runErr != nil {
		var ee *exec.ExitError
		switch {
		case ctx.Err() != nil:
			code = -1 // a timeout is the bid's fault: treat as failing
		case errors.As(runErr, &ee):
			code = ee.ExitCode()
			if c.Sandbox == "docker" && code == 125 {
				return nil, fmt.Errorf("%w: docker could not start the container: %s", ErrSandboxUnavailable, strings.TrimSpace(out.String()))
			}
		default:
			return nil, fmt.Errorf("%w: %v", ErrSandboxUnavailable, runErr)
		}
	}
	output := out.String()
	h := sha256.Sum256([]byte(fmt.Sprintf("%s\x00%s\x00%d\x00%s", c.Image, c.Command, code, output)))
	return &CIResult{OK: code == 0, Digest: hex.EncodeToString(h[:]), Output: output}, nil
}
