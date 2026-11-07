#!/bin/sh
# Claude Code as a bidder with tools: see bidder.sh
BIDDER_MODEL=claude exec "$(dirname "$0")/bidder.sh"
