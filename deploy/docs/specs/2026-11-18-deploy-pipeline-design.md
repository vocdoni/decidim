# Deploy pipeline for decidim-dev and decidim.vocdoni.dev: design

Status: approved (2026-11-18)   Class: architectural
Owner decisions so far (2026-11-18): one image built once and promoted dev → prod; `develop`
deploys to dev automatically; prod deploys from a GitHub Release, behind an approval; release
names are dates with a prefix (`prod-YYYY.MM.DD`); the gem keeps semver; the gem repository
gets one workflow that triggers the fork's bump on every push to `main` (the owner is admin
there); required reviewer for prod is the owner
(altergui) only; if the org forbids a public package, the image is private with read-only tokens;
mechanical gem bumps merge without a human.

## Problem

Nothing records or enforces what runs where.

- Prod (Railway project `decidim-vocdoni`, services `web`, `worker`, `cron-15min`,
  `cron-daily`, `cron-weekly`) is deployed by hand with `railway up` from a checkout of
  `deploy/railway/` (`deploy/railway/README.md`, "Deploying"). Each upload builds the
  Dockerfile again on Railway. Several sessions deploy prod this way in parallel; on
  2026-11-17/18 prod moved through fork 7bf1109 → 9db6ebe → 411a42d → 45a9119 with no record
  beyond Railway's deployment list.
- The three cron services only change when someone remembers to `railway up` them, so they can
  run an image older than `web`.
- Dev (decidim-dev.vocdoni.net, z4) is rebuilt by hand from a `git archive` of
  `deploy/railway/` plus a hand-edited `Gemfile.lock`
  (`/home/vocdoni/decidim-prod-mode/README.md`). Its build is not the prod build.
- A new gem commit (`vocdoni/decidim-secure_elections` main) reaches either environment only
  after someone edits the `revision:` line of `deploy/railway/Gemfile.lock`, runs `bundle lock`,
  and opens a PR.
- "What differs between prod and dev?" needs a manual comparison of SHAs across GitHub,
  Railway and z4.

## Goals

1. Every merge to fork `develop` that changes `deploy/railway/` produces one container image,
   tagged by commit, in GHCR.
2. Dev runs the newest `develop` image within ~10 minutes of it being built, without anyone
   acting, and stays on the previous image if the new one fails its checks.
3. A new commit on gem `main` becomes a merged lock bump on fork `develop` without anyone
   acting, when the bump is mechanical: started within a minute by the gem's push,
   then a check build (~6–12 min). Dev runs it ~10 minutes after the merge.
4. Prod changes only by publishing a GitHub Release `prod-YYYY.MM.DD[.N]` on the fork, which
   promotes the exact image dev ran (no rebuild), after an approval by a required reviewer.
   All five Railway app services move to the same image digest.
5. Rolling prod back is "redeploy the previous release", with the same approval.
6. `prod-<last>...develop` on GitHub answers "what differs between prod and dev".

## Non-goals

- No change to the gem repository beyond the one notify workflow below; its CI and release
  process stay as they are.
- No change to upstream Decidim CI workflows in the fork.
- No staging environment between dev and prod.
- No change to Railway's databases, buckets, variables or domains.
- No automatic prod deploy without approval; no automatic rollback in prod.
- No replacement of `bin/release` or of how migrations run on Railway.

## Current state

- Build context: `deploy/railway/` (fork `develop`, 45a9119). `Dockerfile` is multi-stage,
  Ruby 3.4.7 / Node 24.18; it rebuilds the booth adapter from the pinned gem and precompiles
  assets with `SECRET_KEY_BASE_DUMMY=1` (`Dockerfile:65`). No secret is passed at build time.
- Pins: `deploy/railway/Gemfile.lock` lines 1–4 pin the gem (`remote:
  https://github.com/vocdoni/decidim-secure_elections.git`, `revision:`, `branch: main`);
  a second `GIT` block pins Decidim (the fork itself, `branch: develop`).
- Railway: `web` runs `bin/release` (db:migrate, storage CORS, optional bootstrap) as its
  pre-deploy command and has healthcheck `/up`; `worker` runs Sidekiq; the crons run rake tasks
  on schedules (`deploy/railway/README.md`, "What runs where", "Scheduled tasks"). The services
  build from uploaded source. `.railway/railway.ts` describes part of the project (`web`, `worker`, databases,
  volumes, bucket); the three cron services exist only in Railway and are not in the IaC file —
  do not `railway config apply` without reconciling that. Variables are not managed there.
- Gem migrations must be copied into `deploy/railway/db/migrate/` by hand
  (`deploy/railway/README.md`, "Bumping Decidim or the module", step 2).
- Dev on z4 (`/home/vocdoni/decidim-prod-mode/`): compose project `decidim-dev-prod`, services
  `web` (127.0.0.1:3000), `worker`, one-shot `release`; image tag pinned in `.env`
  (`DECIDIM_IMAGE_TAG`); `checks.sh` runs the exposure checks; the DB's `schema_migrations` was
  reconciled to the image's migration versions on 2026-11-17. Public access is the
  `cloudflared-decidim-dev` tunnel. z4 is reachable over SSH only through the VPN, so GitHub
  cannot push to it.
- Permissions: the owner is admin on `vocdoni/decidim` (environments, secrets, workflows) and
  maintain on the gem repo. The fork is public. The org has no `decidim` container package yet.

## Design

### Image

- Name: `ghcr.io/vocdoni/decidim-vocdoni`.
- Tags: `sha-<12-char fork commit>` (immutable by convention), `develop` (moving), and on
  promotion `prod-YYYY.MM.DD[.N]` and `prod` (moving).
- OCI labels: `org.opencontainers.image.revision` (fork commit),
  `org.opencontainers.image.source` (fork URL), and `io.vocdoni.gem-revision` (the gem
  revision read from `Gemfile.lock`).
- Visibility: public. The image holds no secrets (see Current state); being public lets z4 and
  Railway pull without credentials. The org already publishes public container packages
  (`go-dvote`). If the org forbids public packages, it stays private and z4 gets a read-only
  `read:packages` token; Railway then needs registry credentials, which Railway only supports on
  the Pro plan — confirm the workspace plan before choosing this fallback.

### Workflow 1: build (`.github/workflows/vocdoni_image.yml`)

- Triggers: `push` to `develop` with `paths: deploy/railway/**`, and `workflow_dispatch`
  (needed because merges made with `GITHUB_TOKEN` do not trigger `push` workflows).
- Builds `deploy/railway/Dockerfile` with Buildx, layer cache in GHCR
  (`:buildcache`), pushes `sha-<12>` and `develop`. Permissions: `contents: read`,
  `packages: write`. Concurrency group `image-${{ github.ref }}`; newer runs cancel older ones
  within the same ref. `timeout-minutes: 45`.
- `workflow_dispatch` takes an input `push` (default `true`); with `push: false` it only builds,
  which is how workflow 2 checks a bump branch before merging it.
- It is also the PR check: on `pull_request` touching `deploy/railway/**` it builds without
  pushing, so a broken lock or Dockerfile fails before merge. PR builds use `cache-from` only;
  `cache-to` GHCR is skipped when the token lacks `packages: write` (fork PRs).

### Workflow 2: gem bump (`.github/workflows/vocdoni_gem_bump.yml`)

- Trigger: `workflow_dispatch` only, started by the gem notify workflow on every push to gem
  `main`, or by hand from the Actions tab. No schedule: a polling cron would add hundreds of
  no-op runs a day to the Actions list.
- Reads gem `main` with `git ls-remote` (public, no token) and the pinned revision from
  `deploy/railway/Gemfile.lock`. Equal → exit.
- Otherwise, on branch `bot/gem-bump`: replace the `revision:` line, run `bundle lock` (no
  `--update`; Ruby 3.4.7, bundler 2.6.9) inside `deploy/railway/`.
- Mechanical-bump check, all must hold for auto-merge:
  1. `git diff` of `Gemfile.lock` is exactly the one `revision:` line.
  2. No migration in the gem's `db/migrate/` at the new revision is missing (by base name,
     ignoring the timestamp prefix and the `.decidim_elections_vocdoni` engine suffix that
     `install:migrations` appends) from `deploy/railway/db/migrate/`.
- Opens or updates one PR `Bump decidim-elections-vocdoni to <sha7>` (capitalised and labelled
  `target: developer-experience`, so the upstream PR lint passes when it runs) with the gem's
  commit list in the body. If the check holds: dispatches workflow 1 (`workflow_dispatch` on the
  `bot/gem-bump` ref, `push: false`), waits for its conclusion, and merges (merge commit) only on
  success, then dispatches workflow 1 on `develop`. On build failure, or if the check does not
  hold, it leaves the PR open with `needs-review`, the reason and the run link, and does not
  merge. (PRs opened with `GITHUB_TOKEN` never trigger `pull_request` workflows, so the PR
  check is dispatched explicitly.)
- The job that runs `bundle lock` has `permissions: {}` (no token) and uploads the resulting
  `Gemfile.lock` as an artifact. A second job, which checks out `develop` fresh and never
  executes gem code, downloads the artifact, verifies the mechanical-bump conditions, and holds
  the only write-capable token. Gem-repo write access must not transitively grant fork write
  access.
- The PR body is written by piping `git log --format` output to a file and passing it with
  `--body-file`; commit text never appears inside `${{ }}` expressions or interpolated shell
  strings, and `@` in commit text is escaped (backticks) so no GitHub user is notified.
- Permissions: `contents: write`, `pull-requests: write`, `actions: write`. Concurrency group
  `gem-bump`, no cancellation.

### Gem notify (`.github/workflows/notify_fork.yml` in the gem repo)

- Trigger: `push` to `main`. Runs `gh workflow run vocdoni_gem_bump.yml -R vocdoni/decidim
  --ref develop` with secret `FORK_DISPATCH_TOKEN`: a fine-grained token with only
  **Actions: write** on `vocdoni/decidim` (it can start workflows, not push code), 1-year
  expiry. Permissions of the job's own `GITHUB_TOKEN`: `{}`. No checkout, no gem code runs.
- If a notify run fails, the next push to gem `main` catches up (workflow 2 always compares the
  lock with the current `main` head); in between, workflow 2 can be run by hand.

### Dev updater on z4 (`deploy/dev/` in the fork, installed on z4)

- A systemd timer (every 2 minutes) runs `decidim-dev-update`, a shell script that:
  1. Reads the remote digest of `:develop` (`docker buildx imagetools inspect` or the
     registry API) and the digest the running `web` container uses. Equal → exit.
  2. Pulls the image by digest and tags it locally as `decidim-vocdoni-dev:sha-<12>` (the
     repository name `compose.yaml` pins; `<12>` from the image's
     `org.opencontainers.image.revision` label), keeping manual z4 builds interchangeable.
  3. Runs `db:migrate:status` in a one-shot container. If any `down` migration's base name
     (ignoring timestamp and engine suffix) already appears among the applied ones (the
     2026-11-17 timestamp mismatch), stops and logs an error without deploying. The check can
     only see names of applied migrations whose files exist; `NO FILE` rows are a hard stop too.
  4. Backs up the DB with `pg_dump -Fc` to `/home/vocdoni/decidim-backups/` (keeps the last 5
     updater dumps), runs the `release` service, then
     `docker compose up -d web worker` on the new tag.
  5. Runs the exposure checks against `http://127.0.0.1:3000` (Host header) and the public URL,
     and fails unless: `/up` and `/en/` return 200, `/letter_opener`, `/rails/info` and
     `/rails/info/routes` return 404, and the 404 page shows no web-console or application
     trace. `checks.sh` gains a `--strict` mode that exits non-zero on any violation (today it
     only prints); the updater calls it with `--strict`. On failure, recreates `web` and
     `worker` on the previous tag and logs an error. Migrations
     are not reverted (they are additive; the backup is the way back).
- The previous tag is read from `.env` before anything changes and kept in the script's state
  file for the rollback path; `.env` (`DECIDIM_IMAGE_TAG`, plus the digest as a comment) is
  rewritten only after the checks pass. Every action is logged to the journal. A lock file prevents overlapping runs.
- `flock`, pinned script in the repo, installed by a documented one-time step; manual deploys
  keep working (`.env` + `docker compose up -d`).

### Workflow 3: promote to prod (`.github/workflows/vocdoni_release.yml`)

- Triggers: `release: published` (tag must match `prod-*`), and `workflow_dispatch` with input
  `tag` (an existing `prod-*` tag) for redeploys and rollbacks. The dispatch must run on the tag
  ref itself so it passes the environment's tag policy: `gh workflow run vocdoni_release.yml
  --ref prod-YYYY.MM.DD[.N] -f tag=prod-YYYY.MM.DD[.N]`. `resolve` fails if
  `inputs.tag != github.ref_name`. `deploy/railway/README.md` documents this as the rollback
  command.
- Permissions: `contents: read`, `packages: write` (for the tag push in step 1; the GHCR login
  uses `GITHUB_TOKEN`).
- Job `resolve` (no environment): resolves the tag to a commit, requires that commit to be
  reachable from `develop`, and requires `sha-<12>` to exist in GHCR; reads its digest. Fails
  with a clear message otherwise ("release a commit that dev has built").
- Job `deploy` (`environment: production`, required reviewer(s), no self-review bypass):
  1. Adds tags `prod-YYYY.MM.DD[.N]` and `prod` to the same digest (`docker buildx imagetools
     create`, no rebuild).
  2. Through Railway's public GraphQL API with a project token scoped to environment
     `production`: sets each of `web`, `worker`, `cron-15min`, `cron-daily`, `cron-weekly` to
     image source `ghcr.io/vocdoni/decidim-vocdoni@sha256:<digest>`, deploys `web` first and
     waits for `SUCCESS` (its pre-deploy `bin/release` runs migrations), then deploys `worker`
     and waits for `SUCCESS`, then updates the three crons (they run on their schedules).
     Status is polled every 10 s with a 15-minute timeout per service (pre-deploy `bin/release`
     has Railway's own pre-deploy timeout — raise it if a migration is expected to be slow).
  3. Checks: `https://decidim.vocdoni.dev/up` and `/en/` return 200; for each of the five
     services, reading back the service instance's source via the API returns exactly the image
     reference set in step 2 (`ghcr.io/vocdoni/decidim-vocdoni@sha256:<digest>`). Because the
     source pins the digest, read-back equality is equivalent to digest equality. If the GraphQL
     schema exposes a deployment image/digest field, the check may additionally compare it.
  4. Writes a job summary: release, commit, gem revision, digest, Railway deployment ids, and
     the previous release (the rollback target).
- On failure in step 2 or 3 it stops and reports; it does not roll back. Rolling back is
  running the workflow with the previous `prod-*` tag (approval again).
- Concurrency group `prod-deploy`, no cancellation.

### Cutting a release

- From GitHub's UI ("Draft a new release", tag `prod-2026.11.18`, target `develop`,
  "Generate release notes") or `gh release create prod-2026.11.18 --target <sha> --generate-notes`.
- `deploy/railway/README.md` documents the naming rule (`.2`, `.3` for more than one a day),
  and that the target must be a commit that dev has built.

### Approval

- Environment `production` on the fork: required reviewers (the owner, plus anyone the owner
  names), "prevent self-review" off so the owner can approve their own release, deployment
  branches/tags limited to `prod-*` tags.
- GitHub notifies required reviewers by email, in the web notifications, and as a push in
  GitHub Mobile; approval is the "Review deployments" button on the run page or in the app.
- `RAILWAY_TOKEN` is an environment secret of `production`, so only an approved job can read it.

### Alternatives considered

| Option | Why not |
|---|---|
| Environment branches (`main`→prod, `dev`→dev) | Branches drift; hotfixes need merging both ways; prod would build its own image. |
| Railway builds from the release tag (`railway up` in CI) | Dev and prod would run different builds of the same commit; slower prod deploys. |
| GitHub pushes deploys to z4 | z4 SSH is behind the VPN; a pull-based updater needs no inbound access or deploy key. |
| Watchtower on z4 for dev | Restarts containers but cannot run migrations first, check, or roll back. |
| `repository_dispatch` from the gem | Needs a token with Contents: write on the fork (can push code); `workflow_dispatch` needs only Actions: write. |
| Polling (scheduled workflow) | Up to ~5–25 min of extra latency and hundreds of no-op runs a day in the Actions list. |
| Semver tags on the fork | The fork carries 189 upstream `v*` tags; a deploy has no meaningful major/minor. |

## Compatibility and rollout

1. Merge workflows 1 and 2 and the dev updater (disabled) to `develop`; the gem notify workflow
   goes to gem `main` by its own PR once workflow 2 exists, with the owner creating the token. Workflow 1 builds the
   first image. No environment changes yet.
2. Pre-checks with the owner: org allows a public package (or fallback, which needs Railway
   Pro); a Railway project token for `production` exists. After workflow 1's first push, set
   the `decidim-vocdoni` container package to public (one-time, package settings; new packages
   are private by default) and verify an anonymous `docker pull`.
3. Dev: install the updater on z4, point it at `:develop`. Dev then runs a CI-built image instead
   of a z4-built one. Rollback: disable the timer, set `.env` back to the z4-built tag, `docker
   compose up -d`.
4. Enable workflow 2 (gem bumps).
5. Prod (owner OK at the time): create environment `production` and its secret; publish
   `prod-<date>` targeting the commit dev runs. The first run switches the five Railway services
   from source uploads to the image source. Rollback for this step: in Railway, redeploy the last
   source-built deployment of each service (ids recorded in the run summary before switching),
   or `railway up` from the previous commit as today. Also disable the upstream workflow
   `On Release` (`on_release.yml`) from the Actions UI (no file change): it fires on every
   published release and fails in the fork for lack of `DOCKER_WORKFLOW_PAT`.
6. Update `deploy/railway/README.md` ("Deploying") and the z4 README: manual `railway up` is
   retired; it would switch a service back to source builds.

## Failure modes and security

- **Broken bump**: if a non-mechanical bump fails the check, it is not merged. If a mechanical bump
  breaks the build, workflow 1 fails, `:develop` does not move, dev stays as it was, and
  GitHub emails the workflow failure. `develop` is then fixed by a normal PR.
- **Bad image on dev**: the updater's checks fail, it restores the previous tag, and the error
  is in the journal. A failed migration leaves the DB as the migration left it; restore from
  the backup taken in step 4.
- **Bad image on prod**: `web` fails its healthcheck, Railway keeps the old deployment serving,
  and the job fails. If the failure shows up after `SUCCESS`, roll back with the previous tag.
- **Migrations**: they run on dev first, on a DB whose schema matches prod's migration set. A
  migration that is not backward compatible with the old image can still break the running
  worker during the window between `web` and `worker` deploys; this is true today as well.
- **Secrets**: `RAILWAY_TOKEN` is readable only by the approved prod job. Workflows use
  `GITHUB_TOKEN` with the minimum permissions listed. Third-party actions are pinned by commit
  SHA. No secret is baked into the image or printed in logs. The z4 updater needs no credential
  if the image is public.
- **Supply chain**: anyone who can merge to `develop` can reach dev automatically and prod after
  approval; merge rights on fork `develop` reach dev automatically, as today; gem-repo write
  rights reach dev only through the mechanical-bump gate, whose privileged job never executes
  gem code. The scheduled bump only follows
  gem `main`, whose merge rights are in the same org.
- **Concurrency**: each workflow has a concurrency group; the z4 updater holds a lock file.
  Two prod releases queue rather than overlap.
- **Railway API changes**: the deploy job fails loudly; the manual Railway UI path stays as the
  fallback.

## Acceptance criteria

- [ ] AC1: A PR touching `deploy/railway/` runs workflow 1 as a check (build, no push).
- [ ] AC2: Merging it produces `ghcr.io/vocdoni/decidim-vocdoni:sha-<12>` and moves `:develop`
  to the same digest, with the three labels set (`docker buildx imagetools inspect`).
- [ ] AC3: Within 10 minutes the dev `web` and `worker` containers run that digest, and
  `checks.sh https://decidim-dev.vocdoni.net` passes (journal shows the update).
- [ ] AC4: Pushing an image whose `/up` fails (a test tag, not `develop`; or a forced failure
  flag in the script) makes the updater restore the previous tag; shown in the journal.
- [ ] AC5: A new gem `main` commit with no lock side-effects is merged on `develop` by workflow
  2 and reaches dev with no human step. A bump with an extra lock change or a new migration
  stays open with `needs-review`.
- [ ] AC6: Publishing `prod-YYYY.MM.DD` waits for approval; after approval all five Railway
  services report the promoted digest, `/up` and `/en/` return 200, and the run summary names
  the rollback target.
- [ ] AC7: Running workflow 3 with the previous `prod-*` tag restores the previous digest on all
  five services (after approval).
- [ ] AC8: A release targeting a commit without a built image fails in `resolve`, before any
  approval prompt.
- [ ] AC9: The compare link `prod-<last>...develop` lists exactly the commits dev has and prod
  does not.
- [ ] AC10: A push to gem `main` starts workflow 2 on the fork within a minute (run event `workflow_dispatch`, actor = token owner); running workflow 2 by hand on `develop` bumps to the current gem `main`.

## Constraints

- English in files, conventional commits, no AI attribution or `Co-Authored-By` trailers; docs
  say what is and why, without history wording.
- Never build or test on the operator's laptop; builds run in GitHub Actions or on z4/z6.
- Never print secrets; z4 `dev.env` and Railway variables are never read into logs.
- Third-party GitHub Actions pinned by full commit SHA.
- Prod (decidim.vocdoni.dev, Railway) is not touched until rollout step 5, with the owner's OK
  at that moment.
- Changes go through PRs to `develop`.

## Open questions

None. Answered by the owner on 2026-11-18: reviewers = the owner only; private image with
read-only tokens if the org forbids a public package (needs Railway Pro, see §Image); mechanical
bumps merge without a human.
