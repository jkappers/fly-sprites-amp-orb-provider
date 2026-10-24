#!/usr/bin/env bash
# Drives dispatch.sh through the lifecycle Amp uses: spawn, idempotent spawn,
# pause, repeated pause, resume with a fresh token, and delete. Bootstrap gets a
# dummy token and an unreachable AMP_URL, so it retries forever; that's expected.
# Does not verify Amp connectivity. Test a real thread afterward.
#
#   ./smoke-test.sh
#   SPRITES_ORG=myorg ./smoke-test.sh
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
SPRITE_BIN="${SPRITE_BIN:-sprite}"

export ORB_ID="amp-smoke-$(date +%s)"
export ORB_IMAGE="ignored"
NAME="$ORB_ID"

org_args=()
if [[ -n "${SPRITES_ORG:-}" ]]; then org_args=(-o "$SPRITES_ORG"); fi

dispatch() {
	ORB_OPERATION="$1" ORB_TOKEN="${2:-}" AMP_URL="https://example.invalid" "$DIR/dispatch.sh"
}

service_status() {
	"$SPRITE_BIN" api ${org_args[@]+"${org_args[@]}"} -s "$NAME" /services/amp-bootstrap -- -fsS |
		jq -r '.state.status // "unknown"'
}

step() { printf '\n### %s\n' "$*"; }

cleanup() {
	step "delete $NAME"
	dispatch delete || true
	if "$SPRITE_BIN" list ${org_args[@]+"${org_args[@]}"} --json --prefix "$NAME" |
		jq -e --arg n "$NAME" 'any(.sprites[]?; .name == $n)' >/dev/null; then
		echo "FAIL: $NAME still exists" >&2
		exit 1
	fi
}
trap cleanup EXIT

step "spawn"
time dispatch spawn smoke-token
echo "service: $(service_status)"

step "idempotent spawn"
dispatch spawn smoke-token

step "pause"
time dispatch pause
echo "service: $(service_status)"

step "pause again"
dispatch pause

step "spawn (resume with fresh token)"
time dispatch spawn fresh-smoke-token
echo "service: $(service_status)"

step "pause before delete"
dispatch pause

echo
echo "OK"
