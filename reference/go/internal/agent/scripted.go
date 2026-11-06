package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// Structured prompt data for the scripted backend.
type (
	// DraftData accompanies KindDraft.
	DraftData struct {
		Agent  string
		Goal   string
		Posted []string
	}
	// PatchData accompanies KindPatch.
	PatchData struct {
		Agent  string
		TaskID uint64
		Spec   string
	}
	// PickData accompanies KindPick.
	PickData struct{ Bids []BidReview }
	// AttestData accompanies KindAttest.
	AttestData struct{ Bid BidReview }
)

// Scripted is a deterministic stand-in for an LLM, for tests and for an agent
// with no model configured. It follows the same protocol as real backends.
//
// Behaviors:
//
//	honest (default)  does each job plainly
//	silent            never answers, like a stalled or dead model
//	deny              a compromised attestor: votes no on everything
//	approve           a careless reviewer: picks and approves anything
type Scripted struct{ Behavior string }

// Name identifies the backend.
func (s *Scripted) Name() string { return "scripted:" + s.Behavior }

// Complete answers one request.
func (s *Scripted) Complete(ctx context.Context, r Request) (string, error) {
	if s.Behavior == "silent" {
		<-ctx.Done()
		return "", ctx.Err()
	}
	switch r.Kind {
	case KindDraft:
		d := r.Data.(DraftData)
		for _, line := range strings.Split(d.Goal, "\n") {
			line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "-"))
			if line == "" || contains(d.Posted, line) {
				continue
			}
			return mustJSON(map[string]any{"task": line}), nil
		}
		return `{"task": null}`, nil
	case KindPatch:
		d := r.Data.(PatchData)
		// Everyone writes the same path, so bids on one task really do conflict.
		path := fmt.Sprintf("work/task-%d.txt", d.TaskID)
		content := fmt.Sprintf("%s\nimplemented by %s\n", d.Spec, d.Agent)
		return mustJSON(map[string]any{
			"files": []map[string]string{{"path": path, "content": content}},
			"note":  "scripted patch from " + d.Agent,
		}), nil
	case KindPick:
		d := r.Data.(PickData)
		for _, b := range d.Bids {
			if b.CIOK || s.Behavior == "approve" {
				return mustJSON(map[string]any{"merge": b.ID}), nil
			}
		}
		return `{"merge": 0}`, nil
	case KindAttest:
		ok := s.Behavior != "deny"
		return mustJSON(map[string]any{"approve": ok, "reason": "scripted " + s.Behavior}), nil
	}
	return "", fmt.Errorf("scripted: unknown request kind %q", r.Kind)
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func mustJSON(v any) string {
	raw, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(raw)
}
