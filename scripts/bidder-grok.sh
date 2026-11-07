#!/bin/sh
# Grok Build as a bidder with tools: see bidder.sh
BIDDER_MODEL=grok exec "$(dirname "$0")/bidder.sh"
