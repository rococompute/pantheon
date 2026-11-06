package beacon

import (
	"bytes"
	"strings"
	"testing"

	bls12381 "github.com/kilic/bls12-381"
)

func TestThresholdRoundTrip(t *testing.T) {
	g, shares, err := TrustedDeal(4, 3)
	if err != nil {
		t.Fatal(err)
	}
	msg := Message("c", 7)
	var sigs [][]byte
	for i, s := range shares {
		sig, err := s.Sign(msg)
		if err != nil {
			t.Fatal(err)
		}
		if err := g.VerifyShare(msg, sig, i); err != nil {
			t.Fatalf("share %d: %v", i, err)
		}
		sigs = append(sigs, sig)
	}
	if err := g.VerifyShare(msg, sigs[0], 1); err == nil {
		t.Fatal("share replayed under another index must fail")
	}
	// Any 3 of 4 give the same signature: that is what makes it unbiasable.
	a, err := g.Recover(msg, sigs[:3])
	if err != nil {
		t.Fatal(err)
	}
	b, err := g.Recover(msg, sigs[1:])
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(a, b) {
		t.Fatal("different quorums recovered different signatures")
	}
	if err := g.VerifySeed(msg, a); err != nil {
		t.Fatal(err)
	}
	if err := g.VerifySeed(Message("c", 8), a); err == nil {
		t.Fatal("signature must not verify for another term")
	}
	if _, err := g.Recover(msg, sigs[:2]); err == nil {
		t.Fatal("2 shares must not recover")
	}
	if _, err := g.Recover(msg, [][]byte{sigs[0], sigs[0], sigs[0]}); err == nil {
		t.Fatal("duplicate shares must not count toward the threshold")
	}
}

// A proposer must not be able to change the seed with a point outside the
// prime-order subgroup: those would still pass the pairing check.
func TestSeedRejectsPointsOutsideSubgroup(t *testing.T) {
	g, _, err := TrustedDeal(4, 3)
	if err != nil {
		t.Fatal(err)
	}
	msg := Message("c", 1)
	curve := bls12381.NewG2()
	var raw [96]byte
	raw[0] = 0x80 // compression flag
	rejected := 0
	for x := 1; x < 250; x++ {
		raw[95] = byte(x)
		_, derr := curve.FromCompressed(raw[:])
		if derr == nil || !strings.Contains(derr.Error(), "subgroup") {
			continue // x has no curve point; only on-curve torsion candidates count
		}
		rejected++
		if err := g.VerifySeed(msg, raw[:]); err == nil {
			t.Fatalf("x=%d: on-curve point outside the subgroup was accepted", x)
		}
	}
	if rejected == 0 {
		t.Fatal("found no on-curve candidates, so the test exercised nothing")
	}
}

func TestSeedRejectsNonCanonicalEncoding(t *testing.T) {
	g, shares, err := TrustedDeal(4, 3)
	if err != nil {
		t.Fatal(err)
	}
	msg := Message("c", 2)
	var sigs [][]byte
	for _, s := range shares[:3] {
		sig, _ := s.Sign(msg)
		sigs = append(sigs, sig)
	}
	sig, err := g.Recover(msg, sigs)
	if err != nil {
		t.Fatal(err)
	}
	if err := g.VerifySeed(msg, append(append([]byte{}, sig...), 0)); err == nil {
		t.Fatal("trailing byte accepted")
	}
	flipped := append([]byte{}, sig...)
	flipped[0] ^= 0x20 // the y-sign bit: this is the negated point
	if err := g.VerifySeed(msg, flipped); err == nil {
		t.Fatal("negated signature accepted")
	}
}

func ceremony(t *testing.T) ([]*BoxKeys, [][32]byte, []*Deal) {
	t.Helper()
	var keys []*BoxKeys
	var pubs [][32]byte
	for i := 0; i < 4; i++ {
		k, err := NewBoxKeys()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, k)
		pubs = append(pubs, k.Public)
	}
	var deals []*Deal
	for i := 0; i < 4; i++ {
		d, err := NewDeal(i, 4, 3, pubs)
		if err != nil {
			t.Fatal(err)
		}
		deals = append(deals, d)
	}
	return keys, pubs, deals
}

func TestCeremonyProducesAWorkingGroup(t *testing.T) {
	keys, _, deals := ceremony(t)
	var shares []*Share
	var group *Group
	for i := 0; i < 4; i++ {
		g, s, err := Combine(i, 4, 3, deals, keys[i])
		if err != nil {
			t.Fatal(err)
		}
		if group != nil && g.Commits[0] != group.Commits[0] {
			t.Fatal("parties computed different group keys")
		}
		group = g
		shares = append(shares, s)
	}
	msg := Message("c", 3)
	var sigs [][]byte
	for i, s := range shares {
		sig, err := s.Sign(msg)
		if err != nil {
			t.Fatal(err)
		}
		if err := group.VerifyShare(msg, sig, i); err != nil {
			t.Fatal(err)
		}
		sigs = append(sigs, sig)
	}
	a, err := group.Recover(msg, sigs[:3])
	if err != nil {
		t.Fatal(err)
	}
	b, err := group.Recover(msg, sigs[1:])
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(a, b) {
		t.Fatal("quorums disagree")
	}
	if err := group.VerifySeed(msg, a); err != nil {
		t.Fatal(err)
	}
}

func TestCeremonyCatchesACheatingDealer(t *testing.T) {
	keys, pubs, deals := ceremony(t)
	// Dealer 2 commits to one polynomial and seals shares from another.
	other, err := NewDeal(2, 4, 3, pubs)
	if err != nil {
		t.Fatal(err)
	}
	deals[2].Sealed = other.Sealed
	if _, _, err := Combine(0, 4, 3, deals, keys[0]); err == nil || !strings.Contains(err.Error(), "deal from 2") {
		t.Fatalf("want dealer 2 named, got %v", err)
	}
}

func TestCeremonyRejectsBadShapes(t *testing.T) {
	keys, _, deals := ceremony(t)
	if _, _, err := Combine(0, 4, 3, deals[:3], keys[0]); err == nil {
		t.Fatal("missing deal accepted")
	}
	dup := []*Deal{deals[0], deals[0], deals[1], deals[2]}
	if _, _, err := Combine(0, 4, 3, dup, keys[0]); err == nil {
		t.Fatal("duplicate dealer accepted")
	}
	if _, _, err := Combine(0, 4, 3, deals, keys[1]); err == nil {
		t.Fatal("another party's key opened our share")
	}
}
