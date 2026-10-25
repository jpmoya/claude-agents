#!/bin/bash
# ci-classify.sh — classify ONE failing CI check as infrastructure or real from its failed-step log (#473).
#
#   ci-classify.sh <check name> < failed-log      prints one line, exit 0 = infrastructure, exit 1 = real
#
#   infra:container_start   a job container/service failed to start (fails at "Initialize containers")
#   infra:oom               exit 137 / "Killed" / out of memory
#   infra:enospc            "No space left on device" / ENOSPC
#   infra:runner_lost       runner shut down / lost communication / hosted runner error
#   infra:pr_format         the PR-description "User-facing change" format check (fix the PR text, not the code)
#   real                    anything else, including every assertion error, tsc error, lint error and test failure,
#                           and an empty or unreadable log (unknown is never tolerated)
#
# A real-failure signature anywhere in the log wins over an infrastructure signature: a run that printed a test
# assertion AND was later killed still blocks. Used by the supervisor's one-time CI re-run (supervisor.sh) and
# by the deployer's staging-only tolerance (agents/deployer.md). Pure function of stdin + the name: no network.
name=${1:-}
log=$(cat)

if [ -z "$(printf '%s' "$log" | tr -d '[:space:]')" ]; then echo real; exit 1; fi

# Real: a code/test/type/lint failure. Checked first.
if printf '%s\n' "$log" | grep -qE 'AssertionError|Assertion failed|error TS[0-9]+|Expected:|Received:|✖ [0-9]+ problems?|^[[:space:]]*FAIL[[:space:]]|Tests?:?[[:space:]]+[0-9]+ failed|[0-9]+ failed|expect\(.*\)\.(to|not)|● .* ›|eslint.*(error|problem)'; then
  echo real; exit 1
fi

# Infrastructure
if printf '%s\n' "$log" | grep -qi 'User-facing change' || printf '%s' "$name" | grep -qi 'user-facing change'; then
  echo infra:pr_format; exit 0
fi
if printf '%s\n' "$log" | grep -q 'Initialize containers' \
   && printf '%s\n' "$log" | grep -qiE '##\[error\]|Error response from daemon|failed to (start|create)|unhealthy|container .* (failed|exited)'; then
  echo infra:container_start; exit 0
fi
if printf '%s\n' "$log" | grep -qE 'ENOSPC|No space left on device'; then echo infra:enospc; exit 0; fi
if printf '%s\n' "$log" | grep -qiE 'exit(ed with)? code:? ?137|Exit status 137|OOMKilled|Out of memory|JavaScript heap out of memory|(^|[[:space:]])Killed($|[[:space:]])'; then
  echo infra:oom; exit 0
fi
if printf '%s\n' "$log" | grep -qiE 'received a shutdown signal|lost communication with the server|runner .*(lost|has been removed)|hosted runner encountered an error'; then
  echo infra:runner_lost; exit 0
fi
echo real; exit 1
