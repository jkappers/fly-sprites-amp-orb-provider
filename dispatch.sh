#!/usr/bin/env bash
# dispatch.sh: Amp self-hosted orb dispatch program backed by Fly.io Sprites.
#
# Run by `amp orb provider` once per job with ORB_OPERATION, ORB_ID, ORB_IMAGE,
# ORB_SNAPSHOT_ID, and (spawn only) ORB_TOKEN and AMP_URL. Every operation is
# idempotent. See README.md.
set -euo pipefail

: "${ORB_OPERATION:?ORB_OPERATION is required}"
: "${ORB_ID:?ORB_ID is required}"

SPRITE_BIN="${SPRITE_BIN:-sprite}"
SERVICE="amp-bootstrap"
# Sprite names are DNS-style; Amp thread IDs contain uppercase (amp-T-...).
NAME=$(printf '%s' "$ORB_ID" | tr '[:upper:]' '[:lower:]')

trap 'echo "sprites: $ORB_OPERATION $NAME failed at line $LINENO" >&2' ERR

org_args=()
if [[ -n "${SPRITES_ORG:-}" ]]; then org_args=(-o "$SPRITES_ORG"); fi

# sprite <subcommand> [args...]: org flag goes after the subcommand. The +
# expansion keeps an empty array safe under set -u on bash 3.2 (macOS).
sprite() {
	local cmd="$1"
	shift
	# `command` skips this function when SPRITE_BIN is the default "sprite".
	command "$SPRITE_BIN" "$cmd" ${org_args[@]+"${org_args[@]}"} "$@"
}

# svc <method> <path suffix> [curl args...]: call the services API for this sprite.
svc() {
	local method="$1" path="$2"
	shift 2
	sprite api -s "$NAME" "/services/$SERVICE$path" -- -fsS -X "$method" "$@"
}

exists() {
	sprite list --json --prefix "$NAME" |
		jq -e --arg n "$NAME" '[.sprites[]? | select(.name == $n)] | length > 0' >/dev/null
}

# Runs on every spawn. Setup runs once (the filesystem persists across sleep, so the
# marker keeps later spawns fast); the wrapper is always rewritten.
PROVISION=$(cat <<'EOF'
set -euo pipefail
marker=/etc/amp-orb-provisioned-v2

if [[ ! -f "$marker" ]]; then
	missing=()
	for bin in tmux rg gh; do command -v "$bin" >/dev/null || missing+=("$bin"); done
	if ((${#missing[@]})); then
		pkgs=("${missing[@]/rg/ripgrep}")
		sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
			sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" ||
			echo "warn: could not install ${pkgs[*]}" >&2
	fi

	# Amp's orb contract: a `user` account with a writable /home/user and passwordless sudo.
	id user >/dev/null 2>&1 || sudo useradd -m -U -s /bin/bash user
	echo 'user ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/amp-user >/dev/null
	sudo chmod 0440 /etc/sudoers.d/amp-user

	sudo -u user -H bash -c '[[ -x ~/.amp/bin/amp ]] || curl -fsSL https://ampcode.com/install.sh | bash'
	sudo ln -sf /home/user/.amp/bin/amp /usr/local/bin/amp
	sudo touch "$marker"
fi

# Sprite toolchains (node, npm, go, bun, ...) live in /.sprite/bin, which only the exec
# environment puts on PATH. sudo resets PATH, so `user` login shells need it added here.
sudo tee /etc/profile.d/sprite-path.sh >/dev/null <<'PROFILE'
echo ":$PATH:" | grep -q ":/.sprite/bin:" || export PATH="$PATH:/.sprite/bin"
PROFILE
# The toolchain shims append to these sprite-owned files on first use.
sudo usermod -aG sprite user
sudo chmod g+w /etc/profile.d/languages_env /etc/profile.d/languages_paths

# Runs as the service's user. While bootstrap runs, holds the sprite awake with the
# Tasks API: Sprites pause when idle and drop open connections, even outbound ones.
# Retries bootstrap itself instead of crash-looping the service, because a service
# waiting to restart rejects stop with 409, which would make pause unreliable.
sudo tee /usr/local/bin/amp-orb-bootstrap >/dev/null <<'WRAPPER'
#!/usr/bin/env bash
task() {
	sudo curl -fsS --unix-socket /.sprite/api.sock -H 'Content-Type: application/json' \
		"$@" >/dev/null 2>&1 || echo "warn: tasks API $* failed" >&2
}
cleanup() {
	kill "$hb" ${pid:+"$pid"} 2>/dev/null
	[[ -n "${pid:-}" ]] && wait "$pid" 2>/dev/null
	task -X DELETE http://sprite/v1/tasks/amp-orb
	exit 0
}
trap cleanup TERM INT

while true; do
	task -X PUT http://sprite/v1/tasks/amp-orb -d '{"expire":"5m"}'
	sleep 60
done &
hb=$!

while true; do
	sudo -u user -H --preserve-env=ORB_TOKEN,AMP_URL bash -lc 'cd ~ && exec amp orb bootstrap' &
	pid=$!
	wait "$pid" && break
	echo "amp orb bootstrap exited ($?); retrying in 5s" >&2
	sleep 5 &
	wait $!
done
cleanup
WRAPPER
sudo chmod 0755 /usr/local/bin/amp-orb-bootstrap
EOF
)

spawn() {
	: "${ORB_TOKEN:?ORB_TOKEN is required for spawn}"

	if ! exists; then
		echo "sprites: creating $NAME"
		# A concurrent spawn may win the race; only fail if the sprite still isn't there.
		sprite create --skip-console "$NAME" || exists
	fi

	echo "sprites: provisioning $NAME"
	sprite exec -s "$NAME" --no-stdin -- bash -c "$PROVISION"

	# Write the body to a private file so ORB_TOKEN never appears in argv or logs.
	body=$(mktemp)
	trap 'rm -f "$body"' EXIT
	chmod 600 "$body"
	jq -n --arg token "$ORB_TOKEN" --arg url "${AMP_URL:-}" '{
		cmd: "/usr/local/bin/amp-orb-bootstrap",
		args: [],
		needs: [],
		dir: "/home/sprite",
		env: ({ORB_TOKEN: $token} + (if $url == "" then {} else {AMP_URL: $url} end))
	}' >"$body"

	echo "sprites: starting $SERVICE on $NAME"
	svc PUT "" -H 'Content-Type: application/json' --data-binary "@$body" >/dev/null
	# Restart so a resumed orb picks up the fresh token.
	svc POST /restart >/dev/null
}

pause() {
	exists || return 0
	# Sprites have no explicit pause. Stopping bootstrap removes the last activity,
	# so the sprite drops to warm/cold on its own and keeps its disk.
	echo "sprites: stopping $SERVICE on $NAME"
	local status
	for _ in $(seq 30); do
		svc POST /stop >/dev/null 2>&1 && return 0
		# Stop returns 409 between crash-loop restarts, so retry until the service is
		# running again. A missing service (spawn failed early) has nothing to stop.
		# A stopped service can also report "failed" (exit 143) with no restart scheduled.
		status=$(svc GET "" 2>/dev/null | jq -r '.state as $s |
			if $s == null or $s.status == "stopped" then "stopped"
			elif $s.status == "failed" and (($s.next_restart_at // "0001") | startswith("0001")) then "stopped"
			else $s.status end') || return 0
		[[ "$status" == stopped ]] && return 0
		sleep 2
	done
	echo "sprites: $SERVICE on $NAME did not stop (status: $status)" >&2
	return 1
}

delete() {
	exists || return 0
	echo "sprites: destroying $NAME"
	sprite destroy --force "$NAME"
}

case "$ORB_OPERATION" in
	spawn) spawn ;;
	pause) pause ;;
	delete) delete ;;
	*) echo "sprites: unknown ORB_OPERATION '$ORB_OPERATION'" >&2; exit 2 ;;
esac
