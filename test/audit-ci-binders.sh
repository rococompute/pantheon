#!/bin/sh
# Exercise both the embedded CI verifier and real checked Soma declarations.
set -eu
cd "$(dirname "$0")/.."
SOMA=${SOMA:-soma}
export SOMA
python3 -B test/ci-policy-binders.py
"$SOMA" check test/ci_policy_binders.soma
