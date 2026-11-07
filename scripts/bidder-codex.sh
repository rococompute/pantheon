#!/bin/sh
# codex as a bidder with tools: see bidder.sh
BIDDER_MODEL=codex exec "$(dirname "$0")/bidder.sh"
