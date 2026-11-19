#!/bin/sh
# Independent byte/JSON oracle; implementation and fixtures execute in Soma.
set -eu
cd "$(dirname "$0")/.."
unicode_dir=$(mktemp -d "${TMPDIR:-/tmp}/pantheon-status-unicode.XXXXXX")
trap 'rm -rf "$unicode_dir"' EXIT HUP INT TERM
if ! soma run test/audit_status_unicode.soma > "$unicode_dir/out.jsonl" 2> "$unicode_dir/err"; then
  cat "$unicode_dir/err"
  exit 1
fi
python3 - "$unicode_dir/out.jsonl" <<'PY'
import json,pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_bytes().splitlines()
assert len(lines)==33, len(lines)
for raw in lines:
    # Parse emitted bytes directly: invalid UTF-8 is an error, never replaced.
    row=json.loads(raw)
    label=row['label']
    kind,tail=label.split(':',1)
    digits=''.join(c for c in tail if c.isascii() and c.isdigit())
    rune=tail[len(digits):]
    original='x'*int(digits)+rune
    cap={'name':256,'reason':4000,'title':60,'vote':700,'tree':128}[kind]
    expected=original.encode()[:cap].decode('utf-8',errors='ignore')
    value=row['value']
    if kind=='name':
        actual=value['recent_bids'][0]['author']
        assert value['recent_bids'][0]['author_truncated']==(len(original.encode())>cap)
    elif kind=='reason':
        actual=value['recent_bids'][0]['reason']
        assert value['recent_bids'][0]['reason_truncated']==(len(original.encode())>cap)
    elif kind=='title': actual=value
    elif kind=='vote':
        assert value[:3]==['attest','1','no'],value
        actual=value[3]
    else:
        actual=value['pending_merge']['tree']
        assert value['pending_merge']['tree_truncated']==(len(original.encode())>cap)
    assert actual==expected,(label,repr(actual[-10:]),repr(expected[-10:]))
    assert len(actual.encode())<=cap,(label,len(actual.encode()),cap)
    print('ok UTF-8/JSON boundary '+label)
print('PASS 33 emitted-byte Unicode status/title/reason boundaries')
PY
