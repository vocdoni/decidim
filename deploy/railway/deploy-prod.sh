#!/usr/bin/env bash
# Deploys decidim.vocdoni.dev (Railway, environment production) by hand, with the
# operator's `railway` CLI session: points web, worker and the three crons at the
# GHCR image dev already ran for a release's commit, by digest, one service at a
# time. See README.md, "Releasing".
#
# usage: deploy/railway/deploy-prod.sh <release tag prod-YYYY.MM.DD[.N]> [--yes]
# needs: railway (logged in, `railway whoami`), gh, curl, jq
set -euo pipefail
shopt -s inherit_errexit

REPO=vocdoni/decidim
IMAGE=ghcr.io/vocdoni/decidim-vocdoni
PROD_URL=https://decidim.vocdoni.dev
# Same values as .github/workflows/vocdoni_release.yml. IDs, not secrets.
export RAILWAY_PROJECT_ID=4afc70b1-e33b-458a-8fc5-1fa1e2024007
export RAILWAY_ENVIRONMENT_ID=48a08998-2bc5-4d69-8fba-660fb5e7411f
export RAILWAY_SERVICES="web=5e3f10b6-aa8a-4f52-8615-ee3ea647ba53 worker=11e7679d-27b9-489d-ac6c-68258d8feab1 cron-15min=c7dec447-2ff6-4f6b-bf86-b46227ef0a56 cron-daily=baab6ea5-668d-4002-b9b8-b2711a9c5e3d cron-weekly=46425a81-e6f2-4f2d-8ebc-7324755413d0"
unset RAILWAY_TOKEN

die() { echo "ERROR: $*" >&2; exit 1; }

ref=${1:-} yes=${2:-}
[[ "$ref" =~ ^prod-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] \
  || die "usage: $0 <release tag prod-YYYY.MM.DD[.N]> [--yes]"
for c in railway gh curl jq; do command -v "$c" > /dev/null || die "$c is not installed"; done
railway whoami > /dev/null 2>&1 || die "the railway CLI is not logged in (railway login)"

gh release view "$ref" -R "$REPO" --json tagName > /dev/null 2>&1 \
  || die "no release $ref in $REPO: create it first (README.md, Releasing)"
commit=$(gh api "repos/$REPO/commits/$ref" --jq .sha) || die "cannot resolve $ref in $REPO"
status=$(gh api "repos/$REPO/compare/$commit...develop" --jq .status)
case $status in ahead|identical) ;; *) die "$commit is not on develop" ;; esac

# Anonymous registry read: the package is public.
tag=sha-${commit:0:12}
tok=$(curl -fsS "https://ghcr.io/token?scope=repository:${IMAGE#ghcr.io/}:pull" | jq -r .token)
digest=$(curl -fsS -o /dev/null -D - -H "Authorization: Bearer $tok" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
  "https://ghcr.io/v2/${IMAGE#ghcr.io/}/manifests/$tag" \
  | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }') \
  || die "no image $IMAGE:$tag: deploy a commit that dev has built"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no image $IMAGE:$tag: deploy a commit that dev has built"

here=$(cd "$(dirname "$0")/../.." && pwd)
promote="$here/deploy/ci/railway-promote.sh"

echo "release $ref"
echo "commit $commit"
echo "image  $IMAGE@$digest"
echo
echo "Railway now (rollback: point a service back at its source, or redeploy its latest deployment):"
bash "$promote" check "$IMAGE@$digest"
echo
if [ "$yes" != --yes ]; then
  read -r -p "Deploy this image to $PROD_URL? [y/N] " answer
  [ "$answer" = y ] || die "aborted"
fi

bash "$promote" promote "$IMAGE@$digest"

for path in /up /en/; do
  code=000
  for _ in $(seq 1 12); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROD_URL$path" || true)
    [ "$code" = 200 ] && break
    sleep 10
  done
  echo "$PROD_URL$path $code"
  [ "$code" = 200 ] || die "$PROD_URL$path returned $code"
done
echo "prod runs $ref: $IMAGE@$digest (commit $commit)"
