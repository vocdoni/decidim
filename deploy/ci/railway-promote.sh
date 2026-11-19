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
#   RAILWAY_TOKEN           project token scoped to the target environment (secret);
#                           unset = the `railway` CLI's logged-in session (manual runs)
#   RAILWAY_ENVIRONMENT_ID  the environment the token must belong to
#   RAILWAY_PROJECT_ID      with the CLI session: the project that environment must belong to
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
RAILWAY_TOKEN=${RAILWAY_TOKEN:-}
if [ -z "$RAILWAY_TOKEN" ]; then
  command -v railway > /dev/null || die "RAILWAY_TOKEN is not set and the railway CLI is not installed"
  : "${RAILWAY_PROJECT_ID:?RAILWAY_PROJECT_ID is needed with the railway CLI session}"
fi
: "${RAILWAY_ENVIRONMENT_ID:?RAILWAY_ENVIRONMENT_ID is not set}"
: "${RAILWAY_SERVICES:?RAILWAY_SERVICES is not set}"

# The token goes to curl through a header file, never on a command line.
hdr=$(mktemp)
trap 'rm -f "$hdr"' EXIT
chmod 600 "$hdr"
[ -z "$RAILWAY_TOKEN" ] || printf 'Project-Access-Token: %s\n' "$RAILWAY_TOKEN" > "$hdr"

# gql <document> <variables JSON>: prints .data, fails on HTTP or GraphQL errors.
# GQL_NO_RETRY=1 sends it once: a retried serviceInstanceDeployV2 could start a
# second deployment that supersedes the watched one (rerun the workflow instead).
gql() {
  local body resp
  if [ -z "$RAILWAY_TOKEN" ]; then
    # The CLI sends each request once and exits non-zero on HTTP or GraphQL errors.
    resp=$(railway api --compact --variables "$2" "$1") \
      || die "Railway API request failed: $(jq -r '[.errors[]?.message] | join("; ")' <<<"$resp" 2>/dev/null)"
    jq -c '.data' <<<"$resp"
    return
  fi
  local retry=(--retry 3 --retry-all-errors)
  [ "${GQL_NO_RETRY:-0}" = 1 ] && retry=()
  body=$(jq -nc --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')
  resp=$(curl -sS --fail-with-body --max-time 60 "${retry[@]}" \
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

if [ -n "$RAILWAY_TOKEN" ]; then
  env_id=$(gql "$Q_TOKEN" '{}' | jq -r '.projectToken.environmentId')
  [ "$env_id" = "$RAILWAY_ENVIRONMENT_ID" ] \
    || die "the token belongs to environment $env_id, not $RAILWAY_ENVIRONMENT_ID"
else
  # shellcheck disable=SC2016
  project=$(gql 'query env($id: String!) { environment(id: $id) { projectId } }' \
    "$(jq -nc --arg i "$RAILWAY_ENVIRONMENT_ID" '{id: $i}')" | jq -r '.environment.projectId')
  [ "$project" = "$RAILWAY_PROJECT_ID" ] \
    || die "environment $RAILWAY_ENVIRONMENT_ID belongs to project $project, not $RAILWAY_PROJECT_ID"
fi

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
  dep=$(GQL_NO_RETRY=1 gql "$M_DEPLOY" "$(vars "$id")" | jq -r '.serviceInstanceDeployV2')
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
