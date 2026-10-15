#!/usr/bin/env bash
# Extra coverage for the rendered launcher happy path (#288): no root/Docker/network.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
R=$TMP/root S=$TMP/state B=$TMP/stubs; mkdir -p "$R" "$S" "$B"
for c in docker curl id systemctl useradd getent loginctl runuser chown; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/%s.log"\n' "$c" "$S" "$c" > "$B/$c"
  chmod +x "$B/$c"
done
cat > "$B/curl" <<STUB
#!/usr/bin/env bash
echo "curl \$*" >> "$S/curl.log"
cat >/dev/null
echo '{"encoded_jit_config":"JITCFG"}'
STUB
echo 'echo 1234' >> "$B/id"
export GHA_ROOT=$R GHA_DRY_STUBS=$B
fails=0
chk() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
mkdir -p "$R/etc/gha" "$R/usr/local/lib/gha"
printf 'GHA_MINT_TOKEN=TOK999\nGHA_RUNNER_SCOPE=orgs/acme\n' > "$R/etc/gha/mint.env"
# Render the installed files through setup.sh itself.
bash "$REPO/infra/ci-runners/setup.sh" >"$TMP/setup.out" 2>&1 || { cat "$TMP/setup.out"; }
rm -f "$S"/*.log
bash "$R/usr/local/sbin/gha-slot.sh" 1 >"$TMP/out" 2>&1
chk "launcher exits 0" "[ \$? -eq 0 ]"
chk "mints against the configured scope" "grep -q 'orgs/acme/actions/runners/generate-jitconfig' $S/curl.log"
chk "docker run is --rm with pinned image" "grep -q 'docker run --rm .*gha-runner:2.338.0' $S/docker.log"
chk "token never in argv or output" "! grep -rq TOK999 $S $TMP/out"
chk "JIT config never in argv" "! grep -q JITCFG $S/docker.log"
chk "slot rejects non-numeric" "! bash $R/usr/local/sbin/gha-slot.sh x >/dev/null 2>&1"
[ $fails -eq 0 ]
