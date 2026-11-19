#!/bin/bash
# where-things-run.sh — where do the app repos' CI jobs EXECUTE, read live from GitHub (never from workflow YAML or comments).
#
# Run this BEFORE stating where a job runs. A workflow's `runs-on: fromJSON(vars.X || '"ubuntu-latest"')` only says what happens if
# X is unset or empty; whether that fallback is live is a fact about the repo/org variables, which this prints. GitHub Actions
# only TRIGGERS and orchestrates the jobs (pull_request, push, workflow_run, schedule); the runners listed here EXECUTE them.
#
# Read-only: GET calls only (repo variables, org variables visible to the repo, repo runners, org runners). Only the runner
# variables named below are read, never the other variables. 3 calls per repo + 1 org call per owner.
#
# Output per repo: each runner variable with its source (repo overrides org), what it resolves to, and how many online
# runners carry its labels; then the runner list. Lines starting `FLAG:` are problems:
#   - a variable is unset or empty  -> the workflow's YAML fallback (often GitHub-hosted `ubuntu-latest`) WOULD apply
#   - a variable points at a GitHub-hosted label
#   - a set variable has no online runner with its labels -> jobs QUEUE, they do not fall back to GitHub-hosted
#   - a runner is offline (self-hosted runners are ephemeral and re-register between jobs: re-run once before believing it)
# Exit: 0 = no flags, 1 = at least one FLAG, 2 = could not read GitHub (rate limit? missing admin:org scope?): NO verdict,
# never reported as "unset".
#
# Usage: where-things-run.sh [owner/repo:VAR1,VAR2+bulk ...]
# Env (tests): WTR_GH (gh binary, default gh), WTR_TARGETS (default targets, space separated, same spec as the arguments).
# bash 3.2 compatible.
set -u

GH="${WTR_GH:-gh}"
# What each repo's workflows actually read (checked on each repo's main and staging branches, 2026-11-19). The sales tool does
# not read HOSTED_JOBS_RUNNER_JSON, so it is not required there.
DEFAULT_TARGETS="Benjis-Plants/benjis-ops-tool:CI_RUNNER_JSON+bulk,HOSTED_JOBS_RUNNER_JSON,PROD_DEPLOY_RUNNER_JSON,MOBILE_MAC_RUNNER_JSON Benjis-Plants/benjis-sales-tool:CI_RUNNER_JSON,PROD_DEPLOY_RUNNER_JSON"
# `+bulk` after a variable name (ops tool CI_RUNNER_JSON only): that repo's e2e-full and nightly unit-test jobs ask for
# `benjis-ci-bulk` when the variable is exactly "benjis-ci", so that label must also have an online runner.
BULK_LABEL="benjis-ci-bulk"

command -v jq >/dev/null 2>&1 || { echo "where-things-run: jq is required" >&2; exit 2; }

if [ "$#" -gt 0 ]; then TARGETS="$*"; else TARGETS="${WTR_TARGETS:-$DEFAULT_TARGETS}"; fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/wtr.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

FLAGS=0
flag() { printf 'FLAG: %s\n' "$*"; FLAGS=$((FLAGS + 1)); }
cannot_read() {  # cannot_read <what> <err file> — no verdict is possible
  echo "ERROR: could not read $1 from GitHub, so there is NO verdict (not the same as \"unset\"). Likely a rate limit or a gh login without the needed scope (admin:org for org runners)." >&2
  [ -s "$2" ] && head -3 "$2" >&2
  exit 2
}
fetch() {  # fetch <api path> <out file> <what>
  "$GH" api "$1" > "$2" 2> "$2.err" || cannot_read "$3" "$2.err"
  jq -e . "$2" >/dev/null 2>&1 || cannot_read "$3 (not JSON)" "$2.err"
}

# labels_of <json value> -> JSON array of labels, or "null" when the value is not a string or an array of strings
labels_of() {
  printf '%s' "$1" | jq -c 'if type=="string" then [.] elif type=="array" and all(.[]; type=="string") then . else null end' 2>/dev/null || echo null
}
# online_count <runners file> <labels json> -> number of online runners that carry every label
online_count() {
  jq --argjson want "$2" '[.[] | select(.status=="online") | [.labels[].name] as $l
    | select(all($want[]; . as $w | ([$l[] | select(. == $w)] | length) > 0))] | length' "$1"
}

ORG_RUNNERS_DONE=""
for spec in $TARGETS; do
  repo=${spec%%:*}
  vars=${spec#*:}
  [ "$vars" = "$spec" ] && vars=""
  owner=${repo%%/*}
  key=$(printf '%s' "$repo" | tr '/' '_')

  fetch "repos/$repo/actions/variables?per_page=100" "$TMP/$key.repovars" "variables of $repo"
  fetch "repos/$repo/actions/organization-variables?per_page=100" "$TMP/$key.orgvars" "organization variables visible to $repo"
  fetch "repos/$repo/actions/runners?per_page=100" "$TMP/$key.reporunners" "runners of $repo"
  okey=$(printf '%s' "$owner" | tr '/' '_')
  case " $ORG_RUNNERS_DONE " in
    *" $owner "*) ;;
    *) fetch "orgs/$owner/actions/runners?per_page=100" "$TMP/org_$okey.runners" "org runners of $owner"
       ORG_RUNNERS_DONE="$ORG_RUNNERS_DONE $owner" ;;
  esac
  jq -s '[.[].runners[]] | unique_by(.id)' "$TMP/org_$okey.runners" "$TMP/$key.reporunners" > "$TMP/$key.runners"

  echo "== $repo   (jobs EXECUTE on the runners below; GitHub Actions only TRIGGERS them)"
  printf '%-26s %-8s %-40s %s\n' VARIABLE SOURCE VALUE "RESOLVES TO"
  for v in $(printf '%s' "$vars" | tr ',' ' '); do
    bulk=0
    case "$v" in *+bulk) bulk=1; v=${v%+bulk} ;; esac
    src=""; val=""
    if jq -e --arg n "$v" '.variables[] | select(.name==$n)' "$TMP/$key.repovars" >/dev/null; then
      src=repo; val=$(jq -r --arg n "$v" '.variables[] | select(.name==$n) | .value' "$TMP/$key.repovars")
    elif jq -e --arg n "$v" '.variables[] | select(.name==$n)' "$TMP/$key.orgvars" >/dev/null; then
      src=org; val=$(jq -r --arg n "$v" '.variables[] | select(.name==$n) | .value' "$TMP/$key.orgvars")
    fi
    if [ -z "$val" ]; then
      printf '%-26s %-8s %-40s %s\n' "$v" "${src:--}" "(unset or empty)" "NOT SET"
      if [ "$v" = "MOBILE_MAC_RUNNER_JSON" ]; then
        flag "$repo: $v is unset or empty. The iOS job has no YAML fallback, so it fails; it does not move to GitHub-hosted."
      else
        flag "$repo: $v is unset or empty. Workflows that read it fall through to the next variable in their runs-on chain, and to the YAML fallback (usually GitHub-hosted ubuntu-latest, a few jobs use benjis-ci) when none is set."
      fi
      continue
    fi
    labels=$(labels_of "$val")
    if [ "$labels" = "null" ]; then
      printf '%-26s %-8s %-40s %s\n' "$v" "$src" "$val" "INVALID"
      flag "$repo: $v is not a JSON string or array of strings ($val): workflows that read it will fail to start."
      continue
    fi
    if printf '%s' "$labels" | jq -e 'any(.[]; test("^(ubuntu|windows|macos)-"))' >/dev/null; then
      printf '%-26s %-8s %-40s %s\n' "$v" "$src" "$val" "GITHUB-HOSTED"
      flag "$repo: $v is $val, a GitHub-hosted runner label."
      continue
    fi
    n=$(online_count "$TMP/$key.runners" "$labels")
    printf '%-26s %-8s %-40s %s\n' "$v" "$src" "$val" "self-hosted, $n online runner(s)"
    if [ "$n" -eq 0 ]; then
      flag "$repo: $v needs labels $labels but no online runner carries them. Jobs will QUEUE; they do not fall back to GitHub-hosted."
    fi
    if [ "$bulk" -eq 1 ] && [ "$val" = '"benjis-ci"' ]; then
      bn=$(online_count "$TMP/$key.runners" "[\"$BULK_LABEL\"]")
      if [ "$bn" -eq 0 ]; then
        flag "$repo: jobs ask for $BULK_LABEL when CI_RUNNER_JSON is \"benjis-ci\" (e2e full, nightly unit tests) but no online runner carries it. Those jobs will QUEUE."
      fi
    fi
  done

  echo "runners usable by $repo (org + repo level):"
  total=$(jq 'length' "$TMP/$key.runners")
  if [ "$total" -eq 0 ]; then
    echo "  (none)"
    flag "$repo: no self-hosted runner is registered for it at all."
  else
    jq -r '.[] | [.name, .status, (if .busy then "busy" else "idle" end), ([.labels[].name] | map(select(. != "self-hosted")) | join(","))] | @tsv' "$TMP/$key.runners" \
      | while IFS="$(printf '\t')" read -r name status busy labels; do
          printf '  %-36s %-8s %-5s %s\n' "$name" "$status" "$busy" "$labels"
        done
    for off in $(jq -r '.[] | select(.status != "online") | .name' "$TMP/$key.runners"); do
      flag "$repo: runner $off is offline."
    done
  fi
  echo
done

if [ "$FLAGS" -eq 0 ]; then
  echo "RESULT: OK, no flags. The YAML fallback (ubuntu-latest) is not in use for any variable listed above."
  exit 0
fi
echo "RESULT: $FLAGS flag(s). Offline runners: re-run once (ephemeral runners re-register between jobs) before acting."
exit 1
