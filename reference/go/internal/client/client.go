// Package client is the thin RPC layer wrappers and tools use to read the market
// and send signed transactions through their own node.
package client

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	rpchttp "github.com/cometbft/cometbft/rpc/client/http"

	"pantheon/internal/market"
)

// Client talks to one node.
type Client struct {
	RPC *rpchttp.HTTP
}

// New connects to a node's RPC address, such as http://127.0.0.1:26657.
func New(addr string) (*Client, error) {
	c, err := rpchttp.New(addr, "/websocket")
	if err != nil {
		return nil, err
	}
	return &Client{RPC: c}, nil
}

func (c *Client) query(ctx context.Context, path string) ([]byte, error) {
	res, err := c.RPC.ABCIQuery(ctx, path, nil)
	if err != nil {
		return nil, err
	}
	if res.Response.Code != 0 {
		return nil, fmt.Errorf("query %s: %s", path, res.Response.Log)
	}
	return res.Response.Value, nil
}

// State returns committed market state.
func (c *Client) State(ctx context.Context) (*market.State, error) {
	raw, err := c.query(ctx, "/state")
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 {
		return nil, errors.New("node has no state yet")
	}
	var s market.State
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

// StateHash returns the sha256 of the committed state bytes, for comparing nodes.
func (c *Client) StateHash(ctx context.Context) (string, int64, error) {
	res, err := c.RPC.ABCIQuery(ctx, "/state", nil)
	if err != nil {
		return "", 0, err
	}
	h := sha256.Sum256(res.Response.Value)
	return hex.EncodeToString(h[:]), res.Response.Height, nil
}

// HeadBundle returns a standalone bundle of the repo at head.
func (c *Client) HeadBundle(ctx context.Context) ([]byte, error) {
	return c.query(ctx, "/head-bundle")
}

// BidBundle returns the bundle a bid was submitted with.
func (c *Client) BidBundle(ctx context.Context, bid uint64) ([]byte, error) {
	return c.query(ctx, fmt.Sprintf("/bundle/%d", bid))
}

// Result is the outcome of a transaction that reached a block.
type Result struct {
	Height int64
	Code   uint32
	Log    string
}

// Err converts a failing on-chain result to an error.
func (r *Result) Err() error {
	if r.Code != 0 {
		return fmt.Errorf("transaction failed at height %d: %s", r.Height, r.Log)
	}
	return nil
}

// Sender signs and sends transactions for one agent, one at a time. Nonces come
// from committed state, so it needs no local bookkeeping and survives restarts.
type Sender struct {
	*Client
	Agent   string
	ChainID string
	Key     ed25519.PrivateKey
}

// Send signs b, broadcasts it and waits for it to land in a block. CheckTx
// refusals return immediately, before anything is on chain. It re-broadcasts
// periodically so a node that lost the transaction can't strand it.
func (s *Sender) Send(ctx context.Context, b market.Body) (*Result, error) {
	st, err := s.State(ctx)
	if err != nil {
		return nil, err
	}
	b.Agent = s.Agent
	b.Nonce = st.Nonces[s.Agent] + 1
	raw, err := market.Sign(s.ChainID, s.Key, &b)
	if err != nil {
		return nil, err
	}
	return s.BroadcastRaw(ctx, raw)
}

// BroadcastRaw sends an already-signed transaction and waits for its result.
func (c *Client) BroadcastRaw(ctx context.Context, raw []byte) (*Result, error) {
	hash := sha256.Sum256(raw)
	broadcast := func() error {
		res, err := c.RPC.BroadcastTxSync(ctx, raw)
		if err != nil {
			if strings.Contains(err.Error(), "already exists in cache") {
				return nil
			}
			return err
		}
		if res.Code != 0 {
			return fmt.Errorf("refused by CheckTx: %s", res.Log)
		}
		return nil
	}
	if err := broadcast(); err != nil {
		return nil, err
	}
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	last := time.Now()
	for {
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("waiting for transaction %x: %w", hash[:6], ctx.Err())
		case <-tick.C:
		}
		res, err := c.RPC.Tx(ctx, hash[:], false)
		if err == nil {
			return &Result{Height: res.Height, Code: res.TxResult.Code, Log: res.TxResult.Log}, nil
		}
		if time.Since(last) > 10*time.Second {
			last = time.Now()
			if err := broadcast(); err != nil {
				// CheckTx refusing on a retry means the tx may have just landed.
				if _, e := c.RPC.Tx(ctx, hash[:], false); e != nil {
					return nil, err
				}
			}
		}
	}
}

// KeyFile is an agent's app-key file. It's only ever read by the wrapper process.
type KeyFile struct {
	Agent   string `json:"agent"`
	ChainID string `json:"chain_id"`
	PrivKey []byte `json:"priv_key"`
}

// LoadSender builds a Sender from a key file and RPC address.
func LoadSender(keyPath, rpcAddr string) (*Sender, error) {
	raw, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("reading app key: %w", err)
	}
	var k KeyFile
	if err := json.Unmarshal(raw, &k); err != nil {
		return nil, fmt.Errorf("parsing app key %s: %w", keyPath, err)
	}
	if len(k.PrivKey) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("app key %s holds %d bytes, want %d", keyPath, len(k.PrivKey), ed25519.PrivateKeySize)
	}
	c, err := New(rpcAddr)
	if err != nil {
		return nil, err
	}
	return &Sender{Client: c, Agent: k.Agent, ChainID: k.ChainID, Key: ed25519.PrivateKey(k.PrivKey)}, nil
}
