#!/usr/bin/env bash
# Tests for infra/ci-runners/{setup.sh,probe.sh,README.md} (#288, code for infra #205).
# Runs as a normal user: no root, Docker, network or runner. Host commands are stubs on GHA_DRY_STUBS;
# written paths are prefixed by GHA_ROOT.
#
# Contract pinned by these tests beyond the ticket text (documented in the #288 handoff):
#   - Sentry DSN file: $GHA_ROOT/etc/gha/sentry.env containing SENTRY_DSN=...
#   - Rendered launcher:  $GHA_ROOT/usr/local/sbin/gha-slot.sh <N>  (reads $GHA_ROOT/etc/gha/mint.env)
#   - Rendered hygiene:   $GHA_ROOT/usr/local/sbin/gha-hygiene.sh   (reads $GHA_ROOT/etc/gha/alert.env)
#   - Both honour GHA_ROOT and PATH=$GHA_DRY_STUBS:$PATH at run time.
#   - Sentry event: sent via `sentry-cli` or `curl`; the stubs capture argv, SENTRY_* env, stdin and any
#     `@file` body, so tags may travel in argv, a JSON body, a file or stdin. `release` must be the commit sha
#     (7-40 hex) and appear as release<sep>sha where <sep> is up to 6 non-hex chars ('=', ' ', '":"', ...).
#   - Slot enable/disable goes through `systemctl enable|disable|stop` (state recorded by the stub, not log greps).
#   - The launcher's work dir is the host side of its `docker run -v <host>:<ctr>` bind mount.
#   - `df` may be called with any flags (--output=pcent or -P).
#   - Launcher scope comes from `GHA_RUNNER_SCOPE=` in mint.env (developer-chosen; documented in README).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$REPO/infra/ci-runners/setup.sh"
PROBE="$REPO/infra/ci-runners/probe.sh"
README="$REPO/infra/ci-runners/README.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; n=0
ok()   { n=$((n+1)); echo "ok   - $1"; }
bad()  { n=$((n+1)); fails=$((fails+1)); echo "FAIL - $1${2:+ :: $2}"; }
t()    { # t <name> <command...>  (command must return 0)
  local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

SENT=SENTINEL123
HOOK=https://hooks.slack.test/T0/B0/SENTINELHOOK

mkstubs() { # mkstubs <dir>
  local d=$1; mkdir -p "$d"
  for c in systemctl useradd usermod loginctl docker curl sentry-cli sudo runuser getent id df \
           dockerd-rootless-setuptool.sh apparmor_parser chown; do
    cat > "$d/$c" <<'STUB'
#!/usr/bin/env bash
c=$(basename "$0"); S=${STUB_STATE:?}; mkdir -p "$S"
body=""; envs=""
if [ "$c" = curl ] || [ "$c" = sentry-cli ]; then
  for a in "$@"; do
    case "$a" in @-) ;; @*) [ -f "${a#@}" ] && body="$body $(tr '\n' ' ' < "${a#@}")";; esac
  done
  # stdin is read only when argv says so (never blocks on an inherited stdin)
  case " $* " in *" @-"*|*" -K - "*|*" --config - "*|*" -d - "*) body="$body $(cat | tr '\n' ' ')";; esac
  envs=$(env | grep -E '^SENTRY_(RELEASE|ENVIRONMENT|TAGS?[A-Z_]*|EXTRA[A-Z_]*)=' | tr '\n' ' ')
fi
echo "$c $*${body:+ BODY=$body}${envs:+ ENV=$envs}" >> "$S/$c.log"
case "$c" in
  systemctl)
    cmd=""; for a in "$@"; do case "$a" in enable|disable|stop|start|is-enabled|is-active|is-failed|show|daemon-reload|restart) cmd=$a; break;; esac; done
    now=0; for a in "$@"; do [ "$a" = --now ] && now=1; done
    for a in "$@"; do case "$a" in gha-slot@*|gha-hygiene*)
      u=${a%.service}
      case "$cmd" in start|enable) rm -f "$S/stopped.$u";; stop) touch "$S/stopped.$u";; esac
      case "$cmd" in enable) touch "$S/en.$u";; disable) rm -f "$S/en.$u"; [ $now = 1 ] && touch "$S/stopped.$u";;
        is-enabled|is-active) [ -e "$S/en.$u" ] && { echo enabled; exit 0; } || { echo disabled; exit 1; };; esac;;
    esac; done ;;
  useradd) touch "$S/user"; [ -n "${STUB_USERADD_FAIL:-}" ] && { echo "useradd: boom" >&2; exit 1; } ;;
  getent) [ -e "$S/user" ] || exit 2; echo "gha:x:1234:1234::/home/gha:/bin/bash" ;;
  id) case "$*" in *-u*) echo 1234;; *) echo "uid=1234(gha) gid=1234(gha) groups=1234(gha)";; esac ;;
  loginctl) case "$1" in enable-linger) touch "$S/linger";; show-user) [ -e "$S/linger" ] && echo Linger=yes || echo Linger=no;; esac ;;
  docker)
    case "$1 $2" in
      "build "*|"image build") touch "$S/image";;
      "image inspect"|"image ls"|"images "*|"image list") [ -e "$S/image" ] || exit 1;;
      "system prune"|"container prune"|"builder prune"|"image prune") [ -n "${STUB_DOCKER_PRUNE_FAIL:-}" ] && { echo "prune failed" >&2; exit 1; } ;;
      "info "*) echo "name=rootless /srv/gha/docker";;
    esac
    case "$1" in build) touch "$S/image";; esac ;;
esac
case "$c" in
  curl)
    case "$*" in *generate-jitconfig*) [ -n "${STUB_MINT_FAIL:-}" ] && { echo "mint denied" >&2; exit 22; }; echo '{"encoded_jit_config":"abc"}';; esac ;;
  df) case "$*" in *--output=pcent*) printf 'Use%%\n %s%%\n' "${STUB_DF_PCT:-10}";;
        *) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 %s %s %s%% /\n' "${STUB_DF_PCT:-10}" "$((100-${STUB_DF_PCT:-10}))" "${STUB_DF_PCT:-10}";; esac ;;
  sudo)
    for a in "$@"; do case "$a" in
      test) [ -n "${STUB_SUDO_READABLE:-}" ] && exit 0 || exit 1;;
      ls)   [ -n "${STUB_SUDO_LIST:-}" ] && { echo secret; exit 0; } || { echo "Permission denied" >&2; exit 2; };;
      env|printenv) echo "PATH=/usr/bin"; [ -n "${STUB_ENV_LEAK:-}" ] && echo "GITHUB_TOKEN=x"; exit 0;;
    esac; done; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$d/$c"
  done
}

# newenv: fresh root + stub state; sets R, ST, STUBS and exports seam vars
newenv() {
  R="$TMP/root.$RANDOM$RANDOM"; ST="$TMP/state.$RANDOM$RANDOM"; STUBS="$TMP/stubs.$RANDOM$RANDOM"
  mkdir -p "$R" "$ST"; mkstubs "$STUBS"
  export GHA_ROOT="$R" GHA_DRY_STUBS="$STUBS" STUB_STATE="$ST" PATH="$STUBS:$ORIG_PATH"
  for v in $(env | sed -n 's/^\(SENTRY_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done   # ambient Sentry config must not leak in
  unset STUB_USERADD_FAIL STUB_DOCKER_PRUNE_FAIL STUB_MINT_FAIL STUB_DF_PCT STUB_SUDO_READABLE STUB_SUDO_LIST STUB_ENV_LEAK
}
ORIG_PATH=$PATH
sums() { (cd "$R" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum); }
alltext() { find "$R" -type f -exec cat {} + 2>/dev/null; }
sentry_events() { # one line per captured event: sentry-cli invocations + curl posts to the DSN host
  { grep -h -E '^sentry-cli' "$ST/sentry-cli.log" 2>/dev/null
    grep -h -i 'sentry' "$ST/curl.log" 2>/dev/null; } | grep -c . ; }
setup_dsn() { mkdir -p "$R/etc/gha"; echo "SENTRY_DSN=https://pub@o0.ingest.sentry.test/42" > "$R/etc/gha/sentry.env"; }
setup_alert() { mkdir -p "$R/etc/gha"; echo "SLACK_WEBHOOK_URL=$HOOK" > "$R/etc/gha/alert.env"; }
setup_mint() { mkdir -p "$R/etc/gha"; echo "GHA_MINT_TOKEN=$SENT" > "$R/etc/gha/mint.env"; chmod 600 "$R/etc/gha/mint.env"; }

# ---- files exist -----------------------------------------------------------------------------
t "setup.sh exists"  test -f "$SETUP"
t "probe.sh exists"  test -f "$PROBE"
t "README.md exists" test -f "$README"
t "setup.sh uses set -euo pipefail" grep -q 'set -euo pipefail' "$SETUP"
t "setup.sh and probe.sh pass bash -n" bash -c "bash -n '$SETUP' && bash -n '$PROBE'"
if command -v shellcheck >/dev/null; then
  t "shellcheck clean" shellcheck "$SETUP" "$PROBE"
else echo "skip - shellcheck not installed"; fi

# ---- idempotency -----------------------------------------------------------------------------
test_idempotent() {
  newenv
  bash "$SETUP" >"$TMP/o1" 2>&1 || { echo "first run exit $?"; return 1; }
  local a b; a=$(sums)
  [ -n "$a" ] || { echo "first run wrote nothing"; return 1; }
  bash "$SETUP" >"$TMP/o2" 2>&1; local rc=$?
  b=$(sums)
  [ $rc -eq 0 ] || { echo "second run exit $rc"; return 1; }
  [ "$a" = "$b" ] || { echo "checksums differ"; return 1; }
  grep -qi 'no change' "$TMP/o2" || { echo "no 'no change' in second run"; return 1; }
  ! grep -qE 'WOULD CHANGE|CHANGED:' "$TMP/o2" || { echo "second run reports changes"; return 1; }
}
t "setup twice: second run no change, exit 0, identical checksums" test_idempotent

# ---- --check ---------------------------------------------------------------------------------
test_check_empty() {
  newenv
  bash "$SETUP" --check >"$TMP/c1" 2>&1; local rc=$?
  [ $rc -eq 3 ] || { echo "exit $rc, want 3"; return 1; }
  # one WOULD CHANGE line per step (steps 1-6 always change on an empty root)
  [ "$(grep -c '^WOULD CHANGE:' "$TMP/c1")" -ge 6 ] || { echo "fewer than 6 WOULD CHANGE lines"; return 1; }
  [ -z "$(find "$R" -mindepth 1)" ] || { echo "--check wrote files"; return 1; }
}
t "--check on empty root: exit 3, WOULD CHANGE per step, writes nothing" test_check_empty
test_check_applied() {
  newenv; bash "$SETUP" >/dev/null 2>&1 || return 1
  bash "$SETUP" --check >"$TMP/c2" 2>&1; local rc=$?
  [ $rc -eq 0 ] || { echo "exit $rc, want 0"; return 1; }
  ! grep -q 'WOULD CHANGE' "$TMP/c2" && grep -q '^OK:' "$TMP/c2"
}
t "--check after apply: exit 0, OK lines only" test_check_applied
test_check_no_root() { newenv; [ "$(id -u)" -ne 0 ] || return 0; bash "$SETUP" --check >/dev/null 2>&1; [ $? -eq 3 ]; }
t "--check works as non-root" test_check_no_root

# ---- slots -----------------------------------------------------------------------------------
enabled() { [ -e "$ST/en.gha-slot@$1" ]; }       # state recorded by the systemctl stub (enable/disable verbs only)
stopped() { [ -e "$ST/stopped.gha-slot@$1" ]; }
test_default_two() {
  newenv; bash "$SETUP" >/dev/null 2>&1
  enabled 1 && enabled 2 && ! enabled 3 && ! enabled 4
}
t "default slots = 2 (units 1,2 enabled, 3 not)" test_default_two
test_scale_up() {
  newenv; bash "$SETUP" --slots 2 >/dev/null 2>&1; ! enabled 3 || return 1
  bash "$SETUP" --slots 3 >/dev/null 2>&1 || return 1
  enabled 1 && enabled 2 && enabled 3
}
t "--slots 3 after 2 enables unit 3" test_scale_up
test_scale_down() {
  newenv; bash "$SETUP" --slots 2 >/dev/null 2>&1; enabled 2 || return 1
  bash "$SETUP" --slots 1 >/dev/null 2>&1 || return 1
  enabled 1 && ! stopped 1 && ! enabled 2 && stopped 2
}
t "--slots 1 after 2 disables+stops unit 2 only" test_scale_down

# ---- rendered content ------------------------------------------------------------------------
test_rendered() {
  newenv; bash "$SETUP" --slots 2 >/dev/null 2>&1; local all; all=$(alltext); local s rc=0
  for s in 'OOMScoreAdjust=500' 'MemorySwapMax=0' 'CPUWeight=50' 'IOWeight=50' 'TasksMax=4096' '--rm' \
           'Restart=always' 'benjis-ci' '2.338.0' 'MemoryHigh=4500M' 'generate-jitconfig' \
           'Delegate=' 'data-root' '/srv/gha/docker' 'until=24h' '08:30'; do
    grep -qF -- "$s" <<<"$all" || { echo "missing: $s"; rc=1; }
  done
  grep -Eq 'MemoryMax=(5G|5120M|5368709120)$' <<<"$all" || { echo "MemoryMax != 2.5G x 2"; rc=1; }
  return $rc
}
t "rendered files contain limits/units/label/version (2 slots)" test_rendered
test_memmax_scaled() {
  newenv; bash "$SETUP" --slots 3 >/dev/null 2>&1
  grep -Eq 'MemoryMax=(7\.5G|7680M|8053063680)$' <<<"$(alltext)" || { echo "3 slots: want 7.5G"; return 1; }
  newenv; bash "$SETUP" --slots 1 >/dev/null 2>&1
  grep -Eq 'MemoryMax=(2\.5G|2560M|2684354560)$' <<<"$(alltext)" || { echo "1 slot: want 2.5G"; return 1; }
}
t "MemoryMax scales 2.5G x slots (3 and 1)" test_memmax_scaled
test_version_param() {
  newenv; bash "$SETUP" --runner-version 2.340.1 >/dev/null 2>&1; local all; all=$(alltext)
  grep -qF 2.340.1 <<<"$all" && ! grep -qF 2.338.0 <<<"$all"
}
t "--runner-version pins version everywhere (no leftover default)" test_version_param
test_no_sudo_user() { newenv; bash "$SETUP" >/dev/null 2>&1 || return 1; [ -n "$(find "$R" -type f)" ] && ! grep -rqiE 'gha.*NOPASSWD|usermod .*-aG sudo' "$R"; }
t "gha granted no sudo" test_no_sudo_user

# ---- per-step coverage (setup behaviours 1,2,4,5) ---------------------------------------------
# stub uid for gha is 1234 (id -u gha)
files_like() { find "$R" -type f -path "$1"; }
has_in() { # has_in <path-glob> <fixed string>...: some file matching the glob contains every string
  local g=$1 f str ok_; shift
  for f in $(files_like "$g"); do ok_=1; for str in "$@"; do grep -qF -- "$str" "$f" || ok_=0; done; [ $ok_ = 1 ] && return 0; done
  return 1; }
test_user_slice_limits() {
  newenv; bash "$SETUP" --slots 2 >/dev/null 2>&1
  has_in '*user-1234.slice*' MemoryMax=5G MemoryHigh=4500M MemorySwapMax=0 CPUWeight=50 IOWeight=50 TasksMax=4096 \
    || { echo "limits not in a user-1234.slice drop-in"; return 1; }
}
t "limits sit on user-<uid>.slice (not a runner-unit slice)" test_user_slice_limits
test_oom_user_service() { newenv; bash "$SETUP" >/dev/null 2>&1; has_in '*user@1234.service*' OOMScoreAdjust=500; }
t "OOMScoreAdjust=500 in a user@<uid>.service drop-in" test_oom_user_service
test_oom_runner_unit() { newenv; bash "$SETUP" >/dev/null 2>&1; has_in '*gha-slot@*' OOMScoreAdjust=500 Restart=always; }
t "OOMScoreAdjust=500 and Restart=always in the gha-slot@ unit" test_oom_runner_unit
test_image_built() {
  newenv; bash "$SETUP" >/dev/null 2>&1
  grep -Eq '^docker .*build.*gha-runner:2\.338\.0' "$ST/docker.log"
}
t "runner image built and tagged gha-runner:2.338.0" test_image_built
test_image_built_version() {
  newenv; bash "$SETUP" --runner-version 2.340.1 >/dev/null 2>&1
  grep -Eq '^docker .*build.*gha-runner:2\.340\.1' "$ST/docker.log" && ! grep -q 'gha-runner:2\.338' "$ST/docker.log"
}
t "image tag follows --runner-version" test_image_built_version
test_user_dirs() {
  newenv; bash "$SETUP" >/dev/null 2>&1 || return 1
  [ -d "$R/srv/gha" ] || { echo "no /srv/gha"; return 1; }
  grep -q '^gha:' "$R/etc/subuid" && grep -q '^gha:' "$R/etc/subgid" || { echo "subuid/subgid"; return 1; }
  [ -e "$ST/linger" ] || { echo "linger not enabled"; return 1; }
  [ -e "$ST/user" ] || { echo "gha not created"; return 1; }
}
t "gha user, /srv/gha, subuid/subgid, linger" test_user_dirs
test_work_wiped() {
  newenv; setup_mint; echo "GHA_RUNNER_SCOPE=orgs/benjis" >> "$R/etc/gha/mint.env"
  bash "$SETUP" >/dev/null 2>&1 || return 1
  : > "$ST/docker.log"
  bash "$R/usr/local/sbin/gha-slot.sh" 1 >/dev/null 2>&1
  local line host; line=$(grep -E '^docker .*run ' "$ST/docker.log" | head -1)
  [ -n "$line" ] || { echo "launcher never ran docker run (scope key is GHA_RUNNER_SCOPE in mint.env)"; return 1; }
  host=$(sed -nE 's/.* (-v|--volume)[ =]([^: ]+):.*/\2/p' <<<"$line" | head -1)
  [ -n "$host" ] && [ -d "$host" ] || { echo "no host bind mount dir ($host)"; return 1; }
  case "$host" in "$R"/*) ;; *) echo "work dir outside GHA_ROOT: $host"; return 1;; esac
  echo stale > "$host/stale-from-previous-job"
  bash "$R/usr/local/sbin/gha-slot.sh" 1 >/dev/null 2>&1
  [ ! -e "$host/stale-from-previous-job" ]
}
t "slot work dir wiped on every slot start" test_work_wiped

# ---- secrets ---------------------------------------------------------------------------------
P1='gh''p_'; P2='gh''o_'; P3='github''_pat_'
test_no_tokens_tree() {
  newenv; bash "$SETUP" >/dev/null 2>&1 || return 1
  [ -n "$(find "$R" -type f)" ] && ! grep -rqE "($P1|$P2|$P3)" "$R"
}
t "no ghp_/gho_/github_pat_ in rendered tree" test_no_tokens_tree
test_no_tokens_repo() {
  [ -d "$REPO/infra/ci-runners" ] || return 1
  ! grep -rqE "($P1|$P2|$P3)" "$REPO/infra/ci-runners"
}
t "no ghp_/gho_/github_pat_ in infra/ci-runners" test_no_tokens_repo
test_no_user_gh() { [ -f "$SETUP" ] && ! grep -rqE '\.config/gh|hosts\.yml' "$REPO/infra/ci-runners" --include='*.sh'; }
t "nothing read from ~claude/.config/gh" test_no_user_gh
test_stdin_token() {
  newenv
  printf '%s' "$SENT" | bash "$SETUP" --mint-from-stdin >"$TMP/m.out" 2>"$TMP/m.err"; local rc=$?
  [ $rc -eq 0 ] || { echo "exit $rc"; return 1; }
  local f="$R/etc/gha/mint.env"
  [ -f "$f" ] && grep -qF "$SENT" "$f" || { echo "mint.env missing token"; return 1; }
  [ "$(stat -c %a "$f")" = 600 ] || { echo "mint.env mode $(stat -c %a "$f")"; return 1; }
  ! grep -qF "$SENT" "$TMP/m.out" "$TMP/m.err" || { echo "token echoed"; return 1; }
  [ -z "$(grep -rlF "$SENT" "$R" | grep -v "^$f$")" ] || { echo "token in other file"; return 1; }
  ! grep -rqF "$SENT" "$ST" || { echo "token reached a stubbed command's argv"; return 1; }
}
t "--mint-from-stdin: token only in mint.env (0600), never echoed, never in argv" test_stdin_token
test_mint_env_preexisting() { newenv; setup_mint; bash "$SETUP" >"$TMP/p.out" 2>&1 || return 1; [ -s "$TMP/p.out" ] && ! grep -qF "$SENT" "$TMP/p.out"; }
t "existing mint.env token never printed" test_mint_env_preexisting

# ---- validation ------------------------------------------------------------------------------
check_bad() { # check_bad <args...>
  newenv; bash "$SETUP" "$@" >"$TMP/b.out" 2>&1; local rc=$?
  [ $rc -eq 2 ] || { echo "'$*' exit $rc, want 2"; return 1; }
  grep -qi 'usage' "$TMP/b.out" || { echo "'$*' no usage message"; return 1; }
  [ -z "$(find "$R" -mindepth 1)" ] || { echo "'$*' wrote files"; return 1; }
}
for args in "--slots 0" "--slots abc" "--slots -1" "--runner-version 2.338" "--runner-version v2.338.0" \
            "--runner-version 2.338.0-rc1" "--runner-version abc"; do
  t "invalid '$args' -> exit 2 + usage" check_bad $args
done

# ---- probe -----------------------------------------------------------------------------------
probe_run() { bash "$1" "${@:2}" >"$TMP/pr.out" 2>&1; echo $?; }
test_probe_fail_readable() {
  newenv; export STUB_SUDO_READABLE=1
  local rc; rc=$(probe_run "$PROBE"); [ "$rc" -ne 0 ] && grep -q 'FAIL' "$TMP/pr.out"
}
t "probe: readable ~claude/.claude -> FAIL, non-zero" test_probe_fail_readable
test_probe_fail_list() {
  newenv; export STUB_SUDO_LIST=1
  local rc; rc=$(probe_run "$PROBE"); [ "$rc" -ne 0 ] && grep -q 'FAIL' "$TMP/pr.out"
}
t "probe: can list /home/claude -> FAIL, non-zero" test_probe_fail_list
test_probe_fail_env() {
  newenv; export STUB_ENV_LEAK=1
  local rc; rc=$(probe_run "$PROBE"); [ "$rc" -ne 0 ] && grep -q 'FAIL' "$TMP/pr.out"
}
t "probe: TOKEN in gha env -> FAIL, non-zero" test_probe_fail_env
test_probe_pass() {
  newenv
  local rc; rc=$(probe_run "$PROBE"); [ "$rc" -eq 0 ] || { echo "exit $rc"; return 1; }
  ! grep -q 'FAIL' "$TMP/pr.out" && [ "$(grep -c 'PASS' "$TMP/pr.out")" -ge 4 ]
}
t "probe: all denied -> PASS lines (>=4), exit 0" test_probe_pass
test_probe_via_setup() {
  newenv; export STUB_SUDO_READABLE=1
  bash "$SETUP" --probe >"$TMP/ps.out" 2>&1; [ $? -ne 0 ] && grep -q FAIL "$TMP/ps.out"
}
t "setup.sh --probe behaves like probe.sh" test_probe_via_setup

# ---- hygiene: disk alert ---------------------------------------------------------------------
HY() { echo "$R/usr/local/sbin/gha-hygiene.sh"; }
hygiene_run() { bash "$(HY)" >"$TMP/h.out" 2>&1; }
hook_posts() { grep -c -F "hooks.slack.test" "$ST/curl.log" 2>/dev/null || true; }
test_hy_alert() { # $1 = pct
  newenv; setup_alert; bash "$SETUP" >/dev/null 2>&1; : > "$ST/curl.log"
  export STUB_DF_PCT=$1; hygiene_run || return 1
  [ "$(hook_posts)" -ge 1 ]
}
test_hy_quiet() { # $1 = pct
  newenv; setup_alert; bash "$SETUP" >/dev/null 2>&1; : > "$ST/curl.log"
  export STUB_DF_PCT=$1; hygiene_run || return 1
  [ "$(hook_posts)" -eq 0 ]
}
test_hy_noenv() {
  newenv; bash "$SETUP" >/dev/null 2>&1; : > "$ST/curl.log"; export STUB_DF_PCT=95
  hygiene_run || return 1
  [ ! -s "$ST/curl.log" ]
}
t "hygiene: 85% disk -> Slack alert" test_hy_alert 85
t "hygiene: exactly 80% -> Slack alert (boundary)" test_hy_alert 80
t "hygiene: 79% -> no alert (boundary)" test_hy_quiet 79
t "hygiene: no alert.env -> silent, exit 0" test_hy_noenv
test_hy_prunes() {
  newenv; bash "$SETUP" >/dev/null 2>&1; : > "$ST/docker.log"; hygiene_run || return 1
  # Per code-review of #291: -a would delete the idle gha-runner image, so only these three are allowed.
  grep -Eq 'container prune -f --filter until=24h' "$ST/docker.log" || { echo "no container prune"; return 1; }
  grep -Eq 'builder prune -af --filter until=24h' "$ST/docker.log" || { echo "no builder prune"; return 1; }
  grep -Eq 'image prune -f( |$)' "$ST/docker.log" || { echo "no dangling image prune"; return 1; }
}
t "hygiene prunes containers/build cache >24h and dangling images" test_hy_prunes
test_hy_keeps_image() {
  newenv; bash "$SETUP" >/dev/null 2>&1; : > "$ST/docker.log"; hygiene_run || return 1
  [ -s "$ST/docker.log" ] || { echo "hygiene ran no docker command"; return 1; }
  # no image-removing -a prune: neither `system prune -a*` nor `image prune -a*`
  ! grep -Eq '(system|image) prune .*-[a-z]*a' "$ST/docker.log" || { echo "prune -a would delete gha-runner image"; return 1; }
  ! grep -Eq '(system|image) prune .*--all' "$ST/docker.log" || { echo "prune --all would delete gha-runner image"; return 1; }
  ! grep -Eq '(system|image) prune .*-[a-z]*a' "$(HY)" || { echo "rendered hygiene script has prune -a"; return 1; }
}
t "hygiene never runs an image-removing prune -a (keeps gha-runner image)" test_hy_keeps_image

# ---- observability ---------------------------------------------------------------------------
event_ok() { # asserts exactly one event with release/environment/route tags and no secrets
  [ "$(sentry_events)" -eq 1 ] || { echo "events=$(sentry_events), want 1"; return 1; }
  local ev; ev=$({ cat "$ST/sentry-cli.log" 2>/dev/null; grep -i sentry "$ST/curl.log" 2>/dev/null; })
  grep -qi 'release' <<<"$ev" && grep -qF 'ci-runner' <<<"$ev" && grep -qi 'route' <<<"$ev" \
    || { echo "missing release/environment/route tag"; return 1; }
  grep -qiE 'release[^0-9a-f]{1,6}[0-9a-f]{7,40}' <<<"$ev" || { echo "release is not a commit sha"; return 1; }
  ! grep -qF "$SENT" <<<"$ev" || { echo "token in event"; return 1; }
  ! grep -qF SENTINELHOOK <<<"$ev" || { echo "webhook in event"; return 1; }
}
test_obs_mint() {
  newenv; setup_dsn; setup_alert; bash "$SETUP" --mint-from-stdin <<<"$SENT" >/dev/null 2>&1
  : > "$ST/curl.log"; : > "$ST/sentry-cli.log"
  export STUB_MINT_FAIL=1
  bash "$R/usr/local/sbin/gha-slot.sh" 1 >"$TMP/l.out" 2>"$TMP/l.err"; local rc=$?
  [ $rc -ne 0 ] || { echo "launcher exited 0 on mint failure"; return 1; }
  event_ok || return 1
  grep -qF "$SENT" "$TMP/l.out" "$TMP/l.err" && { echo "token in launcher output"; return 1; }
  [ "$(hook_posts)" -ge 1 ] || { echo "no Slack alert on mint failure"; return 1; }
}
t "obs: launcher mint failure -> 1 event with tags, no secrets, Slack alert" test_obs_mint
test_obs_prune() {
  newenv; setup_dsn; setup_alert; bash "$SETUP" >/dev/null 2>&1
  : > "$ST/curl.log"; : > "$ST/sentry-cli.log"
  export STUB_DOCKER_PRUNE_FAIL=1 STUB_DF_PCT=10
  bash "$(HY)" >"$TMP/h.out" 2>&1; [ $? -ne 0 ] || { echo "hygiene exited 0 on prune failure"; return 1; }
  event_ok
}
t "obs: prune failure -> 1 event with tags, no secrets" test_obs_prune
test_obs_setup() {
  newenv; setup_dsn; export STUB_USERADD_FAIL=1
  rm -f "$ST/user"
  bash "$SETUP" >"$TMP/s.out" 2>"$TMP/s.err"; local rc=$?
  [ $rc -ne 0 ] || { echo "setup exited 0 on step failure"; return 1; }
  event_ok
}
t "obs: setup step failure -> 1 event with tags" test_obs_setup
test_obs_nodsn() {
  newenv; export STUB_USERADD_FAIL=1; rm -f "$ST/user"
  bash "$SETUP" >"$TMP/s.out" 2>&1; local rc=$?
  [ $rc -ne 0 ] && [ -e "$ST/useradd.log" ] || return 1
  [ "$(sentry_events)" -eq 0 ] && ! grep -qi 'sentry' "$TMP/s.out"
}
t "obs: no DSN file -> Sentry skipped silently, failure still non-zero" test_obs_nodsn

# ---- README ----------------------------------------------------------------------------------
for kw in 'mint.env' 'alert.env' '--probe' 'benjis-ci' 'CI_RUNNER_JSON' 'rollback' '--check' '--slots'; do
  t "README mentions $kw" grep -qiF -- "$kw" "$README"
done

# ---- repo hygiene ----------------------------------------------------------------------------
test_no_agents() { [ -z "$(git -C "$REPO" ls-files '.claude/agents' | grep -v '^.claude/agents/deployer.md$')" ]; }
t "no .claude/agents files added" test_no_agents
test_no_pkg() {
  local base; base=$(git -C "$REPO" merge-base HEAD origin/main 2>/dev/null) || return 0
  ! git -C "$REPO" diff --name-only "$base" HEAD | grep -qE '(^|/)package\.json$'
}
t "package.json untouched" test_no_pkg

echo "# $n checks, $fails failed"
[ $fails -eq 0 ]
