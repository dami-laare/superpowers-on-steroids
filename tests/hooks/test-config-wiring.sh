#!/usr/bin/env bash
# The role list, effort list, and builtin defaults must agree everywhere they
# are spelled out: plugin.json, lib-config, the generator + templates, the
# gate, the SDD table, and the emitted block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
GEN="$REPO_ROOT/scripts/gen-agent-variants"
GATE="$REPO_ROOT/hooks/agent-config-gate"
SDD_SKILL="$REPO_ROOT/skills/subagent-driven-development/SKILL.md"

FAILURES=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "config wiring tests"

# shellcheck source=../../hooks/lib-config
. "$REPO_ROOT/hooks/lib-config"

# --- plugin.json defaults == lib-config builtin defaults ---
for key in $SP_KEYS; do
    json_default="$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).userConfig; process.stdout.write(String((c[process.argv[2]]||{}).default ?? ""))' "$PLUGIN_JSON" "$key")"
    lib_default="$(sp_default "$key")"
    if [ -n "$lib_default" ] && [ "$json_default" = "$lib_default" ]; then
        pass "default for $key: plugin.json '$json_default' == lib-config"
    else
        fail "default for $key: plugin.json '$json_default' vs lib-config '$lib_default'"
    fi
done

# --- effort options == SP_EFFORTS ---
json_efforts="$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).userConfig; process.stdout.write(c.reviewer_effort.options.join(" "))' "$PLUGIN_JSON")"
if [ "$json_efforts" = "$SP_EFFORTS" ]; then
    pass "plugin.json effort options match SP_EFFORTS ($SP_EFFORTS)"
else
    fail "plugin.json effort options '$json_efforts' vs SP_EFFORTS '$SP_EFFORTS'"
fi

# --- generator role/effort literals == lib-config ---
gen_roles="$(sed -n 's/^ROLES="\(.*\)"$/\1/p' "$GEN")"
gen_efforts="$(sed -n 's/^EFFORTS="\(.*\)"$/\1/p' "$GEN")"
[ "$gen_roles" = "$SP_ROLES" ] && pass "generator ROLES match SP_ROLES" || fail "generator ROLES '$gen_roles' vs '$SP_ROLES'"
[ "$gen_efforts" = "$SP_EFFORTS" ] && pass "generator EFFORTS match SP_EFFORTS" || fail "generator EFFORTS '$gen_efforts' vs '$SP_EFFORTS'"

# --- gate case lines name the same roles and efforts ---
gate_roles="$(grep -E '^[[:space:]]+implementer\|reviewer\|investigator\|final-reviewer\) ;;' "$GATE" | sed -E 's/^[[:space:]]+//; s/\) ;;$//; s/\|/ /g')"
gate_efforts="$(grep -E '^[[:space:]]+low\|medium\|high\) ;;' "$GATE" | sed -E 's/^[[:space:]]+//; s/\) ;;$//; s/\|/ /g')"
[ "$gate_roles" = "$SP_ROLES" ] && pass "gate role case matches SP_ROLES" || fail "gate role case '$gate_roles' vs '$SP_ROLES'"
[ "$gate_efforts" = "$SP_EFFORTS" ] && pass "gate effort case matches SP_EFFORTS" || fail "gate effort case '$gate_efforts' vs '$SP_EFFORTS'"

# --- template model pins == builtin defaults ---
for role in $SP_ROLES; do
    tmpl="$REPO_ROOT/scripts/agent-templates/caveman-$role.md"
    pin="$(sed -n 's/^model: *//p' "$tmpl")"
    case "$role" in
        implementer) want="$(sp_default implementer_judgment_model)" ;;
        *) want="$(sp_default "$(printf '%s' "$role" | tr - _)_model")" ;;
    esac
    [ "$pin" = "$want" ] && pass "template caveman-$role pins model $want" || fail "template caveman-$role pins '$pin', want '$want'"
done

# --- SDD canonical table has a row per role naming its variant ---
for role in $SP_ROLES; do
    if grep -qE "^\| \`$role\` \| \`caveman-$role-<effort>\` \|" "$SDD_SKILL"; then
        pass "SDD table row for $role names caveman-$role-<effort>"
    else
        fail "SDD table row for $role missing or not naming caveman-$role-<effort>"
    fi
done

# --- the emitted block carries the defaults ---
wiring_home="$(mktemp -d)"
emitted="$(env -i PATH="${PATH:-}" HOME="$wiring_home" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$REPO_ROOT/hooks/session-start" 2>/dev/null)" || emitted=""
rm -rf "$wiring_home"
for line in \
    "implementer: mechanical=$(sp_default implementer_mechanical_model) judgment=$(sp_default implementer_judgment_model) effort=$(sp_default implementer_effort)" \
    "reviewer: model=$(sp_default reviewer_model) effort=$(sp_default reviewer_effort)" \
    "investigator: model=$(sp_default investigator_model) effort=$(sp_default investigator_effort)" \
    "final-reviewer: model=$(sp_default final_reviewer_model) effort=$(sp_default final_reviewer_effort)"; do
    if printf '%s' "$emitted" | grep -qF -- "$line"; then
        pass "session-start emits '$line'"
    else
        fail "session-start does not emit '$line'"
    fi
done

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi
echo "STATUS: PASSED"
