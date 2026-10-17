#!/usr/bin/env bash
# Tests for #356 (scripts/ci-metrics.sh). No network: `gh` and `curl` are stubbed on PATH.
#
# CLI CONTRACT these tests lock in (the ticket leaves the interface open):
#   scripts/ci-metrics.sh collect   fetch jobs completed in the last 26 h, append new ones to
#                                   $CI_METRICS_DATA_DIR/ci-jobs.jsonl, trim lines older than 90 d
#   scripts/ci-metrics.sh rollup    read ci-jobs.jsonl, write $CI_METRICS_DATA_DIR/ci-daily.json
#   scripts/ci-metrics.sh weekly    read ci-daily.json, POST one Slack message to $SLACK_WEBHOOK_URL
# Env: CI_METRICS_DATA_DIR, CI_METRICS_REPOS (config file: one owner/repo per line + SLOTS=<n>),
#      CI_METRICS_NOW (epoch, fixed clock), CI_METRICS_RELEASE (commit SHA), CI_METRICS_ENVIRONMENT,
#      GH_TOKEN, SLACK_WEBHOOK_URL, SENTRY_DSN (https://<key>@<host>/<project>).
# gh API used: `gh api repos/<o>/<r>/actions/runs...` and `gh api repos/<o>/<r>/actions/runs/<id>/jobs...`
#   (responses {"workflow_runs":[...]} / {"jobs":[...]}); curl is used for Slack and Sentry
#   (Sentry store endpoint, same pattern as infra/ci-runners/setup.sh gha_report).
# Definitions: ts = job completed_at; queue_s = started_at - created_at (job); run_s = completed_at -
#   started_at; result = job conclusion; each line may carry an extra `job_id` (used for dedupe).
#   Self-hosted runner = runner_name not starting with "GitHub Actions". Percentile = nearest-rank
#   (ceil(p*n)-th smallest); median of an even count = mean of the two middle values.
#   rollup keys: jobs.<name>.{run_s_median,run_s_p90,queue_s_median,queue_s_p90}, longest_queue_s,
#   jobs_per_runner.<runner>, slot_busy_pct (number, 0-100).
#   weekly reads ci-daily.json only; queue p90 = max over jobs of queue_s_p90; busy = slot_busy_pct;
#   job median = max over jobs of run_s_median; rules strict ">" and checked in order add slot, split job.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT=$REPO/scripts/ci-metrics.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
B=$TMP/bin; S=$TMP/state; FIX=$TMP/fix; mkdir -p "$B" "$S" "$FIX"
fails=0
chk() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

NOW=$(jq -n '"2026-10-17T12:00:00Z"|fromdateiso8601')
iso() { jq -rn --argjson n "$NOW" --argjson o "$1" '($n+$o)|todate'; }
TOKEN=ghp_SECRETTOKEN123
HOOK=https://hooks.slack.test/services/T000/B000/SECRETHOOK
DSN=https://pubkey@sentry.test/42

# ---- stubs ----------------------------------------------------------------
cat > "$B/gh" <<'STUB'
#!/usr/bin/env bash
a="$*"
if [ -n "${GH_STUB_FAIL:-}" ] && { [ -z "${GH_STUB_FAIL_MATCH:-}" ] || [[ $a == *"$GH_STUB_FAIL_MATCH"* ]]; }; then
  echo "gh: HTTP $GH_STUB_FAIL: Forbidden" >&2; exit 1
fi
[ -z "${GH_STUB_EMPTY:-}" ] || exit 0
if [[ $a =~ actions/runs/([0-9]+)/jobs ]]; then cat "$GH_STUB_FIX/jobs-${BASH_REMATCH[1]}.json"
elif [[ $a =~ repos/([^/]+)/([^/\ ?]+)/actions/runs ]]; then cat "$GH_STUB_FIX/runs-${BASH_REMATCH[1]}__${BASH_REMATCH[2]}.json"
else echo "gh stub: unexpected call: $a" >&2; exit 2; fi
STUB
cat > "$B/curl" <<'STUB'
#!/usr/bin/env bash
n=$(ls "$CURL_STATE" | grep -c '\.argv$'); n=$((n+1))
printf '%s\n' "$@" > "$CURL_STATE/$n.argv"
body=""; url=""
while [ $# -gt 0 ]; do
  case $1 in -d|--data|--data-binary|--data-raw) body=$2; shift;; http*) url=$1;; esac; shift
done
printf '%s' "$url" > "$CURL_STATE/$n.url"; printf '%s' "$body" > "$CURL_STATE/$n.body"
STUB
chmod +x "$B/gh" "$B/curl"
export PATH="$B:$PATH" GH_STUB_FIX=$FIX CURL_STATE=$S

# ---- fixtures -------------------------------------------------------------
cat > "$TMP/repos" <<'EOF'
acme/app
acme/lib
SLOTS=4
EOF
job() { # id name status conclusion created_off started_off|null completed_off|null runner
  jq -n --argjson id "$1" --arg name "$2" --arg st "$3" --arg c "$4" --arg cr "$(iso "$5")" \
    --arg s "$([ "$6" = null ] && echo null || iso "$6")" --arg e "$([ "$7" = null ] && echo null || iso "$7")" --arg r "$8" \
    '{id:$id,name:$name,status:$st,conclusion:(if $c=="null" then null else $c end),created_at:$cr,
      started_at:(if $s=="null" then null else $s end),completed_at:(if $e=="null" then null else $e end),
      runner_name:(if $r=="null" then null else $r end)}'
}
mkfix() {
  jq -n '{workflow_runs:[{id:101,name:"CI",status:"completed",conclusion:"failure"},{id:102,name:"CI",status:"in_progress",conclusion:null}]}' > "$FIX/runs-acme__app.json"
  jq -n '{workflow_runs:[{id:201,name:"Lint",status:"completed",conclusion:"success"}]}' > "$FIX/runs-acme__lib.json"
  # j1001 build: queue 30, run 125.  j1002 test: queue 600, run 900, failure.
  # j1004 skipped, j1005 cancelled before start (started_at null), j1003 in progress (run 102).
  # j1007 completed 27 h ago (outside 26 h window); j1008 completed 25 h ago (inside), queue 100, run 900.
  jq -s '{jobs:.}' \
    <(job 1001 build completed success -3600 -3570 -3445 gha-1) \
    <(job 1002 test completed failure -3600 -3000 -2100 gha-2) \
    <(job 1004 deploy completed skipped -3600 -3600 -3600 null) \
    <(job 1005 e2e completed cancelled -3600 null -3500 null) \
    <(job 1007 build completed success -98000 -97900 -97200 gha-1) \
    <(job 1008 build completed success -91000 -90900 -90000 gha-1) > "$FIX/jobs-101.json"
  jq -s '{jobs:.}' <(job 1003 build in_progress null -3000 -2900 null gha-1) > "$FIX/jobs-102.json"
  jq -s '{jobs:.}' <(job 2001 lint completed success -500 -495 -485 "GitHub Actions 7") > "$FIX/jobs-201.json"
}
mkfix
newenv() { # fresh data dir + env
  D=$TMP/data.$RANDOM; mkdir -p "$D"; rm -f "${S:?}"/*
  export CI_METRICS_DATA_DIR=$D CI_METRICS_REPOS=$TMP/repos CI_METRICS_NOW=$NOW GH_TOKEN=$TOKEN \
    SLACK_WEBHOOK_URL=$HOOK SENTRY_DSN=$DSN CI_METRICS_RELEASE=abc123def456 CI_METRICS_ENVIRONMENT=ci-metrics-test
  unset GH_STUB_FAIL GH_STUB_FAIL_MATCH GH_STUB_EMPTY
}
J() { echo "$D/ci-jobs.jsonl"; }

# ---- AC1: correct fields; skips in-progress / skipped / cancelled-before-start --------
newenv
bash "$SCRIPT" collect >"$TMP/out" 2>"$TMP/err"; rc=$?
chk "AC1 collect exits 0" "[ $rc -eq 0 ]"
chk "AC1 four jobs recorded (1001,1002,1008,2001)" "[ \"\$(jq -s -c '[.[].job_id]|sort' $(J) 2>/dev/null)\" = '[1001,1002,1008,2001]' ]"
q() { jq -s -r --argjson id "$1" ".[]|select(.job_id==\$id)|$2" "$(J)" 2>/dev/null; }
chk "AC1 build queue_s=30" "[ \"\$(q 1001 .queue_s)\" = 30 ]"
chk "AC1 build run_s=125" "[ \"\$(q 1001 .run_s)\" = 125 ]"
chk "AC1 test queue_s=600 run_s=900" "[ \"\$(q 1002 '[.queue_s,.run_s]|@csv')\" = '600,900' ]"
chk "AC1 test result=failure" "[ \"\$(q 1002 .result)\" = failure ]"
chk "AC1 repo/workflow/job/runner fields" "[ \"\$(q 1001 '[.repo,.workflow,.job,.runner_name]|join(\"|\")')\" = 'acme/app|CI|build|gha-1' ]"
chk "AC1 ts = completed_at" "[ \"\$(q 1001 .ts)\" = '$(iso -3445)' ]"
chk "AC1 second repo job captured" "[ \"\$(q 2001 '[.repo,.workflow,.job,.queue_s,.run_s]|join(\"|\")')\" = 'acme/lib|Lint|lint|5|10' ]"
chk "AC1 in-progress job skipped" "[ -s $(J) ] && [ -z \"\$(q 1003 .job)\" ]"
chk "AC1 skipped job skipped" "[ -s $(J) ] && [ -z \"\$(q 1004 .job)\" ]"
chk "AC1 cancelled-before-start (null started_at) skipped" "[ -s $(J) ] && [ -z \"\$(q 1005 .job)\" ]"
chk "AC1 job completed 27h ago outside window" "[ -s $(J) ] && [ -z \"\$(q 1007 .job)\" ]"
chk "AC1 job completed 25h ago inside window" "[ \"\$(q 1008 .run_s)\" = 900 ]"

# ---- AC2: dedupe -----------------------------------------------------------
cp "$(J)" "$TMP/first.jsonl" 2>/dev/null
bash "$SCRIPT" collect >/dev/null 2>&1; rc=$?
chk "AC2 re-run exits 0" "[ $rc -eq 0 ]"
chk "AC2 re-run appends nothing" "[ -s $(J) ] && cmp -s $(J) $TMP/first.jsonl && [ \$(wc -l < $(J)) -eq 4 ]"

# ---- AC5: retention (90 days) ---------------------------------------------
newenv
old=$(iso -$((90*86400+60))); keep=$(iso -$((90*86400-60)))
printf '{"ts":"%s","repo":"acme/app","workflow":"CI","job":"old","runner_name":"gha-1","result":"success","queue_s":1,"run_s":1,"job_id":9001}\n{"ts":"%s","repo":"acme/app","workflow":"CI","job":"keep","runner_name":"gha-1","result":"success","queue_s":1,"run_s":1,"job_id":9002}\n' "$old" "$keep" > "$(J)"
bash "$SCRIPT" collect >/dev/null 2>&1; rc=$?
chk "AC5 collect exits 0" "[ $rc -eq 0 ]"
chk "AC5 line 90d+60s old trimmed" "! grep -q '\"job_id\":9001' $(J)"
chk "AC5 line 90d-60s old kept" "[ $rc -eq 0 ] && grep -q '\"job_id\":9002' $(J)"
chk "AC5 new jobs still appended" "grep -q '\"job_id\":1001' $(J)"

# ---- AC3: rollup against hand-computed values -----------------------------
newenv
t=$(iso -3600)
row() { printf '{"ts":"%s","repo":"acme/app","workflow":"CI","job":"%s","runner_name":"%s","result":"success","queue_s":%s,"run_s":%s,"job_id":%s}\n' "$t" "$1" "$2" "$3" "$4" "$5"; }
{ # build on gha-1: run 60,120,180,240,300 queue 10..50 -> sum run 900
  row build gha-1 10 60 1; row build gha-1 20 120 2; row build gha-1 30 180 3; row build gha-1 40 240 4; row build gha-1 50 300 5
  # test on gha-2: one job, run 33660, queue 400 (longest wait)
  row test gha-2 400 33660 6
  # lint on a GitHub-hosted runner: counted per runner, excluded from busy %
  row lint "GitHub Actions 3" 5 500 7
} > "$(J)"
# hand arithmetic: build run median=180, p90=ceil(.9*5)=5th=300; queue median=30, p90=50.
# busy = (900+33660)/(4 slots*86400) = 34560/345600 = 10 %.
bash "$SCRIPT" rollup >/dev/null 2>&1; rc=$?
R=$D/ci-daily.json
chk "AC3 rollup exits 0" "[ $rc -eq 0 ]"
chk "AC3 build run_s median 180 / p90 300" "[ \"\$(jq -c '.jobs.build|[.run_s_median,.run_s_p90]' $R 2>/dev/null)\" = '[180,300]' ]"
chk "AC3 build queue_s median 30 / p90 50" "[ \"\$(jq -c '.jobs.build|[.queue_s_median,.queue_s_p90]' $R 2>/dev/null)\" = '[30,50]' ]"
chk "AC3 single-sample job: median=p90" "[ \"\$(jq -c '.jobs.test|[.run_s_median,.run_s_p90,.queue_s_p90]' $R 2>/dev/null)\" = '[33660,33660,400]' ]"
chk "AC3 longest queue wait 400" "[ \"\$(jq '.longest_queue_s' $R 2>/dev/null)\" = 400 ]"
chk "AC3 jobs per runner" "[ \"\$(jq -c '.jobs_per_runner|[.[\"gha-1\"],.[\"gha-2\"],.[\"GitHub Actions 3\"]]' $R 2>/dev/null)\" = '[5,1,1]' ]"
chk "AC3 slot busy 10%" "jq -e '(.slot_busy_pct-10)|fabs<0.01' $R >/dev/null 2>&1"
# even-count median: run 10,20,30,40 -> 25
{ row even gha-1 1 10 1; row even gha-1 1 20 2; row even gha-1 1 30 3; row even gha-1 1 40 4; } > "$(J)"
bash "$SCRIPT" rollup >/dev/null 2>&1
chk "AC3 even-count median is mean of middle two (25)" "[ \"\$(jq '.jobs.even.run_s_median' $R 2>/dev/null)\" = 25 ]"

# ---- AC4: weekly message ---------------------------------------------------
daily() { # build_q90 busy test_median
  jq -n --argjson q "$1" --argjson b "$2" --argjson m "$3" '{
    jobs:{build:{run_s_median:100,run_s_p90:150,queue_s_median:10,queue_s_p90:$q},
          test:{run_s_median:$m,run_s_p90:($m+50),queue_s_median:5,queue_s_p90:20}},
    longest_queue_s:($q+10),jobs_per_runner:{"gha-1":9,"gha-2":2},slot_busy_pct:$b}' > "$D/ci-daily.json"
}
weekly_case() { # name q90 busy median expected
  newenv; daily "$2" "$3" "$4"
  bash "$SCRIPT" weekly >"$TMP/out" 2>"$TMP/err"; rc=$?
  msg=$(jq -r '.text' "$S/1.body" 2>/dev/null)
  chk "AC4 $1: exits 0, one POST to the webhook only" "[ $rc -eq 0 ] && [ \$(ls $S | grep -c '\.url\$') -eq 1 ] && [ \"\$(cat $S/1.url)\" = '$HOOK' ]"
  chk "AC4 $1: suggestion is '$5'" "[[ \"\$msg\" == *'$5'* ]]"
  chk "AC4 $1: <= 15 lines" "[ -n \"\$msg\" ] && [ \$(printf '%s\n' \"\$msg\" | wc -l) -le 15 ]"
  for other in "add slot" "split job" "no change"; do
    [ "$other" = "$5" ] || chk "AC4 $1: does not say '$other'" "[ -n \"\$msg\" ] && [[ \"\$msg\" != *'$other'* ]]"
  done
}
weekly_case "queue p90 300s busy 75%" 300 75 100 "add slot"
weekly_case "median job 700s" 30 20 700 "split job"
weekly_case "all quiet" 30 20 100 "no change"
weekly_case "boundary queue p90 =120 (not >)" 120 75 100 "no change"
weekly_case "boundary busy =60 (not >)" 300 60 100 "no change"
weekly_case "boundary median =600 (not >)" 30 20 600 "no change"
weekly_case "both rules fire: add slot wins" 300 75 700 "add slot"
newenv; daily 300 75 700; bash "$SCRIPT" weekly >/dev/null 2>&1; msg=$(jq -r '.text' "$S/1.body" 2>/dev/null)
chk "AC4 message names worst-queue job (build), longest-median job (test), busiest runner (gha-1)" "[[ \"\$msg\" == *build* && \"\$msg\" == *test* && \"\$msg\" == *gha-1* ]]"
chk "AC6 message has no token/webhook" "[ -n \"\$msg\" ] && [[ \"\$msg\" != *$TOKEN* && \"\$msg\" != *SECRETHOOK* ]]"

# ---- AC6/AC8: failures -----------------------------------------------------
newenv; export GH_STUB_FAIL=403
bash "$SCRIPT" collect >"$TMP/out" 2>"$TMP/err"; rc=$?
chk "AC6 403: exits non-zero (and not the stub's 99)" "[ $rc -ne 0 ] && [ $rc -ne 99 ]"
chk "AC6 403: nothing written" "grep -q 403 $TMP/err && [ ! -s $(J) ] && [ ! -e $D/ci-daily.json ]"
chk "AC6 403: error captured on stderr" "grep -q 403 $TMP/err"
chk "AC6 403: no secrets in stdout/stderr" "grep -q 403 $TMP/err && ! grep -q -e $TOKEN -e SECRETHOOK $TMP/out $TMP/err"
sb=""; for f in "$S"/*.url; do [ -e "$f" ] && [ "$(cat "$f")" = "https://sentry.test/api/42/store/" ] && sb=${f%.url}.body; done
chk "AC8 403: Sentry event POSTed to the DSN project store endpoint" "[ -n '$sb' ]"
chk "AC8 Sentry route tag ci-metrics/collect" "[ \"\$(jq -r '.tags.route' '$sb' 2>/dev/null)\" = ci-metrics/collect ]"
chk "AC8 Sentry release = commit SHA" "[ \"\$(jq -r '.release' '$sb' 2>/dev/null)\" = abc123def456 ]"
chk "AC8 Sentry environment" "[ \"\$(jq -r '.environment' '$sb' 2>/dev/null)\" = ci-metrics-test ]"
chk "AC8 Sentry event has no secrets" "[ -f '$sb' ] && ! grep -q -e $TOKEN -e SECRETHOOK '$sb'"
chk "AC8 alert goes to the existing Slack webhook" "grep -qx '$HOOK' $S/*.url 2>/dev/null || cat $S/*.url 2>/dev/null | grep -qx '$HOOK'"
chk "AC8 Slack alert body has no secrets" "cat $S/*.url >/dev/null 2>&1 && ! grep -q $TOKEN $S/*.body"
chk "AC8 no destination other than Sentry + webhook" "ls $S/*.url >/dev/null 2>&1 && ! cat $S/*.url | tr -s '\n' | grep -v -x -e 'https://sentry.test/api/42/store/' -e '$HOOK' | grep -q ."

newenv; export GH_STUB_EMPTY=1
bash "$SCRIPT" collect >"$TMP/out" 2>"$TMP/err"; rc=$?
chk "AC6 empty API response: non-zero exit, nothing written" "[ $rc -ne 0 ] && [ $rc -ne 99 ] && [ ! -s $(J) ]"
chk "AC6 empty API response: error text captured" "[ \$(wc -c < $TMP/err) -gt 0 ] && ! grep -q NotImplemented $TMP/err"

newenv; export GH_STUB_FAIL=403 GH_STUB_FAIL_MATCH=acme/lib   # first repo ok, second repo 403
bash "$SCRIPT" collect >/dev/null 2>"$TMP/err"; rc=$?
chk "AC6 failure on 2nd repo: non-zero, nothing written for the 1st either" "[ $rc -ne 0 ] && grep -q 403 $TMP/err && [ ! -s $(J) ]"

newenv; printf 'KEEP\n' > "$(J)"; export GH_STUB_FAIL=403
bash "$SCRIPT" collect >/dev/null 2>"$TMP/err"
chk "AC6 existing jsonl untouched on failure" "grep -q 403 $TMP/err && [ \"\$(cat $(J))\" = KEEP ]"

newenv; rm -f "$D/ci-jobs.jsonl"
bash "$SCRIPT" rollup >/dev/null 2>"$TMP/err"; rc=$?
chk "AC8 rollup with no data: non-zero, no rollup file" "[ $rc -ne 0 ] && [ $rc -ne 99 ] && [ ! -e $D/ci-daily.json ]"
chk "AC8 rollup Sentry route ci-metrics/rollup" "[ \"\$(jq -r '.tags.route' $S/1.body 2>/dev/null)\" = ci-metrics/rollup ]"
newenv; rm -f "$D/ci-daily.json"
bash "$SCRIPT" weekly >/dev/null 2>&1; rc=$?
chk "AC8 weekly with no rollup: non-zero" "[ $rc -ne 0 ] && [ $rc -ne 99 ]"
chk "AC8 weekly Sentry route ci-metrics/weekly" "grep -l 'ci-metrics/weekly' $S/*.body >/dev/null 2>&1"

# ---- AC6: secrets never land in data files on success ----------------------
newenv; bash "$SCRIPT" collect >/dev/null 2>&1; bash "$SCRIPT" rollup >/dev/null 2>&1
chk "AC6 token/webhook absent from jsonl and rollup" "[ -s $(J) ] && [ -s $D/ci-daily.json ] && ! grep -q -e $TOKEN -e SECRETHOOK $(J) $D/ci-daily.json"

# ---- AC7: workflow ---------------------------------------------------------
W=$REPO/.github/workflows/ci-metrics.yml
perm=$([ -f "$W" ] && awk '/^permissions:/{p=1;next} p&&/^[^ ]/{p=0} p&&NF{gsub(/^ +| +$/,"");print}' "$W" | sort | tr '\n' '|')
chk "AC7 workflow file exists" "[ -f $W ]"
chk "AC7 actionlint clean" "[ -f $W ] && actionlint $W"
chk "AC7 permissions exactly contents: write, actions: read" "[ '$perm' = 'actions: read|contents: write|' ]"
chk "AC7 daily schedule (cron with * * * day fields)" "[ -f $W ] && grep -Eq 'cron: *.[0-9*/, -]+ [0-9*/, -]+ \\* \\* \\*' $W"
chk "AC7 runs on ubuntu-latest, never self-hosted" "[ -f $W ] && grep -q 'runs-on: *ubuntu-latest' $W && ! grep -q self-hosted $W"
chk "AC7 runs scripts/ci-metrics.sh" "[ -f $W ] && grep -q 'scripts/ci-metrics.sh' $W"
chk "AC7 cross-repo token comes from a secret" "[ -f $W ] && grep -Eq 'GH_TOKEN: *\\$\\{\\{ *secrets\\.' $W"

# AC9: pre-existing tests stay green (run separately; not re-baselined here).
[ $fails -eq 0 ]
