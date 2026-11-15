#!/bin/sh
# Sets up a Linux machine (Debian or Ubuntu) to run a Pantheon node: builds
# Soma from source, then Pantheon with it. Safe to run again: it skips what's
# done. Run it from a Pantheon checkout.
#
#   scripts/setup-node.sh
#   SOMA_REPO=/path/to/soma-checkout scripts/setup-node.sh
#
# SOMA_REPO  where Soma's source is: a git URL or a directory (default:
#            git@github.com:yevbar/soma.git, private: the machine needs a
#            key that can read it)
# SOMA_REF   the branch or commit to build (default: gradual)
# SOMA_DIR   where Soma is built (default: ~/soma)
# SOMA_ONLY  1: stop once Soma is built (deploy/Dockerfile builds Soma in a
#            layer of its own, so a Pantheon change doesn't rebuild it)
#
# When it's done, put Soma's bin directory on your PATH (it prints the line);
# ./main.exe is the node. docs/NETWORK.md says what to do next.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
SOMA_DIR=${SOMA_DIR:-$HOME/soma}
SOMA_REF=${SOMA_REF:-gradual}
SOMA_REPO=${SOMA_REPO:-git@github.com:yevbar/soma.git}
say() { printf 'setup: %s\n' "$*"; }

# 1. system packages: git, a C toolchain, opam, gmp for zarith
missing=""
for c in git make cc opam jq curl m4 pkg-config; do command -v $c >/dev/null || missing="$missing $c"; done
[ -e /usr/include/gmp.h ] || [ -e "/usr/include/$(uname -m)-linux-gnu/gmp.h" ] || missing="$missing gmp"
if [ -n "$missing" ]; then
  command -v apt-get >/dev/null || { echo "setup: missing:$missing. Install them with your package manager and run again" >&2; exit 1; }
  say "installing system packages (missing:$missing)"
  sudo apt-get update -q && sudo apt-get install -y -q git build-essential opam jq curl m4 pkg-config libgmp-dev rsync ca-certificates
fi

# 2. opam
[ -d "$HOME/.opam" ] || { say "initializing opam"; opam init --bare -y --disable-sandboxing -q; }

# 3. Soma's source
if [ ! -f "$SOMA_DIR/dune-project" ]; then
  if [ -d "$SOMA_REPO/.git" ]; then
    say "copying Soma's $SOMA_REF from $SOMA_REPO"
    mkdir -p "$SOMA_DIR"; (cd "$SOMA_REPO" && git archive --format=tar "$SOMA_REF") | tar -x -C "$SOMA_DIR"
  elif [ -d "$SOMA_REPO" ]; then
    say "copying Soma from $SOMA_REPO"
    mkdir -p "$SOMA_DIR"; cp -R "$SOMA_REPO/." "$SOMA_DIR/"
  else
    say "cloning Soma from $SOMA_REPO"
    git clone -q "$SOMA_REPO" "$SOMA_DIR" || { echo "setup: cloning $SOMA_REPO failed. It is private: give this machine a key that can read it (a deploy key), or set SOMA_REPO to a directory with Soma's source" >&2; exit 1; }
    git -C "$SOMA_DIR" checkout -q "$SOMA_REF"
  fi
fi

# 4. Soma's build switch and the build: GRADUAL.md's quick start, in a
# switch named soma-build.
cd "$SOMA_DIR"
if ! opam switch list --short 2>/dev/null | grep -qx soma-build; then
  say "making the soma-build opam switch, OCaml 4.14.2: a few minutes"
  opam switch create soma-build ocaml-base-compiler.4.14.2 --no-install -y -q
fi
opam install --switch=soma-build -y -q --deps-only ./soma-runtime.opam
if [ ! -x _build/install/default/bin/soma ]; then
  say "building Soma: this takes a while"
  eval "$(opam env --switch=soma-build --set-switch)"
  make dunestrap > "$SOMA_DIR/setup-dunestrap.log" 2>&1 || { tail -30 "$SOMA_DIR/setup-dunestrap.log"; echo "setup: make dunestrap failed (log: $SOMA_DIR/setup-dunestrap.log)" >&2; exit 1; }
  dune build soma-runtime.install soma-core.install > "$SOMA_DIR/setup-build.log" 2>&1 || { tail -40 "$SOMA_DIR/setup-build.log"; echo "setup: building Soma failed (log: $SOMA_DIR/setup-build.log)" >&2; exit 1; }
fi
[ -f _build/install/default/lib/coq/theories/Init/Prelude.vo ] || { echo "setup: Soma built without its standard library (no Prelude.vo): see $SOMA_DIR/setup-build.log" >&2; exit 1; }
export PATH="$SOMA_DIR/_build/install/default/bin:$PATH"
command -v soma >/dev/null || { echo "setup: Soma didn't build: see the output above" >&2; exit 1; }

if [ "${SOMA_ONLY:-}" = 1 ]; then say "Soma is built: $SOMA_DIR/_build/install/default/bin/soma"; exit 0; fi

# 5. Pantheon. The first build makes Soma's own OCaml switch
# (~/.cache/soma/ocaml) and installs what shell.definition names (OCaml's
# Unix, which comes with the compiler).
cd "$here"
say "building Pantheon"
soma build main.soma || { echo "setup: building Pantheon failed: see above" >&2; exit 1; }
say "done: $here/main.exe. For soma itself: export PATH=\"$SOMA_DIR/_build/install/default/bin:\$PATH\""
