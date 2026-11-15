#!/bin/sh
# Installs Pantheon: Soma if it isn't installed, then Pantheon built with it,
# and a `pantheon` command on your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/yevbar/pantheon/master/install.sh | sh
#   ./install.sh                      (from a checkout: builds that checkout)
#
# Run it again to update: it fetches PANTHEON_REF and rebuilds. Soma's first
# install takes about 30 minutes and 3 GB; Pantheon's first build then makes
# Soma's OCaml switch for programs (~/.cache/soma/ocaml), a few minutes more.
#
# PANTHEON_REPO  where to fetch Pantheon from (default: https://github.com/yevbar/pantheon.git)
# PANTHEON_REF   the branch, tag or commit to build (default: master)
# PANTHEON_DIR   where Pantheon is kept and built (default: ~/.pantheon; ignored
#                when run from a checkout, which is built in place and never fetched)
# PANTHEON_BIN   where the `pantheon` command goes (default: ~/.local/bin)
# SOMA_REPO, SOMA_REF, SOMA_DIR, SOMA_SWITCH, SOMA_BIN
#                passed to Soma's install.sh when Soma is missing (see its top)
set -eu

PANTHEON_REPO=${PANTHEON_REPO:-https://github.com/yevbar/pantheon.git}
PANTHEON_REF=${PANTHEON_REF:-master}
PANTHEON_BIN=${PANTHEON_BIN:-$HOME/.local/bin}
SOMA_REPO=${SOMA_REPO:-https://github.com/yevbar/soma.git}
SOMA_REF=${SOMA_REF:-gradual}
export SOMA_REPO SOMA_REF
say() { printf 'pantheon-install: %s\n' "$*"; }
die() { printf 'pantheon-install: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is missing: install it with your package manager, then run this again"

# 1. Soma. Its installer is fetched from Soma's repository, by URL or, when
# that fails (a private repository, no curl), by cloning it with git, which
# can use SSH. It's run piped, so it keeps Soma in SOMA_DIR (~/.soma).
SOMA_BIN=${SOMA_BIN:-$HOME/.local/bin}
export SOMA_BIN
if command -v soma >/dev/null 2>&1; then
  SOMA=$(command -v soma)
elif [ -x "$SOMA_BIN/soma" ]; then
  SOMA=$SOMA_BIN/soma
else
  say "Soma isn't installed: installing it first (about 30 minutes the first time)"
  raw=$(printf '%s' "$SOMA_REPO" | sed -n 's#^https://github.com/\([^/]*/[^/.]*\)\(\.git\)\{0,1\}$#https://raw.githubusercontent.com/\1#p')
  script=""
  if [ -n "$raw" ] && command -v curl >/dev/null 2>&1; then
    script=$(curl -fsSL "$raw/$SOMA_REF/install.sh" 2>/dev/null || true)
  fi
  if [ -z "$script" ]; then
    tmp=$(mktemp -d)
    git clone -q --depth 1 -b "$SOMA_REF" "$SOMA_REPO" "$tmp/soma" \
      || die "fetching Soma from $SOMA_REPO failed. While yevbar/soma is private, use SSH: SOMA_REPO=git@github.com:yevbar/soma.git"
    script=$(cat "$tmp/soma/install.sh")
    rm -rf "$tmp"
  fi
  printf '%s\n' "$script" | sh || die "installing Soma failed: see above"
  SOMA=$SOMA_BIN/soma
fi
[ -x "$SOMA" ] || die "no soma command at $SOMA"

# 2. The source: this checkout if the script is in one, otherwise
# PANTHEON_DIR, fetched at PANTHEON_REF. Piped into sh, $0 is the shell.
here=""
case $0 in *install.sh) here=$(cd "$(dirname "$0")" && pwd) ;; esac
if [ -n "$here" ] && [ -f "$here/main.soma" ] && [ -f "$here/runtime/node_shell.soma" ]; then
  PANTHEON_DIR=$here
  say "building the checkout at $PANTHEON_DIR"
else
  PANTHEON_DIR=${PANTHEON_DIR:-$HOME/.pantheon}
  mkdir -p "$PANTHEON_DIR"
  [ -d "$PANTHEON_DIR/.git" ] || git -C "$PANTHEON_DIR" init -q
  git -C "$PANTHEON_DIR" remote remove origin 2>/dev/null || true
  git -C "$PANTHEON_DIR" remote add origin "$PANTHEON_REPO"
  say "fetching $PANTHEON_REF from $PANTHEON_REPO into $PANTHEON_DIR"
  git -C "$PANTHEON_DIR" fetch -q --depth 1 origin "$PANTHEON_REF" \
    || die "fetching $PANTHEON_REF from $PANTHEON_REPO failed. While yevbar/pantheon is private, use SSH: PANTHEON_REPO=git@github.com:yevbar/pantheon.git"
  git -C "$PANTHEON_DIR" checkout -q --force --detach FETCH_HEAD
fi
cd "$PANTHEON_DIR"
say "Pantheon $(git log -1 --format='%h %s' 2>/dev/null || echo '(not a git checkout)')"

# 3. The build: main.exe is the whole program, all Soma. The first build
# makes Soma's switch for programs (Soma.Host's primitives use OCaml's
# Unix, which comes with the compiler: nothing is installed from opam).
log=$PANTHEON_DIR/install.log
say "building Pantheon with $SOMA (log: $log)"
"$SOMA" build main.soma > "$log" 2>&1 || { tail -40 "$log"; die "the build failed: see $log"; }
[ -x "$PANTHEON_DIR/main.exe" ] || die "the build made no main.exe: see $log"

# 4. The command: a wrapper, so the node knows its own absolute path.
mkdir -p "$PANTHEON_BIN"
printf '#!/bin/sh\nexec "%s/main.exe" "$@"\n' "$PANTHEON_DIR" > "$PANTHEON_BIN/pantheon"
chmod +x "$PANTHEON_BIN/pantheon"
"$PANTHEON_BIN/pantheon" 2>&1 | grep -q 'pantheon init' || die "$PANTHEON_BIN/pantheon doesn't run: see $log"
say "done: $PANTHEON_BIN/pantheon (Pantheon's source, scripts and docs are in $PANTHEON_DIR)"
case :$PATH: in
  *":$PANTHEON_BIN:"*) say "next: docs/AGENT-SETUP.md runs a test network; or run pantheon for its commands" ;;
  *) say "$PANTHEON_BIN isn't on your PATH. Add it: export PATH=\"$PANTHEON_BIN:\$PATH\"" ;;
esac
