#!/bin/sh
# A tiny calculator. Usage: sh calc.sh <command> <a> <b>
case "$1" in
  add) echo $(($2 + $3)) ;;
  *) echo "usage: calc.sh add <a> <b>" >&2; exit 2 ;;
esac
