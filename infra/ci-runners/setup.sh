#!/usr/bin/env bash
# Re-runnable setup of a self-hosted GitHub Actions runner VM (#288, plan in #205).
# Usage: setup.sh [--slots N] [--slot-gb G] [--runner-version X.Y.Z] [--check] [--mint-from-stdin] [--probe]
# Test seams: GHA_ROOT prefixes every written path; GHA_DRY_STUBS is prepended to PATH.
set -euo pipefail

DEFAULT_VERSION=2.338.0
DEFAULT_SLOTS=2
MAX_SLOTS=16
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${GHA_ROOT:-}
[ -z "${GHA_DRY_STUBS:-}" ] || PATH="$GHA_DRY_STUBS:$PATH"
export PATH

SLOT_GB=4 SLOTS=$DEFAULT_SLOTS VERSION=$DEFAULT_VERSION CHECK=0 FROM_STDIN=0 PROBE=0

usage() {
  cat >&2 <<EOF
Usage: setup.sh [--slots N] [--slot-gb G] [--runner-version X.Y.Z] [--check] [--mint-from-stdin] [--probe]
  --slots N             runner slots, 1..$MAX_SLOTS (default $DEFAULT_SLOTS)
  --slot-gb G           memory cap per slot in GiB, 4..8 (default 4; 5 leaves room for a 4000m job container plus runner and Docker)
  --runner-version V    pinned actions/runner version, X.Y.Z (default $DEFAULT_VERSION)
  --check               change nothing; print WOULD CHANGE/OK per step; exit 3 if changes pending
  --mint-from-stdin     read the mint token from stdin and store it root-only in /etc/gha/mint.env
  --probe               run probe.sh (isolation assertions) and exit
EOF
}
usage_die() { echo "setup.sh: $1" >&2; usage; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --slots) [ $# -ge 2 ] || usage_die "--slots needs a value"; SLOTS=$2; shift 2 ;;
    --slot-gb) [ $# -ge 2 ] || usage_die "--slot-gb needs a value"; SLOT_GB=$2; shift 2 ;;
    --runner-version) [ $# -ge 2 ] || usage_die "--runner-version needs a value"; VERSION=$2; shift 2 ;;
    --check) CHECK=1; shift ;;
    --mint-from-stdin) FROM_STDIN=1; shift ;;
    --probe) PROBE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_die "unknown argument: $1" ;;
  esac
done
[[ $SLOTS =~ ^[1-9][0-9]?$ ]] && [ "$SLOTS" -le "$MAX_SLOTS" ] || usage_die "--slots must be an integer 1..$MAX_SLOTS"
[[ $SLOT_GB =~ ^[4-8]$ ]] || usage_die "--slot-gb must be an integer 4..8"
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_die "--runner-version must look like 2.338.0"
if [ "$PROBE" = 1 ]; then exec bash "$SCRIPT_DIR/probe.sh"; fi

TOKEN=""
if [ "$FROM_STDIN" = 1 ] && [ "$CHECK" = 0 ]; then
  set +x
  IFS= read -r TOKEN || true
  [ -n "$TOKEN" ] || usage_die "--mint-from-stdin got an empty token"
fi
if [ -z "$ROOT" ] && [ "$CHECK" = 0 ] && [ "$EUID" -ne 0 ]; then
  echo "setup.sh: must run as root (use --check to preview)" >&2; exit 1
fi

RELEASE=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
total=$((10 * SLOT_GB * SLOTS))   # tenths of GiB: SLOT_GB per slot (CI job containers are 4G; 5G on a shared host)
if [ $((total % 10)) -eq 0 ]; then MEMMAX="$((total / 10))G"; else MEMMAX="$((total / 10)).$((total % 10))G"; fi
MEMHIGH="$((900 * SLOT_GB * SLOTS))M"

render() {
  local s; s=$(cat)
  s=${s//@VERSION@/$VERSION}; s=${s//@RELEASE@/$RELEASE}
  s=${s//@MEMMAX@/$MEMMAX}; s=${s//@MEMHIGH@/$MEMHIGH}
  printf '%s\n' "$s"
}

# Runtime library, installed to /usr/local/lib/gha/common.sh and sourced here too.
lib_text() { render <<'EOF'
# gha common (installed by infra/ci-runners/setup.sh)
GHA_RELEASE=@RELEASE@
GHA_ROOT=${GHA_ROOT:-}
[ -z "${GHA_DRY_STUBS:-}" ] || PATH="$GHA_DRY_STUBS:$PATH"
export PATH
gha_envval() { # file key -> value (empty if absent)
  [ -r "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -n 1
}
gha_docker_env() { export DOCKER_HOST="unix:///run/user/$(id -u gha)/docker.sock"; }
gha_report() { # route message -> one Sentry event (skipped silently without a DSN file)
  local dsn m=${2//\\/\\\\}
  dsn=$(gha_envval "$GHA_ROOT/etc/gha/sentry.env" SENTRY_DSN)
  [[ $dsn =~ ^(https?)://([^@:/]+)@([^/]+)/([0-9]+)/?$ ]] || return 0
  m=${m//\"/\\\"}; m=${m//$'\n'/ }
  curl -sS --max-time 10 -o /dev/null -X POST "${BASH_REMATCH[1]}://${BASH_REMATCH[3]}/api/${BASH_REMATCH[4]}/store/" \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=${BASH_REMATCH[2]}, sentry_client=gha-ci-runners/1" \
    -H "Content-Type: application/json" \
    --data "{\"message\":\"$m\",\"level\":\"error\",\"release\":\"$GHA_RELEASE\",\"environment\":\"ci-runner\",\"tags\":{\"route\":\"$1\"}}" \
    >/dev/null 2>&1 || true
}
gha_alert() { # text -> Slack via the existing webhook in alert.env (silent if absent)
  local url; url=$(gha_envval "$GHA_ROOT/etc/gha/alert.env" SLACK_WEBHOOK_URL)
  [ -n "$url" ] || return 0
  curl -sS --max-time 10 -X POST -H 'Content-type: application/json' --data "{\"text\":\"$1\"}" "$url" >/dev/null 2>&1 || true
}
gha_fail() { # route message
  echo "ERROR: $1: $2" >&2
  gha_report "$1" "$2"
  gha_alert "CI runner failure ($1): $2 [${HOSTNAME:-host} $GHA_RELEASE]"
  exit 1
}
EOF
}
# shellcheck disable=SC1090
. <(lib_text)

launcher_text() { render <<'EOF'
#!/usr/bin/env bash
# gha-slot.sh <slot>: mint one single-use JIT runner config and run it in a throwaway container.
set -euo pipefail
set +x
GHA_RUNNER_VERSION=@VERSION@
GHA_LABEL=benjis-ci
# shellcheck disable=SC1091
. "${GHA_ROOT:-}/usr/local/lib/gha/common.sh"
slot=${1:-}
[[ $slot =~ ^[0-9]+$ ]] || { echo "Usage: gha-slot.sh <slot>" >&2; exit 2; }
mint="$GHA_ROOT/etc/gha/mint.env"
scope=$(gha_envval "$mint" GHA_RUNNER_SCOPE)   # e.g. orgs/<org> or repos/<owner>/<repo>
tok=$(gha_envval "$mint" GHA_MINT_TOKEN)
[ -n "$tok" ] && [ -n "$scope" ] || gha_fail launcher/mint "mint.env missing GHA_MINT_TOKEN or GHA_RUNNER_SCOPE"
gha_docker_env
# free the container name before minting, so a name conflict cannot register runners that never run
docker rm -f "gha-slot-$slot" >/dev/null 2>&1 || true
work="$GHA_ROOT/srv/gha/work/$slot"   # same absolute path inside the runner and on the daemon, so job containers (container:) bind it correctly
rname="gha-${HOSTNAME:-host}-$slot-$RANDOM"
body="{\"name\":\"$rname\",\"runner_group_id\":1,\"labels\":[\"self-hosted\",\"$GHA_LABEL\"],\"work_folder\":\"$work\"}"
resp=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl -sS -f --max-time 30 -K - -X POST \
  -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  --data "$body" "https://api.github.com/$scope/actions/runners/generate-jitconfig" 2>/dev/null) \
  || gha_fail launcher/mint "JIT config request failed"
tok=""
jit=$(sed -n 's/.*"encoded_jit_config"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$resp")
[ -n "$jit" ] || gha_fail launcher/mint "no encoded_jit_config in response"
rm -rf "$work"; mkdir -p "$work"; chown gha:gha "$work"
t0=$(date +%s); rc=0
ACTIONS_RUNNER_INPUT_JITCONFIG=$jit docker run --rm --name "gha-slot-$slot" \
  -e ACTIONS_RUNNER_INPUT_JITCONFIG -v "${DOCKER_HOST#unix://}:/var/run/docker.sock" -v "$work:$work" \
  "gha-runner:$GHA_RUNNER_VERSION" || rc=$?
# one line per ephemeral runner life (idle wait + one job) for bottleneck tracking; rc 137 = killed (out of memory)
{ mkdir -p "$GHA_ROOT/var/log/gha" && printf '{"ts":"%s","slot":%s,"runner":"%s","life_seconds":%s,"rc":%s}\n' \
    "$(date -u +%FT%TZ)" "$slot" "$rname" "$(($(date +%s) - t0))" "$rc" >> "$GHA_ROOT/var/log/gha/jobs.jsonl"; } 2>/dev/null || true
exit "$rc"
EOF
}
hygiene_text() { render <<'EOF'
#!/usr/bin/env bash
# gha-hygiene.sh: daily docker prune and disk alert (>=80% root usage).
set -euo pipefail
# shellcheck disable=SC1091
. "${GHA_ROOT:-}/usr/local/lib/gha/common.sh"
gha_docker_env
pct=$(df --output=pcent "$GHA_ROOT/" 2>/dev/null | tail -n 1 | tr -dc '0-9' || true)
if [ -n "$pct" ] && [ "$pct" -ge 80 ]; then gha_alert "CI runner disk at ${pct}% on ${HOSTNAME:-host}"; fi
# cap the metrics logs (14 days of per-minute samples; last 5000 runner lives)
mlog="$GHA_ROOT/var/log/gha"
if [ -s "$mlog/host.csv" ]; then
  awk -v n=20160 'NR==FNR{c=NR;next} FNR==1||FNR>c-n' "$mlog/host.csv" "$mlog/host.csv" > "$mlog/host.csv.tmp" \
    && mv -f "$mlog/host.csv.tmp" "$mlog/host.csv" || true
fi
if [ -s "$mlog/jobs.jsonl" ]; then
  tail -n 5000 "$mlog/jobs.jsonl" > "$mlog/jobs.jsonl.tmp" && mv -f "$mlog/jobs.jsonl.tmp" "$mlog/jobs.jsonl" || true
fi
# Never `-a` on images: it would delete the idle gha-runner image and break every slot.
{ docker container prune -f --filter until=24h && docker builder prune -af --filter until=24h && docker image prune -f; } >/dev/null 2>&1 || gha_fail hygiene/prune "docker prune failed"
EOF
}
metrics_text() { render <<'EOF'
#!/usr/bin/env bash
# gha-metrics.sh: one CSV sample per run (systemd timer, every minute) -> /var/log/gha/host.csv
# Columns: ts,memavail_mb,swap_used_mb,load1,steal_pct,disk_pct,gha_mem_mb,gha_oom_kills,slots_up,jobs_running
set -uo pipefail
R=${GHA_ROOT:-}
[ -z "${GHA_DRY_STUBS:-}" ] || PATH="$GHA_DRY_STUBS:$PATH"
out="$R/var/log/gha/host.csv"; state="$R/run/gha-metrics.stat"
mkdir -p "$(dirname "$out")" "$(dirname "$state")"
[ -s "$out" ] || echo "ts,memavail_mb,swap_used_mb,load1,steal_pct,disk_pct,gha_mem_mb,gha_oom_kills,slots_up,jobs_running" > "$out"
read -r memavail swaptot swapfree < <(awk '/^MemAvailable:/{a=$2} /^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{printf "%d %d %d", a/1024, t/1024, f/1024}' "$R/proc/meminfo")
load1=$(cut -d' ' -f1 "$R/proc/loadavg")
read -r tot steal < <(awk '/^cpu /{t=0; for(i=2;i<=9;i++) t+=$i; print t, $9}' "$R/proc/stat")
prev_t=0 prev_s=0
[ -r "$state" ] && read -r prev_t prev_s < "$state"
echo "$tot $steal" > "$state"
steal_pct=$(awk -v t="$tot" -v s="$steal" -v pt="$prev_t" -v ps="$prev_s" 'BEGIN{d=t-pt; if (pt==0||d<=0) print "0.0"; else printf "%.1f", 100*(s-ps)/d}')
disk=$(df --output=pcent "$R/" 2>/dev/null | tail -n 1 | tr -dc '0-9')
uid=$(id -u gha 2>/dev/null || echo 0)
cg="$R/sys/fs/cgroup/user.slice/user-$uid.slice"
gmem=0; [ -r "$cg/memory.current" ] && gmem=$(( $(cat "$cg/memory.current") / 1048576 ))
oom=0;  [ -r "$cg/memory.events" ] && oom=$(awk '$1=="oom_kill"{print $2}' "$cg/memory.events")
slots=$(systemctl list-units 'gha-slot@*' --state=active --no-legend 2>/dev/null | wc -l)
jobs=$(pgrep -c -f Runner.Worker 2>/dev/null || true)
printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "$memavail" "$((swaptot - swapfree))" "$load1" "$steal_pct" \
  "${disk:-0}" "$gmem" "${oom:-0}" "$((slots + 0))" "$((${jobs:-0} + 0))" >> "$out"
EOF
}
metrics_unit_text() { render <<'EOF'
[Unit]
Description=GHA runner host metrics sample

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gha-metrics.sh
EOF
}
metrics_timer_text() { render <<'EOF'
[Unit]
Description=GHA runner host metrics, every minute

[Timer]
OnCalendar=minutely
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
}
slot_unit_text() { render <<'EOF'
[Unit]
Description=GitHub Actions runner slot %i (label benjis-ci, ephemeral JIT)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/gha/mint.env
StartLimitIntervalSec=0

[Service]
Type=simple
OOMScoreAdjust=500
Restart=always
RestartSec=10
ExecStart=/usr/local/sbin/gha-slot.sh %i

[Install]
WantedBy=multi-user.target
EOF
}
hygiene_unit_text() { render <<'EOF'
[Unit]
Description=GHA runner hygiene (docker prune, disk alert)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gha-hygiene.sh
EOF
}
timer_text() { render <<'EOF'
[Unit]
Description=Daily GHA runner hygiene

[Timer]
OnCalendar=*-*-* 08:30:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
EOF
}
dockerfile_text() { render <<'EOF'
FROM ubuntu:24.04
ARG RUNNER_VERSION=@VERSION@
ENV RUNNER_ALLOW_RUNASROOT=1 DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git jq sudo \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; a=$(dpkg --print-architecture); case "$a" in amd64) a=x64;; arm64) a=arm64;; *) exit 1;; esac; \
    mkdir -p /home/runner && cd /home/runner \
    && curl -fsSL -o r.tgz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${a}-${RUNNER_VERSION}.tar.gz" \
    && tar xzf r.tgz && rm r.tgz && ./bin/installdependencies.sh
# docker CLI only: container: jobs talk to gha's rootless daemon through the socket the launcher mounts
RUN set -eux; a=$(uname -m); curl -fsSL "https://download.docker.com/linux/static/stable/${a}/docker-27.3.1.tgz" | tar xz -C /usr/local/bin --strip-components=1 docker/docker
WORKDIR /home/runner
ENTRYPOINT ["./run.sh"]
EOF
}

# ---- step plumbing --------------------------------------------------------------------------
CHANGED=0 RELOAD=0 STEP=init
note_change() {
  CHANGED=$((CHANGED + 1))
  if [ "$CHECK" = 1 ]; then echo "WOULD CHANGE: $1"; else echo "CHANGED: $1"; fi
}
ok() { echo "OK: $1"; }
run() { "$@" || gha_fail "setup/$STEP" "$1 failed (exit $?)"; }
put() { # dest mode content
  local dest=$1 mode=$2 content=$3
  if [ -f "$dest" ] && [ "$(cat "$dest")" = "$content" ] && [ "$(stat -c %a "$dest")" = "$mode" ]; then
    ok "$dest"; return 0
  fi
  note_change "$dest"
  [ "$CHECK" = 1 ] && return 0
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" > "$dest.tmp"
  chmod "$mode" "$dest.tmp"
  mv -f "$dest.tmp" "$dest"
}
put_unit() { # a unit/drop-in change needs daemon-reload
  local before=$CHANGED; put "$@"; [ "$CHANGED" -eq "$before" ] || RELOAD=1
}
ensure_line() { # file prefix line
  if [ -f "$1" ] && grep -q "^$2" "$1"; then ok "$1 has $2"; return 0; fi
  note_change "$1: add $3"
  [ "$CHECK" = 1 ] || { mkdir -p "$(dirname "$1")"; printf '%s\n' "$3" >> "$1"; }
}

# ---- steps ----------------------------------------------------------------------------------
step_user() {
  STEP=user
  if getent passwd gha >/dev/null 2>&1; then ok "user gha"; else
    note_change "create user gha (no sudo, locked password)"
    [ "$CHECK" = 1 ] || run useradd --create-home --shell /bin/bash gha
  fi
  local d
  for d in /srv/gha /srv/gha/docker /srv/gha/work /srv/gha/image; do
    if [ -d "$ROOT$d" ]; then ok "dir $d"; else
      note_change "mkdir $d"
      [ "$CHECK" = 1 ] || { mkdir -p "$ROOT$d"; run chown gha:gha "$ROOT$d"; }
    fi
  done
  ensure_line "$ROOT/etc/subuid" "gha:" "gha:100000:65536"
  ensure_line "$ROOT/etc/subgid" "gha:" "gha:100000:65536"
  if loginctl show-user gha 2>/dev/null | grep -q '^Linger=yes'; then ok "linger gha"; else
    note_change "enable linger for gha"
    [ "$CHECK" = 1 ] || run loginctl enable-linger gha
  fi
}

step_cgroup() {
  STEP=cgroup
  put_unit "$ROOT/etc/systemd/system/user-$UID_GHA.slice.d/50-gha-limits.conf" 644 "$(render <<'EOF'
[Slice]
MemoryMax=@MEMMAX@
MemoryHigh=@MEMHIGH@
MemorySwapMax=0
CPUWeight=50
IOWeight=50
TasksMax=4096
EOF
)"
  put_unit "$ROOT/etc/systemd/system/user@$UID_GHA.service.d/50-gha.conf" 644 "$(render <<'EOF'
[Service]
OOMScoreAdjust=500
Delegate=cpu io memory pids
EOF
)"
}

step_docker() {
  STEP=docker
  local cfg="$ROOT/home/gha/.config/docker/daemon.json" before=$CHANGED
  put "$cfg" 644 '{ "data-root": "/srv/gha/docker" }'
  local changed=$((CHANGED - before)) installed=0
  if docker info 2>/dev/null | grep -q rootless; then installed=1; ok "rootless docker for gha"; else
    note_change "install rootless docker for gha"
    [ "$CHECK" = 1 ] || run runuser -l gha -c "XDG_RUNTIME_DIR=/run/user/$UID_GHA dockerd-rootless-setuptool.sh install"
  fi
  [ "$CHECK" = 1 ] && return 0
  if [ "$changed" -gt 0 ]; then
    run chown -R gha:gha "$ROOT/home/gha/.config"
    [ "$installed" = 0 ] || run runuser -l gha -c "XDG_RUNTIME_DIR=/run/user/$UID_GHA systemctl --user restart docker"
  fi
}

step_image() {
  STEP=image
  local before=$CHANGED
  put "$ROOT/srv/gha/image/Dockerfile" 644 "$(dockerfile_text)"
  if [ "$CHANGED" -eq "$before" ] && docker image inspect "gha-runner:$VERSION" >/dev/null 2>&1; then
    ok "image gha-runner:$VERSION"; return 0
  fi
  [ "$CHANGED" -ne "$before" ] || note_change "build image gha-runner:$VERSION"
  [ "$CHECK" = 1 ] || run docker build -t "gha-runner:$VERSION" "$ROOT/srv/gha/image"
  # container: jobs bind-mount the runner's /home/runner/externals from the DAEMON's filesystem, so the same files must
  # exist there at that path (the runner image has them at the same path inside)
  if [ "$CHECK" = 0 ]; then
    run docker rm -f gha-externals-copy >/dev/null 2>&1 || true
    run docker create --name gha-externals-copy "gha-runner:$VERSION"
    run rm -rf "$ROOT/home/runner/externals"
    run mkdir -p "$ROOT/home/runner"
    run docker cp gha-externals-copy:/home/runner/externals "$ROOT/home/runner/externals"
    run docker rm gha-externals-copy
    run chown -R gha:gha "$ROOT/home/runner"
  fi
}

step_units() {
  STEP=units
  put "$ROOT/usr/local/lib/gha/common.sh" 644 "$(lib_text)"
  put "$ROOT/usr/local/sbin/gha-slot.sh" 755 "$(launcher_text)"
  put "$ROOT/usr/local/sbin/gha-hygiene.sh" 755 "$(hygiene_text)"
  put "$ROOT/usr/local/sbin/gha-metrics.sh" 755 "$(metrics_text)"
  put_unit "$ROOT/etc/systemd/system/gha-slot@.service" 644 "$(slot_unit_text)"
  put_unit "$ROOT/etc/systemd/system/gha-hygiene.service" 644 "$(hygiene_unit_text)"
  put_unit "$ROOT/etc/systemd/system/gha-hygiene.timer" 644 "$(timer_text)"
  put_unit "$ROOT/etc/systemd/system/gha-metrics.service" 644 "$(metrics_unit_text)"
  put_unit "$ROOT/etc/systemd/system/gha-metrics.timer" 644 "$(metrics_timer_text)"
  if [ -d "$ROOT/var/log/gha" ]; then ok "dir /var/log/gha"; else
    note_change "mkdir /var/log/gha"
    [ "$CHECK" = 1 ] || mkdir -p "$ROOT/var/log/gha"
  fi
  if [ "$RELOAD" = 1 ] && [ "$CHECK" = 0 ]; then run systemctl daemon-reload; fi
}

step_enable() {
  STEP=enable
  local i
  for ((i = 1; i <= SLOTS; i++)); do
    # a failed slot (e.g. from an earlier start limit) is revived on every run
    if [ "$CHECK" = 0 ] && [ -f "$ROOT/etc/gha/mint.env" ]; then
      systemctl reset-failed "gha-slot@$i.service" >/dev/null 2>&1 || true   # fails on a never-loaded unit (fresh systemd)
      run systemctl start "gha-slot@$i.service"
    fi
    if [ "$(systemctl is-enabled "gha-slot@$i.service" 2>/dev/null)" = enabled ]; then ok "slot $i enabled"; else
      note_change "enable gha-slot@$i"
      if [ "$CHECK" = 0 ]; then
        run systemctl enable "gha-slot@$i.service"
        [ "$(systemctl is-enabled "gha-slot@$i.service" 2>/dev/null)" = enabled ] \
          || gha_fail "setup/$STEP" "gha-slot@$i is not enabled after systemctl enable"
      fi
    fi
  done
  for ((i = SLOTS + 1; i <= MAX_SLOTS; i++)); do
    if systemctl is-active "gha-slot@$i.service" >/dev/null 2>&1 \
       || [ -L "$ROOT/etc/systemd/system/multi-user.target.wants/gha-slot@$i.service" ]; then
      note_change "disable and stop gha-slot@$i"
      [ "$CHECK" = 1 ] || run systemctl disable --now "gha-slot@$i.service"
    fi
  done
  if systemctl is-enabled gha-hygiene.timer >/dev/null 2>&1; then ok "hygiene timer enabled"; else
    note_change "enable gha-hygiene.timer"
    [ "$CHECK" = 1 ] || run systemctl enable --now gha-hygiene.timer
  fi
  if systemctl is-enabled gha-metrics.timer >/dev/null 2>&1; then ok "metrics timer enabled"; else
    note_change "enable gha-metrics.timer"
    [ "$CHECK" = 1 ] || run systemctl enable --now gha-metrics.timer
  fi
}

mint_has_token() { # token file (no argv exposure of the token)
  local l; while IFS= read -r l; do [ "$l" = "GHA_MINT_TOKEN=$1" ] && return 0; done < "$2"; return 1
}
step_mint() {
  STEP=mint
  local f="$ROOT/etc/gha/mint.env" others=""
  if [ -n "$TOKEN" ]; then
    if [ -f "$f" ] && mint_has_token "$TOKEN" "$f" && [ "$(stat -c %a "$f")" = 600 ]; then ok "mint.env token"; return 0; fi
    note_change "write $f (0600)"
    others=$(grep -v '^GHA_MINT_TOKEN=' "$f" 2>/dev/null || true)
    install -d -m 0750 "$(dirname "$f")"
    install -m 0600 /dev/null "$f"
    { [ -z "$others" ] || printf '%s\n' "$others"; printf 'GHA_MINT_TOKEN=%s\n' "$TOKEN"; } > "$f"
    # slots were skipped by ConditionPathExists until the token existed: start them now
    local i; for ((i = 1; i <= SLOTS; i++)); do
      run systemctl reset-failed "gha-slot@$i.service"; run systemctl start "gha-slot@$i.service"
    done
  elif [ -f "$f" ]; then
    if [ "$(stat -c %a "$f")" = 600 ]; then ok "mint.env present (0600)"; else
      note_change "chmod 600 $f"; [ "$CHECK" = 1 ] || chmod 600 "$f"
    fi
  else
    echo "WARN: $f absent - launcher cannot mint until it is supplied (see README)"
  fi
}

UID_GHA=$(id -u gha 2>/dev/null || echo UID)
step_user
UID_GHA=$(id -u gha 2>/dev/null || echo UID)
gha_docker_env 2>/dev/null || true
step_cgroup
step_docker
step_image
step_units
step_enable
step_mint
TOKEN=""

if [ "$CHANGED" -eq 0 ]; then echo "no change"; exit 0; fi
if [ "$CHECK" = 1 ]; then echo "$CHANGED change(s) pending"; exit 3; fi
echo "$CHANGED step(s) applied"
