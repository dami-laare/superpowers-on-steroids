#!/usr/bin/env bash
# agent-tier-gate: denies config-blind or below-floor caveman-* dispatches,
# allows everything else, and never blocks on bad input.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_ROOT/hooks/run-hook.cmd"
GATE="$REPO_ROOT/hooks/agent-tier-gate"
SDD_SKILL="$REPO_ROOT/skills/subagent-driven-development/SKILL.md"

FAILURES=0
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

P="superpowers-on-steroids"
ROOT="CLAUDE_PLUGIN_ROOT=$REPO_ROOT"

# payload SUBAGENT MODEL PROMPT — "-" omits the key, "null" sends JSON null.
payload() {
    node -e '
const [sub, model, prompt] = process.argv.slice(1);
const ti = { description: "task", prompt };
if (sub !== "-") ti.subagent_type = sub;
if (model === "null") ti.model = null;
else if (model !== "-") ti.model = model;
process.stdout.write(JSON.stringify({
  session_id: "s1", hook_event_name: "PreToolUse", tool_name: "Agent",
  tool_input: ti, tool_use_id: "toolu_1"
}));
' "$@"
}

# run_gate STDIN [ENV=VALUE ...] — sets GATE_OUT and GATE_RC.
run_gate() {
    local stdin="$1"
    shift
    GATE_RC=0
    GATE_OUT="$(printf '%s' "$stdin" | env -i PATH="$PATH" HOME="$TEST_HOME" "$@" \
        bash "$WRAPPER" agent-tier-gate 2>/dev/null)" || GATE_RC=$?
}

expect_allow() {
    local desc="$1" stdin="$2"
    shift 2
    run_gate "$stdin" "$@"
    if [ "$GATE_RC" -eq 0 ] && [ -z "$GATE_OUT" ]; then
        pass "$desc"
    else
        fail "$desc"
        echo "    rc=$GATE_RC out=$GATE_OUT"
    fi
}

expect_deny() {
    local desc="$1" needle="$2" stdin="$3"
    shift 3
    run_gate "$stdin" "$@"
    if [ "$GATE_RC" -eq 0 ] && printf '%s' "$GATE_OUT" | NEEDLE="$needle" node -e '
const out = JSON.parse(require("fs").readFileSync(0, "utf8"));
const h = out.hookSpecificOutput || {};
if (h.hookEventName !== "PreToolUse") process.exit(1);
if (h.permissionDecision !== "deny") process.exit(1);
if (!String(h.permissionDecisionReason).includes(process.env.NEEDLE)) process.exit(1);
'; then
        pass "$desc"
    else
        fail "$desc"
        echo "    rc=$GATE_RC out=$GATE_OUT"
    fi
}

echo "agent-tier-gate tests"

# --- Registration ---
if node -e '
const hooks = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hooks;
const entry = (hooks.PreToolUse || []).find((e) => e.matcher === "Agent|Task");
if (!entry) { console.error("no PreToolUse entry with matcher Agent|Task"); process.exit(1); }
const h = entry.hooks[0];
if (h.shell !== "bash") { console.error("shell is not bash"); process.exit(1); }
if (!/run-hook\.cmd" agent-tier-gate$/.test(h.command)) { console.error(`bad command: ${h.command}`); process.exit(1); }
' "$REPO_ROOT/hooks/hooks.json"; then
    pass "hooks.json registers PreToolUse Agent|Task via run-hook.cmd with shell:bash"
else
    fail "hooks.json registers PreToolUse Agent|Task via run-hook.cmd with shell:bash"
fi

if grep -q "agent-tier-gate" "$REPO_ROOT/hooks/hooks-cursor.json"; then
    fail "hooks-cursor.json does not register the gate"
else
    pass "hooks-cursor.json does not register the gate"
fi

# --- Omission ---
expect_deny "reviewer without model is denied when standard is configured" '"sonnet" (standard tier)' \
    "$(payload "$P:caveman-reviewer" - "review it")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_deny "model: null counts as omitted" '"sonnet"' \
    "$(payload "$P:caveman-investigator" null "look")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_deny "final-reviewer without model names the capable tier" '"opus" (capable tier)' \
    "$(payload "$P:caveman-final-reviewer" - "final")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE=opus
expect_deny "implementer names both configured tiers" '"haiku" (cheap tier, transcription or single-file work) or "sonnet" (standard tier' \
    "$(payload "$P:caveman-implementer" - "build")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_MODEL_CHEAP=haiku CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
run_gate "$(payload "$P:caveman-implementer" - "build")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_CHEAP=haiku
if [[ "$GATE_OUT" == *'\"haiku\"'* ]] && [[ "$GATE_OUT" != *standard* ]]; then
    pass "implementer with only cheap configured names cheap only"
else
    fail "implementer with only cheap configured names cheap only"
    echo "    out=$GATE_OUT"
fi
expect_allow "omitted model with nothing configured falls back to the frontmatter pin" \
    "$(payload "$P:caveman-reviewer" - "review it")" "$ROOT"
expect_allow "omitted model is allowed when only an unrelated tier is configured" \
    "$(payload "$P:caveman-reviewer" - "review it")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_CHEAP=haiku
expect_deny "SUPERPOWERS_MODEL_* env wins over the plugin option" '"opus" (standard tier)' \
    "$(payload "$P:caveman-reviewer" - "review it")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet SUPERPOWERS_MODEL_STANDARD=opus

# --- Present model ---
expect_allow "reviewer on its configured tier is allowed" \
    "$(payload "$P:caveman-reviewer" sonnet "review it")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_allow "implementer on the capable tier is allowed (no ceiling)" \
    "$(payload "$P:caveman-implementer" opus "build")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_CHEAP=haiku
expect_allow "investigator on haiku is allowed (no floor)" \
    "$(payload "$P:caveman-investigator" haiku "look")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet

# --- Floor ---
expect_deny "reviewer on the configured cheap model is denied" '"sonnet"' \
    "$(payload "$P:caveman-reviewer" haiku "review it")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_MODEL_CHEAP=haiku CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_deny "reviewer on haiku is denied with no config (built-in rank)" '"sonnet"' \
    "$(payload "$P:caveman-reviewer" haiku "review it")" "$ROOT"
expect_deny "final-reviewer on sonnet is denied" '"opus"' \
    "$(payload "$P:caveman-final-reviewer" sonnet "final")" "$ROOT"
expect_allow "a value shared by two tiers ranks at the higher one" \
    "$(payload "$P:caveman-final-reviewer" opus "final")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=opus CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE=opus
expect_allow "the named built-in model passes when the floor tier is unconfigured" \
    "$(payload "$P:caveman-reviewer" sonnet "review it")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_CHEAP=sonnet
expect_allow "an unknown model is allowed" \
    "$(payload "$P:caveman-final-reviewer" some-new-model "final")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE=opus

# --- Scope ---
expect_allow "non-caveman subagent is ignored" \
    "$(payload general-purpose - "anything")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_allow "missing subagent_type is ignored" \
    "$(payload - - "anything")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
denied_input="$(payload "$P:caveman-reviewer" - "review it")"
expect_allow "Cursor is left alone" "$denied_input" \
    "$ROOT" CURSOR_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_allow "Copilot CLI is left alone" "$denied_input" \
    "$ROOT" COPILOT_CLI=1 CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_allow "no CLAUDE_PLUGIN_ROOT is left alone" "$denied_input" \
    CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet

# --- Parsing ---
expect_deny "prompt text posing as a model key is not a model" '"sonnet"' \
    "$(payload "$P:caveman-reviewer" - 'x", "model": "sonnet", "y": "')" \
    "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_deny "a prompt ending in a backslash keeps the walk in step" '"sonnet"' \
    "$(payload "$P:caveman-reviewer" - 'path C:\')" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_allow "a prompt ending in a backslash still reads the real model" \
    "$(payload "$P:caveman-reviewer" sonnet 'path C:\')" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_deny "a model key nested below tool_input is ignored" '"sonnet"' \
    "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"$P:caveman-reviewer\",\"extra\":{\"model\":\"sonnet\"},\"prompt\":\"p\"}}" \
    "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_allow "duplicate model key is ambiguous and allowed" \
    "{\"tool_input\":{\"subagent_type\":\"$P:caveman-reviewer\",\"model\":\"haiku\",\"model\":\"haiku\"}}" "$ROOT"
expect_allow "non-string model is ambiguous and allowed" \
    "{\"tool_input\":{\"subagent_type\":\"$P:caveman-reviewer\",\"model\":5}}" "$ROOT"
expect_allow "unterminated JSON is allowed" \
    "{\"tool_input\":{\"subagent_type\":\"$P:caveman-reviewer\",\"prompt\":\"unterminated" \
    "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_allow "non-JSON input is allowed" "not json at all" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
expect_allow "empty input is allowed" "" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet

big_prompt="$(node -e 'process.stdout.write("line with \"quotes\" and \\\\ slashes\n".repeat(3000))')"
start=$SECONDS
expect_deny "a ~100 KB prompt is handled" '"sonnet"' \
    "$(payload "$P:caveman-reviewer" - "$big_prompt")" "$ROOT" CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet
if [ $((SECONDS - start)) -le 10 ]; then
    pass "a ~100 KB prompt finishes within 10s"
else
    fail "a ~100 KB prompt finishes within 10s"
fi

# --- Wiring: the gate's policy matches the canonical tier table ---
for agent in caveman-implementer caveman-reviewer caveman-investigator caveman-final-reviewer; do
    row="$(grep -E "^\| \`$agent\` \|" "$SDD_SKILL" || true)"
    table_tiers="$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/, "", $3); gsub(/ or /, " ", $3); print $3}')"
    table_floor="$(printf '%s' "$row" | awk -F'|' '{gsub(/^ +| +$/, "", $4); print $4}')"
    [ "$table_floor" = "none" ] && table_floor=""
    line="$(grep -F "$P:$agent)" "$GATE" || true)"
    gate_tiers="$(printf '%s' "$line" | sed -n 's/.* tiers="\([^"]*\)".*/\1/p')"
    gate_floor="$(printf '%s' "$line" | sed -n 's/.* floor="\([^"]*\)".*/\1/p')"
    if [ -n "$row" ] && [ -n "$line" ] && [ "$table_tiers" = "$gate_tiers" ] && [ "$table_floor" = "$gate_floor" ]; then
        pass "wiring: $agent tier '$gate_tiers' floor '${gate_floor:-none}' matches the SDD table"
    else
        fail "wiring: $agent table ('$table_tiers'/'$table_floor') vs gate ('$gate_tiers'/'$gate_floor')"
    fi
done

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi

echo "STATUS: PASSED"
