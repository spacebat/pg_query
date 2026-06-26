#!/bin/bash
# Tier-1 memory-safety check for the tenant-filter rewrite path (Task 09).
#
# Builds the standalone, Ruby-free harness ext/pg_query/qualify_memcheck.c
# against the already-compiled extension objects (everything except
# pg_query_ruby.o, which depends on libruby) and runs it under Valgrind. With no
# Ruby interpreter in the process there is essentially no Valgrind noise, so
# --error-exitcode=1 is a trustworthy pass/fail signal and no suppression file
# is needed.
#
# Usage: bin/run_memcheck.sh   (from the repo root)

set -euo pipefail

cd "$(dirname "$0")/.."

EXT=ext/pg_query
HARNESS="$EXT/qualify_memcheck.c"
BIN="${TMPDIR:-/tmp}/pg_query_qualify_memcheck"

echo "Building extension objects (rake compile)..."
bundle exec rake compile >/dev/null

echo "Linking memcheck harness..."
# All compiled objects except the Ruby binding and the harness itself.
OBJS=()
for o in "$EXT"/*.o; do
  case "$(basename "$o")" in
    pg_query_ruby.o|qualify_memcheck.o) continue ;;
    *) OBJS+=("$o") ;;
  esac
done

cc -O1 -g \
  -I "$EXT/include" -I "$EXT/include/postgres" \
  "$HARNESS" "${OBJS[@]}" \
  -lm -lpthread \
  -o "$BIN"

echo "Running under Valgrind..."
valgrind \
  --error-exitcode=1 \
  --leak-check=full \
  --errors-for-leak-kinds=definite,indirect \
  --track-origins=yes \
  "$BIN"

echo "memcheck (tier 1, C harness) passed with no Valgrind findings."
