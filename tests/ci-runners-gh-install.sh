#!/usr/bin/env bash
# #485 fix cycle: the gha-runner image must include the gh CLI (Benjis-Plants/benjis-ops-tool#1922 -- regression-watch
# and stamp-staging-milestone fail their gh calls on the self-hosted runner image, which has no gh).
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/infra/ci-runners/setup.sh"
f=0
chk() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; f=$((f+1)); fi; }
dockerfile=$(awk '/^dockerfile_text\(\)/,/^}/' "$S")

chk "installs gh from GitHub's official apt repo (cli.github.com keyring)" \
  '[[ $dockerfile == *"cli.github.com/packages/githubcli-archive-keyring.gpg"* ]]'
chk "keyring is signed-by'd, not a bare apt-key add" \
  '[[ $dockerfile == *"signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg"* ]]'
chk "gh install layer cleans up apt lists" \
  '[[ $dockerfile == *"install -y --no-install-recommends gh"*"&& rm -rf /var/lib/apt/lists/*"* ]]'
chk "gh install layer runs before the runner-download layer" \
  '[[ $dockerfile == *"install -y --no-install-recommends gh"*"actions-runner-linux"* ]]'

# AC2 (#485): no other line of dockerfile_text() changes.
chk "base image line unchanged" '[[ $dockerfile == *"FROM ubuntu:24.04"* ]]'
chk "original curl/jq/sudo install line unchanged" \
  '[[ $dockerfile == *"apt-get install -y --no-install-recommends curl ca-certificates git jq sudo"* ]]'
chk "runner download layer unchanged" '[[ $dockerfile == *"actions-runner-linux-\${a}-\${RUNNER_VERSION}.tar.gz"* ]]'
chk "docker CLI layer unchanged" '[[ $dockerfile == *"download.docker.com/linux/static/stable"* ]]'
chk "entrypoint unchanged" '[[ $dockerfile == *'"'"'ENTRYPOINT ["./run.sh"]'"'"'* ]]'

chk "README documents gh in the runner image" 'grep -qi "includes the \`gh\` CLI" "$(dirname "$S")/README.md"'

echo "# $f failed"; [ "$f" -eq 0 ]
