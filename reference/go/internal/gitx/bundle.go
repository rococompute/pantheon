package gitx

import (
	"bytes"
	"compress/zlib"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
)

// Limits bound what a bundle may cost a node. They are consensus parameters.
type Limits struct {
	MaxBundleBytes   int   `json:"max_bundle_bytes"`
	MaxUnpackedBytes int64 `json:"max_unpacked_bytes"`
	MaxPackObjects   int   `json:"max_pack_objects"`
}

// BundleInfo is what CheckBundle learned from a bundle.
type BundleInfo struct {
	Commit        string
	Prerequisites []string
	Objects       int
	UnpackedBytes int64
}

var oidRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// CheckBundle is a pure-Go structural check that runs before any git process
// sees attacker bytes. It enforces the v3 sha256 format, a single refs/heads/bid
// head, and a hard bound on inflated size. Without that bound a small delta-bomb
// bundle could make every node spin, and any wall-clock timeout around git would
// be nondeterministic.
func CheckBundle(b []byte, lim Limits) (*BundleInfo, error) {
	if lim.MaxBundleBytes > 0 && len(b) > lim.MaxBundleBytes {
		return nil, fmt.Errorf("bundle is %d bytes, limit is %d", len(b), lim.MaxBundleBytes)
	}
	info := &BundleInfo{}
	rest := b
	next := func() (string, error) {
		i := bytes.IndexByte(rest, '\n')
		if i < 0 {
			return "", errors.New("bundle header is truncated")
		}
		line := string(rest[:i])
		rest = rest[i+1:]
		return line, nil
	}
	first, err := next()
	if err != nil {
		return nil, err
	}
	if first != "# v3 git bundle" {
		return nil, fmt.Errorf("unsupported bundle signature %q: create it from a sha256 repo", first)
	}
	sawFormat := false
	var heads []string
	for {
		line, err := next()
		if err != nil {
			return nil, err
		}
		if line == "" {
			break
		}
		switch {
		case strings.HasPrefix(line, "@"):
			if line != "@object-format=sha256" {
				return nil, fmt.Errorf("unsupported bundle capability %q", line)
			}
			sawFormat = true
		case strings.HasPrefix(line, "-"):
			oid, _, _ := strings.Cut(line[1:], " ")
			if !oidRe.MatchString(oid) {
				return nil, fmt.Errorf("bad prerequisite %q", line)
			}
			info.Prerequisites = append(info.Prerequisites, oid)
		default:
			oid, name, ok := strings.Cut(line, " ")
			if !ok || !oidRe.MatchString(oid) {
				return nil, fmt.Errorf("bad bundle ref line %q", line)
			}
			if name != BidRef {
				return nil, fmt.Errorf("bundle must advertise only %s, found %s", BidRef, name)
			}
			heads = append(heads, oid)
		}
	}
	if !sawFormat {
		return nil, errors.New("bundle does not declare @object-format=sha256")
	}
	if len(heads) != 1 {
		return nil, fmt.Errorf("bundle must have exactly one head, found %d", len(heads))
	}
	info.Commit = heads[0]
	if err := checkPack(rest, lim, info); err != nil {
		return nil, fmt.Errorf("bundle pack: %w", err)
	}
	return info, nil
}

// checkPack walks every pack entry, inflating under a budget.
func checkPack(pack []byte, lim Limits, info *BundleInfo) error {
	const hdr, trailer = 12, sha256.Size
	if len(pack) < hdr+trailer {
		return errors.New("too short")
	}
	if string(pack[:4]) != "PACK" {
		return errors.New("missing PACK signature")
	}
	if v := binary.BigEndian.Uint32(pack[4:8]); v != 2 {
		return fmt.Errorf("unsupported pack version %d", v)
	}
	count := binary.BigEndian.Uint32(pack[8:12])
	if lim.MaxPackObjects > 0 && int64(count) > int64(lim.MaxPackObjects) {
		return fmt.Errorf("%d objects, limit is %d", count, lim.MaxPackObjects)
	}
	body := pack[:len(pack)-trailer]
	sum := sha256.Sum256(body)
	if !bytes.Equal(sum[:], pack[len(pack)-trailer:]) {
		return errors.New("checksum mismatch")
	}
	budget := lim.MaxUnpackedBytes
	if budget <= 0 {
		budget = 1 << 62
	}
	var total int64
	r := bytes.NewReader(body[hdr:])
	for i := uint32(0); i < count; i++ {
		c, err := r.ReadByte()
		if err != nil {
			return errors.New("truncated entry header")
		}
		typ := (c >> 4) & 7
		declared := int64(c & 0x0f)
		for shift := uint(4); c&0x80 != 0; shift += 7 {
			if shift > 56 {
				return errors.New("entry size overflow")
			}
			if c, err = r.ReadByte(); err != nil {
				return errors.New("truncated entry size")
			}
			declared |= int64(c&0x7f) << shift
		}
		if declared < 0 || declared > budget {
			return fmt.Errorf("entry declares %d bytes, budget is %d", declared, budget)
		}
		switch typ {
		case 1, 2, 3, 4: // commit, tree, blob, tag
		case 6: // ofs-delta: variable-length negative offset
			for {
				c, err := r.ReadByte()
				if err != nil {
					return errors.New("truncated ofs-delta")
				}
				if c&0x80 == 0 {
					break
				}
			}
		case 7: // ref-delta: base object id
			if _, err := r.Seek(sha256.Size, io.SeekCurrent); err != nil {
				return err
			}
		default:
			return fmt.Errorf("invalid entry type %d", typ)
		}
		zr, err := zlib.NewReader(r)
		if err != nil {
			return fmt.Errorf("entry %d: %v", i, err)
		}
		// Read one byte past the declared size so an understated header is caught
		// without inflating more than the budget allows.
		data, err := io.ReadAll(io.LimitReader(zr, declared+1))
		if err != nil {
			return fmt.Errorf("entry %d: %v", i, err)
		}
		if int64(len(data)) != declared {
			return fmt.Errorf("entry %d: inflated size does not match header", i)
		}
		// Drain to the end of stream so the adler checksum is read and the reader
		// lands on the next entry.
		var one [1]byte
		if n, err := zr.Read(one[:]); n != 0 || err != io.EOF {
			return fmt.Errorf("entry %d: bad zlib stream end", i)
		}
		zr.Close()
		size := declared
		if typ == 6 || typ == 7 {
			result, err := deltaResultSize(data)
			if err != nil {
				return fmt.Errorf("entry %d: %v", i, err)
			}
			size = result
		}
		if size < 0 || size > budget-total {
			return fmt.Errorf("unpacked size exceeds limit of %d bytes", budget)
		}
		total += size
	}
	if r.Len() != 0 {
		return errors.New("trailing data after last entry")
	}
	info.Objects = int(count)
	info.UnpackedBytes = total
	return nil
}

// deltaResultSize reads the base size then the result size varints of a delta.
func deltaResultSize(d []byte) (int64, error) {
	pos := 0
	read := func() (int64, error) {
		var v int64
		for shift := uint(0); ; shift += 7 {
			if pos >= len(d) || shift > 56 {
				return 0, errors.New("bad delta header")
			}
			c := d[pos]
			pos++
			v |= int64(c&0x7f) << shift
			if c&0x80 == 0 {
				return v, nil
			}
		}
	}
	if _, err := read(); err != nil {
		return 0, err
	}
	return read()
}
