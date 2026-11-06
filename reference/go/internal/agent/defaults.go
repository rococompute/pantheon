package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// perspectives give each agent a different priority when judging, so they don't
// share one blind spot.
var perspectives = map[string]string{
	"claude": "correctness: does the change do exactly what the task asks, including edge cases?",
	"codex":  "verification: is the change minimal and actually covered by tests?",
	"grok":   "adversarial review: how could this patch be abused, and does it hide any behavior?",
	"muse":   "simplicity: is this the simplest change that could work, with nothing unrelated?",
}

// WriteDefaults creates wrapper/agent.json for each agent. Each one reads only
// its own external/<agent>/ documents, so one injected document can reach at most
// one model, which stays within the f=1 the market tolerates.
func WriteDefaults(dir string, agents []string, override []byte) error {
	for _, a := range agents {
		c := DefaultConfig()
		c.Perspective = perspectives[a]
		for _, other := range agents {
			if other != a {
				c.Context.Exclude = append(c.Context.Exclude, "external/"+other+"/**")
			}
		}
		if len(override) > 0 {
			if err := json.Unmarshal(override, &c); err != nil {
				return fmt.Errorf("--agent-config: %w", err)
			}
		}
		raw, err := json.MarshalIndent(c, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, a, "wrapper", "agent.json"), raw, 0o600); err != nil {
			return err
		}
	}
	return nil
}

// WriteHome creates one host's wrapper/agent.json during multi-host setup.
func WriteHome(home string, override []byte) error {
	raw, err := os.ReadFile(filepath.Join(home, "wrapper", "app.key"))
	if err != nil {
		return err
	}
	var k struct {
		Agent string `json:"agent"`
	}
	if err := json.Unmarshal(raw, &k); err != nil {
		return err
	}
	c := DefaultConfig()
	c.Perspective = perspectives[k.Agent]
	for other := range perspectives {
		if other != k.Agent {
			c.Context.Exclude = append(c.Context.Exclude, "external/"+other+"/**")
		}
	}
	sort.Strings(c.Context.Exclude)
	if len(override) > 0 {
		if err := json.Unmarshal(override, &c); err != nil {
			return fmt.Errorf("--agent-config: %w", err)
		}
	}
	out, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(home, "wrapper", "agent.json"), out, 0o600)
}
