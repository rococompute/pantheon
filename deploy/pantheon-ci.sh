#!/bin/sh
# Runs a CI command on the checkout an attestor's check mounts at /work, in
# this image, as any uid, with no network and a read-only root:
#
#   pantheon-ci "soma build main.soma && test/edits.sh"
#
# It copies the checkout to /tmp/w, points Soma and opam at the image's
# prebuilt switches (Soma records which libraries a switch has under its
# cache, keyed by the switch's path, so that record is copied too), and runs
# the command there.
set -eu
export HOME=/tmp XDG_CACHE_HOME=/tmp/cache OPAMROOT=/home/pantheon/.opam SOMA_OCAML_SWITCH=/home/pantheon/.cache/soma/ocaml
d=$XDG_CACHE_HOME/soma/ocaml
mkdir -p "$d"
cp /home/pantheon/.cache/soma/ocaml/installed "$d/installed-$(printf %s "$SOMA_OCAML_SWITCH" | md5sum | cut -d' ' -f1)"
cp -R /work /tmp/w
cd /tmp/w
exec sh -c "$1"
