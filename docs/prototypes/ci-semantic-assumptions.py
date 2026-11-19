#!/usr/bin/env python3
"""Non-enforcing experiment: export checked assumptions using `soma hash`.

This deliberately does not replace deploy/ci-command.py. See the accompanying
CI-POLICY.md for completeness/trust requirements before using such a manifest
as a security policy. Explicit entry points only; no discovery claim.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--soma', required=True, help='trusted compiler executable')
parser.add_argument('sources', nargs='+', type=Path)
args = parser.parse_args()
manifest = {'prototype_version': 1, 'enforcing': False, 'sources': {}}
digest = re.compile(r'[0-9a-f]{64}')
for source in args.sources:
    if source.suffix != '.soma':
        parser.error('supply .soma entry points; their .exp is checked with them')
    checked = subprocess.run([args.soma, 'hash', str(source)], check=True,
                             capture_output=True, text=True,
                             env=dict(os.environ, SOMA_HASH_FIELDS='1'))
    declarations = {}
    for line in checked.stdout.splitlines():
        fields = line.split('\t')
        if (len(fields) < 4 or not fields[0]
                or not all(digest.fullmatch(value) for value in fields[1:4])
                or any(not value or any(c.isspace() for c in value) for value in fields[4:])):
            raise SystemExit('unexpected soma hash fields (prototype fails closed): ' + line)
        name, contract, witness, shape, *assumptions = fields
        if name in declarations:
            raise SystemExit('duplicate declaration in soma hash output: ' + name)
        declarations[name] = {'contract': contract, 'witness': witness,
                              'shape': shape, 'assumptions': assumptions}
    manifest['sources'][str(source)] = declarations
print(json.dumps(manifest, sort_keys=True, indent=2))
