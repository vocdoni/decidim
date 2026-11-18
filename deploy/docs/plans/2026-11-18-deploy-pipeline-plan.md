# Deploy pipeline for decidim-dev and decidim.vocdoni.dev: implementation plan

Spec: deploy/docs/specs/2026-11-18-deploy-pipeline-design.md (approved 2026-11-18; audit folded in: .delivery/2026-11-18-deploy-pipeline/audit-spec.md)
Class: architectural
Repos and branches:
- Fork /home/user/src/vd/decidim-deploy-bump (github.com/vocdoni/decidim) → feat/deploy-pipeline (base develop 45a9119960; spec commits up to d9be3dc6a4; plan tasks commit on top)
- Gem github.com/vocdoni/decidim-secure_elections, worktree /home/user/src/vd/decidim-secure_elections-notify-fork → feat/notify-fork (base origin/main 27e582bacbc911d36c6edd620228b1d0754e109b)

## Global Constraints
- Commit convention: conventional commits (`ci(deploy): ...`, `feat(deploy): ...`, `docs(deploy): ...`), English, no AI attribution and no `Co-Authored-By` trailer of any kind.
- Never push, never open PRs; the controller does. Commit with explicit paths only (`git commit -m ... -- <paths>`); never `git add -A`.
- Never build, test or lint on the laptop. Lint and the shell test run on z6 (`ssh z6.vocdoni.net`, scratch dir `~/scratch/deploy-pipeline/`, Docker available). Docker image builds are not run by implementers; they are proven in GitHub Actions after the push.
- Lint recipe (used by every task; `<files>` = the task's files, paths relative to the repo root):
  ```bash
  R=/home/user/src/vd/decidim-deploy-bump   # gem task: R=/home/user/src/vd/decidim-secure_elections-notify-fork
  tar -C "$R" -cf - <files> | ssh z6.vocdoni.net 'd=~/scratch/deploy-pipeline/lint; rm -rf "$d"; mkdir -p "$d"; tar -x -C "$d"'
  ssh z6.vocdoni.net 'cd ~/scratch/deploy-pipeline/lint && docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -no-color <workflow files>; echo "actionlint exit $?"'
  ssh z6.vocdoni.net 'cd ~/scratch/deploy-pipeline/lint && docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.11.0 <shell files>; echo "shellcheck exit $?"'
  ```
  Expected: no findings, `actionlint exit 0` / `shellcheck exit 0`. All file contents in this plan passed this on z6 on 2026-11-18.
- File contents in this plan are complete and exact; write them verbatim (no reformatting, no added comments). Shell scripts are committed with mode 755 (`chmod 755` before committing; check with `git ls-files -s <path>` → `100755`).
- Never print secrets: z4 `dev.env`, Railway variables, `RAILWAY_TOKEN`, `FORK_DISPATCH_TOKEN`, any GHCR token. Never read `dev.env`.
- Third-party actions are pinned by full commit SHA with the tag in a comment, exactly as written in this plan.
- Docs and comments say what is and why; no history wording ("was", "previously", "moved from", "since <date>").
- Prod (decidim.vocdoni.dev, Railway project `decidim-vocdoni`) and z4 are not touched by any task. Every change to them is a rollout step in "Merge and release", with the owner's OK at that moment.

## Review Focus
- Privilege split in `.github/workflows/vocdoni_gem_bump.yml`: job `lock` (`permissions: {}`, container, runs gem code via `bundle lock`) versus job `bump` (write token, never runs gem code). `bump` must use nothing from `lock` except `outputs.changed` and the artifact, and the artifact is accepted only through `deploy/ci/gem-bump-check.sh`.
- Injection points: gem commit text reaches only `$RUNNER_TEMP/body.md` through `git log | sed` (backticks stripped, `@` wrapped, `#N` qualified) and `--body-file`; tag names in `vocdoni_release.yml` go through `env:` and a regex before use; no `${{ }}` of event text inside `run:`.
- `vocdoni_image.yml`: `:develop` and `sha-<12>` are pushed only when `github.ref == refs/heads/develop`, whatever the dispatch input says.
- `vocdoni_release.yml`: `RAILWAY_TOKEN` is an environment secret read only in the two Railway steps of `deploy` (environment `production`); `resolve` has no environment and fails before the approval prompt; dispatches must run on the tag ref.
- `deploy/ci/railway-promote.sh`: the GraphQL documents, the token-environment guard, per-service order (web → worker → crons) and the read-back checks.
- `deploy/dev/decidim-dev-update`: `.env` is rewritten only after both strict checks pass; the rollback path (`rollback()`) restores `prev_tag` read from `.env` before any change; the migration guard and the failed-digest skip.

## Plan decisions beyond the spec (controller: rule on these)
<!-- Not copied into briefs. -->
1. **NO FILE baseline (spec §Dev updater step 3).** The z4 DB has 1410 applied versions; 753 of them have no file in `deploy/railway/db/migrate/` (dev-app timestamps left in `schema_migrations` by the 2026-11-17 reconciliation; read-only `psql` count on 2026-11-18). A literal "any `NO FILE` row is a hard stop" blocks every deploy. The updater records those versions once at install (`--record-baseline` → `.update/nofile-baseline`) and stops only on `NO FILE` versions outside the baseline. The alternative (deleting the 753 rows) is a dev DB change for the owner to decide.
2. **Failed digests are not retried every 2 minutes.** The spec has no rule for it; without one a bad image would be backed up, migrated, deployed and rolled back every timer tick. The updater writes the digest to `.update/failed-digest` and skips it until a newer image or `--retry`.
3. **Workflow 3 moves one service at a time** (set source → read back → deploy → wait), web first, instead of setting all five sources first. Same order of deploys; it also keeps worker/crons from moving early if Railway turns out to start a deploy on a source change (unverified). The crons get a `serviceInstanceDeployV2` too and are waited for: a source change alone does not change the deployment they run (their current deployments report `SUCCESS`).
4. **Labels.** The fork has neither `target: developer-experience` nor `needs-review` (checked 2026-11-18); `gh pr create --label` fails on a missing label. A rollout step creates both before workflow 2 first runs.
5. **Single-manifest images** (`provenance: false`, `sbom: false`): the GHCR digest is then the digest z4's `RepoDigests` and Railway's `meta.imageDigest` show. Workflow 3 compares `meta.imageDigest` as a warning only (spec: "may additionally compare").
6. **Job `bump` re-derives everything** (gem head via `ls-remote`, pinned revision from its own checkout); a lock built from a gem head that moved meanwhile is dropped with a notice (the queued run for the newer push handles it).
7. **Job `lock` uses the `ruby:3.4.7` container** (pinned by digest) instead of `ruby/setup-ruby`, and fetches only `Gemfile` and `Gemfile.lock` from `raw.githubusercontent.com` at the develop SHA read by `ls-remote`: no checkout action and no token.
8. **`#N` in gem commit subjects** is rewritten to `vocdoni/decidim-secure_elections#N`, so PR bodies link the gem PR instead of a fork PR with the same number (GitHub adds a cross-reference on the gem PR).

## Task order and parallelism
| Task | Depends on | Repo/files | May run in parallel with |
|---|---|---|---|
| 1 Image workflow | none | fork: `.github/workflows/vocdoni_image.yml` | 5 |
| 2 Gem bump workflow | none (calls task 1's workflow by name) | fork: `.github/workflows/vocdoni_gem_bump.yml`, `deploy/ci/gem-bump-check.sh`, `deploy/ci/gem-bump-check_test.sh` | 5 |
| 3 Dev updater files | none | fork: `deploy/dev/*` | 5 |
| 4 Release workflow | none | fork: `.github/workflows/vocdoni_release.yml`, `deploy/ci/railway-promote.sh` | 5 |
| 5 Gem notify workflow | none | gem: `.github/workflows/notify_fork.yml` | 1, 2, 3, 4, 6 |
| 6 Railway README | none (documents 1–4) | fork: `deploy/railway/README.md` | 5 |

Tasks 1–4 and 6 share one worktree and branch: run them one after another (any order; 1, 2, 3, 4, 6 is the natural one). Task 5 is in the gem repository and can run at any time.

## Tasks

### Task 1: image build and PR check workflow
Model: standard   Repo: /home/user/src/vd/decidim-deploy-bump   Files: `.github/workflows/vocdoni_image.yml`
Goal: build `deploy/railway/` once per develop commit and push `sha-<12>` + `:develop` with the three labels; build without pushing on PRs and on dispatch with `push: false` (AC1, AC2).

Step 1: write `.github/workflows/vocdoni_image.yml`:
```yaml
# Builds the decidim.vocdoni.dev image from deploy/railway/ (see
# deploy/docs/specs/2026-11-18-deploy-pipeline-design.md, "Workflow 1").
# develop pushes publish ghcr.io/vocdoni/decidim-vocdoni:sha-<12> and :develop;
# pull requests and workflow_dispatch with push=false only build.
name: "[Vocdoni] Image"

on:
  push:
    branches: [develop]
    paths:
      - "deploy/railway/**"
      - ".github/workflows/vocdoni_image.yml"
  pull_request:
    paths:
      - "deploy/railway/**"
      - ".github/workflows/vocdoni_image.yml"
  # Merges made with GITHUB_TOKEN (gem bumps) do not fire `push`; the gem bump
  # workflow dispatches this one instead, with push=false on its PR branch.
  workflow_dispatch:
    inputs:
      push:
        description: "Push sha-<12> and :develop (only honoured on develop)"
        type: boolean
        default: true

permissions:
  contents: read
  packages: write

concurrency:
  group: image-${{ github.ref }}
  cancel-in-progress: true

env:
  IMAGE: ghcr.io/vocdoni/decidim-vocdoni

jobs:
  build:
    name: Build image
    runs-on: ubuntu-24.04
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Resolve tags and labels
        id: meta
        env:
          EVENT: ${{ github.event_name }}
          PUSH_INPUT: ${{ inputs.push }}
        run: |
          set -euo pipefail
          # Only develop moves :develop; any other ref is a check build.
          push=false
          if [ "$GITHUB_REF" = refs/heads/develop ]; then
            if [ "$EVENT" = push ] || { [ "$EVENT" = workflow_dispatch ] && [ "$PUSH_INPUT" = true ]; }; then
              push=true
            fi
          fi
          gem_rev=$(awk '/decidim-secure_elections\.git/ { f = 1 } f && $1 == "revision:" { print $2; exit }' deploy/railway/Gemfile.lock)
          if ! [[ "$gem_rev" =~ ^[0-9a-f]{40}$ ]]; then
            echo "::error::cannot read the decidim-secure_elections revision from deploy/railway/Gemfile.lock"
            exit 1
          fi
          sha12=${GITHUB_SHA:0:12}
          {
            echo "push=$push"
            echo "sha12=$sha12"
            echo "tags<<EOF"
            echo "$IMAGE:sha-$sha12"
            echo "$IMAGE:develop"
            echo "EOF"
            echo "labels<<EOF"
            echo "org.opencontainers.image.revision=$GITHUB_SHA"
            echo "org.opencontainers.image.source=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
            echo "io.vocdoni.gem-revision=$gem_rev"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1

      - name: Log in to GHCR
        if: steps.meta.outputs.push == 'true'
        uses: docker/login-action@8aa5831fb8d48d8f76594c7ddde61ae58019f550 # v4.8.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build${{ steps.meta.outputs.push == 'true' && ' and push' || '' }}
        id: build
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: deploy/railway
          file: deploy/railway/Dockerfile
          platforms: linux/amd64
          push: ${{ steps.meta.outputs.push == 'true' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          # One plain manifest, no attestation index: the digest GHCR reports is
          # the one z4 and Railway pull and the one workflow 3 promotes.
          provenance: false
          sbom: false
          cache-from: type=registry,ref=${{ env.IMAGE }}:buildcache
          cache-to: ${{ steps.meta.outputs.push == 'true' && format('type=registry,ref={0}:buildcache,mode=max', env.IMAGE) || '' }}

      - name: Summary
        env:
          PUSHED: ${{ steps.meta.outputs.push }}
          SHA12: ${{ steps.meta.outputs.sha12 }}
          DIGEST: ${{ steps.build.outputs.digest }}
        run: |
          {
            echo "### decidim-vocdoni image"
            echo
            if [ "$PUSHED" = true ]; then
              echo "Pushed \`$IMAGE:sha-$SHA12\` and \`$IMAGE:develop\`, digest \`$DIGEST\`."
            else
              echo "Check build of \`$GITHUB_SHA\` (not pushed)."
            fi
          } >> "$GITHUB_STEP_SUMMARY"
```

Step 2: lint (Global Constraints recipe) with `<files>` = `.github/workflows/vocdoni_image.yml`, actionlint on that file, no shellcheck call.
Expected: `actionlint exit 0`, no findings.

Step 3: commit
`git commit -m "ci(deploy): build the decidim-vocdoni image in GHCR" -- .github/workflows/vocdoni_image.yml`

Interfaces this task provides to later tasks: workflow file name `vocdoni_image.yml`; `workflow_dispatch` input `push` (boolean, default `true`, honoured only on `refs/heads/develop`); image `ghcr.io/vocdoni/decidim-vocdoni` with tags `sha-<first 12 of the fork commit>`, `develop`, cache tag `buildcache`; labels `org.opencontainers.image.revision`, `org.opencontainers.image.source`, `io.vocdoni.gem-revision`; single-platform `linux/amd64` manifest (no index).

### Task 2: gem bump workflow with the two-job privilege split
Model: strong   Repo: /home/user/src/vd/decidim-deploy-bump   Files: `.github/workflows/vocdoni_gem_bump.yml`, `deploy/ci/gem-bump-check.sh`, `deploy/ci/gem-bump-check_test.sh`
Goal: on dispatch, bump the module's lock revision to gem `main`, open/update one PR, and merge it only when the bump is mechanical and the image builds (AC5, AC10).

Step 1: write the failing test `deploy/ci/gem-bump-check_test.sh` (mode 755):
```bash
#!/usr/bin/env bash
# Tests for gem-bump-check.sh. Run: bash deploy/ci/gem-bump-check_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check=$here/gem-bump-check.sh
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

old=1111111111111111111111111111111111111111
new=2222222222222222222222222222222222222222
fork=3333333333333333333333333333333333333333

lock() { # $1 = gem revision, $2 = extra spec line (optional)
  cat <<EOF
GIT
  remote: https://github.com/vocdoni/decidim-secure_elections.git
  revision: $1
  branch: main
  specs:
    decidim-elections-vocdoni (0.1.0)
      faraday (~> 2.9)${2:-}

GIT
  remote: https://github.com/vocdoni/decidim.git
  revision: $fork
  branch: develop
  specs:
    decidim (0.33.0.dev)

BUNDLED WITH
   2.6.9
EOF
}

mkdir -p "$t/app"
touch "$t/app/20261106114202_add_deleted_fields_to_users.decidim.rb" \
      "$t/app/20261116163555_add_live_results_sync_to_vocdoni_processes.decidim_elections_vocdoni.rb"
lock "$old" > "$t/base.lock"
lock "$new" > "$t/new.lock"
lock "$new" $'\n      faraday-retry (~> 2.2)' > "$t/extra.lock"
lock "$fork" > "$t/forkrev.lock"
printf '%s\n' 20261111120001_add_live_results_sync_to_vocdoni_processes.rb > "$t/gem.list"
printf '%s\n' 20261111120001_add_live_results_sync_to_vocdoni_processes.rb 20261201000000_add_tally_column.rb > "$t/gem-new.list"
# shellcheck disable=SC2016 # a literal, hostile-looking file name
printf '%s\n' 'evil$(id).rb' > "$t/gem-odd.list"

fails=0
expect() { # $1 = name, $2 = want exit, $3 = want stdout substring, rest = args
  local name=$1 want=$2 grepfor=$3; shift 3
  local out code
  out=$("$check" "$@" 2>&1); code=$?
  if [ "$code" != "$want" ] || ! grep -qF -- "$grepfor" <<<"$out"; then
    echo "FAIL $name: exit $code (want $want), output: $out"
    fails=$((fails + 1))
  else
    echo "ok   $name"
  fi
}

expect mechanical          0 "mechanical"            "$t/base.lock" "$t/new.lock"     "$new" "$t/app" "$t/gem.list"
expect extra-lock-change   1 "beyond the"            "$t/base.lock" "$t/extra.lock"   "$new" "$t/app" "$t/gem.list"
expect wrong-block-changed 1 "beyond the"            "$t/base.lock" "$t/forkrev.lock" "$new" "$t/app" "$t/gem.list"
expect new-migration       1 "add_tally_column"      "$t/base.lock" "$t/new.lock"     "$new" "$t/app" "$t/gem-new.list"
expect odd-entry           1 "unexpected name"       "$t/base.lock" "$t/new.lock"     "$new" "$t/app" "$t/gem-odd.list"
expect already-pinned      1 "already pins"          "$t/base.lock" "$t/base.lock"    "$old" "$t/app" "$t/gem.list"
expect bad-sha             2 "40-char"               "$t/base.lock" "$t/new.lock"     "abc"  "$t/app" "$t/gem.list"

if [ "$fails" -ne 0 ]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
```
Run on z6 (the checker does not exist yet):
```bash
R=/home/user/src/vd/decidim-deploy-bump
tar -C "$R" -cf - deploy/ci | ssh z6.vocdoni.net 'd=~/scratch/deploy-pipeline/lint; rm -rf "$d"; mkdir -p "$d"; tar -x -C "$d"'
ssh z6.vocdoni.net 'cd ~/scratch/deploy-pipeline/lint && bash deploy/ci/gem-bump-check_test.sh'
```
Expected: seven `FAIL ...` lines (exit 127 from the missing script) and `7 failed`.

Step 2: write `deploy/ci/gem-bump-check.sh` (mode 755):
```bash
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
```
Run the same two commands as in step 1.
Expected:
```
ok   mechanical
ok   extra-lock-change
ok   wrong-block-changed
ok   new-migration
ok   odd-entry
ok   already-pinned
ok   bad-sha
all passed
```

Step 3: write `.github/workflows/vocdoni_gem_bump.yml`:
```yaml
# Bumps decidim-elections-vocdoni in deploy/railway/Gemfile.lock to the head of
# vocdoni/decidim-secure_elections main (see
# deploy/docs/specs/2026-11-18-deploy-pipeline-design.md, "Workflow 2").
# Started by the gem's notify workflow on every push to its main, or by hand.
#
# Two jobs, so gem-repo write access never turns into fork write access:
# - `lock` runs `bundle lock`, which evaluates the gem's gemspec (gem code),
#   with no token at all, and hands the lock over as an artifact.
# - `bump` holds the write token, never runs gem code, and treats the artifact
#   as untrusted input: gem-bump-check.sh accepts it only if it differs from
#   develop's lock in exactly the revision line.
name: "[Vocdoni] Gem bump"

on:
  workflow_dispatch: {}

permissions: {}

concurrency:
  group: gem-bump
  cancel-in-progress: false

env:
  GEM_REPO: https://github.com/vocdoni/decidim-secure_elections.git

jobs:
  lock:
    name: Lock (no token)
    if: github.ref == 'refs/heads/develop'
    runs-on: ubuntu-24.04
    timeout-minutes: 30
    permissions: {}
    container:
      image: ruby:3.4.7@sha256:779ca68b84fe3804e27f5b7ea5ab001005c708b7236a798c15b860d71cba9d21 # ruby:3.4.7
    outputs:
      changed: ${{ steps.pin.outputs.changed }}
    steps:
      # Public repositories only: plain HTTPS, no credentials, no checkout action.
      - name: Read the pinned and the current gem revision
        id: pin
        run: |
          set -euo pipefail
          mkdir work
          develop=$(git ls-remote "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY.git" refs/heads/develop | cut -f1)
          gem=$(git ls-remote "$GEM_REPO" refs/heads/main | cut -f1)
          for v in "$develop" "$gem"; do
            [[ "$v" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::ls-remote returned no commit"; exit 1; }
          done
          raw="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/$develop/deploy/railway"
          curl -fsSL -o work/Gemfile "$raw/Gemfile"
          curl -fsSL -o work/Gemfile.lock "$raw/Gemfile.lock"
          pinned=$(awk '/decidim-secure_elections\.git/ { f = 1 } f && $1 == "revision:" { print $2; exit }' work/Gemfile.lock)
          [[ "$pinned" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::cannot read the pinned revision"; exit 1; }
          echo "develop $develop pins $pinned; gem main is $gem"
          if [ "$pinned" = "$gem" ]; then
            echo "changed=false" >> "$GITHUB_OUTPUT"
          else
            echo "changed=true" >> "$GITHUB_OUTPUT"
            # The revision is unique to the gem's GIT block (the Decidim block pins a fork commit).
            sed -i "s/^  revision: $pinned\$/  revision: $gem/" work/Gemfile.lock
          fi

      - name: bundle lock
        if: steps.pin.outputs.changed == 'true'
        working-directory: work
        env:
          BUNDLE_FROZEN: "false"
          BUNDLE_DEPLOYMENT: "false"
        run: |
          set -euo pipefail
          gem install bundler:2.6.9 --no-document
          bundle _2.6.9_ lock

      - name: Upload the lock
        if: steps.pin.outputs.changed == 'true'
        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: gem-bump-lock
          path: work/Gemfile.lock
          retention-days: 5
          if-no-files-found: error

  bump:
    name: Check, open PR, build, merge
    needs: lock
    if: needs.lock.outputs.changed == 'true'
    runs-on: ubuntu-24.04
    timeout-minutes: 75
    permissions:
      contents: write
      pull-requests: write
      actions: write
    env:
      GH_TOKEN: ${{ github.token }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: develop

      - name: Download the lock
        uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: gem-bump-lock
          path: ${{ runner.temp }}/artifact

      - name: Fetch the gem's history (git data only, nothing runs)
        id: gem
        run: |
          set -euo pipefail
          gem=$(git ls-remote "$GEM_REPO" refs/heads/main | cut -f1)
          [[ "$gem" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::ls-remote returned no commit"; exit 1; }
          pinned=$(awk '/decidim-secure_elections\.git/ { f = 1 } f && $1 == "revision:" { print $2; exit }' deploy/railway/Gemfile.lock)
          [[ "$pinned" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::cannot read the pinned revision"; exit 1; }
          git init -q "$RUNNER_TEMP/gem"
          git -C "$RUNNER_TEMP/gem" fetch -q --filter=blob:none "$GEM_REPO" main
          git -C "$RUNNER_TEMP/gem" ls-tree --name-only "$gem" db/migrate/ | sed 's|^db/migrate/||' > "$RUNNER_TEMP/gem-migrations.txt"
          {
            echo "gem=$gem"
            echo "pinned=$pinned"
            echo "short=${gem:0:7}"
          } >> "$GITHUB_OUTPUT"

      - name: Mechanical-bump check
        id: check
        env:
          GEM: ${{ steps.gem.outputs.gem }}
          PINNED: ${{ steps.gem.outputs.pinned }}
        run: |
          set -uo pipefail
          # develop got this revision some other way since the lock job read it.
          if [ "$GEM" = "$PINNED" ]; then
            echo "::notice::develop already pins $GEM"
            echo "stale=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          bash deploy/ci/gem-bump-check.sh deploy/railway/Gemfile.lock "$RUNNER_TEMP/artifact/Gemfile.lock" \
            "$GEM" deploy/railway/db/migrate "$RUNNER_TEMP/gem-migrations.txt" > "$RUNNER_TEMP/check.txt"
          code=$?
          cat "$RUNNER_TEMP/check.txt"
          case $code in
            0) echo "mechanical=true" >> "$GITHUB_OUTPUT" ;;
            1) echo "mechanical=false" >> "$GITHUB_OUTPUT" ;;
            *) echo "::error::gem-bump-check.sh failed (exit $code)"; exit 1 ;;
          esac
          # gem main moved after the lock job read it: the dispatch for that push
          # is queued behind this run and bumps to the new head.
          if [ "$code" = 1 ] && ! grep -q "revision: $GEM\$" "$RUNNER_TEMP/artifact/Gemfile.lock"; then
            echo "stale=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Stop on a stale lock
        if: steps.check.outputs.stale == 'true'
        run: echo "::notice::nothing to merge from this run; a queued run (if any) bumps to the new head"

      - name: Commit to bot/gem-bump and open or update the PR
        if: steps.check.outputs.stale != 'true'
        id: pr
        env:
          GEM: ${{ steps.gem.outputs.gem }}
          PINNED: ${{ steps.gem.outputs.pinned }}
          SHORT: ${{ steps.gem.outputs.short }}
        run: |
          set -euo pipefail
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git checkout -q -B bot/gem-bump
          cp "$RUNNER_TEMP/artifact/Gemfile.lock" deploy/railway/Gemfile.lock
          git commit -q -m "chore(deploy): bump decidim-elections-vocdoni to $SHORT" -- deploy/railway/Gemfile.lock
          git push -q --force origin bot/gem-bump
          echo "head=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"

          # Gem commit text goes only through files: @mentions are wrapped in
          # backticks so nobody is notified, and #N points at the gem repo.
          body=$RUNNER_TEMP/body.md
          # shellcheck disable=SC2016 # the sed scripts match literal backticks
          {
            echo "Bumps \`decidim-elections-vocdoni\` from vocdoni/decidim-secure_elections@$PINNED to vocdoni/decidim-secure_elections@$GEM."
            echo
            echo "Gem commits:"
            echo
            { git -C "$RUNNER_TEMP/gem" log --first-parent --format='- %h %s' "$PINNED..$GEM" \
                || echo "- (history between the two revisions is not available)"; } \
              | sed -E 's/`//g; s/@([A-Za-z0-9_.\/-]+)/`@\1`/g; s/(^|[^A-Za-z0-9_\/])#([0-9]+)/\1vocdoni\/decidim-secure_elections#\2/g'
            echo
            echo "Opened by the \`[Vocdoni] Gem bump\` workflow: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
          } > "$body"

          title="Bump decidim-elections-vocdoni to $SHORT"
          pr=$(gh pr list --head bot/gem-bump --base develop --state open --json number --jq '.[0].number // empty')
          if [ -n "$pr" ]; then
            gh pr edit "$pr" --title "$title" --body-file "$body"
          else
            gh pr create --base develop --head bot/gem-bump --title "$title" --body-file "$body" \
              --label "target: developer-experience"
            pr=$(gh pr list --head bot/gem-bump --base develop --state open --json number --jq '.[0].number')
          fi
          echo "number=$pr" >> "$GITHUB_OUTPUT"

      - name: Not mechanical, leave the PR for review
        if: steps.check.outputs.stale != 'true' && steps.check.outputs.mechanical == 'false'
        env:
          PR: ${{ steps.pr.outputs.number }}
        run: |
          set -euo pipefail
          {
            echo "Not merged automatically: this bump needs a review."
            echo
            sed 's/^/- /' "$RUNNER_TEMP/check.txt"
            echo
            echo "Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
          } > "$RUNNER_TEMP/comment.md"
          gh pr edit "$PR" --add-label needs-review
          gh pr comment "$PR" --body-file "$RUNNER_TEMP/comment.md"

      - name: Build the bump branch (no push)
        if: steps.check.outputs.stale != 'true' && steps.check.outputs.mechanical == 'true'
        id: build
        env:
          HEAD: ${{ steps.pr.outputs.head }}
        run: |
          set -euo pipefail
          gh workflow run vocdoni_image.yml --ref bot/gem-bump -f push=false
          run_id=
          for _ in $(seq 1 24); do
            sleep 5
            run_id=$(gh run list --workflow vocdoni_image.yml --branch bot/gem-bump --event workflow_dispatch \
              --limit 20 --json databaseId,headSha \
              --jq "map(select(.headSha == \"$HEAD\")) | .[0].databaseId // empty")
            [ -n "$run_id" ] && break
          done
          [ -n "$run_id" ] || { echo "::error::the dispatched image build did not show up"; exit 1; }
          echo "run_url=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$run_id" >> "$GITHUB_OUTPUT"
          if gh run watch "$run_id" --exit-status --interval 30 > /dev/null; then
            echo "ok=true" >> "$GITHUB_OUTPUT"
          else
            echo "ok=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Build failed, leave the PR for review
        if: steps.build.outputs.ok == 'false'
        env:
          PR: ${{ steps.pr.outputs.number }}
          RUN_URL: ${{ steps.build.outputs.run_url }}
        run: |
          set -euo pipefail
          printf 'Not merged automatically: the image build failed.\n\nBuild: %s\n' "$RUN_URL" > "$RUNNER_TEMP/comment.md"
          gh pr edit "$PR" --add-label needs-review
          gh pr comment "$PR" --body-file "$RUNNER_TEMP/comment.md"
          echo "::error::image build failed: $RUN_URL"
          exit 1

      - name: Merge and build develop
        if: steps.build.outputs.ok == 'true'
        env:
          PR: ${{ steps.pr.outputs.number }}
          HEAD: ${{ steps.pr.outputs.head }}
        run: |
          set -euo pipefail
          gh pr edit "$PR" --remove-label needs-review || true
          gh pr merge "$PR" --merge --match-head-commit "$HEAD"
          gh workflow run vocdoni_image.yml --ref develop -f push=true
```

Step 4: lint (recipe) with `<files>` = `.github/workflows/vocdoni_gem_bump.yml deploy/ci/gem-bump-check.sh deploy/ci/gem-bump-check_test.sh`; actionlint on the workflow; shellcheck on the two scripts.
Expected: `actionlint exit 0`, `shellcheck exit 0`.

Step 5: commit
`chmod 755 deploy/ci/gem-bump-check.sh deploy/ci/gem-bump-check_test.sh`
`git add -- .github/workflows/vocdoni_gem_bump.yml deploy/ci/gem-bump-check.sh deploy/ci/gem-bump-check_test.sh`
`git commit -m "ci(deploy): bump the elections module lock on dispatch" -- .github/workflows/vocdoni_gem_bump.yml deploy/ci/gem-bump-check.sh deploy/ci/gem-bump-check_test.sh`

Interfaces this task provides to later tasks: workflow file name `vocdoni_gem_bump.yml` (dispatch on `develop`, no inputs; task 5 calls it); branch `bot/gem-bump`; PR title `Bump decidim-elections-vocdoni to <sha7>`; labels `target: developer-experience`, `needs-review` (must exist in the fork, see rollout); `deploy/ci/gem-bump-check.sh <base-lock> <new-lock> <gem-sha> <app-migrate-dir> <gem-migrations-list>` → exit 0 mechanical / 1 not (reasons on stdout) / 2 bad input.

### Task 3: dev updater on z4 (files only)
Model: strong   Repo: /home/user/src/vd/decidim-deploy-bump   Files: `deploy/dev/README.md`, `deploy/dev/compose.yaml`, `deploy/dev/checks.sh`, `deploy/dev/decidim-dev-update`, `deploy/dev/decidim-dev-update.service`, `deploy/dev/decidim-dev-update.timer`
Goal: version the z4 host files and add the pull-based updater with strict checks and rollback (AC3, AC4). Nothing is installed on z4 by this task.

`compose.yaml` is the z4 file as of 2026-11-18 with three added comment lines (services unchanged); `checks.sh` keeps the z4 output lines and adds `--strict`.

Step 1: write `deploy/dev/checks.sh` (mode 755):
```bash
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
```

Step 2: write `deploy/dev/decidim-dev-update` (mode 755):
```bash
#!/usr/bin/env bash
# decidim-dev-update: moves decidim-dev.vocdoni.net (z4, compose project
# decidim-dev-prod) to the newest ghcr.io/vocdoni/decidim-vocdoni:develop image.
# Run every 2 minutes by decidim-dev-update.timer; see README.md next to it.
#
# usage: decidim-dev-update [--ref <tag>] [--force-fail] [--retry]
#        decidim-dev-update --record-baseline
#   --ref <tag>        deploy another tag of the image instead of develop
#   --force-fail       deploy even if already running that digest, then treat
#                      the checks as failed (exercises the rollback path)
#   --retry            try a digest that failed before (normally skipped)
#   --record-baseline  store the migration versions applied in the DB that have
#                      no file in the running image (one-time, at install)
#
# A run: compare digests; pull and tag decidim-vocdoni-dev:sha-<12>; refuse to
# deploy if the migration status looks unreconciled; pg_dump; run `release`
# (db:migrate); recreate web and worker; run checks.sh --strict locally and on
# the public URL; on failure recreate web and worker on the previous tag.
# .env is rewritten only after the checks pass. Migrations are not reverted;
# the dump is the way back.
set -euo pipefail
shopt -s inherit_errexit

DIR=/home/vocdoni/decidim-prod-mode
IMAGE=ghcr.io/vocdoni/decidim-vocdoni
LOCAL_REPO=decidim-vocdoni-dev
HOST=decidim-dev.vocdoni.net
BACKUP_DIR=/home/vocdoni/decidim-backups
BACKUP_KEEP=5
PG_CONTAINER=decidim-postgres-1
PG_DB=decidim_development_app_development
STATE_DIR=$DIR/.update
BASELINE=$STATE_DIR/nofile-baseline
FAILED=$STATE_DIR/failed-digest
STATE=$STATE_DIR/state

# Journal priorities (SyslogLevelPrefix) under systemd, plain text otherwise.
if [ -n "${INVOCATION_ID:-}" ]; then p_info='<6>' p_err='<3>'; else p_info='' p_err=''; fi
log() { echo "${p_info}$*"; }
err() { echo "${p_err}ERROR: $*"; }
die() { err "$*"; exit 1; }

ref=develop force_fail=0 retry=0 baseline_only=0
while [ $# -gt 0 ]; do
  case $1 in
    --ref) ref=${2:?--ref needs a tag}; shift 2 ;;
    --force-fail) force_fail=1; shift ;;
    --retry) retry=1; shift ;;
    --record-baseline) baseline_only=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$ref" =~ ^[A-Za-z0-9_.-]+$ ]] || die "bad tag: $ref"

cd "$DIR"
mkdir -p "$STATE_DIR"
exec 9> "$STATE_DIR/lock"
if ! flock -n 9; then
  log "another run holds $STATE_DIR/lock; exiting"
  exit 0
fi

current_tag() { sed -n 's/^DECIDIM_IMAGE_TAG=//p' .env | tail -1; }

# migrate_status <local tag>: `db:migrate:status` from a one-shot release container.
migrate_status() {
  DECIDIM_IMAGE_TAG=$1 docker compose --profile release run --rm --no-deps -T release \
    bin/rails db:migrate:status 2> /dev/null
}
nofile_versions() { awk '$1 == "up" && /NO FILE/ { print $2 }' | sort -u; }

if [ "$baseline_only" = 1 ]; then
  tag=$(current_tag)
  [ -n "$tag" ] || die ".env has no DECIDIM_IMAGE_TAG"
  status=$(migrate_status "$tag") || die "db:migrate:status failed on $LOCAL_REPO:$tag"
  nofile_versions <<<"$status" > "$BASELINE.tmp"
  mv "$BASELINE.tmp" "$BASELINE"
  log "recorded $(wc -l < "$BASELINE") applied versions without a file in $LOCAL_REPO:$tag to $BASELINE"
  exit 0
fi

# 1. Digests.
remote=$(docker buildx imagetools inspect "$IMAGE:$ref" --format '{{json .Manifest}}' | jq -r .digest) \
  || die "cannot read $IMAGE:$ref"
[[ "$remote" =~ ^sha256:[0-9a-f]{64}$ ]] || die "bad digest for $IMAGE:$ref: $remote"

running=none
cid=$(docker compose ps -q web || true)
if [ -n "$cid" ]; then
  img=$(docker inspect -f '{{.Image}}' "$cid")
  if docker image inspect -f '{{json .RepoDigests}}' "$img" | jq -e --arg d "$IMAGE@$remote" 'any(.[]; . == $d)' > /dev/null; then
    running=$remote
  fi
fi
if [ "$running" = "$remote" ] && [ "$force_fail" = 0 ]; then
  exit 0
fi
if [ "$retry" = 0 ] && [ "$force_fail" = 0 ] && [ -f "$FAILED" ] && [ "$(cat "$FAILED")" = "$remote" ]; then
  exit 0 # failed before; logged then. Run with --retry to try it again.
fi
# A failed digest is skipped by later timer runs until --retry or a new image.
fail_digest() {
  [ "$force_fail" = 1 ] || echo "$remote" > "$FAILED"
  die "$*"
}

prev_tag=$(current_tag)
[ -n "$prev_tag" ] || die ".env has no DECIDIM_IMAGE_TAG"
docker image inspect "$LOCAL_REPO:$prev_tag" > /dev/null 2>&1 || die "previous image $LOCAL_REPO:$prev_tag is missing"
log "$IMAGE:$ref is $remote; dev runs $LOCAL_REPO:$prev_tag"

# 2. Pull by digest and tag with the fork commit.
docker pull -q "$IMAGE@$remote" > /dev/null || die "pull of $IMAGE@$remote failed"
rev=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE@$remote")
[[ "$rev" =~ ^[0-9a-f]{40}$ ]] || fail_digest "image $remote has no org.opencontainers.image.revision label"
new_tag="sha-${rev:0:12}"
new_id=$(docker image inspect -f '{{.Id}}' "$IMAGE@$remote")
if old_id=$(docker image inspect -f '{{.Id}}' "$LOCAL_REPO:$new_tag" 2> /dev/null) && [ "$old_id" != "$new_id" ]; then
  # Same commit, different build: keep the existing tag (it may be the rollback target).
  new_tag="$new_tag-${remote:7:12}"
fi
docker tag "$IMAGE@$remote" "$LOCAL_REPO:$new_tag"
printf 'prev_tag=%s\nnew_tag=%s\ndigest=%s\nstarted=%s\n' "$prev_tag" "$new_tag" "$remote" "$(date -u +%FT%TZ)" > "$STATE"
log "tagged $LOCAL_REPO:$new_tag (fork $rev)"

# 3. Migration guard. Base name = file name without timestamp, engine suffix, .rb.
[ -f "$BASELINE" ] || die "no $BASELINE; run decidim-dev-update --record-baseline once"
status=$(migrate_status "$new_tag") || fail_digest "db:migrate:status failed on $LOCAL_REPO:$new_tag"
files=$(docker run --rm --entrypoint ls "$LOCAL_REPO:$new_tag" db/migrate) \
  || fail_digest "cannot list db/migrate in $LOCAL_REPO:$new_tag"
names=$(sed -nE 's/^([0-9]+)_([a-z0-9_]+)(\.[a-z0-9_]+)?\.rb$/\1 \2/p' <<<"$files")

new_nofile=$(comm -23 <(nofile_versions <<<"$status") "$BASELINE")
if [ -n "$new_nofile" ]; then
  fail_digest "applied migrations without a file in $new_tag (not in the baseline): $(head -5 <<<"$new_nofile" | tr '\n' ' ')- reconcile schema_migrations by hand"
fi
clash=$(awk '
  NR == FNR { name[$1] = $2; next }
  $1 == "up" && !/NO FILE/ && ($2 in name) { up[name[$2]] = 1 }
  $1 == "down" && ($2 in name) { down[name[$2]] = 1 }
  END { for (n in down) if (n in up) print n }
' <(echo "$names") <(echo "$status"))
if [ -n "$clash" ]; then
  fail_digest "pending migrations already applied under another version: $(tr '\n' ' ' <<<"$clash")- mark them in schema_migrations by hand"
fi
pending=$(awk '$1 == "down"' <<<"$status" | wc -l)
log "migration guard passed; $pending pending"

# 4. Backup, release, recreate.
backup="$BACKUP_DIR/decidim_dev-updater-$(date -u +%Y%m%dT%H%M%SZ)-$new_tag.dump"
( umask 077; docker exec "$PG_CONTAINER" pg_dump -U postgres -Fc "$PG_DB" > "$backup" ) \
  || { rm -f "$backup"; fail_digest "pg_dump failed"; }
log "backup $backup ($(du -h "$backup" | cut -f1))"
find "$BACKUP_DIR" -maxdepth 1 -name 'decidim_dev-updater-*.dump' -printf '%f\n' | sort | head -n -"$BACKUP_KEEP" \
  | while IFS= read -r old; do rm -f -- "$BACKUP_DIR/$old"; log "removed old backup $old"; done

DECIDIM_IMAGE_TAG=$new_tag docker compose --profile release run --rm --no-deps -T release \
  || fail_digest "release (db:migrate) failed on $new_tag; web and worker still run $prev_tag; DB as the migration left it; backup $backup"
log "release done on $new_tag"

rollback() {
  err "$1; rolling back web and worker to $prev_tag"
  if DECIDIM_IMAGE_TAG=$prev_tag docker compose up -d --wait --wait-timeout 300 web worker; then
    log "rolled back to $prev_tag"
  else
    err "rollback to $prev_tag did not come up healthy; check docker compose ps"
  fi
  ./checks.sh http://127.0.0.1:3000 -H "Host: $HOST" -H "X-Forwarded-Proto: https" || true
  fail_digest "deploy of $new_tag failed (migrations stay applied; backup $backup)"
}

if ! DECIDIM_IMAGE_TAG=$new_tag docker compose up -d --wait --wait-timeout 300 web worker; then
  rollback "web/worker on $new_tag did not become healthy"
fi

# 5. Checks.
ok=1
./checks.sh --strict http://127.0.0.1:3000 -H "Host: $HOST" -H "X-Forwarded-Proto: https" || ok=0
./checks.sh --strict "https://$HOST" || ok=0
if [ "$force_fail" = 1 ]; then
  log "--force-fail: treating the checks as failed"
  ok=0
fi
[ "$ok" = 1 ] || rollback "checks failed on $new_tag"

# Only now does .env follow.
printf '# decidim-dev-update %s: %s@%s\nDECIDIM_IMAGE_TAG=%s\n' "$(date -u +%FT%TZ)" "$IMAGE" "$remote" "$new_tag" > .env.tmp
chmod --reference=.env .env.tmp
mv .env.tmp .env
rm -f "$FAILED"
log "dev runs $LOCAL_REPO:$new_tag ($IMAGE@$remote)"
```

Step 3: write `deploy/dev/decidim-dev-update.service`:
```ini
[Unit]
Description=Move decidim-dev.vocdoni.net to the newest ghcr.io/vocdoni/decidim-vocdoni:develop image
Documentation=file:/home/vocdoni/decidim-prod-mode/README.md
Requires=docker.service
After=docker.service network-online.target decidim-dev-prod.service
Wants=network-online.target

[Service]
Type=oneshot
User=vocdoni
WorkingDirectory=/home/vocdoni/decidim-prod-mode
ExecStart=/usr/local/bin/decidim-dev-update
SyslogIdentifier=decidim-dev-update
# pg_dump, db:migrate, two health waits and the checks.
TimeoutStartSec=45min
```
and `deploy/dev/decidim-dev-update.timer`:
```ini
[Unit]
Description=Check for a new decidim-dev image every 2 minutes

[Timer]
OnBootSec=5min
# Counted from the end of the previous run, so runs never stack.
OnUnitInactiveSec=2min
Unit=decidim-dev-update.service

[Install]
WantedBy=timers.target
```

Step 4: write `deploy/dev/compose.yaml`:
```yaml
# decidim-dev.vocdoni.net on z4: the Railway production image (deploy/railway
# of vocdoni/decidim develop) in RAILS_ENV=production, with dev env vars.
# The image is ghcr.io/vocdoni/decidim-vocdoni tagged locally by
# decidim-dev-update as decidim-vocdoni-dev:sha-<12>, or a manual z4 build.
# Postgres and Redis are the devcontainer's (project "decidim"), reached over
# its network. The CF tunnel (cloudflared-decidim-dev.service) -> 127.0.0.1:3000.
name: decidim-dev-prod

x-app: &app
  image: decidim-vocdoni-dev:${DECIDIM_IMAGE_TAG:?set in .env}
  env_file: [dev.env]
  restart: unless-stopped
  networks: [decidim]
  volumes:
    # Active Storage "local" service; same files the dev-mode app used.
    - /home/vocdoni/decidim/development_app/storage:/app/storage

services:
  web:
    <<: *app
    ports:
      - "127.0.0.1:3000:3000"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:3000/up"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

  worker:
    <<: *app
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]

  # One-shot: `docker compose run --rm release` (db:migrate), as Railway's pre-deploy.
  release:
    <<: *app
    restart: "no"
    profiles: [release]
    command: ["bin/release"]

networks:
  decidim:
    name: decidim_default
    external: true
```

Step 5: write `deploy/dev/README.md` (installed as the z4 README). The block below is the file indented by four spaces (it contains its own code fences); write it with the indent removed, e.g. save the block to a scratch file and `sed 's/^    //'`; blank lines stay blank:

    # decidim-dev.vocdoni.net (z4) in production mode

    The public dev instance runs the same image as Railway prod (decidim.vocdoni.dev):
    `ghcr.io/vocdoni/decidim-vocdoni`, built by GitHub Actions from `deploy/railway/` of
    `vocdoni/decidim` develop, in `RAILS_ENV=production` with dev variables. No
    letter_opener, web-console, `/rails/info` or error traces.

    The files in this directory are installed in `/home/vocdoni/decidim-prod-mode/` on
    z4 (see [Install](#install)); this copy in the fork is the reference.

    | Piece | What |
    |-------|------|
    | `compose.yaml` | project `decidim-dev-prod`: `web` (Puma, `127.0.0.1:3000`), `worker` (Sidekiq), `release` (one-shot `bin/release` = `db:migrate`) |
    | `dev.env` | all variables, secrets included (chmod 600, never print or copy; not in the fork) |
    | `.env` | `DECIDIM_IMAGE_TAG`, the running image `decidim-vocdoni-dev:<tag>`; written by the updater after a deploy passes its checks |
    | `decidim-dev-update` | the updater, installed as `/usr/local/bin/decidim-dev-update` |
    | `decidim-dev-update.service`, `.timer` | systemd units in `/etc/systemd/system/`; the timer runs the updater 2 minutes after the previous run ends |
    | `.update/` | updater state: `lock`, `state` (previous and new tag of the last run), `failed-digest`, `nofile-baseline` |
    | `checks.sh` | exposure/health checks; `--strict` exits 1 on any violation |
    | Postgres / Redis | the devcontainer's `decidim-postgres-1` / `decidim-redis-1` (network `decidim_default`), DB `decidim_development_app_development` |
    | uploads | bind mount of `/home/vocdoni/decidim/development_app/storage` (Active Storage `local`) |
    | boot | `decidim-dev-prod.service` (`docker compose up -d`) plus `restart: unless-stopped` |
    | public access | `cloudflared-decidim-dev.service`, tunnel to `localhost:3000` |

    `SECRET_KEY_BASE` is the dev app's `credentials.yml.enc` secret: Decidim encrypts
    attributes with it, so it must not change. `DECIDIM_ADMIN_PASSWORD_STRONG=false`
    keeps dev admin passwords working. The organization's own SMTP settings must stay
    empty, otherwise they override the instance's SMTP variables.

    Not ported from Railway: the cron services (Decidim's scheduled rake tasks).

    ## How a new image reaches dev

    A merge to fork `develop` that touches `deploy/railway/` makes the `[Vocdoni] Image`
    workflow push `ghcr.io/vocdoni/decidim-vocdoni:sha-<12>` and move `:develop`. Within
    2 minutes `decidim-dev-update`:

    1. compares the digest of `:develop` with the one the `web` container runs; equal
       means nothing to do. A digest whose deploy failed is skipped until a newer image
       appears or someone runs `decidim-dev-update --retry`;
    2. pulls it by digest and tags it `decidim-vocdoni-dev:sha-<12>` (`<12>` from the
       `org.opencontainers.image.revision` label);
    3. runs `db:migrate:status` on the new image and stops without deploying if an
       applied migration has no file in it and is not in `.update/nofile-baseline`, or if
       a pending migration's base name (no timestamp, no engine suffix) matches an
       applied one: those need a hand reconciliation of `schema_migrations` (see
       [Migration versions](#migration-versions));
    4. dumps the DB to `/home/vocdoni/decidim-backups/decidim_dev-updater-<time>-<tag>.dump`
       (keeps the last 5 updater dumps), runs `release` (`db:migrate`) and recreates
       `web` and `worker` on the new tag;
    5. runs `checks.sh --strict` against `127.0.0.1:3000` and the public URL. On failure it
       recreates `web` and `worker` on the previous tag and logs an error; migrations
       stay applied (they are additive; the dump is the way back). `.env` moves to the
       new tag only when the checks pass.

    ```bash
    journalctl -u decidim-dev-update -n 100      # what the updater did
    systemctl list-timers decidim-dev-update.timer
    sudo systemctl start decidim-dev-update      # run now
    decidim-dev-update --retry                   # retry a digest that failed
    decidim-dev-update --ref sha-<12>            # deploy another tag of the image
    decidim-dev-update --force-fail              # exercise the rollback path
    ```

    ## Install

    One time, as `vocdoni` on z4, from a checkout of the fork at the merged commit
    (`/home/vocdoni/decidim` has the `vocdoni-fork` remote):

    ```bash
    cd /home/vocdoni/decidim && git fetch vocdoni-fork
    src=$(mktemp -d) && git archive vocdoni-fork/develop deploy/dev | tar -x -C "$src"
    cd /home/vocdoni/decidim-prod-mode
    install -m 0644 "$src/deploy/dev/compose.yaml" "$src/deploy/dev/README.md" .
    install -m 0755 "$src/deploy/dev/checks.sh" .
    sudo install -m 0755 "$src/deploy/dev/decidim-dev-update" /usr/local/bin/decidim-dev-update
    sudo install -m 0644 "$src/deploy/dev/decidim-dev-update.service" "$src/deploy/dev/decidim-dev-update.timer" /etc/systemd/system/
    sudo systemctl daemon-reload
    decidim-dev-update --record-baseline   # applied versions with no file in the running image
    ```

    If the package `ghcr.io/vocdoni/decidim-vocdoni` is private, log in once with a
    read-only token (classic PAT with only `read:packages`, or a fine-grained token with
    packages read); Docker keeps it in `~/.docker/config.json`:

    ```bash
    docker login ghcr.io -u <github-user> --password-stdin   # paste the token, then Ctrl-D
    ```

    First deploy, then the timer:

    ```bash
    decidim-dev-update --force-fail   # deploys :develop, fails on purpose, rolls back to the running tag
    decidim-dev-update                # deploys :develop for real
    sudo systemctl enable --now decidim-dev-update.timer
    ```

    ## Manual deploy

    Manual deploys keep working; stop the timer first so it does not move dev back to
    `:develop`:

    ```bash
    sudo systemctl stop decidim-dev-update.timer
    echo "DECIDIM_IMAGE_TAG=<tag>" > .env
    docker compose --profile release run --rm release bin/rails db:migrate:status | grep down   # back up first if any
    docker compose --profile release run --rm release   # bin/release = db:migrate
    docker compose up -d web worker                     # recreates both on the new tag
    ./checks.sh https://decidim-dev.vocdoni.net
    ```

    To go back to the CI image: `sudo systemctl start decidim-dev-update.timer`.

    ### A z4 build

    For a change not yet on fork develop (for example a gem SHA under test), build on
    z4 and deploy it as above:

    ```bash
    cd /home/vocdoni/decidim-prod-mode
    git -C /home/vocdoni/decidim fetch vocdoni-fork
    rm -rf app && mkdir app && git -C /home/vocdoni/decidim archive vocdoni-fork/develop:deploy/railway | tar -x -C app
    # optional gem bump: edit the decidim-secure_elections `revision:` in app/Gemfile.lock, then
    docker run --rm -u 1000 -v $PWD/app:/w -w /w -e HOME=/tmp -e BUNDLE_DEPLOYMENT=0 -e BUNDLE_FROZEN=0 -e BUNDLE_PATH=/tmp/b \
      decidim-vocdoni-dev:$(sed -n s/^DECIDIM_IMAGE_TAG=//p .env) bundle lock
    TAG=$(git -C /home/vocdoni/decidim rev-parse --short=7 vocdoni-fork/develop)
    docker build -t decidim-vocdoni-dev:$TAG app > build-$TAG.log 2>&1   # ~5 min on z4
    ```

    If the gem adds migrations, copy them into `app/db/migrate/` first
    (`bin/rails decidim_elections_vocdoni:install:migrations` in the same kind of container).

    ## Migration versions

    The DB was built by `development_app/`, whose migration files carry different
    timestamps than `deploy/railway/db/migrate/`. Every migration of the image was
    matched by name to an applied dev migration and its version inserted into
    `schema_migrations`, so `db:migrate:status` shows all `up`. The dev-app versions
    stay in `schema_migrations` and show as `NO FILE`; `.update/nofile-baseline` lists
    them so the updater only stops on new ones. A `down` whose name already exists
    among the applied migrations must be marked (insert its version) rather than run.

    ## Backups

    The updater dumps before every deploy. By hand:

    ```bash
    umask 077; docker exec decidim-postgres-1 pg_dump -U postgres -Fc decidim_development_app_development \
      > /home/vocdoni/decidim-backups/decidim_dev-$(date +%F-%H%M).dump
    ```

    ## Logs, console, status

    ```bash
    docker compose logs -f --tail=200 web worker
    docker compose exec web bin/rails console
    docker compose exec web bin/rails runner 'p Sidekiq::Stats.new.queues'
    docker compose ps
    ```

    ## Roll back to a z4-built image

    ```bash
    sudo systemctl disable --now decidim-dev-update.timer
    echo "DECIDIM_IMAGE_TAG=<z4-built tag>" > .env
    docker compose up -d web worker
    ```

    ## Roll back to the devcontainer (development mode)

    Development mode exposes letter_opener, web-console and error traces. Do not put it
    behind the public tunnel again.

    ```bash
    sudo systemctl disable --now decidim-dev-update.timer
    sudo systemctl stop cloudflared-decidim-dev.service
    sudo systemctl disable --now decidim-dev-prod.service
    docker compose down
    cd /home/vocdoni/decidim && ./start-decidim.sh start   # old devcontainer, untouched
    ```

    The units `decidim-dev.service` and `decidim-dev-watchdog.timer` are disabled, not removed.

Step 6: lint (recipe) with `<files>` = `deploy/dev`; shellcheck on `deploy/dev/checks.sh deploy/dev/decidim-dev-update`; no actionlint call.
Expected: `shellcheck exit 0`.

Step 7: commit
`chmod 755 deploy/dev/checks.sh deploy/dev/decidim-dev-update`
`git add -- deploy/dev`
`git commit -m "feat(deploy): dev updater for decidim-dev on z4" -- deploy/dev`

Interfaces this task provides to later tasks: `checks.sh [--strict] <base-url> [curl args...]`; `decidim-dev-update [--ref <tag>] [--force-fail] [--retry]` and `--record-baseline`; units `decidim-dev-update.service` / `.timer`; state in `/home/vocdoni/decidim-prod-mode/.update/`; dumps `/home/vocdoni/decidim-backups/decidim_dev-updater-*.dump`.

### Task 4: promote-to-prod workflow and the Railway API script
Model: strong   Repo: /home/user/src/vd/decidim-deploy-bump   Files: `.github/workflows/vocdoni_release.yml`, `deploy/ci/railway-promote.sh`
Goal: on a `prod-*` release (or a dispatch on that tag), after approval, retag the dev-built image and move all five Railway app services to its digest, web first (AC6, AC7, AC8).

Railway facts used here (read-only introspection with `railway api describe`, 2026-11-18): endpoint `https://backboard.railway.com/graphql/v2`, header `Project-Access-Token`; `serviceInstanceUpdate(serviceId, environmentId, input: ServiceInstanceUpdateInput!): Boolean!` with `input.source: ServiceSourceInput {image, repo}`; `serviceInstanceDeployV2(serviceId, environmentId, commitSha): String!` returns the deployment id; `serviceInstance(serviceId, environmentId) { source { image repo } latestDeployment { id status meta } }`; `deployment(id) { status meta }`, `meta.imageDigest` present; `DeploymentStatus` = BUILDING CRASHED DEPLOYING FAILED INITIALIZING NEEDS_APPROVAL QUEUED REMOVED REMOVING SKIPPED SLEEPING SUCCESS WAITING; `projectToken { projectId environmentId }`. IDs: environment `production` 48a08998-2bc5-4d69-8fba-660fb5e7411f; services web 5e3f10b6-aa8a-4f52-8615-ee3ea647ba53, worker 11e7679d-27b9-489d-ac6c-68258d8feab1, cron-15min c7dec447-2ff6-4f6b-bf86-b46227ef0a56, cron-daily baab6ea5-668d-4002-b9b8-b2711a9c5e3d, cron-weekly 46425a81-e6f2-4f2d-8ebc-7324755413d0.

Step 1: write `deploy/ci/railway-promote.sh` (mode 755):
```bash
#!/usr/bin/env bash
# Points Railway services at one container image (by digest) and deploys them
# in order, through Railway's public GraphQL API. Used by vocdoni_release.yml;
# see deploy/railway/README.md, "Deploying".
#
# usage: railway-promote.sh check   <image@sha256:digest>
#        railway-promote.sh promote <image@sha256:digest>
#   check   reads the token's environment and each service's current source and
#           latest deployment (the rollback information); changes nothing.
#   promote for each service in order: sets the image source, reads it back,
#           deploys, and waits for SUCCESS; then reads every source back again.
#
# Environment:
#   RAILWAY_TOKEN           project token scoped to the target environment (secret)
#   RAILWAY_ENVIRONMENT_ID  the environment the token must belong to
#   RAILWAY_SERVICES        "name=serviceId ..." in deploy order
#   SUMMARY_FILE            optional; markdown table rows are appended to it
#   POLL_INTERVAL, POLL_TIMEOUT  seconds; default 10 and 900 per service
set -euo pipefail
shopt -s inherit_errexit

API=${RAILWAY_API:-https://backboard.railway.com/graphql/v2}
POLL_INTERVAL=${POLL_INTERVAL:-10}
POLL_TIMEOUT=${POLL_TIMEOUT:-900}
SUMMARY_FILE=${SUMMARY_FILE:-/dev/null}

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: $0 check|promote <image@sha256:digest>"
mode=$1 image=$2
case $mode in check|promote) ;; *) die "unknown mode: $mode" ;; esac
[[ "$image" =~ ^[a-z0-9./_-]+@sha256:[0-9a-f]{64}$ ]] || die "image must be a digest reference: $image"
: "${RAILWAY_TOKEN:?RAILWAY_TOKEN is not set}"
: "${RAILWAY_ENVIRONMENT_ID:?RAILWAY_ENVIRONMENT_ID is not set}"
: "${RAILWAY_SERVICES:?RAILWAY_SERVICES is not set}"

# The token goes to curl through a header file, never on a command line.
hdr=$(mktemp)
trap 'rm -f "$hdr"' EXIT
chmod 600 "$hdr"
printf 'Project-Access-Token: %s\n' "$RAILWAY_TOKEN" > "$hdr"

# gql <document> <variables JSON>: prints .data, fails on HTTP or GraphQL errors.
gql() {
  local body resp
  body=$(jq -nc --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')
  resp=$(curl -sS --fail-with-body --max-time 60 --retry 3 --retry-all-errors \
    -H "Content-Type: application/json" -H @"$hdr" --data-binary "$body" "$API") \
    || die "Railway API request failed: $(jq -r '[.errors[]?.message] | join("; ")' <<<"$resp" 2>/dev/null)"
  if jq -e '(.errors // []) | length > 0' <<<"$resp" > /dev/null; then
    die "Railway API error: $(jq -r '[.errors[].message] | join("; ")' <<<"$resp")"
  fi
  jq -c '.data' <<<"$resp"
}

# The $names below are GraphQL variables, not shell expansions.
Q_TOKEN='query { projectToken { projectId environmentId } }'
# shellcheck disable=SC2016
Q_INSTANCE='query instance($serviceId: String!, $environmentId: String!) {
  serviceInstance(serviceId: $serviceId, environmentId: $environmentId) {
    serviceName
    source { image repo }
    latestDeployment { id status meta }
  }
}'
# shellcheck disable=SC2016
M_SOURCE='mutation setSource($serviceId: String!, $environmentId: String!, $input: ServiceInstanceUpdateInput!) {
  serviceInstanceUpdate(serviceId: $serviceId, environmentId: $environmentId, input: $input)
}'
# shellcheck disable=SC2016
M_DEPLOY='mutation deploy($serviceId: String!, $environmentId: String!) {
  serviceInstanceDeployV2(serviceId: $serviceId, environmentId: $environmentId)
}'
# shellcheck disable=SC2016
Q_DEPLOYMENT='query deployment($id: String!) { deployment(id: $id) { id status meta } }'

env_id=$(gql "$Q_TOKEN" '{}' | jq -r '.projectToken.environmentId')
[ "$env_id" = "$RAILWAY_ENVIRONMENT_ID" ] \
  || die "the token belongs to environment $env_id, not $RAILWAY_ENVIRONMENT_ID"

vars() { jq -nc --arg s "$1" --arg e "$RAILWAY_ENVIRONMENT_ID" '{serviceId: $s, environmentId: $e}'; }
instance() { gql "$Q_INSTANCE" "$(vars "$1")" | jq -c '.serviceInstance'; }
source_of() { jq -r '.source.image // .source.repo // "(uploaded source)"' <<<"$1"; }

read -r -a services <<<"$RAILWAY_SERVICES"
for entry in "${services[@]}"; do
  [[ "$entry" =~ ^[a-z0-9-]+=[0-9a-f-]{36}$ ]] || die "bad RAILWAY_SERVICES entry: $entry"
done

if [ "$mode" = check ]; then
  for entry in "${services[@]}"; do
    name=${entry%%=*} id=${entry#*=}
    si=$(instance "$id")
    [ "$(jq -r .serviceName <<<"$si")" = "$name" ] || die "service $id is not named $name"
    src=$(source_of "$si")
    dep=$(jq -r '.latestDeployment.id // "none"' <<<"$si")
    st=$(jq -r '.latestDeployment.status // "none"' <<<"$si")
    echo "$name: source $src; latest deployment $dep ($st)"
    echo "| $name | \`$src\` | \`$dep\` ($st) |" >> "$SUMMARY_FILE"
  done
  exit 0
fi

wait_for() { # $1 = service name, $2 = deployment id
  local waited=0 st
  while :; do
    st=$(gql "$Q_DEPLOYMENT" "$(jq -nc --arg i "$2" '{id: $i}')" | jq -r '.deployment.status')
    case $st in
      SUCCESS|SLEEPING) echo "$1: deployment $2 is $st"; return 0 ;;
      FAILED|CRASHED|REMOVED|SKIPPED) die "$1: deployment $2 ended $st" ;;
      NEEDS_APPROVAL) die "$1: deployment $2 waits for an approval in Railway" ;;
    esac
    [ "$waited" -lt "$POLL_TIMEOUT" ] || die "$1: deployment $2 still $st after ${POLL_TIMEOUT}s"
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
}

# One service at a time, so the worker and the crons only move after web's
# pre-deploy (bin/release: db:migrate) has succeeded.
for entry in "${services[@]}"; do
  name=${entry%%=*} id=${entry#*=}
  input=$(jq -nc --arg i "$image" '{source: {image: $i}}')
  gql "$M_SOURCE" "$(vars "$id" | jq -c --argjson in "$input" '. + {input: $in}')" > /dev/null
  si=$(instance "$id")
  got=$(source_of "$si")
  [ "$got" = "$image" ] || die "$name: source reads back as $got, expected $image"
  dep=$(gql "$M_DEPLOY" "$(vars "$id")" | jq -r '.serviceInstanceDeployV2')
  [ -n "$dep" ] && [ "$dep" != null ] || die "$name: no deployment id returned"
  echo "$name: source set, deployment $dep started"
  wait_for "$name" "$dep"
  digest=$(gql "$Q_DEPLOYMENT" "$(jq -nc --arg i "$dep" '{id: $i}')" | jq -r '.deployment.meta.imageDigest // "n/a"')
  if [ "$digest" != n/a ] && [ "$digest" != "${image#*@}" ]; then
    echo "WARNING: $name: Railway reports image digest $digest, promoted ${image#*@}" >&2
  fi
  echo "| $name | \`$dep\` | $digest |" >> "$SUMMARY_FILE"
done

# Read-back check over all services: the source pins the digest, so equality
# here is digest equality.
for entry in "${services[@]}"; do
  name=${entry%%=*} id=${entry#*=}
  si=$(instance "$id")
  got=$(source_of "$si")
  [ "$got" = "$image" ] || die "$name: source reads back as $got after the deploy, expected $image"
done
echo "all services run $image"
```

Step 2: write `.github/workflows/vocdoni_release.yml`:
```yaml
# Promotes the image dev ran to decidim.vocdoni.dev (Railway), after approval
# (see deploy/docs/specs/2026-11-18-deploy-pipeline-design.md, "Workflow 3").
# Triggered by publishing a release `prod-YYYY.MM.DD[.N]`, or for redeploys and
# rollbacks by a dispatch on the tag itself:
#   gh workflow run vocdoni_release.yml --ref prod-YYYY.MM.DD -f tag=prod-YYYY.MM.DD
name: "[Vocdoni] Release to prod"

on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      tag:
        description: "prod-* tag to deploy; run the workflow on that same tag"
        required: true
        type: string

permissions:
  contents: read
  packages: write

concurrency:
  group: prod-deploy
  cancel-in-progress: false

env:
  IMAGE: ghcr.io/vocdoni/decidim-vocdoni
  PROD_URL: https://decidim.vocdoni.dev
  # Railway project decidim-vocdoni, environment production. IDs, not secrets.
  RAILWAY_ENVIRONMENT_ID: 48a08998-2bc5-4d69-8fba-660fb5e7411f
  RAILWAY_SERVICES: >-
    web=5e3f10b6-aa8a-4f52-8615-ee3ea647ba53
    worker=11e7679d-27b9-489d-ac6c-68258d8feab1
    cron-15min=c7dec447-2ff6-4f6b-bf86-b46227ef0a56
    cron-daily=baab6ea5-668d-4002-b9b8-b2711a9c5e3d
    cron-weekly=46425a81-e6f2-4f2d-8ebc-7324755413d0

jobs:
  resolve:
    name: Resolve release
    if: github.event_name == 'workflow_dispatch' || startsWith(github.event.release.tag_name, 'prod-')
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      contents: read
      packages: read
    outputs:
      tag: ${{ steps.r.outputs.tag }}
      commit: ${{ steps.r.outputs.commit }}
      digest: ${{ steps.r.outputs.digest }}
      gem: ${{ steps.r.outputs.gem }}
      previous: ${{ steps.r.outputs.previous }}
    steps:
      - name: Resolve the tag to a built image
        id: r
        env:
          GH_TOKEN: ${{ github.token }}
          EVENT: ${{ github.event_name }}
          INPUT_TAG: ${{ inputs.tag }}
          RELEASE_TAG: ${{ github.event.release.tag_name }}
        run: |
          set -euo pipefail
          fail() { echo "::error::$*"; exit 1; }
          if [ "$EVENT" = release ]; then tag=$RELEASE_TAG; else tag=$INPUT_TAG; fi
          [[ "$tag" =~ ^prod-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] \
            || fail "tag must look like prod-YYYY.MM.DD or prod-YYYY.MM.DD.N"
          # The production environment only admits prod-* tag refs.
          if [ "$GITHUB_REF_TYPE" != tag ] || [ "$GITHUB_REF_NAME" != "$tag" ]; then
            fail "run on the tag itself: gh workflow run vocdoni_release.yml --ref $tag -f tag=$tag"
          fi
          commit=$(gh api "repos/$GITHUB_REPOSITORY/commits/$tag" --jq .sha)
          [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve $tag"
          status=$(gh api "repos/$GITHUB_REPOSITORY/compare/$commit...develop" --jq .status)
          case $status in
            ahead|identical) ;;
            *) fail "release a commit that dev has built: $tag ($commit) is not on develop" ;;
          esac
          echo "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin > /dev/null
          ref="$IMAGE:sha-${commit:0:12}"
          manifest=$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' 2> /dev/null) \
            || fail "no image $ref: release a commit that dev has built"
          digest=$(jq -r .digest <<<"$manifest")
          [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "cannot read the digest of $ref"
          gem=$(docker buildx imagetools inspect "$IMAGE@$digest" --format '{{json .Image}}' \
            | jq -r '.config.Labels["io.vocdoni.gem-revision"] // "unknown"')
          previous=$(git ls-remote --tags --refs "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY.git" 'refs/tags/prod-*' \
            | sed 's|.*refs/tags/||' | grep -E '^prod-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$' | sort -V \
            | awk -v t="$tag" '$0 == t { exit } { p = $0 } END { print p }')
          {
            echo "tag=$tag"
            echo "commit=$commit"
            echo "digest=$digest"
            echo "gem=$gem"
            echo "previous=$previous"
          } >> "$GITHUB_OUTPUT"
          echo "$tag -> $commit -> $IMAGE@$digest (gem $gem); previous release: ${previous:-none}"

  deploy:
    name: Deploy to Railway
    needs: resolve
    runs-on: ubuntu-24.04
    timeout-minutes: 90
    environment:
      name: production
      url: https://decidim.vocdoni.dev
    permissions:
      contents: read
      packages: write
    env:
      TAG: ${{ needs.resolve.outputs.tag }}
      COMMIT: ${{ needs.resolve.outputs.commit }}
      DIGEST: ${{ needs.resolve.outputs.digest }}
      GEM: ${{ needs.resolve.outputs.gem }}
      PREVIOUS: ${{ needs.resolve.outputs.previous }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Tag the image as the release and prod
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          echo "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin > /dev/null
          docker buildx imagetools create --tag "$IMAGE:$TAG" --tag "$IMAGE:prod" "$IMAGE@$DIGEST"
          for t in "$TAG" prod; do
            got=$(docker buildx imagetools inspect "$IMAGE:$t" --format '{{json .Manifest}}' | jq -r .digest)
            [ "$got" = "$DIGEST" ] || { echo "::error::$IMAGE:$t is $got, expected $DIGEST"; exit 1; }
          done

      - name: Railway services before the deploy
        env:
          RAILWAY_TOKEN: ${{ secrets.RAILWAY_TOKEN }}
        run: |
          set -euo pipefail
          {
            echo "| service | source before | latest deployment before |"
            echo "|---|---|---|"
          } > "$RUNNER_TEMP/before.md"
          SUMMARY_FILE=$RUNNER_TEMP/before.md bash deploy/ci/railway-promote.sh check "$IMAGE@$DIGEST"

      - name: Deploy web, worker and the crons
        env:
          RAILWAY_TOKEN: ${{ secrets.RAILWAY_TOKEN }}
        run: |
          set -euo pipefail
          {
            echo "| service | deployment | Railway image digest |"
            echo "|---|---|---|"
          } > "$RUNNER_TEMP/after.md"
          SUMMARY_FILE=$RUNNER_TEMP/after.md bash deploy/ci/railway-promote.sh promote "$IMAGE@$DIGEST"

      - name: Check decidim.vocdoni.dev
        run: |
          set -euo pipefail
          for path in /up /en/; do
            code=000
            for _ in $(seq 1 12); do
              code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROD_URL$path" || true)
              [ "$code" = 200 ] && break
              sleep 10
            done
            echo "$PROD_URL$path $code"
            [ "$code" = 200 ] || { echo "::error::$PROD_URL$path returned $code"; exit 1; }
          done

      - name: Summary
        if: always()
        run: |
          {
            echo "### Release $TAG"
            echo
            echo "- Commit: \`$COMMIT\`"
            echo "- Gem revision: \`$GEM\`"
            echo "- Image: \`$IMAGE@$DIGEST\`"
            if [ -n "$PREVIOUS" ]; then
              echo "- Previous release (rollback target): \`$PREVIOUS\`, roll back with"
              echo "  \`gh workflow run vocdoni_release.yml --ref $PREVIOUS -f tag=$PREVIOUS\`"
            else
              echo "- Previous release: none"
            fi
            echo
            echo "#### Before"
            echo
            cat "$RUNNER_TEMP/before.md" 2> /dev/null || echo "(not read)"
            echo
            echo "#### Deployed"
            echo
            cat "$RUNNER_TEMP/after.md" 2> /dev/null || echo "(not deployed)"
          } >> "$GITHUB_STEP_SUMMARY"
```

Step 3: lint (recipe) with `<files>` = `.github/workflows/vocdoni_release.yml deploy/ci/railway-promote.sh`; actionlint on the workflow, shellcheck on the script.
Expected: `actionlint exit 0`, `shellcheck exit 0`.

Step 4: commit
`chmod 755 deploy/ci/railway-promote.sh`
`git add -- .github/workflows/vocdoni_release.yml deploy/ci/railway-promote.sh`
`git commit -m "ci(deploy): promote a release image to Railway prod" -- .github/workflows/vocdoni_release.yml deploy/ci/railway-promote.sh`

Interfaces this task provides to later tasks: workflow `vocdoni_release.yml` (release `published` with a `prod-*` tag; dispatch `--ref <tag> -f tag=<tag>`); environment `production` with secret `RAILWAY_TOKEN`; `railway-promote.sh check|promote <image@sha256:digest>` with env `RAILWAY_TOKEN`, `RAILWAY_ENVIRONMENT_ID`, `RAILWAY_SERVICES`, optional `SUMMARY_FILE`, `POLL_INTERVAL`, `POLL_TIMEOUT`, `RAILWAY_API`.

### Task 5: gem notify workflow
Model: fast   Repo: /home/user/src/vd/decidim-secure_elections-notify-fork   Files: `.github/workflows/notify_fork.yml`
Goal: every push to gem `main` dispatches the fork's `vocdoni_gem_bump.yml` on `develop` (AC10).

Step 0: create the worktree (the main clone is on another branch; do not touch it):
```bash
git -C /home/user/src/vd/decidim-secure_elections fetch origin
git -C /home/user/src/vd/decidim-secure_elections worktree add /home/user/src/vd/decidim-secure_elections-notify-fork -b feat/notify-fork 27e582bacbc911d36c6edd620228b1d0754e109b
```
Expected: `Preparing worktree (new branch 'feat/notify-fork')`. If `origin/main` is no longer 27e582b, stop and report it to the controller.

Step 1: write `.github/workflows/notify_fork.yml`:
```yaml
# Starts the lock bump in vocdoni/decidim (workflow vocdoni_gem_bump.yml) on
# every push to main, so a new gem commit reaches decidim-dev without anyone
# acting. FORK_DISPATCH_TOKEN is a fine-grained token with only Actions: write
# on vocdoni/decidim: it can start workflows there, not push code.
name: Notify fork

on:
  push:
    branches: [main]

permissions: {}

jobs:
  dispatch:
    name: Dispatch the fork's gem bump
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - name: gh workflow run
        env:
          GH_TOKEN: ${{ secrets.FORK_DISPATCH_TOKEN }}
        run: |
          set -euo pipefail
          if [ -z "$GH_TOKEN" ]; then
            echo "::error::secret FORK_DISPATCH_TOKEN is not set"
            exit 1
          fi
          gh workflow run vocdoni_gem_bump.yml -R vocdoni/decidim --ref develop
```

Step 2: lint (recipe, gem `R`) with `<files>` = `.github/workflows/notify_fork.yml`; actionlint on it.
Expected: `actionlint exit 0`.

Step 3: commit
`git -C /home/user/src/vd/decidim-secure_elections-notify-fork add -- .github/workflows/notify_fork.yml`
`git -C /home/user/src/vd/decidim-secure_elections-notify-fork commit -m "ci: notify vocdoni/decidim on every push to main" -- .github/workflows/notify_fork.yml`

Interfaces this task provides to later tasks: repository secret `FORK_DISPATCH_TOKEN` (created by the owner in the rollout).

### Task 6: Railway README, deploying, releasing and rolling back
Model: standard   Repo: /home/user/src/vd/decidim-deploy-bump   Files: `deploy/railway/README.md`
Goal: document the pipeline as the way prod and dev change, the release naming rule and the rollback command (spec §Cutting a release, §Compatibility and rollout step 6).

Step 1: replace `deploy/railway/README.md` with the block below, indent of four spaces removed (the file contains its own code fences; blank lines stay blank):

    # decidim.vocdoni.dev on Railway

    Production deploy of Decidim with the Vocdoni elections module
    ([decidim-elections-vocdoni](https://github.com/vocdoni/decidim-secure_elections)),
    served at <https://decidim.vocdoni.dev>.

    This directory is a self-contained Rails application: the Decidim app skeleton
    generated by `decidim-generators` from this fork, trimmed for production, plus
    the Dockerfile and the Railway configuration. Nothing outside it is uploaded or
    built.

    ## What runs where

    Railway project `decidim-vocdoni` (workspace Vocdoni, region europe-west4):

    | Service    | What                                   | Config |
    |------------|----------------------------------------|--------|
    | `web`      | Puma; release step `bin/release` (pre-deploy: `db:migrate`); healthcheck `/up`; custom domain `decidim.vocdoni.dev` | `Dockerfile`, `.railway/railway.ts` |
    | `worker`   | Sidekiq, queues in `config/sidekiq.yml` (`vocdoni` plus Decidim's) | same image, `bundle exec sidekiq -C config/sidekiq.yml` |
    | `cron-15min`, `cron-daily`, `cron-weekly` | Decidim's scheduled rake tasks, one run per trigger (see [Scheduled tasks](#scheduled-tasks)) | same image, start command and cron schedule per service |
    | `Postgres` | Railway Postgres, 50 GB volume, with backups (see [Backups](#backups)) | |
    | `Redis`    | Railway Redis (Sidekiq, Action Cable)   | |
    | `uploads`  | Railway bucket (S3-compatible, private) | Active Storage `s3` service |

    `.railway/railway.ts` is Railway's infrastructure-as-code description of part
    of the project (Railway has deprecated `railway.toml`/`railway.json`
    config-as-code): `web`, `worker`, the databases, volumes and the bucket. The
    three cron services exist only in Railway, and the app services run a GHCR
    image (see [Deploying](#deploying)) while the file describes Dockerfile builds,
    so do not `railway config apply` it without reconciling both. Variables are left
    unmanaged there because they hold secrets. Applying it with
    `railway config plan|apply` needs the `railway` npm package, so run it from a
    build host, not from a laptop.

    ### Storage

    Uploads go to the `uploads` Railway bucket. A Railway volume can only be mounted
    on one service, and the worker also reads and writes files (Active Storage
    analysis, exports), so a volume on `web` would not work. The bucket survives
    redeploys and is shared by both services. It is private: files are served
    through presigned URLs and uploaded directly from the browser, so
    `config/initializers/storage_csp.rb` adds the bucket host to Decidim's CSP, and
    the release step sets the bucket's CORS rule for browser uploads from
    `RAILS_HOSTS` (`bin/rails storage:cors`, see `lib/tasks/storage.rake`).

    ### Scheduled tasks

    Railway cron services run the image's start command on a schedule (UTC) and
    exit; `restartPolicyType` is `NEVER`, so a failed run waits for the next
    trigger. They replace the system crontab a Decidim host would have.

    | Service | Schedule | Start command |
    |---------|----------|---------------|
    | `cron-15min` | `*/15 * * * *` | `bundle exec rails decidim_participatory_processes:change_active_step` |
    | `cron-daily` | `5 0 * * *` | `bundle exec rails decidim:delete_download_your_data_files decidim:open_data:export decidim_meetings:clean_registration_forms decidim:reminders:all decidim:mailers:notifications_digest_daily decidim:participants:delete_inactive_participants` |
    | `cron-weekly` | `5 0 * * 6` | `bundle exec rails decidim:mailers:notifications_digest_weekly` |

    They need the same variables as `worker`: they read the database, enqueue jobs
    in Redis and write exports to the bucket.

    ### Backups

    Railway backups on the `Postgres` volume: daily, kept 6 days, and weekly, kept
    27 days. Restores are done from the `Postgres` service's Backups tab in the
    Railway dashboard.

    ## Variables

    Set on `web`, `worker` and the cron services (secret values never live in this
    repository):

    | Name | Value |
    |------|-------|
    | `SECRET_KEY_BASE` | 128 hex chars from a CSPRNG (`openssl rand -hex 64`); same on both services |
    | `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` |
    | `REDIS_URL` | `${{Redis.REDIS_URL}}` |
    | `STORAGE_PROVIDER` | `s3` |
    | `AWS_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT` | `${{uploads.BUCKET}}`, `${{uploads.ACCESS_KEY_ID}}`, `${{uploads.SECRET_ACCESS_KEY}}`, `${{uploads.ENDPOINT}}` |
    | `AWS_REGION` | `auto` |
    | `RAILS_HOSTS` | `decidim.vocdoni.dev` (comma-separated; `config.hosts`) |
    | `HOSTNAME` | `decidim.vocdoni.dev` (Decidim builds URLs outside requests from it) |
    | `DECIDIM_APPLICATION_NAME`, `DECIDIM_MAILER_SENDER`, `DECIDIM_AVAILABLE_LOCALES`, `DECIDIM_DEFAULT_LOCALE` | Decidim settings |
    | `RAILS_MAX_THREADS` | `5` |
    | `WEB_CONCURRENCY` | `web` only: Puma worker processes |
    | `SIDEKIQ_CONCURRENCY` | `worker` only |
    | `VOCDONI_API_URL`, `VOCDONI_API_KEY`, `VOCDONI_ORG_ADDRESS`, `VOCDONI_EXPLORER_URL` | the Vocdoni SaaS environment, the integrator API key and the managed organization the instance publishes to (optional `VOCDONI_*_TIMEOUT`). The app boots and serves without them; only the elections Security tab and publishing need them. Check with `railway ssh --service web -- bin/rails decidim_elections_vocdoni:doctor` |

    Not set yet:

    - **SMTP**: `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`,
      `SMTP_DOMAIN` (plus optional `SMTP_AUTHENTICATION`, `SMTP_STARTTLS_AUTO`).
      While `SMTP_ADDRESS` is unset, mail is discarded (`delivery_method = :test`).

    SSL: Railway terminates TLS. `config.assume_ssl` is on, Decidim turns on
    `force_ssl` in production, and `/up` is exempt from the HTTPS redirect and from
    host authorization so Railway's healthcheck reaches it. Mail is rendered in the
    worker, outside any request, so `config.action_mailer.default_url_options` sets
    `protocol: "https"` (and `HOSTNAME` as host) for the links in it.

    ## Deploying

    All five app services (`web`, `worker`, `cron-15min`, `cron-daily`,
    `cron-weekly`) run one image, `ghcr.io/vocdoni/decidim-vocdoni`, pinned by
    digest. Railway does not build anything; the image is built once by GitHub
    Actions and runs on decidim-dev first.

    | Step | What happens |
    |------|--------------|
    | merge to `develop` touching `deploy/railway/` | workflow `[Vocdoni] Image` (`.github/workflows/vocdoni_image.yml`) builds this directory's `Dockerfile` and pushes `sha-<12-char commit>` and `develop` |
    | within ~2 minutes | decidim-dev (z4) runs the new `:develop` image if its checks pass (`deploy/dev/README.md`) |
    | publish a release `prod-YYYY.MM.DD` | workflow `[Vocdoni] Release to prod` (`.github/workflows/vocdoni_release.yml`) waits for approval in the `production` environment |
    | after approval | the image gets the tags `prod-YYYY.MM.DD` and `prod`; `web` deploys first (its pre-deploy `bin/release` runs `db:migrate`), then `worker`, then the crons, each waiting for `SUCCESS` |

    The image holds no secrets: assets are precompiled with `SECRET_KEY_BASE_DUMMY=1`
    and every variable comes from Railway at run time. Each build installs gems from
    `Gemfile.lock`, rebuilds the Vocdoni booth adapter
    (`public/vocdoni/booth-adapter.js`) from the pinned module source, copies
    Decidim's npm packages from the pinned Decidim checkout, then runs
    `assets:precompile` (Shakapacker).

    Do not `railway up` a service: it uploads source, switches that service back to a
    Railway build, and the five services stop running the same image.

    ### Releasing

    A release names a commit that dev has already run; the image for it is
    `sha-<12-char commit>`, built when the commit landed on `develop`. Names are
    `prod-YYYY.MM.DD`, with `.2`, `.3`, ... for further releases on the same day.

    ```bash
    # the commit dev runs: journalctl -u decidim-dev-update on z4, or the newest
    # successful [Vocdoni] Image run on develop
    gh release create prod-2026.11.18 --target <commit> --generate-notes
    ```

    or from GitHub's UI: "Draft a new release", tag `prod-2026.11.18`, target the
    commit (or `develop` when dev runs its head), "Generate release notes".

    The required reviewer approves with "Review deployments" on the run page (or in
    GitHub Mobile). The run fails before asking for approval if the commit is not on
    `develop` or has no `sha-<12>` image. Its summary lists the commit, the gem
    revision, the image digest, the Railway deployments and the previous release.

    `prod-<last release>...develop` on GitHub (Compare) lists what dev runs and prod
    does not.

    ### Rolling back

    Run the release workflow again with the previous release tag, on that tag (the
    `production` environment only admits `prod-*` tags), and approve it:

    ```bash
    gh workflow run vocdoni_release.yml --ref prod-2026.11.17 -f tag=prod-2026.11.17
    ```

    The same command redeploys the current release. Migrations are not rolled back;
    Postgres backups are below. If GitHub Actions or the Railway API is unavailable,
    redeploy an earlier deployment of each service from the Railway dashboard.

    ## First boot

    `script/bootstrap_organization.rb` creates the system admin, the organization
    (host `decidim.vocdoni.dev`, no seed data) and its admin, idempotently. The
    release step (`bin/release`) runs it when `BOOTSTRAP_JSON` is set on `web`:
    set the variable, deploy once, delete the variable. Pass bcrypt digests
    (`*_password_digest`) rather than passwords, so the plaintext never leaves the
    operator's machine; the script header lists the keys. With SSH access it also
    reads the JSON from STDIN:
    `railway ssh --service web -- bin/rails runner script/bootstrap_organization.rb`.

    The credentials are kept outside the repository, in
    `~/.config/decidim-prod/creds.json` (mode 600) on the operator's machine.

    ## Bumping Decidim or the module

    Both come from git and are pinned by branch in the `Gemfile`
    (`DECIDIM_REF`, `VOCDONI_REF`); `Gemfile.lock` holds the exact commits.

    The module follows `vocdoni/decidim-secure_elections` `main` by itself: every push
    there starts the workflow `[Vocdoni] Gem bump`
    (`.github/workflows/vocdoni_gem_bump.yml`), which also runs by hand from the
    Actions tab. It changes the module's `revision:` in `Gemfile.lock`, runs
    `bundle lock`, and opens the PR `Bump decidim-elections-vocdoni to <sha7>`. When
    the lock diff is that one line and no gem migration is missing from `db/migrate/`,
    it builds the image from the PR branch and merges on success; otherwise the PR stays
    open with the label `needs-review` and a comment with the reason.

    Decidim bumps, and module bumps that bring migrations or other lock changes, are
    done by hand on a build host with Ruby 3.4.7 and Node 24.18 (not on a laptop):

    ```bash
    # 1. move the lock to the branch head (or edit DECIDIM_REF / VOCDONI_REF first)
    bundle lock --update decidim decidim-elections decidim-elections-vocdoni
    # 2. copy any new migrations from the engines
    bin/rails decidim:choose_target_plugins railties:install:migrations
    bin/rails decidim_elections_vocdoni:install:migrations
    # 3. refresh the npm lockfile against the new Decidim packages
    cp -r "$(bundle info --path decidim)/packages" . && npm install && rm -rf packages
    ```

    Commit `Gemfile.lock`, `db/migrate/` and `package-lock.json` in a PR to `develop`.
    The PR build fails on purpose (`npm ci`) if Decidim's packages changed and the npm
    lockfile was not refreshed.
Check that only the `railway.ts` paragraph, the "Deploying" section and the "Bumping Decidim or the module" section changed: `git diff --stat -- deploy/railway/README.md` and read `git diff -- deploy/railway/README.md`.

Step 2: commit (this also makes the merge build an image: the PR touches `deploy/railway/`)
`git commit -m "docs(deploy): deploy, release and roll back through the pipeline" -- deploy/railway/README.md`

## Merge and release
<!-- Not copied into briefs; the controller executes this after the gate audit. It is the rollout of spec §Compatibility and rollout. -->

Which acceptance criteria can be proven when:
- Before merge (on the fork PR): AC1 only. `pull_request` runs the workflow file from the PR, but `workflow_dispatch` (workflow 2 dispatching workflow 1, the gem dispatching workflow 2, release dispatches) only works once the file is on `develop`, the default branch.
- After merge to develop: AC2 (first push build), AC3/AC4 (z4 install), AC10 + AC5 positive (gem notify merge), AC8 (test tag), AC6/AC9 (first release), AC7 (second release or a redeploy).
- AC5 negative (extra lock change, new migration) is proven by `gem-bump-check_test.sh` on z6 and, in production use, by the first real gem migration; no fake commit is pushed to gem `main` for it.

1. Full checks (z6): lint every new file with the recipe (`<files>` = `.github/workflows/vocdoni_image.yml .github/workflows/vocdoni_gem_bump.yml .github/workflows/vocdoni_release.yml deploy/ci deploy/dev`) and run `bash deploy/ci/gem-bump-check_test.sh` → `actionlint exit 0`, `shellcheck exit 0`, `all passed`. Gem: actionlint on `notify_fork.yml` → exit 0.

2. **Owner OK:** push `feat/deploy-pipeline` and open the PR to `develop` (title `Deploy pipeline: GHCR image, dev updater, gem bump, prod release`, label of the owner's choice). Expect `[Vocdoni] Image` to run as a PR check (build, no push) and pass (AC1): `gh pr checks <n> -R vocdoni/decidim` shows `Build image  pass`. If the build exceeds 45 minutes or fails in Actions only (cache, runner disk), fix in the PR.

3. **Owner OK:** merge the PR with a merge commit. The push to `develop` runs `[Vocdoni] Image` and pushes the first image. Check: `gh run list -R vocdoni/decidim -w vocdoni_image.yml -b develop -L 1` → `completed success`; `gh api orgs/vocdoni/packages/container/decidim-vocdoni/versions --jq '.[0].metadata.container.tags'` → `["sha-<12 of the merge commit>","develop"]` (order may vary).

4. **Owner OK (org/package admin):** decide the package visibility. Default: set `ghcr.io/vocdoni/decidim-vocdoni` to public (package settings → Danger Zone → Change visibility). Then on z6, anonymously (AC2):
   ```bash
   ssh z6.vocdoni.net 'export DOCKER_CONFIG=$(mktemp -d); docker buildx imagetools inspect ghcr.io/vocdoni/decidim-vocdoni:develop --format "{{json .Manifest}}" | jq -r .digest; docker buildx imagetools inspect ghcr.io/vocdoni/decidim-vocdoni:develop --format "{{json .Image}}" | jq .config.Labels; docker pull -q ghcr.io/vocdoni/decidim-vocdoni:develop'
   ```
   Expected: one `sha256:` digest equal to that of `:sha-<12>`; labels `org.opencontainers.image.revision` = merge commit, `org.opencontainers.image.source` = `https://github.com/vocdoni/decidim`, `io.vocdoni.gem-revision` = 27e582b...; pull succeeds. If the org forbids public packages: stop; the fallback (read-only token on z4, Railway registry credentials) needs the Railway Pro plan, so confirm the workspace plan with the owner first.
   Rollback: set the package back to private (package settings → Danger Zone → Change visibility).

5. **Owner OK:** create the two labels workflow 2 uses:
   `gh label create "target: developer-experience" -R vocdoni/decidim --color 0E8A16` and `gh label create needs-review -R vocdoni/decidim --color D93F0B`.
   Rollback: `gh label delete "target: developer-experience" -R vocdoni/decidim --yes` and `gh label delete needs-review -R vocdoni/decidim --yes` (only if unused).

6. **Owner OK (z4 change):** install the dev updater, as `vocdoni` on z4, exactly as `deploy/dev/README.md` "Install" says (the `docker login` step only if the package stayed private; the owner pastes the token, it is never shown here). Then:
   - `decidim-dev-update --record-baseline` → `recorded 753 applied versions without a file ...` (the count may differ if the image's migrations changed; it must be in the hundreds, not 0).
   - AC4: `decidim-dev-update --force-fail` → journal-style output ending with `ERROR: checks failed on sha-<12>; rolling back web and worker to d26bddd-gemcd5bbdd`, `rolled back to d26bddd-gemcd5bbdd`, `ERROR: deploy of sha-<12> failed ...`; `docker compose ps` shows web/worker on `decidim-vocdoni-dev:d26bddd-gemcd5bbdd`; `.env` unchanged; `./checks.sh --strict https://decidim-dev.vocdoni.net; echo $?` → `0`.
   - AC3: `decidim-dev-update` → ends with `dev runs decidim-vocdoni-dev:sha-<12> (ghcr.io/vocdoni/decidim-vocdoni@sha256:...)`; `.env` holds the new tag and the digest comment; `docker inspect -f '{{.Image}}' decidim-dev-prod-web-1 decidim-dev-prod-worker-1` → the same image ID as `docker image inspect -f '{{.Id}}' ghcr.io/vocdoni/decidim-vocdoni@<digest>`.
   - `sudo systemctl enable --now decidim-dev-update.timer`; `systemctl list-timers decidim-dev-update.timer` shows the next run; after one tick `journalctl -u decidim-dev-update -n 5` shows a clean exit (no output beyond the start/finish lines: the digest is equal).
   Rollback of this step: `sudo systemctl disable --now decidim-dev-update.timer`, `echo "DECIDIM_IMAGE_TAG=d26bddd-gemcd5bbdd" > .env`, `docker compose up -d web worker`.

7. Workflow 2 by hand, before the gem notify exists: `gh workflow run vocdoni_gem_bump.yml -R vocdoni/decidim --ref develop`. Expected (gem `main` is still the pinned 27e582b): job `Lock (no token)` succeeds with `develop <sha> pins 27e582b...; gem main is 27e582b...`, job `Check, open PR, build, merge` skipped, no PR. If gem `main` moved meanwhile, a bump PR appears instead; follow it as in step 8.

8. **Owner OK (token):** the owner creates a fine-grained token, resource owner `vocdoni`, repository `vocdoni/decidim` only, permission **Actions: Read and write** (Metadata read is implied), expiry 1 year, and stores it as repository secret `FORK_DISPATCH_TOKEN` in `vocdoni/decidim-secure_elections` (`gh secret set FORK_DISPATCH_TOKEN -R vocdoni/decidim-secure_elections`, pasted by the owner). If the org requires approval of fine-grained tokens, an org admin approves it.
   Pre-check: `gh api repos/vocdoni/decidim/branches/develop/protection` (404 = unprotected, OK). If develop has required reviews or required status checks, mechanical bumps cannot auto-merge (bot PRs trigger no `pull_request` checks and `gh pr merge` as github-actions[bot] is rejected); exempt the bot or relax the rule before enabling the notify workflow.
   **Owner OK:** push `feat/notify-fork` and open the gem PR to `main`; merge it (owner is admin there). The merge is itself a push to gem `main`, so it proves AC10 and AC5 (positive) end to end:
   - `gh run list -R vocdoni/decidim-secure_elections -w notify_fork.yml -L 1` → `success`.
   - Within a minute `gh run list -R vocdoni/decidim -w vocdoni_gem_bump.yml -L 1 --json event,actor,status` → event `workflow_dispatch`, actor = the token owner (AC10).
   - The run opens `Bump decidim-elections-vocdoni to <sha7 of the gem merge>` (one-line lock diff, no migrations), dispatches `[Vocdoni] Image` on `bot/gem-bump` with push=false, merges after it passes, then dispatches `[Vocdoni] Image` on `develop`; ~10 minutes later `journalctl -u decidim-dev-update` on z4 shows `dev runs decidim-vocdoni-dev:sha-<12 of the bump merge>` (AC5 positive).
   - Check the PR body: commit list present, any `@name` rendered in code, nobody mentioned.
   Rollback: `gh workflow disable notify_fork.yml -R vocdoni/decidim-secure_elections` (or revert the gem PR), `gh secret delete FORK_DISPATCH_TOKEN -R vocdoni/decidim-secure_elections`, and the owner revokes the fine-grained token.

9. AC8, before any environment exists: tag a commit that is on develop but has no image, and dispatch on it:
   ```bash
   T=prod-2000.01.01; C=$(git -C /home/user/src/vd/decidim-deploy-bump rev-parse feat/deploy-pipeline)   # the PR head: on develop after the merge, never built (only the merge commit was)
   gh api repos/vocdoni/decidim/git/refs -f ref=refs/tags/$T -f sha=$C
   gh workflow run vocdoni_release.yml -R vocdoni/decidim --ref $T -f tag=$T
   ```
   **Owner OK** for the test tag. Expected: job `Resolve release` fails with `no image ghcr.io/vocdoni/decidim-vocdoni:sha-<12>: release a commit that dev has built`; job `Deploy to Railway` never starts (no approval prompt, no environment yet). Then delete the tag: `gh api -X DELETE repos/vocdoni/decidim/git/refs/tags/$T`.

10. Optional, **owner OK**: rehearse the Railway mutations on a throwaway Railway project (one service from a public image, its own project token): run `deploy/ci/railway-promote.sh check|promote <public-image@sha256:...>` on z6 with `RAILWAY_ENVIRONMENT_ID` / `RAILWAY_SERVICES` of that project, then delete the project. It proves the unverified points below (digest refs as image source, project-token rights, whether `serviceInstanceUpdate` is applied at once or staged) without touching prod.

11. **Owner OK (prod settings, each individually):**
    - Disable the upstream `On Release` workflow (no file change): `gh workflow disable on_release.yml -R vocdoni/decidim`.
    - Railway: the owner creates a project token in project `decidim-vocdoni`, environment `production` (Project Settings → Tokens). It is never shown in chat or logs.
    - GitHub environment `production`:
      ```bash
      gh api -X PUT repos/vocdoni/decidim/environments/production --input - <<'EOF'
      {"reviewers":[{"type":"User","id":2815267}],"prevent_self_review":false,
       "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
      EOF
      gh api -X POST repos/vocdoni/decidim/environments/production/deployment-branch-policies -f name='prod-*' -f type=tag
      gh secret set RAILWAY_TOKEN --env production -R vocdoni/decidim   # the owner pastes the token
      ```
      (2815267 = `altergui`.) Check: `gh api repos/vocdoni/decidim/environments/production --jq '.protection_rules'` lists `required_reviewers` with altergui and `prevent_self_review: false`; `.../deployment-branch-policies` lists `prod-*` type `tag`.
    Rollback: `gh workflow enable on_release.yml -R vocdoni/decidim`; `gh api -X DELETE repos/vocdoni/decidim/environments/production` (removes the environment, its secret and its tag policy); the owner revokes the Railway project token in Project Settings → Tokens.

12. **Owner OK at that moment (first prod release, switches Railway from source builds to the image):**
    - Find the commit dev runs: on z4 `grep DECIDIM_IMAGE_TAG /home/vocdoni/decidim-prod-mode/.env` → `sha-<12>`; resolve it: `gh api repos/vocdoni/decidim/commits/<12> --jq .sha`.
    - `gh release create prod-YYYY.MM.DD -R vocdoni/decidim --target <commit> --generate-notes`.
    - The run waits for approval; the owner approves ("Review deployments"). Watch: `gh run watch <id> -R vocdoni/decidim --exit-status`.
    - AC6: run succeeds; its summary has the "Before" table (source `(uploaded source)` and the last source-built deployment id of each service: these ids are the rollback of this step) and the "Deployed" table with five deployment ids; `curl -s -o /dev/null -w '%{http_code}\n' https://decidim.vocdoni.dev/up` and `/en/` → `200`; read-only read-back of the five sources:
      ```bash
      for s in 5e3f10b6-aa8a-4f52-8615-ee3ea647ba53 11e7679d-27b9-489d-ac6c-68258d8feab1 c7dec447-2ff6-4f6b-bf86-b46227ef0a56 baab6ea5-668d-4002-b9b8-b2711a9c5e3d 46425a81-e6f2-4f2d-8ebc-7324755413d0; do railway api --compact "query { serviceInstance(environmentId: \"48a08998-2bc5-4d69-8fba-660fb5e7411f\", serviceId: \"$s\") { serviceName source { image } latestDeployment { status } } }"; done
      ```
      → each `source.image` = `ghcr.io/vocdoni/decidim-vocdoni@<digest>`, status `SUCCESS`.
    - `docker buildx imagetools inspect ghcr.io/vocdoni/decidim-vocdoni:prod` (z6) → same digest.
    - Rollback of this step: in Railway, redeploy each service's last source-built deployment from the "Before" table (dashboard, or `deploymentRedeploy`), or `railway up` from the previous commit as before; then delete the release if needed.

13. AC9: `gh api repos/vocdoni/decidim/compare/prod-YYYY.MM.DD...develop --jq '.ahead_by, (.commits | map(.sha[0:12]))'` → the commits on develop after the released commit; the newest equals the `sha-<12>` z4 runs (or none if dev still runs the released commit).

14. AC7, **owner OK**: redeploy the current release through a dispatch on its tag (`gh workflow run vocdoni_release.yml -R vocdoni/decidim --ref prod-YYYY.MM.DD -f tag=prod-YYYY.MM.DD`, approve) → same digest on all five services. A rollback to an earlier image is proven at the second release: dispatch the first tag, approve, check the five sources read back the first digest, then dispatch the second tag again.

15. Close-out: the ledger records the release tag, the digest, the run URLs of steps 2, 3, 8, 12; the z4 README is the installed `deploy/dev/README.md` (step 6). Delete the scratch dirs on z6 (`~/scratch/deploy-pipeline`).

Unverified until the rollout (each fails closed):
- Railway: whether `serviceInstanceUpdate` with `source.image` applies at once or is staged, whether it starts a deploy by itself, whether a `@sha256:` reference is accepted, and whether a project token may run these mutations. The script reads the source back before deploying and stops on a mismatch; step 10 can prove all four without prod. Also note: `serviceInstanceUpdate` with the id of a non-fork environment updates all non-fork environments (schema description); the project has only `production` today — recheck if an environment is ever added.
- `docker buildx imagetools create` with one single-manifest source keeps the digest; the workflow verifies both new tags against the digest before any Railway call. If it ever produces an index, replace that step with a registry-API manifest copy.
- Build time of the image on `ubuntu-24.04` runners (z4 builds take ~5 min; limit 45 min).
- `gh run list ... --json headSha` finding the dispatched build of `bot/gem-bump` within 2 minutes.
