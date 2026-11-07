#!/bin/sh
# Sets up a Linux machine (Debian or Ubuntu) to run a Pantheon node: builds
# Soma from source, then Pantheon with it. Safe to run again: it skips what's
# done. Run it from a Pantheon checkout.
#
#   SOMA_REPO=git@github.com:you/soma.git scripts/setup-node.sh
#   SOMA_REPO=/path/to/soma-checkout     scripts/setup-node.sh
#
# SOMA_REPO  where Soma's source is: a git URL or a directory (required unless
#            SOMA_DIR already holds it)
# SOMA_REF   the branch or commit to build (default: gradual)
# SOMA_DIR   where Soma is built (default: ~/soma)
#
# When it's done, put Soma's bin directory on your PATH (it prints the line);
# ./main.exe is the node. docs/NETWORK.md says what to do next.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
SOMA_DIR=${SOMA_DIR:-$HOME/soma}
SOMA_REF=${SOMA_REF:-gradual}
say() { printf 'setup: %s\n' "$*"; }

# 1. system packages: git, a C toolchain, opam, gmp for zarith, zlib for cryptokit
missing=""
for c in git make cc opam jq curl m4 pkg-config; do command -v $c >/dev/null || missing="$missing $c"; done
[ -e /usr/include/gmp.h ] || [ -e "/usr/include/$(uname -m)-linux-gnu/gmp.h" ] || missing="$missing gmp"
[ -e /usr/include/zlib.h ] || missing="$missing zlib"
if [ -n "$missing" ]; then
  command -v apt-get >/dev/null || { echo "setup: missing:$missing. Install them with your package manager and run again" >&2; exit 1; }
  say "installing system packages (missing:$missing)"
  sudo apt-get update -q && sudo apt-get install -y -q git build-essential opam jq curl m4 pkg-config libgmp-dev zlib1g-dev rsync ca-certificates
fi

# 2. opam
[ -d "$HOME/.opam" ] || { say "initializing opam"; opam init --bare -y --disable-sandboxing -q; }

# 3. Soma's source
if [ ! -f "$SOMA_DIR/dune-project" ]; then
  [ -n "${SOMA_REPO:-}" ] || { echo "setup: set SOMA_REPO to Soma's git URL or a directory with its source" >&2; exit 1; }
  if [ -d "$SOMA_REPO/.git" ]; then
    say "copying Soma's $SOMA_REF from $SOMA_REPO"
    mkdir -p "$SOMA_DIR"; (cd "$SOMA_REPO" && git archive --format=tar "$SOMA_REF") | tar -x -C "$SOMA_DIR"
  elif [ -d "$SOMA_REPO" ]; then
    say "copying Soma from $SOMA_REPO"
    mkdir -p "$SOMA_DIR"; cp -R "$SOMA_REPO/." "$SOMA_DIR/"
  else
    say "cloning Soma from $SOMA_REPO"
    git clone -q "$SOMA_REPO" "$SOMA_DIR" && git -C "$SOMA_DIR" checkout -q "$SOMA_REF"
  fi
fi

# 4. Soma's build switch and the build. This is GRADUAL.md's recipe, with
# three changes. The switch is a named one, soma-build, not ./_opam: opam
# builds packages inside the switch, and dune would climb into Soma's own
# project. It adds the wasm library that Soma's WebAssembly plugin needs. And
# it runs `make dunestrap`, which generates the theories' build rules (their
# dune files aren't committed).
cd "$SOMA_DIR"
if ! opam switch list --short 2>/dev/null | grep -qx soma-build; then
  say "making the soma-build opam switch, OCaml 4.14.2: a few minutes"
  opam switch create soma-build ocaml-base-compiler.4.14.2 --no-install -y -q
fi
opam install --switch=soma-build -y -q dune ocamlfind zarith wasm
if [ ! -x _build/install/default/bin/soma ]; then
  say "building Soma: this takes a while"
  eval "$(opam env --switch=soma-build --set-switch)"
  make dunestrap > "$SOMA_DIR/setup-dunestrap.log" 2>&1 || { tail -30 "$SOMA_DIR/setup-dunestrap.log"; echo "setup: make dunestrap failed (log: $SOMA_DIR/setup-dunestrap.log)" >&2; exit 1; }
  dune build soma-runtime.install soma-core.install > "$SOMA_DIR/setup-build.log" 2>&1 || { tail -40 "$SOMA_DIR/setup-build.log"; echo "setup: building Soma failed (log: $SOMA_DIR/setup-build.log)" >&2; exit 1; }
fi
[ -f _build/install/default/lib/coq/theories/Init/Prelude.vo ] || { echo "setup: Soma built without its standard library (no Prelude.vo): see $SOMA_DIR/setup-build.log" >&2; exit 1; }
export PATH="$SOMA_DIR/_build/install/default/bin:$PATH"
# On Linux, compiling a .definition finds Rocq's library from where the soma
# binary really is (_build/default), not the install tree: say where it is.
export ROCQLIB="$SOMA_DIR/_build/install/default/lib/coq"
command -v soma >/dev/null || { echo "setup: Soma didn't build: see the output above" >&2; exit 1; }

# 5. Pantheon. The first build makes Soma's own OCaml switch
# (~/.cache/soma/ocaml) and installs what shell.definition names: cryptokit
# and yojson.
cd "$here"
say "building Pantheon"
# Soma installs the newest version of each library, and Soma can't pin one
# yet. cryptokit 1.21 changed its RSA API, so pin 1.20, as shell.ml expects.
sw=${SOMA_OCAML_SWITCH:-$HOME/.cache/soma/ocaml}
if ! soma build main.soma; then
  [ -d "$sw" ] || { echo "setup: building Pantheon failed: see above" >&2; exit 1; }
  say "pinning cryptokit 1.20 in $sw, and building again"
  opam pin add --switch="$sw" -y -q cryptokit 1.20
  soma build main.soma
fi
say "done: $here/main.exe. For soma itself: export PATH=\"$SOMA_DIR/_build/install/default/bin:\$PATH\" ROCQLIB=\"$ROCQLIB\""
