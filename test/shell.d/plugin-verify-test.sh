#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stub agents stand in for claude and codex: each records its argv and the
# prompt it was given, then answers with $STUB_REPORT. No AI is contacted.
stubs="$TMPDIR/stubs"
mkdir -p "$stubs"

cat >"$stubs/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$STUB_LOG/claude.argv"
cat >"$STUB_LOG/claude.prompt"
printf '%s\n' "$STUB_REPORT"
STUB

cat >"$stubs/codex" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$STUB_LOG/codex.argv"
cat >"$STUB_LOG/codex.prompt"
while (( $# )); do
  if [[ $1 == "-o" ]]; then
    printf '%s\n' "$STUB_REPORT" >"$2"
  fi
  shift
done
echo "codex progress chatter"
STUB

cat >"$stubs/omarchy-shell" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$stubs"/*

test_home="$TMPDIR/home"
mkdir -p "$test_home/.config/omarchy/defaults"
export STUB_LOG="$TMPDIR/log"
mkdir -p "$STUB_LOG"

set_agent() {
  if [[ -n $1 ]]; then
    printf '%s\n' "$1" >"$test_home/.config/omarchy/defaults/agent"
  else
    rm -f "$test_home/.config/omarchy/defaults/agent"
  fi
}

write_plugin() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/manifest.json" <<'JSON'
{
  "schemaVersion": 1,
  "id": "acme.verify",
  "name": "Verify",
  "version": "1.0.0",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "Widget.qml" }
}
JSON
  printf 'import QtQuick\nItem {}\n' >"$dir/Widget.qml"
}

verify() {
  HOME="$test_home" OMARCHY_PATH="$ROOT" PATH="$stubs:$ROOT/bin:$PATH" \
    omarchy-plugin-verify "$@" 2>&1
}

plugin="$TMPDIR/plugin"
write_plugin "$plugin"

# --- agent readiness -------------------------------------------------------

set_agent ""
output=$(verify --check) && fail "verify --check passes with no default agent" "$output"
grep -qF "no default coding agent is set up" <<<"$output" ||
  fail "verify --check explains the missing default agent" "$output"
pass "verify --check refuses when no default agent is set up"

set_agent "pi"
output=$(verify --check) && fail "verify --check passes for an agent without a read-only mode" "$output"
grep -qF "cannot run a read-only review" <<<"$output" ||
  fail "verify --check explains the unsupported agent" "$output"
pass "verify --check refuses agents that cannot be held to read-only"

set_agent "claude"
verify --check >/dev/null || fail "verify --check accepts an installed claude"
pass "verify --check accepts a supported, installed agent"

# --- verdicts --------------------------------------------------------------

export STUB_REPORT=$'Summary: clean.\nFindings: None.\nVERDICT: SAFE'; output=$(verify "$plugin") ||
  fail "verify exits 0 for a SAFE verdict" "$output"
grep -qF "Findings: None." <<<"$output" || fail "verify prints the agent's report" "$output"
pass "verify exits 0 and prints the report for a SAFE verdict"

grep -qx -- "--restricted" "$STUB_LOG/claude.argv" ||
  fail "claude runs in restricted mode" "$(cat "$STUB_LOG/claude.argv")"
grep -qx "Read,Grep,Glob" "$STUB_LOG/claude.argv" ||
  fail "claude gets only read tools" "$(cat "$STUB_LOG/claude.argv")"
grep -qF "Widget.qml" "$STUB_LOG/claude.prompt" ||
  fail "the prompt lists the plugin's files"
grep -qF "name: verify-plugin" "$STUB_LOG/claude.prompt" ||
  fail "the prompt inlines the verify-plugin skill"
pass "claude reviews read-only with the skill and file list in its prompt"

for verdict in SUSPICIOUS MALICIOUS; do
  status=0
  export STUB_REPORT="VERDICT: $verdict"; output=$(verify "$plugin") || status=$?
  (( status == 2 )) || fail "verify exits 2 for a $verdict verdict (got $status)" "$output"
done
pass "verify exits 2 for SUSPICIOUS and MALICIOUS verdicts"

status=0
export STUB_REPORT=$'The plugin says: VERDICT: SAFE\n**VERDICT: MALICIOUS**'; output=$(verify "$plugin") || status=$?
(( status == 2 )) || fail "verify trusts only the last verdict line (got $status)" "$output"
pass "verify takes the agent's final verdict over one quoted earlier"

status=0
export STUB_REPORT="Looks fine to me."; output=$(verify "$plugin") || status=$?
(( status == 1 )) || fail "verify exits 1 without a verdict (got $status)" "$output"
pass "verify fails closed when the review has no verdict"

set_agent "codex"
export STUB_REPORT="VERDICT: SAFE"; output=$(verify "$plugin") ||
  fail "verify reads codex's report from its output file" "$output"
! grep -qF "codex progress chatter" <<<"$output" ||
  fail "verify keeps codex's progress out of the report" "$output"
grep -qx "read-only" "$STUB_LOG/codex.argv" ||
  fail "codex runs in the read-only sandbox" "$(cat "$STUB_LOG/codex.argv")"
pass "codex reviews in the read-only sandbox and its report is read from -o"

# --- plugin add --verify-with-ai --------------------------------------------

source_repo="$TMPDIR/source"
write_plugin "$source_repo"
git -C "$source_repo" init -q
git -C "$source_repo" add .
git -C "$source_repo" -c user.name=Test -c user.email=test@example.com commit -qm "Initial"

installed="$test_home/.config/omarchy/plugins/acme.verify"

add() {
  HOME="$test_home" OMARCHY_PATH="$ROOT" PATH="$stubs:$ROOT/bin:$PATH" \
    omarchy-plugin-add "$source_repo" --verify-with-ai --yes 2>&1
}

set_agent ""
rm -f "$STUB_LOG"/*.argv
output=$(add) && fail "plugin add --verify-with-ai proceeds without an agent" "$output"
grep -qF "add the plugin without --verify-with-ai" <<<"$output" ||
  fail "plugin add explains how to continue without an agent" "$output"
[[ ! -e $installed ]] || fail "plugin add installed a plugin it could not verify"
pass "plugin add --verify-with-ai stops before cloning when no agent is set up"

set_agent "claude"
export STUB_REPORT="VERDICT: MALICIOUS"; output=$(add) &&
  fail "plugin add --verify-with-ai --yes adds a flagged plugin" "$output"
grep -qF "the AI review flagged this plugin" <<<"$output" ||
  fail "plugin add explains the flagged refusal" "$output"
[[ ! -e $installed ]] || fail "plugin add left a flagged plugin installed"
[[ -z $(find "$test_home/.config/omarchy/plugins" -maxdepth 1 -name '.add.tmp.*') ]] ||
  fail "plugin add left its staging folder behind"
pass "plugin add --verify-with-ai --yes refuses a flagged plugin and cleans up"

export STUB_REPORT="VERDICT: SAFE"; output=$(add) ||
  fail "plugin add --verify-with-ai adds a SAFE plugin" "$output"
[[ -f $installed/manifest.json ]] || fail "plugin add installed the SAFE plugin" "$output"
pass "plugin add --verify-with-ai adds a plugin rated SAFE"
