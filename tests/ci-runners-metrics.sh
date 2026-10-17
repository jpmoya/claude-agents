#!/usr/bin/env bash
# Tests for the CI metrics logging (claude-agents#355, goal "Cut CI job costs"): host sampler, runner-life log,
# log trimming, and ci-report.sh. No root, Docker, network or runner; host commands are stubs.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$REPO/infra/ci-runners/setup.sh"
REPORT="$REPO/infra/ci-runners/ci-report.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
R=$TMP/root S=$TMP/state B=$TMP/stubs; mkdir -p "$R" "$S" "$B"
for c in docker systemctl useradd getent loginctl runuser chown df pgrep; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/%s.log"\n' "$c" "$S" "$c" > "$B/$c"; chmod +x "$B/$c"
done
cat > "$B/curl" <<STUB
#!/usr/bin/env bash
cat >/dev/null; echo '{"encoded_jit_config":"JITCFG"}'
STUB
cat > "$B/id" <<'STUB'
#!/usr/bin/env bash
echo 1234
STUB
cat > "$B/df" <<'STUB'
#!/usr/bin/env bash
printf 'Use%%\n 61%%\n'
STUB
cat > "$B/systemctl" <<STUB
#!/usr/bin/env bash
# minimal state: enable/disable create or remove a marker, is-enabled reads it, list-units shows two active slots
case "\$1" in
  list-units) echo "gha-slot@1.service loaded active running x"; echo "gha-slot@2.service loaded active running x";;
  enable) for a in "\$@"; do case "\$a" in gha-*) touch "$S/en.\${a%.service}";; esac; done;;
  disable) for a in "\$@"; do case "\$a" in gha-*) rm -f "$S/en.\${a%.service}";; esac; done;;
  is-enabled) [ -e "$S/en.\${2%.service}" ] && { echo enabled; exit 0; } || { echo disabled; exit 1; };;
esac
exit 0
STUB
cat > "$B/pgrep" <<'STUB'
#!/usr/bin/env bash
echo 1
STUB
chmod +x "$B"/*
export GHA_ROOT=$R GHA_DRY_STUBS=$B
fails=0
chk() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
mkdir -p "$R/etc/gha" "$R/usr/local/lib/gha"
printf 'GHA_MINT_TOKEN=TOK999\nGHA_RUNNER_SCOPE=orgs/acme\n' > "$R/etc/gha/mint.env"
bash "$SETUP" >"$TMP/setup.out" 2>&1 || cat "$TMP/setup.out"

# ---- installed pieces ---------------------------------------------------------------------------
chk "setup installs the sampler, its unit and a minutely timer" \
  "[ -x $R/usr/local/sbin/gha-metrics.sh ] && grep -q 'OnCalendar=minutely' $R/etc/systemd/system/gha-metrics.timer && [ -f $R/etc/systemd/system/gha-metrics.service ]"
chk "setup creates the metrics log dir" "[ -d $R/var/log/gha ]"

# ---- sampler ------------------------------------------------------------------------------------
mkdir -p "$R/proc" "$R/sys/fs/cgroup/user.slice/user-1234.slice"
cat > "$R/proc/meminfo" <<'M'
MemTotal:        8000000 kB
MemAvailable:    3145728 kB
SwapTotal:       4194304 kB
SwapFree:        4096000 kB
M
echo "1.50 1.20 1.00 1/200 123" > "$R/proc/loadavg"
echo "cpu  1000 0 1000 8000 0 0 0 0 0 0" > "$R/proc/stat"
echo 2147483648 > "$R/sys/fs/cgroup/user.slice/user-1234.slice/memory.current"
printf 'low 0\nhigh 0\nmax 0\noom 1\noom_kill 3\n' > "$R/sys/fs/cgroup/user.slice/user-1234.slice/memory.events"
M="$R/usr/local/sbin/gha-metrics.sh"; CSV="$R/var/log/gha/host.csv"
bash "$M"; first=$(sed -n 2p "$CSV")
chk "sampler writes header + one row" "[ \$(wc -l < $CSV) -eq 2 ] && head -1 $CSV | grep -q '^ts,memavail_mb,'"
chk "row: free mem 3072MB, swap used 96MB, load 1.50, disk 61, gha mem 2048MB, 3 oom kills, 2 slots, 1 job" \
  "echo '$first' | grep -Eq '^[0-9T:Z-]+,3072,96,1.50,0.0,61,2048,3,2,1$'"
echo "cpu  1000 0 1000 9000 0 0 100 100 0 0" > "$R/proc/stat"    # +1200 total, +100 steal -> 8.3%
bash "$M"
chk "steal % is the delta since the last sample" "sed -n 3p $CSV | cut -d, -f5 | grep -q '^8.3\$'"
chk "sampler never prints secrets (no token in the csv)" "! grep -q TOK999 $CSV"

# ---- runner-life log ----------------------------------------------------------------------------
bash "$R/usr/local/sbin/gha-slot.sh" 1 >/dev/null 2>&1
J="$R/var/log/gha/jobs.jsonl"
chk "launcher logs one JSON line per runner life with rc 0" \
  "[ \$(wc -l < $J) -eq 1 ] && jq -e '.slot==1 and .rc==0 and (.runner|startswith(\"gha-\")) and (.life_seconds>=0)' $J >/dev/null"
printf '#!/usr/bin/env bash\necho "docker $*" >> "%s/docker.log"\n[ "$1" = run ] && exit 137\nexit 0\n' "$S" > "$B/docker"; chmod +x "$B/docker"
bash "$R/usr/local/sbin/gha-slot.sh" 2 >/dev/null 2>&1; rc=$?
chk "a killed runner (137) is logged with rc 137 and the launcher still exits 137" "[ $rc -eq 137 ] && tail -1 $J | jq -e '.rc==137 and .slot==2' >/dev/null"
chk "no token or JIT config in the job log" "! grep -Eq 'TOK999|JITCFG' $J"

# ---- trimming -----------------------------------------------------------------------------------
{ echo "ts,memavail_mb,swap_used_mb,load1,steal_pct,disk_pct,gha_mem_mb,gha_oom_kills,slots_up,jobs_running"; for i in $(seq 1 25000); do echo "t$i,1,1,1,1,1,1,0,2,1"; done; } > "$CSV"
for i in $(seq 1 6000); do echo "{\"n\":$i}" >> "$J"; done
bash "$R/usr/local/sbin/gha-hygiene.sh" >/dev/null 2>&1
chk "hygiene keeps the csv header and the newest 20160 samples" \
  "[ \$(wc -l < $CSV) -eq 20161 ] && head -1 $CSV | grep -q '^ts,' && tail -1 $CSV | grep -q '^t25000,'"
chk "hygiene keeps the newest 5000 runner lives" "[ \$(wc -l < $J) -eq 5000 ] && tail -1 $J | grep -q '\"n\":6000'"

# ---- ci-report ----------------------------------------------------------------------------------
mkdir -p "$TMP/h"
printf 'ts,memavail_mb,swap_used_mb,load1,steal_pct,disk_pct,gha_mem_mb,gha_oom_kills,slots_up,jobs_running\na,3000,0,2.0,0.5,60,1200,0,2,1\nb,600,10,9.5,12.0,86,6000,1,2,2\nc,2500,10,3.1,1.0,86,2000,1,2,2\n' > "$TMP/h/box.csv"
cat > "$TMP/jobs.jsonl" <<'F'
{"repo":"o/scheduler","name":"unit-tests","runner":"gha-a","labels":"self-hosted,benjis-ci","conclusion":"success","created":"2026-10-17T09:48:54Z","started":"2026-10-17T10:05:13Z","completed":"2026-10-17T10:28:13Z"}
{"repo":"o/scheduler","name":"migration-rehearsal","runner":"gha-a","labels":"self-hosted,benjis-ci","conclusion":"success","created":"2026-10-17T10:05:00Z","started":"2026-10-17T10:31:01Z","completed":"2026-10-17T10:32:01Z"}
{"repo":"o/quoting","name":"Quality","runner":"GitHub Actions 1","labels":"ubuntu-latest","conclusion":"success","created":"2026-10-17T09:00:00Z","started":"2026-10-17T09:00:05Z","completed":"2026-10-17T09:04:05Z"}
F
OUT=$(CI_REPORT_JOBS_FILE="$TMP/jobs.jsonl" CI_REPORT_HOST_DIR="$TMP/h" bash "$REPORT" --days 7 2>&1)
chk "report: separates self-hosted from hosted jobs" "grep -q '== self-hosted ==' <<<\"\$OUT\" && grep -q '== hosted ==' <<<\"\$OUT\""
chk "report: shows the 26 min queue wait for migration-rehearsal" "grep -Eq 'migration-rehearsal.* 26m' <<<\"\$OUT\""
chk "report: names the longest wait as the top bottleneck" "grep -q 'longest wait for a runner slot: migration-rehearsal waited 26 min' <<<\"\$OUT\""
chk "report: host line has peak memory, steal and oom kills" "grep -q 'peak_gha_mem=6000MB.*peak_steal=12.0%.*oom_kills=1' <<<\"\$OUT\""
chk "report: suggests memory-bound, noisy CPU and add-a-slot from the samples" \
  "grep -q 'memory-bound' <<<\"\$OUT\" && grep -q 'shared cores are noisy' <<<\"\$OUT\" && grep -q 'add a slot' <<<\"\$OUT\""
chk "report: rejects an unknown flag" "! bash $REPORT --nope >/dev/null 2>&1"
[ $fails -eq 0 ]
