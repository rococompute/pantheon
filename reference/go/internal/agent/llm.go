package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

// Prompt kinds.
const (
	KindDraft  = "draft_task"
	KindPatch  = "write_patch"
	KindPick   = "pick_bid"
	KindAttest = "attest"
)

// Request is one question to an LLM. Prompt is what real models read. Data holds
// the same facts in structured form, for the scripted test backend.
type Request struct {
	Kind   string
	Prompt string
	Data   any
}

// Backend answers prompts with text. That's the whole interface: no tools, no
// files, no keys. Everything a model does passes through the wrapper as text.
type Backend interface {
	Complete(ctx context.Context, r Request) (string, error)
	Name() string
}

// NewBackend builds a backend from its spec, one of: claude, codex, grok, muse,
// scripted:<behavior>. model may be empty for the backend's default.
func NewBackend(spec, model string) (Backend, error) {
	name, arg, _ := strings.Cut(spec, ":")
	switch name {
	case "claude":
		return &claudeCLI{model: model}, nil
	case "codex":
		return &codexCLI{model: model}, nil
	case "grok":
		if model == "" {
			model = "grok-4.7"
		}
		return newHTTP("grok", "https://api.x.ai/v1", "XAI_API_KEY", model)
	case "muse":
		base := os.Getenv("MUSE_BASE_URL")
		if base == "" {
			return nil, errors.New("backend muse needs MUSE_BASE_URL (an OpenAI-compatible endpoint), MUSE_API_KEY and MUSE_MODEL. " +
				"Without them, run this agent with --backend scripted:honest and the market still works, with a stand-in for Muse")
		}
		if model == "" {
			model = os.Getenv("MUSE_MODEL")
		}
		if model == "" {
			return nil, errors.New("backend muse needs MUSE_MODEL or --model")
		}
		return newHTTP("muse", base, "MUSE_API_KEY", model)
	case "scripted":
		return &Scripted{Behavior: arg}, nil
	}
	return nil, fmt.Errorf("unknown backend %q: use claude, codex, grok, muse or scripted:<behavior>", spec)
}

// runCLI runs a model CLI from an empty directory, with the prompt on stdin.
func runCLI(ctx context.Context, name string, args []string, prompt string) (string, error) {
	cwd, err := os.MkdirTemp("", "pantheon-llm-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(cwd)
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = cwd
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Env = scrubEnv(os.Environ())
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		tail := errb.String()
		if len(tail) > 2000 {
			tail = tail[len(tail)-2000:]
		}
		return "", fmt.Errorf("%s: %w: %s", name, err, tail)
	}
	return out.String(), nil
}

// scrubEnv keeps wrapper settings out of model processes.
func scrubEnv(in []string) []string {
	var out []string
	for _, kv := range in {
		if !strings.HasPrefix(kv, "PANTHEON_") {
			out = append(out, kv)
		}
	}
	return out
}

// claudeCLI runs Claude Code in print mode with every tool off.
type claudeCLI struct{ model string }

func (c *claudeCLI) Name() string { return "claude" }

func (c *claudeCLI) Complete(ctx context.Context, r Request) (string, error) {
	args := []string{"-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--setting-sources", "", "--output-format", "text"}
	if c.model != "" {
		args = append(args, "--model", c.model)
	}
	return runCLI(ctx, "claude", args, r.Prompt)
}

// codexCLI runs Codex with its shell tools, MCP servers and apps off. Codex's
// read-only sandbox alone isn't enough: it may still read any file on disk, which
// would include this agent's key.
type codexCLI struct{ model string }

func (c *codexCLI) Name() string { return "codex" }

func (c *codexCLI) Complete(ctx context.Context, r Request) (string, error) {
	f, err := os.CreateTemp("", "pantheon-codex-*.out")
	if err != nil {
		return "", err
	}
	name := f.Name()
	f.Close()
	defer os.Remove(name)
	args := []string{"exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
		"--disable", "shell_tool", "--disable", "unified_exec", "--disable", "apps",
		"--disable", "browser_use", "-c", `approval_policy="never"`, "-c", "mcp_servers={}", "-o", name}
	if c.model != "" {
		args = append(args, "--model", c.model)
	}
	args = append(args, "-")
	if _, err := runCLI(ctx, "codex", args, r.Prompt); err != nil {
		return "", err
	}
	raw, err := os.ReadFile(name)
	return string(raw), err
}

// httpLLM speaks the OpenAI chat-completions protocol.
type httpLLM struct {
	name, base, key, model string
	client                 *http.Client
}

func newHTTP(name, base, keyEnv, model string) (*httpLLM, error) {
	key := os.Getenv(keyEnv)
	if key == "" {
		return nil, fmt.Errorf("backend %s needs %s in the wrapper's environment", name, keyEnv)
	}
	return &httpLLM{name: name, base: strings.TrimRight(base, "/"), key: key, model: model, client: &http.Client{Timeout: 10 * time.Minute}}, nil
}

func (h *httpLLM) Name() string { return h.name }

func (h *httpLLM) Complete(ctx context.Context, r Request) (string, error) {
	body, err := json.Marshal(map[string]any{
		"model":    h.model,
		"messages": []map[string]string{{"role": "user", "content": r.Prompt}},
	})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", h.base+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+h.key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := h.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode != 200 {
		if len(raw) > 500 {
			raw = raw[:500]
		}
		return "", fmt.Errorf("%s: HTTP %d: %s", h.name, resp.StatusCode, raw)
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", err
	}
	if len(out.Choices) == 0 {
		return "", fmt.Errorf("%s: empty response", h.name)
	}
	return out.Choices[0].Message.Content, nil
}

// Budgeted caps LLM calls. An overnight loop shouldn't spend without a limit.
type Budgeted struct {
	Backend
	Max  int64
	used atomic.Int64
}

// ErrBudget means this wrapper has used up its LLM calls.
var ErrBudget = errors.New("LLM call budget exhausted: raise max_llm_calls in wrapper/agent.json and restart")

// Complete counts the call, or refuses it when the budget is gone.
func (b *Budgeted) Complete(ctx context.Context, r Request) (string, error) {
	if b.Max > 0 && b.used.Add(1) > b.Max {
		return "", ErrBudget
	}
	return b.Backend.Complete(ctx, r)
}

// ParseJSON pulls the JSON object out of a model reply, tolerating prose and
// code fences around it.
func ParseJSON(reply string, into any) error {
	start := strings.IndexByte(reply, '{')
	end := strings.LastIndexByte(reply, '}')
	if start < 0 || end <= start {
		tail := reply
		if len(tail) > 200 {
			tail = tail[:200]
		}
		return fmt.Errorf("no JSON object in reply: %q", tail)
	}
	return json.Unmarshal([]byte(reply[start:end+1]), into)
}

// tempDirUnder makes a scratch directory, creating parent as needed.
func tempDirUnder(parent, pattern string) (string, error) {
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return "", err
	}
	abs, err := filepath.Abs(parent)
	if err != nil {
		return "", err
	}
	return os.MkdirTemp(abs, pattern)
}
