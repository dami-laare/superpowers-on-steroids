#!/usr/bin/env bash
# agent-config-gate: denies caveman-* dispatches whose variant suffix or
# model does not match <SUPERPOWERS_CONFIG>, allows everything else, and
# never blocks on bad input.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_ROOT/hooks/run-hook.cmd"

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
        bash "$WRAPPER" agent-config-gate 2>/dev/null)" || GATE_RC=$?
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

echo "agent-config-gate tests"

# --- Registration ---
if node -e '
const hooks = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hooks;
const entry = (hooks.PreToolUse || []).find((e) => e.matcher === "Agent|Task");
if (!entry) { console.error("no PreToolUse entry with matcher Agent|Task"); process.exit(1); }
const h = entry.hooks[0];
if (h.shell !== "bash") { console.error("shell is not bash"); process.exit(1); }
if (!/run-hook\.cmd" agent-config-gate \|\| true$/.test(h.command)) { console.error(`bad command: ${h.command}`); process.exit(1); }
' "$REPO_ROOT/hooks/hooks.json"; then
    pass "hooks.json registers PreToolUse Agent|Task via run-hook.cmd with shell:bash"
else
    fail "hooks.json registers PreToolUse Agent|Task via run-hook.cmd with shell:bash"
fi

if grep -q "agent-config-gate\|agent-tier-gate" "$REPO_ROOT/hooks/hooks-cursor.json"; then
    fail "hooks-cursor.json does not register the gate"
else
    pass "hooks-cursor.json does not register the gate"
fi

if [ -e "$REPO_ROOT/hooks/agent-tier-gate" ] || [ -e "$REPO_ROOT/tests/hooks/test-agent-tier-gate.sh" ]; then
    fail "old agent-tier-gate files removed"
else
    pass "old agent-tier-gate files removed"
fi

# --- Allowed pairs on builtin defaults (every role is always configured) ---
expect_allow "reviewer-medium on sonnet is allowed by default" \
    "$(payload "$P:caveman-reviewer-medium" sonnet "review it")" "$ROOT"
expect_allow "investigator-medium on sonnet is allowed by default" \
    "$(payload "$P:caveman-investigator-medium" sonnet "look")" "$ROOT"
expect_allow "final-reviewer-high on opus is allowed by default" \
    "$(payload "$P:caveman-final-reviewer-high" opus "final")" "$ROOT"
expect_allow "implementer-low on haiku (mechanical) is allowed by default" \
    "$(payload "$P:caveman-implementer-low" haiku "build")" "$ROOT"
expect_allow "implementer-low on sonnet (judgment) is allowed by default" \
    "$(payload "$P:caveman-implementer-low" sonnet "build")" "$ROOT"
expect_allow "implementer-high on opus (round-3 escalation) is allowed by default" \
    "$(payload "$P:caveman-implementer-high" opus "fix")" "$ROOT"

# --- Config changes the allowed pair ---
expect_allow "configured reviewer effort and model are allowed" \
    "$(payload "$P:caveman-reviewer-high" opus "review it")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=opus CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT=high
expect_deny "the default pair is denied once config moves it" 'caveman-reviewer-high + model "opus" (configured)' \
    "$(payload "$P:caveman-reviewer-medium" sonnet "review it")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=opus CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT=high
expect_deny "SUPERPOWERS_* env wins over the plugin option" 'caveman-reviewer-medium + model "opus"' \
    "$(payload "$P:caveman-reviewer-medium" sonnet "review it")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=sonnet SUPERPOWERS_REVIEWER_MODEL=opus
expect_allow "escalation pair follows the final reviewer model" \
    "$(payload "$P:caveman-implementer-high" fable "fix")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_FINAL_REVIEWER_MODEL=fable
expect_deny "a non-alias configured model falls back to the default alias" 'caveman-reviewer-medium + model "sonnet"' \
    "$(payload "$P:caveman-reviewer-medium" claude-opus-5-5 "review it")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=claude-opus-5-5
expect_deny "escalation pair is always effort high" 'caveman-implementer-high + model "opus" (round-3 escalation)' \
    "$(payload "$P:caveman-implementer-medium" opus "fix")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_IMPLEMENTER_EFFORT=medium
expect_deny "an invalid configured effort falls back to the default" 'caveman-reviewer-medium + model "sonnet"' \
    "$(payload "$P:caveman-reviewer-low" sonnet "review it")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT=xhigh

# --- Denials ---
expect_deny "wrong effort suffix is denied" 'caveman-reviewer-medium + model "sonnet" (configured)' \
    "$(payload "$P:caveman-reviewer-low" sonnet "review it")" "$ROOT"
expect_deny "wrong model is denied" 'caveman-final-reviewer-high + model "opus"' \
    "$(payload "$P:caveman-final-reviewer-high" sonnet "final")" "$ROOT"
expect_deny "an unknown model is denied (exact match only)" 'caveman-final-reviewer-high + model "opus"' \
    "$(payload "$P:caveman-final-reviewer-high" some-new-model "final")" "$ROOT"
expect_deny "missing model is denied and the dispatch is named" 'caveman-reviewer-medium + model "sonnet" (configured)' \
    "$(payload "$P:caveman-reviewer-medium" - "review it")" "$ROOT"
expect_deny "model: null counts as missing" 'caveman-investigator-medium + model "sonnet"' \
    "$(payload "$P:caveman-investigator-medium" null "look")" "$ROOT"
expect_deny "implementer denial lists all three pairs" 'caveman-implementer-low + model "haiku" (mechanical), caveman-implementer-low + model "sonnet" (judgment), caveman-implementer-high + model "opus" (round-3 escalation)' \
    "$(payload "$P:caveman-implementer-low" - "build")" "$ROOT"
expect_deny "bare caveman-reviewer is unknown" 'unknown caveman agent: dispatch superpowers-on-steroids:caveman-<role>-<effort>' \
    "$(payload "$P:caveman-reviewer" sonnet "review it")" "$ROOT"
expect_deny "unknown effort suffix is unknown" 'unknown caveman agent' \
    "$(payload "$P:caveman-reviewer-xhigh" sonnet "review it")" "$ROOT"
expect_deny "unknown role is unknown" 'unknown caveman agent' \
    "$(payload "$P:caveman-tester-low" sonnet "test")" "$ROOT"
run_gate "$(payload "$P:caveman-reviewer-medium" - 'x" \\ y')" "$ROOT"
if printf '%s' "$GATE_OUT" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' 2>/dev/null; then
    pass "deny reason is valid JSON with awkward prompt text"
else
    fail "deny reason is valid JSON with awkward prompt text"
fi

# --- Scope ---
expect_allow "non-caveman subagent is ignored" \
    "$(payload general-purpose - "anything")" "$ROOT"
expect_allow "the caveman plugin's own agents are ignored" \
    "$(payload "caveman:cavecrew-builder" - "anything")" "$ROOT"
expect_allow "missing subagent_type is ignored" \
    "$(payload - - "anything")" "$ROOT"
denied_input="$(payload "$P:caveman-reviewer-medium" - "review it")"
expect_allow "Cursor is left alone" "$denied_input" \
    "$ROOT" CURSOR_PLUGIN_ROOT="$REPO_ROOT"
expect_allow "Copilot CLI is left alone" "$denied_input" \
    "$ROOT" COPILOT_CLI=1
expect_allow "no CLAUDE_PLUGIN_ROOT is left alone" "$denied_input"

# --- Parsing ---
expect_deny "prompt text posing as a model key is not a model" '"sonnet"' \
    "$(payload "$P:caveman-reviewer-medium" - 'x", "model": "sonnet", "y": "')" "$ROOT"
expect_deny "a prompt ending in a backslash keeps the walk in step" '"sonnet"' \
    "$(payload "$P:caveman-reviewer-medium" - 'path C:\')" "$ROOT"
expect_allow "a prompt ending in a backslash still reads the real model" \
    "$(payload "$P:caveman-reviewer-medium" sonnet 'path C:\')" "$ROOT"
expect_deny "a model key nested below tool_input is ignored" '"sonnet"' \
    "{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"$P:caveman-reviewer-medium\",\"extra\":{\"model\":\"sonnet\"},\"prompt\":\"p\"}}" "$ROOT"
expect_allow "duplicate model key is ambiguous and allowed" \
    "{\"tool_input\":{\"subagent_type\":\"$P:caveman-reviewer-medium\",\"model\":\"haiku\",\"model\":\"haiku\"}}" "$ROOT"
expect_allow "non-string model is ambiguous and allowed" \
    "{\"tool_input\":{\"subagent_type\":\"$P:caveman-reviewer-medium\",\"model\":5}}" "$ROOT"
expect_allow "unterminated JSON is allowed" \
    "{\"tool_input\":{\"subagent_type\":\"$P:caveman-reviewer-medium\",\"prompt\":\"unterminated" "$ROOT"
expect_allow "non-JSON input is allowed" "not json at all" "$ROOT"
expect_allow "empty input is allowed" "" "$ROOT"

big_prompt="$(node -e 'process.stdout.write("line with \"quotes\" and \\\\ slashes\n".repeat(3000))')"
start=$SECONDS
expect_deny "a ~100 KB prompt is handled" '"sonnet"' \
    "$(payload "$P:caveman-reviewer-medium" - "$big_prompt")" "$ROOT"
if [ $((SECONDS - start)) -le 10 ]; then
    pass "a ~100 KB prompt finishes within 10s"
else
    fail "a ~100 KB prompt finishes within 10s"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi

echo "STATUS: PASSED"
