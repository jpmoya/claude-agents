#!/bin/bash
# STUB (issue #8) — placeholder written by the test-writer so tests/test-shared-lib.sh can source
# it and fail on an assertion. The developer replaces this file: it must hold the SETSID probe,
# count_running, mem_available_mb, has_capacity (moved verbatim from orchestrate.sh / supervisor.sh)
# and marker_last_jq (prints the jq expression for the newest real routing marker, or "none").
marker_last_jq() { echo "marker_last_jq: NotImplemented" >&2; return 1; }
