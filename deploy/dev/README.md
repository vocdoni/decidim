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
| `.update/` | updater state: `lock`, `state` (previous and new tag of the last run — if a run died between the recreate and the `.env` write, `.env` lags the running tag; compare `docker compose ps` with `.env` and set `DECIDIM_IMAGE_TAG` in `.env` to `new_tag` from `state` by hand — a rerun exits early because the running digest already matches), `failed-digest`, `nofile-baseline` |
| `checks.sh` | exposure/health checks; `--strict` exits 1 on any violation |
| Postgres / Redis | the devcontainer's `decidim-postgres-1` / `decidim-redis-1` (network `decidim_default`), DB `decidim_development_app_development` |
| uploads | bind mount of `/home/vocdoni/decidim/development_app/storage` (Active Storage `local`) |
| boot | `decidim-dev-prod.service` (`docker compose up -d`) plus `restart: unless-stopped` |
| public access | `cloudflared-decidim-dev.service`, tunnel to `localhost:3000` |

`SECRET_KEY_BASE` is the dev app's `credentials.yml.enc` secret: Decidim encrypts
attributes with it, so it must not change. `DECIDIM_ADMIN_PASSWORD_STRONG=false`
keeps dev admin passwords working. Mail goes out through Resend SMTP (same account as prod); the organization's own SMTP settings must stay
empty, otherwise they override it.

Not ported from Railway: the cron services (Decidim's scheduled rake tasks).

## How a new image reaches dev

A merge to fork `develop` that touches `deploy/railway/` makes the `[Vocdoni] Image`
workflow push `ghcr.io/vocdoni/decidim-vocdoni:sha-<12>` and move `:develop`. Within
2 minutes `decidim-dev-update`:

1. compares the digest of `:develop` with the one the `web` container runs; equal
   means nothing to do. A digest whose deploy failed is skipped until a newer image
   appears or someone runs `decidim-dev-update --retry`; a failure to read the
   migration status or to dump the DB is retried on the next tick;
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

Old `decidim-vocdoni-dev` images pile up (one per deploy). Prune by hand now and
then, keeping at least the running tag and the previous one (the rollback
target): `docker images decidim-vocdoni-dev` then `docker rmi decidim-vocdoni-dev:<old-tag>`.

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
