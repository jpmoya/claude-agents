#!/bin/bash
# Keep the Clog VM's CLIs and logins in step with the Mac.  Run on the Mac.
#   vm-sync.sh [status|tools|creds|all]     (default: all)
#
#   tools   install/upgrade the CLIs the Mac uses on the VM (npm, into ~/.local; idempotent)
#   creds   copy credential files + derive tokens from the Mac keychain onto the VM (never stored in this repo)
#   status  versions and a live "who am I" per service on both machines
#
# Not synced on purpose (log in once on the VM, tokens rotate): Vercel (`vercel login`), gh (own OAuth), claude (own token).
# Re-run `creds` after any re-login/rotation on the Mac (wrangler, gws, Supabase PAT, Sentry token).
# Add a service: one line in FILES (path pairs) and/or a check in `status`.  Older/legacy: ~/dev/hetzner-sync-local.sh (do not use).
set -uo pipefail
VM="${VM_HOST:-clog-exec}"
export PATH="$PATH:/opt/homebrew/bin"
VMPATH='export PATH=$HOME/.local/bin:$PATH; [ -f ~/.config/vm-sync.env ] && . ~/.config/vm-sync.env;'
vm() { ssh -o ConnectTimeout=10 "$VM" "$VMPATH $1"; }

# "mac path|vm path" — relative to $HOME, directories end in /.  Missing Mac sources are skipped.
FILES=(
  ".config/gws/|.config/gws/"                                   # jp@benjis.com Google Workspace (credentials.enc + .encryption_key)
  ".config/gws-personal/|.config/gws-personal/"
  "Library/Preferences/.wrangler/config/default.toml|.config/.wrangler/config/default.toml"   # Cloudflare (OAuth)
  ".config/neonctl/credentials.json|.config/neonctl/credentials.json"
  ".config/resend/credentials.json|.config/resend/credentials.json"
  ".config/benjis/|.config/benjis/"                              # QBO scraper env
  ".claude/mcp-servers/gdrive-personal/|.claude/mcp-servers/gdrive-personal/"
  ".claude/mcp-servers/gdrive-casa-verde/|.claude/mcp-servers/gdrive-casa-verde/"   # incl. .attio-credentials
  ".config/gcloud/service-accounts/|.config/gcloud/service-accounts/"
  "dev/benjis-hub/.env|benjis-hub/.env"                          # Ramp, Gmail client secret
  "dev/benjis-hub/gws/.env|benjis-hub/gws/.env"
  "dev/benjis-quoting-tool/app/.env.local|benjis-quoting-tool/app/.env.local"   # Copper
)
NPM_TOOLS=(supabase @sentry/cli wrangler vercel firebase-tools neonctl@2)

do_tools() {
  echo "== tools"
  vm "npm i -g --prefix ~/.local ${NPM_TOOLS[*]} 2>&1 | tail -2"
  vm 'cd ~/benjis-hub && git pull --ff-only -q 2>&1 | tail -1; cd gws && npm ci --silent 2>&1 | tail -1; ./node_modules/.bin/gws --version 2>&1 | head -1' # gws lives in benjis-hub/gws
}

do_creds() {
  echo "== files"
  local pair src dst
  for pair in "${FILES[@]}"; do
    src="${pair%%|*}"; dst="${pair##*|}"
    [ -e "$HOME/$src" ] || { echo "  skip (no Mac copy): $src"; continue; }
    vm "mkdir -p \"\$(dirname ~/$dst)\""
    rsync -a -e ssh "$HOME/$src" "$VM:~/$dst" && vm "chmod -R go-rwx ~/$dst" && echo "  ok: $dst"
  done
  echo "== derived tokens"
  local sb se tmp; tmp=$(mktemp); chmod 600 "$tmp"
  sb=$(security find-generic-password -s "Supabase CLI" -w 2>/dev/null)
  case "$sb" in go-keyring-base64:*) sb=$(printf %s "${sb#go-keyring-base64:}" | base64 -d) ;; esac
  se=$(sed -n 's/^token *= *//p' "$HOME/.sentryclirc" 2>/dev/null | head -1)
  printf 'SB=%s\nSE=%s\n' "$sb" "$se" > "$tmp"
  scp -q "$tmp" "$VM:/tmp/.vm-sync-creds" && rm -f "$tmp"
  vm 'python3 - <<"P"
import json,os,re
c=dict(l.rstrip("\n").split("=",1) for l in open("/tmp/.vm-sync-creds") if "=" in l)
p=os.path.expanduser("~/.claude/settings.local.json"); d=json.load(open(p)); e=d.setdefault("env",{})
if c["SB"]: e["SUPABASE_ACCESS_TOKEN"]=e["SUPABASE_MGMT_PAT"]=c["SB"]
if c["SE"]: e["SENTRY_AUTH_TOKEN"]=c["SE"]
json.dump(d,open(p,"w"),indent=2)
f=os.path.expanduser("~/.config/vm-sync.env"); o=""
if c["SB"]: o+="export SUPABASE_ACCESS_TOKEN=%s\n"%c["SB"]
if c["SE"]: o+="export SENTRY_AUTH_TOKEN=%s\n"%c["SE"]
o+="export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file\n"
open(f,"w").write(o); os.chmod(f,0o600)
b=os.path.expanduser("~/.bashrc"); s=re.sub(r"\n# vm-sync tokens.*?# end vm-sync tokens\n","",open(b).read(),flags=re.S)
hook="[ -f ~/.config/vm-sync.env ] && . ~/.config/vm-sync.env  # vm-sync (claude-agents/bin/vm-sync.sh)\n"
if hook not in s: s=hook+s
open(b,"w").write(s)
P
rm -f /tmp/.vm-sync-creds; echo "  ok: SUPABASE_ACCESS_TOKEN, SENTRY_AUTH_TOKEN (settings.local.json env + ~/.config/vm-sync.env)"'
}

do_status() {
  echo "== versions        (Mac | VM)"
  local t
  for t in vercel supabase sentry-cli wrangler firebase neonctl gh gcloud op; do
    printf "  %-11s %-22s | " "$t" "$( { $t --version 2>&1 | head -1; } 2>/dev/null | cut -c1-22)"
    vm "$t --version 2>&1 | head -1 | cut -c1-30" 2>/dev/null || echo MISSING
  done
  echo "== logins on the VM"
  vm 'echo "vercel:   $(vercel whoami 2>&1 | tail -1)"
      echo "supabase: $(supabase orgs list 2>&1 | grep -c "|") org rows"
      echo "sentry:   $(sentry-cli info 2>&1 | grep -m1 "User:" || echo FAIL)"
      echo "wrangler: $(wrangler whoami 2>&1 | grep -m1 -iE "email|not authenticated" | cut -c1-80)"
      echo "gh:       $(gh auth status 2>&1 | grep -m1 "Logged in" | sed "s/^ *. //")"
      echo "gcloud:   $(gcloud auth list --format="value(account)" 2>&1 | head -1)"
      echo "neon:     $(neonctl me 2>&1 | head -2 | tail -1 | cut -c1-60)"
      echo "gws:      $(cd ~/benjis-hub/gws && ./node_modules/.bin/gws auth status 2>&1 | head -3 | tr "\n" " " | cut -c1-120)"'
}

case "${1:-all}" in
  tools) do_tools ;; creds) do_creds ;; status) do_status ;;
  all) do_tools; do_creds; do_status ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
