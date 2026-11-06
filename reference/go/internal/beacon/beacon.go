// Package beacon implements the 3-of-4 threshold BLS randomness used to draw the
// term leader. A threshold BLS signature is unique for a given message and key,
// so no subset of signers (and no block proposer) can choose among outcomes.
package beacon

import (
	"crypto/cipher"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/drand/kyber"
	bls "github.com/drand/kyber-bls12381"
	"github.com/drand/kyber/share"
	"github.com/drand/kyber/sign/tbls"
	"github.com/drand/kyber/util/random"
	bls12381 "github.com/kilic/bls12-381"
)

var (
	suite  = bls.NewBLS12381Suite()
	scheme = tbls.NewThresholdSchemeOnG2(suite)
)

// Group is the public side of the sharing, stored in genesis.
type Group struct {
	N       int      `json:"n"`
	T       int      `json:"t"`
	Commits []string `json:"commits"` // hex G1 points; Commits[0] is the group key
}

// Share is one validator's secret.
type Share struct {
	Index int    `json:"index"`
	Value string `json:"value"` // hex scalar
}

// stream is kyber's crypto/rand-backed randomness source.
var stream cipher.Stream = random.New()

// Message is what every validator signs to seed a given term.
func Message(chainID string, term uint64) []byte {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], term)
	return append([]byte("pantheon/term/v1\x00"+chainID+"\x00"), b[:]...)
}

func (g *Group) pubPoly() (*share.PubPoly, error) {
	if len(g.Commits) != g.T {
		return nil, fmt.Errorf("group has %d commits, want t=%d", len(g.Commits), g.T)
	}
	commits := make([]kyber.Point, len(g.Commits))
	for i, c := range g.Commits {
		raw, err := hex.DecodeString(c)
		if err != nil {
			return nil, err
		}
		p := suite.G1().Point()
		if err := p.UnmarshalBinary(raw); err != nil {
			return nil, err
		}
		commits[i] = p
	}
	return share.NewPubPoly(suite.G1(), suite.G1().Point().Base(), commits), nil
}

func commitsOf(pub *share.PubPoly) ([]string, error) {
	_, commits := pub.Info()
	out := make([]string, len(commits))
	for i, c := range commits {
		raw, err := c.MarshalBinary()
		if err != nil {
			return nil, err
		}
		out[i] = hex.EncodeToString(raw)
	}
	return out, nil
}

func encodeShare(s *share.PriShare) (Share, error) {
	raw, err := s.V.MarshalBinary()
	if err != nil {
		return Share{}, err
	}
	return Share{Index: s.I, Value: hex.EncodeToString(raw)}, nil
}

func (s Share) decode() (*share.PriShare, error) {
	raw, err := hex.DecodeString(s.Value)
	if err != nil {
		return nil, err
	}
	v := suite.G1().Scalar()
	if err := v.UnmarshalBinary(raw); err != nil {
		return nil, err
	}
	return &share.PriShare{I: s.Index, V: v}, nil
}

// Sign produces this validator's share of the signature over msg.
func (s Share) Sign(msg []byte) ([]byte, error) {
	p, err := s.decode()
	if err != nil {
		return nil, err
	}
	return scheme.Sign(p, msg)
}

// VerifyShare checks a share came from the validator at wantIndex.
func (g *Group) VerifyShare(msg, sig []byte, wantIndex int) error {
	i, err := scheme.IndexOf(sig)
	if err != nil {
		return err
	}
	if i != wantIndex {
		return fmt.Errorf("share index %d, want %d", i, wantIndex)
	}
	if i < 0 || i >= g.N {
		return fmt.Errorf("share index %d out of range", i)
	}
	pub, err := g.pubPoly()
	if err != nil {
		return err
	}
	return scheme.VerifyPartial(pub, msg, sig)
}

// Recover combines at least T valid shares. Invalid shares are skipped.
func (g *Group) Recover(msg []byte, shares [][]byte) ([]byte, error) {
	pub, err := g.pubPoly()
	if err != nil {
		return nil, err
	}
	seen := map[int]bool{}
	var unique [][]byte
	for _, s := range shares {
		i, err := scheme.IndexOf(s)
		if err != nil || i < 0 || i >= g.N || seen[i] {
			continue
		}
		seen[i] = true
		unique = append(unique, s)
	}
	return scheme.Recover(pub, msg, unique, g.T, g.N)
}

// VerifySeed checks a recovered signature and rejects any encoding other than
// the one canonical point. G2 has a large cofactor, and adding a torsion element
// to a signature leaves the pairing check passing while changing its bytes. A
// proposer could otherwise grind the seed, so the subgroup check is essential.
func (g *Group) VerifySeed(msg, sig []byte) error {
	if len(sig) != suite.G2().PointLen() {
		return fmt.Errorf("seed signature is %d bytes, want %d", len(sig), suite.G2().PointLen())
	}
	curve := bls12381.NewG2()
	p, err := curve.FromCompressed(sig)
	if err != nil {
		return fmt.Errorf("seed signature: %w", err)
	}
	if !curve.InCorrectSubgroup(p) {
		return errors.New("seed signature is outside the prime-order subgroup")
	}
	if curve.IsZero(p) {
		return errors.New("seed signature is the identity")
	}
	if string(curve.ToCompressed(p)) != string(sig) {
		return errors.New("seed signature encoding is not canonical")
	}
	pub, err := g.pubPoly()
	if err != nil {
		return err
	}
	return scheme.VerifyRecovered(pub.Commit(), msg, sig)
}

// SeedValue hashes a verified signature down to the draw's seed.
func SeedValue(sig []byte) []byte {
	h := sha256.Sum256(sig)
	return h[:]
}

// TrustedDeal is a trusted-dealer setup. The dealer learns the group secret, so it is
// only for local devnets: real deployments use the ceremony in dkg.go.
func TrustedDeal(n, t int) (*Group, []Share, error) {
	secret := suite.G1().Scalar().Pick(stream)
	return dealWith(n, t, secret)
}

func dealWith(n, t int, secret kyber.Scalar) (*Group, []Share, error) {
	pri := share.NewPriPoly(suite.G1(), t, secret, stream)
	pub := pri.Commit(suite.G1().Point().Base())
	commits, err := commitsOf(pub)
	if err != nil {
		return nil, nil, err
	}
	var shares []Share
	for _, s := range pri.Shares(n) {
		e, err := encodeShare(s)
		if err != nil {
			return nil, nil, err
		}
		shares = append(shares, e)
	}
	return &Group{N: n, T: t, Commits: commits}, shares, nil
}

// MarshalShare encodes a share for its key file.
func MarshalShare(s Share) ([]byte, error) { return json.MarshalIndent(s, "", "  ") }
