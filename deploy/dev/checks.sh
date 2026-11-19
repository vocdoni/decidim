#!/usr/bin/env bash
# Exposure and health checks for decidim-dev.vocdoni.net (z4).
#
# usage: checks.sh [--strict] <base-url> [curl args...]
#   ./checks.sh http://127.0.0.1:3000 -H "Host: decidim-dev.vocdoni.net" -H "X-Forwarded-Proto: https"
#   ./checks.sh https://decidim-dev.vocdoni.net
#
# Prints every result. With --strict it exits 1 unless /up and /en/ return 200,
# /letter_opener, /rails/info and /rails/info/routes return 404, and the 404
# page shows no web-console and no application trace (decidim-dev-update
# relies on this exit status).
set -uo pipefail

strict=0
if [ "${1:-}" = --strict ]; then strict=1; shift; fi
if [ $# -lt 1 ]; then
  echo "usage: $0 [--strict] <base-url> [curl args...]" >&2
  exit 2
fi
B=$1; shift

body=$(mktemp)
trap 'rm -f "$body"' EXIT
fail=0

c() { curl -s -o "$body" -w "%{http_code}" --max-time 20 "$@" || true; }

# expect_path <path> <wanted status> [curl args...]
expect_path() {
  local p=$1 want=$2 got
  shift 2
  got=$(c "$@" "$B$p")
  printf '%-26s %s\n' "$p" "$got"
  if [ "$got" != "$want" ]; then
    echo "  FAIL: expected $want"
    fail=1
  fi
}

expect_path /en/ 200 "$@"
grep -o '/decidim-packs/js/decidim_core-[a-f0-9]*\.js' "$body" | head -1 | sed 's/^/  hashed pack: /'
expect_path /letter_opener 404 "$@"
expect_path /rails/info/routes 404 "$@"
expect_path /rails/info 404 "$@"

got=$(c "$@" "$B/nonexistent-xyz")
console=$(grep -ci 'web-console\|console_session' "$body" || true)
trace=$(grep -c 'Application Trace' "$body" || true)
printf '%-26s %s  web-console:%s app-trace:%s\n' /nonexistent-xyz "$got" "$console" "$trace"
if [ "$console" != 0 ] || [ "$trace" != 0 ]; then
  echo "  FAIL: the 404 page exposes web-console or a trace"
  fail=1
fi

printf '%-26s %s\n' /vocdoni/booth-adapter.js "$(c "$@" "$B/vocdoni/booth-adapter.js")"
expect_path /up 200 "$@"

if [ "$strict" = 1 ] && [ "$fail" = 1 ]; then
  echo "checks failed"
  exit 1
fi
exit 0
