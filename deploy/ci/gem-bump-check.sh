#!/usr/bin/env bash
# Mechanical-bump check for the decidim-elections-vocdoni lock bump (workflow
# vocdoni_gem_bump.yml). Reads files only; never runs gem code.
#
# usage: gem-bump-check.sh <base Gemfile.lock> <new Gemfile.lock> <gem sha> \
#          <app db/migrate dir> <file listing the gem's db/migrate entries>
#
# Exit 0: the bump is mechanical. Exit 1: it is not; one reason per line on
# stdout. Exit 2: bad arguments or input.
set -euo pipefail

if [ $# -ne 5 ]; then
  echo "usage: $0 <base-lock> <new-lock> <gem-sha> <app-migrate-dir> <gem-migrations-list>" >&2
  exit 2
fi
base_lock=$1 new_lock=$2 gem_sha=$3 app_migrate=$4 gem_list=$5

if ! [[ "$gem_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "gem sha is not a 40-char hex commit" >&2
  exit 2
fi
for f in "$base_lock" "$new_lock" "$gem_list"; do
  [ -f "$f" ] || { echo "missing file: $f" >&2; exit 2; }
done
[ -d "$app_migrate" ] || { echo "missing dir: $app_migrate" >&2; exit 2; }

reasons=()

# 1. The lock differs from the base in exactly the gem's `revision:` line.
# Build the expected lock (base with only that line replaced) and compare bytes.
expected=$(mktemp)
trap 'rm -f "$expected"' EXIT
awk -v sha="$gem_sha" '
  /^GIT$/ { in_git = 1; gem = 0 }
  /^$/ { in_git = 0; gem = 0 }
  in_git && $0 == "  remote: https://github.com/vocdoni/decidim-secure_elections.git" { gem = 1 }
  gem && $1 == "revision:" && !done { print "  revision: " sha; done = 1; next }
  { print }
  END { if (!done) exit 3 }
' "$base_lock" > "$expected" || { echo "base lock has no decidim-secure_elections revision line" >&2; exit 2; }

if cmp -s "$base_lock" "$expected"; then
  reasons+=("the base lock already pins $gem_sha")
elif ! cmp -s "$expected" "$new_lock"; then
  reasons+=("Gemfile.lock changes beyond the decidim-secure_elections revision line")
fi

# 2. Every gem migration is already in the app, by base name: the timestamp
# prefix and the engine suffix (.decidim_elections_vocdoni) that
# install:migrations adds are ignored.
app_names=$(find "$app_migrate" -maxdepth 1 -type f -name '*.rb' -printf '%f\n' \
  | sed -nE 's/^[0-9]+_([a-z0-9_]+)(\.[a-z0-9_]+)?\.rb$/\1/p' | sort -u)
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if [[ "$entry" =~ ^[0-9]+_([a-z0-9_]+)\.rb$ ]]; then
    name=${BASH_REMATCH[1]}
    if ! grep -qxF "$name" <<<"$app_names"; then
      reasons+=("gem migration $name is not in deploy/railway/db/migrate (copy it with install:migrations)")
    fi
  else
    reasons+=("the gem's db/migrate has an entry with an unexpected name")
  fi
done < "$gem_list"

if [ ${#reasons[@]} -gt 0 ]; then
  printf '%s\n' "${reasons[@]}"
  exit 1
fi
echo "mechanical: one revision line, no new migrations"
