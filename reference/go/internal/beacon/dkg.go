package beacon

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"

	"github.com/drand/kyber"
	"github.com/drand/kyber/share"
	"golang.org/x/crypto/nacl/box"
)

// This is a Joint-Feldman key generation with no dealer. Each party picks a
// random polynomial, publishes commitments to it, and seals one evaluation to each
// other party. A party's final share is the sum of what it received, and the group
// key is the sum of all commitments. Nobody ever holds the group secret.
//
// There is no complaint round. If a share doesn't match its dealer's commitments
// the ceremony aborts and names the dealer, which suits a one-time setup among
// four known parties: rerun it without trusting that party's host.

// BoxKeys is a party's encryption keypair for the ceremony.
type BoxKeys struct {
	Public  [32]byte
	Private [32]byte
}

// NewBoxKeys makes a fresh ceremony keypair.
func NewBoxKeys() (*BoxKeys, error) {
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return &BoxKeys{Public: *pub, Private: *priv}, nil
}

// Deal is one party's public contribution.
type Deal struct {
	Dealer  int      `json:"dealer"`
	Commits []string `json:"commits"`
	Sealed  []string `json:"sealed"` // hex; Sealed[j] is only readable by party j
}

// NewDeal generates this party's polynomial and seals its evaluations. The
// polynomial is discarded when this returns, except through the shares.
func NewDeal(dealer, n, t int, recipients [][32]byte) (*Deal, error) {
	if len(recipients) != n {
		return nil, fmt.Errorf("%d recipients, want %d", len(recipients), n)
	}
	pri := share.NewPriPoly(suite.G1(), t, nil, stream)
	commits, err := commitsOf(pri.Commit(suite.G1().Point().Base()))
	if err != nil {
		return nil, err
	}
	d := &Deal{Dealer: dealer, Commits: commits}
	for j, s := range pri.Shares(n) {
		raw, err := s.V.MarshalBinary()
		if err != nil {
			return nil, err
		}
		pub := recipients[j]
		sealed, err := box.SealAnonymous(nil, raw, &pub, rand.Reader)
		if err != nil {
			return nil, err
		}
		d.Sealed = append(d.Sealed, hex.EncodeToString(sealed))
	}
	return d, nil
}

// Combine verifies every deal, and returns the group and this party's share. It
// fails if any share sent to this party doesn't match its dealer's commitments.
func Combine(self, n, t int, deals []*Deal, keys *BoxKeys) (*Group, *Share, error) {
	if len(deals) != n {
		return nil, nil, fmt.Errorf("%d deals, want one from each of %d parties", len(deals), n)
	}
	seen := map[int]bool{}
	var sum *share.PubPoly
	total := suite.G1().Scalar().Zero()
	for _, d := range deals {
		if seen[d.Dealer] || d.Dealer < 0 || d.Dealer >= n {
			return nil, nil, fmt.Errorf("bad or duplicate dealer index %d", d.Dealer)
		}
		seen[d.Dealer] = true
		if len(d.Sealed) != n {
			return nil, nil, fmt.Errorf("deal from %d has %d sealed shares, want %d", d.Dealer, len(d.Sealed), n)
		}
		g := Group{N: n, T: t, Commits: d.Commits}
		pub, err := g.pubPoly()
		if err != nil {
			return nil, nil, fmt.Errorf("deal from %d: %w", d.Dealer, err)
		}
		v, err := openShare(d.Sealed[self], keys)
		if err != nil {
			return nil, nil, fmt.Errorf("deal from %d: cannot open our share: %w", d.Dealer, err)
		}
		if !pub.Check(&share.PriShare{I: self, V: v}) {
			return nil, nil, fmt.Errorf("deal from %d: our share doesn't match its commitments: abort the ceremony", d.Dealer)
		}
		total = total.Add(total, v)
		if sum == nil {
			sum = pub
		} else if sum, err = sum.Add(pub); err != nil {
			return nil, nil, err
		}
	}
	commits, err := commitsOf(sum)
	if err != nil {
		return nil, nil, err
	}
	raw, err := total.MarshalBinary()
	if err != nil {
		return nil, nil, err
	}
	return &Group{N: n, T: t, Commits: commits}, &Share{Index: self, Value: hex.EncodeToString(raw)}, nil
}

func openShare(sealedHex string, keys *BoxKeys) (kyber.Scalar, error) {
	sealed, err := hex.DecodeString(sealedHex)
	if err != nil {
		return nil, err
	}
	raw, ok := box.OpenAnonymous(nil, sealed, &keys.Public, &keys.Private)
	if !ok {
		return nil, fmt.Errorf("decryption failed")
	}
	v := suite.G1().Scalar()
	if err := v.UnmarshalBinary(raw); err != nil {
		return nil, err
	}
	return v, nil
}
