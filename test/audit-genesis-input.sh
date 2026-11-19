#!/bin/sh
# Exercise the actual CLI; synthetic tiny keys test input/identity checks,
# not RSA signing. No node, key generation, model, network or Git work runs.
set -eu
cd "$(dirname "$0")/.."
PANTHEON=${PANTHEON:-"$PWD/main.exe"}
export PANTHEON
python3 - <<'PY'
import copy
import json
import os
import pathlib
import subprocess
import tempfile

binary = str(pathlib.Path(os.environ['PANTHEON']).resolve())
checks = 0
failures = []
base_parts = {
    name: {'name': name, 'addr': '127.0.0.1:%d' % (39100+i),
           'tip': '%064x' % (i+1),
           'pubkey': {'size': 8, 'n': n, 'e': '03'}}
    for i, (name, n) in enumerate(zip('abcd', ['ab', 'ad', 'af', 'b1']))
}

def genesis(label, *, network=None, change=None, local=None, accepted=False, contains=None):
    global checks
    checks += 1
    with tempfile.TemporaryDirectory(prefix='pantheon-genesis-input-') as tmp:
        root = pathlib.Path(tmp)
        net, home = root/'net', root/'home'
        (net/'parts').mkdir(parents=True)
        home.mkdir()
        (net/'network.json').write_text(json.dumps(network if network is not None else {'repos': []}))
        parts = copy.deepcopy(base_parts)
        if change:
            change(parts)
        for name, part in parts.items():
            (net/'parts'/(name+'.json')).write_text(json.dumps(part))
        if local is not None:
            (home/'key.json').write_text(json.dumps(local))
        result = subprocess.run([binary, 'genesis', str(home), str(net)],
                                text=True, capture_output=True, timeout=15)
        output = result.stdout + result.stderr
        success = result.returncode == 0
        matches = success == accepted and (contains is None or contains in output)
        if accepted and success:
            actual = json.loads((home/'genesis.json').read_text())
            matches = matches and len(actual['agents']) == 4
        if not accepted:
            matches = matches and not (home/'genesis.json').exists()
        if matches:
            print('ok '+label)
        else:
            failures.append(label)
            print('FAIL %s: exit=%s, expected %s; %s' %
                  (label, result.returncode, 'accept' if accepted else 'refuse', output.strip()))

genesis('valid minimal network', accepted=True)
genesis('valid numeric settings and string metadata', network={
    'repos': [], 'block_ms': 200,
    'params': {'merge_approvals':'0', 'term_blocks':'007', 'finish':'1', 'label':'two words'}}, accepted=True)
known = ['block_ms','term_blocks','max_merges','stall_blocks','attest_window','fallback_blocks',
         'max_open_tasks','max_pending_bids','bid_cooldown','merge_approvals','reveal_window',
         'max_files','keep_settled','max_block_txs','task_rejects','task_blocks','bid_blocks','finish']
for name in known:
    genesis('nondecimal parameter '+name, network={'repos':[], 'params':{name:'one'}}, contains='parameter '+name)
for value in ['', '-5', '12x', '1e3', '9999999999999999999', '1000000001']:
    genesis('invalid numeric parameter '+repr(value), network={'repos':[], 'params':{'reveal_window':value}},
            contains='parameter reveal_window')
genesis('numeric parameter must still be a JSON string', network={'repos':[], 'params':{'merge_approvals':1}})
genesis('unknown metadata must also be a JSON string', network={'repos':[], 'params':{'label':1}})
genesis('params must be an object', network={'repos':[], 'params':[]})
for value in [-1, 0, 1.5, '200', 1000000000000000000, 1000000001]:
    genesis('invalid block_ms '+repr(value), network={'repos':[], 'block_ms':value}, contains='block_ms')

for field in ['name','addr','tip','pubkey']:
    genesis('missing agent '+field, change=lambda p, f=field: p['d'].pop(f))
for field in ['name','addr','tip']:
    for value in ['', 123]:
        genesis('invalid agent %s %r' % (field,value),
                change=lambda p, f=field, v=value: p['d'].__setitem__(f,v))
for field in ['size','n','e']:
    genesis('missing public-key '+field, change=lambda p, f=field: p['d']['pubkey'].pop(f))
for label, field, value in [('width mismatch','size',16), ('nonnumeric width','size','8'),
                            ('even modulus','n','ac'), ('zero modulus','n','00'),
                            ('unit modulus','n','01'), ('invalid hex','n','xx'),
                            ('unit exponent','e','01'), ('even exponent','e','02')]:
    genesis('invalid key '+label, change=lambda p,f=field,v=value: p['d']['pubkey'].__setitem__(f,v))

def duplicate(p, extra):
    p['d']['pubkey'] = copy.deepcopy(p['a']['pubkey'])
    p['d']['pubkey'].update(extra)

genesis('duplicate key despite extra JSON member', change=lambda p: duplicate(p, {'extra':'ignored'}),
        contains='duplicate public key')
genesis('duplicate key despite hex case and whitespace', change=lambda p: duplicate(p, {'n':' AB ', 'e':' 03 '}),
        contains='duplicate public key')
genesis('duplicate key despite leading zeros and matching padded width',
        change=lambda p: duplicate(p, {'n':'00ab', 'size':16, 'e':'0003'}), contains='duplicate public key')
genesis('invalid duplicate width', change=lambda p: duplicate(p, {'size':16}))
# Both semantic widths and pre-decode raw text are bounded. Oversized text
# containing valid hex/whitespace must not evade checks through canonicalization.
genesis('oversized declared key width', change=lambda p: p['d']['pubkey'].update(size=4104,n='ab'*513))
genesis('oversized raw modulus whitespace', change=lambda p: p['d']['pubkey'].update(n=' '*4097+'b1'))
genesis('oversized raw modulus hex', change=lambda p: p['d']['pubkey'].update(n='ab'*2049,size=32784))
genesis('oversized decoded exponent', change=lambda p: p['d']['pubkey'].update(e='03'*9))
genesis('oversized raw exponent whitespace', change=lambda p: p['d']['pubkey'].update(e=' '*65+'03'))
genesis('maximum supported key and exponent widths', change=lambda p: p['d']['pubkey'].update(size=4096,n='ab'*512,e='03'*8), accepted=True)
genesis('maximum numeric parameter', network={'repos':[], 'block_ms':1000000000,
         'params':{'max_files':'1000000000','max_block_txs':'1000000000'}}, accepted=True)
local = {'agent':'a', 'key':dict(base_parts['a']['pubkey'], d='01')}
genesis('local private fields do not affect public identity', local=local, accepted=True)
genesis('local exponent mismatch', local={'agent':'a', 'key':dict(local['key'], e='05')}, contains="key isn't in")
genesis('local declared width mismatch', local={'agent':'a', 'key':dict(local['key'], size=16)}, contains="key isn't in")

# These must fail before init creates keys or any network state.
with tempfile.TemporaryDirectory(prefix='pantheon-init-input-') as tmp:
    invalid_flags = [(['--param','term_blocks=one'], '--param term_blocks wants'),
                     (['--param','block_ms=0'], '--param block_ms wants'),
                     (['--block-ms','0'], '--block-ms must be positive'),
                     (['--block-ms','-5'], '--block-ms wants a number'),
                     (['--block-ms','1000000001'], '--block-ms must be positive'),
                     (['--param','max_block_txs=1000000001'], '--param max_block_txs wants')]
    for index, (flags, diagnostic) in enumerate(invalid_flags):
        checks += 1
        home = pathlib.Path(tmp)/str(index)
        result = subprocess.run([binary,'init',str(home)]+flags, text=True, capture_output=True, timeout=15)
        label = 'init refuses '+repr(flags)
        if result.returncode != 0 and not home.exists() and diagnostic in result.stdout+result.stderr:
            print('ok '+label)
        else:
            failures.append(label)
            print('FAIL '+label+': '+result.stdout+result.stderr)

print('%d checks, %d failures' % (checks,len(failures)))
if failures:
    raise SystemExit(1)
print('PASS genesis input validation')
PY
