package market

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
)

// Transaction types.
const (
	TxPostTask  = "post_task"
	TxSubmitBid = "submit_bid"
	TxWithdraw  = "withdraw_bid"
	TxMerge     = "merge"
	TxAttest    = "attest"
	TxReject    = "reject"
	TxCloseTask = "close_task"
)

// Wire formats: the first byte selects the envelope.
const (
	envSigned byte = 0x01 // 0x01 | ed25519 sig (64) | body json
	envSeed   byte = 0x02 // 0x02 | recovered BLS signature; only proposers add it
)

// Body is a signed market transaction. Unused fields are empty.
type Body struct {
	Agent      string `json:"agent"`
	Nonce      uint64 `json:"nonce"`
	Type       string `json:"type"`
	Spec       string `json:"spec,omitempty"`
	BaseCommit string `json:"base_commit,omitempty"`
	TaskID     uint64 `json:"task_id,omitempty"`
	Bundle     []byte `json:"bundle,omitempty"`
	Note       string `json:"note,omitempty"`
	BidID      uint64 `json:"bid_id,omitempty"`
	OK         bool   `json:"ok,omitempty"`
	CIDigest   string `json:"ci_digest,omitempty"`
	Tree       string `json:"tree,omitempty"`
	Reason     string `json:"reason,omitempty"`
}

func signingBytes(chainID string, body []byte) []byte {
	return append([]byte("pantheon/tx/v1\x00"+chainID+"\x00"), body...)
}

// Sign encodes and signs a body for the given chain.
func Sign(chainID string, key ed25519.PrivateKey, b *Body) ([]byte, error) {
	raw, err := json.Marshal(b)
	if err != nil {
		return nil, err
	}
	sig := ed25519.Sign(key, signingBytes(chainID, raw))
	out := make([]byte, 0, 1+len(sig)+len(raw))
	out = append(out, envSigned)
	out = append(out, sig...)
	return append(out, raw...), nil
}

// EncodeSeed wraps a recovered BLS signature for inclusion in a block.
func EncodeSeed(sig []byte) []byte { return append([]byte{envSeed}, sig...) }

// IsSeed reports whether raw is a seed transaction.
func IsSeed(raw []byte) bool { return len(raw) > 0 && raw[0] == envSeed }

// SeedSig extracts the signature from a seed transaction.
func SeedSig(raw []byte) []byte { return raw[1:] }

// Decode parses a signed transaction and verifies its signature against the
// sender's genesis key. Failures here mean junk, never a role or state problem.
func (s *State) Decode(raw []byte) (*Body, error) {
	if len(raw) < 1+ed25519.SignatureSize || raw[0] != envSigned {
		return nil, errors.New("not a signed market transaction")
	}
	sig := raw[1 : 1+ed25519.SignatureSize]
	bodyRaw := raw[1+ed25519.SignatureSize:]
	var b Body
	dec := json.NewDecoder(bytes.NewReader(bodyRaw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		return nil, fmt.Errorf("malformed body: %v", err)
	}
	if dec.More() {
		return nil, errors.New("malformed body: trailing data")
	}
	a := s.Agent(b.Agent)
	if a == nil {
		return nil, fmt.Errorf("unknown agent %q", b.Agent)
	}
	if len(a.AppPubKey) != ed25519.PublicKeySize || !ed25519.Verify(a.AppPubKey, signingBytes(s.ChainID, bodyRaw), sig) {
		return nil, fmt.Errorf("bad signature for agent %s", b.Agent)
	}
	return &b, nil
}
