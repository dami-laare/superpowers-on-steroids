#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_UNDER_TEST="$REPO_ROOT/hooks/session-start"
WRAPPER_UNDER_TEST="$REPO_ROOT/hooks/run-hook.cmd"

FAILURES=0
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
    echo "  [PASS] $1"
}

fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

make_home() {
    local name="$1"
    local home="$TEST_ROOT/$name/home"
    mkdir -p "$home"
    printf '%s\n' "$home"
}

assert_command_output() {
    local description="$1"
    local shape="$2"
    local contains="$3"
    local not_contains="$4"
    local home="$5"
    shift 5

    local output
    if ! output="$(env -i PATH="${PATH:-}" HOME="$home" "$@" 2>&1)"; then
        fail "$description"
        echo "    hook exited non-zero"
        echo "$output" | sed 's/^/      /'
        return
    fi

    if printf '%s' "$output" | \
        EXPECT_SHAPE="$shape" \
        EXPECT_CONTAINS="$contains" \
        EXPECT_NOT_CONTAINS="$not_contains" \
        node -e '
const fs = require("fs");

const input = fs.readFileSync(0, "utf8");
let payload;
try {
  payload = JSON.parse(input);
} catch (error) {
  console.error(`invalid JSON: ${error.message}`);
  process.exit(1);
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

const shape = process.env.EXPECT_SHAPE;
let context;

if (shape === "nested") {
  if (!hasOwn(payload, "hookSpecificOutput")) {
    fail("missing hookSpecificOutput");
  }
  if (hasOwn(payload, "additional_context") || hasOwn(payload, "additionalContext")) {
    fail("nested output also included a top-level context field");
  }
  const hookOutput = payload.hookSpecificOutput;
  if (!hookOutput || typeof hookOutput !== "object" || Array.isArray(hookOutput)) {
    fail("hookSpecificOutput is not an object");
  }
  if (hookOutput.hookEventName !== "SessionStart") {
    fail(`unexpected hookEventName: ${hookOutput.hookEventName}`);
  }
  context = hookOutput.additionalContext;
} else if (shape === "cursor") {
  if (hasOwn(payload, "hookSpecificOutput")) {
    fail("cursor output included hookSpecificOutput");
  }
  if (!hasOwn(payload, "additional_context")) {
    fail("cursor output missing additional_context");
  }
  if (hasOwn(payload, "additionalContext")) {
    fail("cursor output included additionalContext");
  }
  context = payload.additional_context;
} else if (shape === "sdk") {
  if (hasOwn(payload, "hookSpecificOutput")) {
    fail("sdk output included hookSpecificOutput");
  }
  if (!hasOwn(payload, "additionalContext")) {
    fail("sdk output missing additionalContext");
  }
  if (hasOwn(payload, "additional_context")) {
    fail("sdk output included additional_context");
  }
  context = payload.additionalContext;
} else {
  fail(`unknown expected shape: ${shape}`);
}

if (typeof context !== "string" || context.trim() === "") {
  fail("injected context was empty");
}

const expectedTexts = (process.env.EXPECT_CONTAINS || "")
  .split("\u001f")
  .filter(Boolean);
for (const expectedText of expectedTexts) {
  if (!context.includes(expectedText)) {
    fail(`context did not contain expected text: ${expectedText}`);
  }
}

const forbiddenTexts = (process.env.EXPECT_NOT_CONTAINS || "")
  .split("\u001f")
  .filter(Boolean);
for (const forbiddenText of forbiddenTexts) {
  if (context.includes(forbiddenText)) {
    fail(`context contained forbidden text: ${forbiddenText}`);
  }
}
'; then
        pass "$description"
    else
        fail "$description"
        echo "    output:"
        echo "$output" | sed 's/^/      /'
    fi
}

echo "SessionStart hook output tests"

# Registration shape: the hook must declare shell:"bash" so Claude Code on
# Windows dispatches via Git Bash (or fails with an actionable error) instead
# of PowerShell/cmd.exe, whose parsers break on the quoted command string
# (PowerShell ParserError; cmd.exe quote-stripping on paths with metacharacters).
if node -e '
const hooks = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const entry = hooks.hooks.SessionStart[0].hooks[0];
if (entry.shell !== "bash") {
  console.error(`SessionStart hook shell is ${JSON.stringify(entry.shell)}, expected "bash"`);
  process.exit(1);
}
if (!/run-hook\.cmd" session-start$/.test(entry.command)) {
  console.error(`unexpected SessionStart command shape: ${entry.command}`);
  process.exit(1);
}
' "$REPO_ROOT/hooks/hooks.json"; then
    pass "hooks.json registers SessionStart with shell:bash dispatch"
else
    fail "hooks.json registers SessionStart with shell:bash dispatch"
fi

claude_home="$(make_home claude-code)"
assert_command_output \
    "Claude Code emits nested SessionStart additionalContext" \
    "nested" \
    "" \
    "" \
    "$claude_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

wrapper_home="$(make_home run-hook-wrapper)"
assert_command_output \
    "run-hook.cmd wrapper dispatches to the named session-start script" \
    "nested" \
    "" \
    "" \
    "$wrapper_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$WRAPPER_UNDER_TEST" session-start

cursor_home="$(make_home cursor)"
assert_command_output \
    "Cursor emits top-level additional_context only" \
    "cursor" \
    "" \
    "" \
    "$cursor_home" \
    CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

copilot_home="$(make_home copilot-cli)"
assert_command_output \
    "Copilot CLI emits top-level additionalContext only" \
    "sdk" \
    "" \
    "" \
    "$copilot_home" \
    COPILOT_CLI=1 \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

legacy_home="$(make_home legacy-warning-removed)"
mkdir -p "$legacy_home/.config/superpowers/skills"
assert_command_output \
    "SessionStart omits obsolete legacy custom-skill warning" \
    "nested" \
    "" \
    "Superpowers now uses"$'\037'"~/.config/superpowers/skills"$'\037'"~/.claude/skills"$'\037'"legacy" \
    "$legacy_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

# --- Per-plugin config (userConfig -> CLAUDE_PLUGIN_OPTION_* -> context) ---

defaults_block="<SUPERPOWERS_CONFIG>"$'\n'"mode: standard"$'\n'"implementer: mechanical=haiku judgment=sonnet effort=low"$'\n'"reviewer: model=sonnet effort=medium"$'\n'"investigator: model=sonnet effort=medium"$'\n'"final-reviewer: model=opus effort=high"$'\n'"</SUPERPOWERS_CONFIG>"

# Default configuration and no configuration must be byte-identical: the
# plugin UI's defaults are the builtin defaults.
baseline_home="$(make_home config-baseline)"
unconfigured="$(env -i PATH="${PATH:-}" HOME="$baseline_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$HOOK_UNDER_TEST")"
default_configured="$(env -i PATH="${PATH:-}" HOME="$baseline_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PLUGIN_OPTION_MODE=standard \
    CLAUDE_PLUGIN_OPTION_IMPLEMENTER_MECHANICAL_MODEL=haiku \
    CLAUDE_PLUGIN_OPTION_IMPLEMENTER_JUDGMENT_MODEL=sonnet \
    CLAUDE_PLUGIN_OPTION_IMPLEMENTER_EFFORT=low \
    CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=sonnet \
    CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT=medium \
    CLAUDE_PLUGIN_OPTION_INVESTIGATOR_MODEL=sonnet \
    CLAUDE_PLUGIN_OPTION_INVESTIGATOR_EFFORT=medium \
    CLAUDE_PLUGIN_OPTION_FINAL_REVIEWER_MODEL=opus \
    CLAUDE_PLUGIN_OPTION_FINAL_REVIEWER_EFFORT=high \
    bash "$HOOK_UNDER_TEST")"
if [[ "$unconfigured" == "$default_configured" ]]; then
    pass "explicit defaults emit byte-identical output to no config"
else
    fail "explicit defaults emit byte-identical output to no config"
fi

assert_command_output \
    "unconfigured hook emits the full defaults block" \
    "nested" \
    "$defaults_block" \
    "warning:" \
    "$baseline_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HOOK_UNDER_TEST"

fast_home="$(make_home config-fast)"
assert_command_output \
    "mode=fast emits mode: fast with every role line" \
    "nested" \
    "<SUPERPOWERS_CONFIG>"$'\n'"mode: fast"$'\n'"implementer: mechanical=haiku"$'\037'"final-reviewer: model=opus effort=high" \
    "" \
    "$fast_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=fast \
    bash "$HOOK_UNDER_TEST"

roles_home="$(make_home config-roles)"
assert_command_output \
    "plugin options set each role's model and effort" \
    "nested" \
    "implementer: mechanical=sonnet judgment=opus effort=high"$'\037'"reviewer: model=opus effort=low"$'\037'"investigator: model=haiku effort=high"$'\037'"final-reviewer: model=claude-opus-5-5 effort=medium" \
    "warning:" \
    "$roles_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_IMPLEMENTER_MECHANICAL_MODEL=sonnet \
    CLAUDE_PLUGIN_OPTION_IMPLEMENTER_JUDGMENT_MODEL=opus \
    CLAUDE_PLUGIN_OPTION_IMPLEMENTER_EFFORT=high \
    CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=opus \
    CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT=low \
    CLAUDE_PLUGIN_OPTION_INVESTIGATOR_MODEL=haiku \
    CLAUDE_PLUGIN_OPTION_INVESTIGATOR_EFFORT=high \
    CLAUDE_PLUGIN_OPTION_FINAL_REVIEWER_MODEL=claude-opus-5-5 \
    CLAUDE_PLUGIN_OPTION_FINAL_REVIEWER_EFFORT=medium \
    bash "$HOOK_UNDER_TEST"

bogus_home="$(make_home config-bogus-mode)"
assert_command_output \
    "unrecognised mode falls back to standard with a warning" \
    "nested" \
    "mode: standard"$'\037'"warning: CLAUDE_PLUGIN_OPTION_MODE ignored: not a valid value for mode (using standard)" \
    "mode: turbo" \
    "$bogus_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=turbo \
    bash "$HOOK_UNDER_TEST"

bogus_effort_home="$(make_home config-bogus-effort)"
assert_command_output \
    "an effort outside low|medium|high falls back with a warning" \
    "nested" \
    "reviewer: model=sonnet effort=medium"$'\037'"warning: CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT ignored: not a valid value for reviewer_effort (using medium)" \
    "effort=xhigh" \
    "$bogus_effort_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT=xhigh \
    bash "$HOOK_UNDER_TEST"

inject_home="$(make_home config-injection)"
assert_command_output \
    "values failing the whitelist are dropped, warned, and JSON stays valid" \
    "nested" \
    "implementer: mechanical=haiku"$'\037'"warning: CLAUDE_PLUGIN_OPTION_IMPLEMENTER_MECHANICAL_MODEL ignored" \
    "\$(id)" \
    "$inject_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_IMPLEMENTER_MECHANICAL_MODEL='he" + $(id) + "llo' \
    bash "$HOOK_UNDER_TEST"

legacy_tier_home="$(make_home config-legacy-tier)"
assert_command_output \
    "legacy tier variables are ignored with a warning" \
    "nested" \
    "reviewer: model=sonnet"$'\037'"warning: SUPERPOWERS_MODEL_STANDARD ignored since 7.0 - use SUPERPOWERS_<ROLE>_MODEL; see release notes"$'\037'"warning: CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE ignored since 7.0" \
    "" \
    "$legacy_tier_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SUPERPOWERS_MODEL_STANDARD=opus \
    CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE=opus \
    bash "$HOOK_UNDER_TEST"

copilot_config_home="$(make_home config-copilot)"
assert_command_output \
    "config block also reaches the Copilot CLI output shape" \
    "sdk" \
    "mode: fast"$'\037'"final-reviewer: model=opus effort=high" \
    "" \
    "$copilot_config_home" \
    COPILOT_CLI=1 \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=fast \
    bash "$HOOK_UNDER_TEST"

cursor_config_home="$(make_home config-cursor)"
assert_command_output \
    "config block also reaches the Cursor output shape" \
    "cursor" \
    "mode: fast"$'\037'"final-reviewer: model=opus effort=high" \
    "" \
    "$cursor_config_home" \
    CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=fast \
    bash "$HOOK_UNDER_TEST"

# --- SUPERPOWERS_* env overrides (env wins over the plugin option) ---
env_fast_home="$(make_home config-env-fast)"
assert_command_output \
    "SUPERPOWERS_MODE=fast alone sets mode: fast" \
    "nested" \
    "<SUPERPOWERS_CONFIG>"$'\n'"mode: fast" \
    "" \
    "$env_fast_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SUPERPOWERS_MODE=fast \
    bash "$HOOK_UNDER_TEST"

env_override_home="$(make_home config-env-override)"
assert_command_output \
    "SUPERPOWERS_MODE=standard force-disables a fast plugin option" \
    "nested" \
    "mode: standard" \
    "mode: fast" \
    "$env_override_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=fast \
    SUPERPOWERS_MODE=standard \
    bash "$HOOK_UNDER_TEST"

env_bogus_home="$(make_home config-env-bogus)"
assert_command_output \
    "SUPERPOWERS_MODE failing the whitelist is warned and the plugin option applies" \
    "nested" \
    "mode: fast"$'\037'"warning: SUPERPOWERS_MODE ignored: not a valid value for mode (using fast)" \
    "\$(id)" \
    "$env_bogus_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=fast \
    SUPERPOWERS_MODE='fast; $(id)' \
    bash "$HOOK_UNDER_TEST"

env_unset_home="$(make_home config-env-unset)"
assert_command_output \
    "empty SUPERPOWERS_MODE defers to the plugin option" \
    "nested" \
    "<SUPERPOWERS_CONFIG>"$'\n'"mode: fast" \
    "warning:" \
    "$env_unset_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=fast \
    SUPERPOWERS_MODE= \
    bash "$HOOK_UNDER_TEST"

env_unset_alone_home="$(make_home config-env-unset-alone)"
env_unset_alone_output="$(env -i PATH="${PATH:-}" HOME="$env_unset_alone_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SUPERPOWERS_MODE= bash "$HOOK_UNDER_TEST")"
if [[ "$env_unset_alone_output" == "$unconfigured" ]]; then
    pass "empty SUPERPOWERS_MODE alone emits byte-identical output to no config"
else
    fail "empty SUPERPOWERS_MODE alone emits byte-identical output to no config"
fi

env_role_wins_home="$(make_home config-env-role-wins)"
assert_command_output \
    "SUPERPOWERS_REVIEWER_MODEL wins over the plugin option" \
    "nested" \
    "reviewer: model=opus effort=medium" \
    "model=sonnet effort=medium"$'\037'"warning:" \
    "$env_role_wins_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=sonnet \
    SUPERPOWERS_REVIEWER_MODEL=opus \
    bash "$HOOK_UNDER_TEST"

env_role_effort_home="$(make_home config-env-role-effort)"
assert_command_output \
    "SUPERPOWERS_FINAL_REVIEWER_EFFORT and SUPERPOWERS_IMPLEMENTER_MECHANICAL_MODEL apply" \
    "nested" \
    "implementer: mechanical=sonnet judgment=sonnet effort=low"$'\037'"final-reviewer: model=opus effort=medium" \
    "warning:" \
    "$env_role_effort_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SUPERPOWERS_FINAL_REVIEWER_EFFORT=medium \
    SUPERPOWERS_IMPLEMENTER_MECHANICAL_MODEL=sonnet \
    bash "$HOOK_UNDER_TEST"

env_role_empty_home="$(make_home config-env-role-empty)"
assert_command_output \
    "empty SUPERPOWERS_REVIEWER_MODEL defers to the plugin option" \
    "nested" \
    "reviewer: model=opus effort=medium" \
    "warning:" \
    "$env_role_empty_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=opus \
    SUPERPOWERS_REVIEWER_MODEL= \
    bash "$HOOK_UNDER_TEST"

env_role_bogus_home="$(make_home config-env-role-bogus)"
assert_command_output \
    "SUPERPOWERS_REVIEWER_MODEL failing the whitelist is warned and the plugin option applies" \
    "nested" \
    "reviewer: model=opus effort=medium"$'\037'"warning: SUPERPOWERS_REVIEWER_MODEL ignored: not a valid value for reviewer_model (using opus)" \
    "x/y" \
    "$env_role_bogus_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=opus \
    SUPERPOWERS_REVIEWER_MODEL='x/y' \
    bash "$HOOK_UNDER_TEST"

# --- systemMessage: warnings also surface to your human partner on Claude Code ---
sysmsg_home="$(make_home config-sysmsg)"
sysmsg_output="$(env -i PATH="${PATH:-}" HOME="$sysmsg_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SUPERPOWERS_MODEL_CHEAP=haiku bash "$HOOK_UNDER_TEST")"
if printf '%s' "$sysmsg_output" | node -e '
const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (typeof p.systemMessage !== "string") process.exit(1);
if (!p.systemMessage.includes("SUPERPOWERS_MODEL_CHEAP ignored since 7.0")) process.exit(1);
'; then
    pass "a warning is also emitted as top-level systemMessage"
else
    fail "a warning is also emitted as top-level systemMessage"
fi

nosysmsg_output="$(env -i PATH="${PATH:-}" HOME="$sysmsg_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$HOOK_UNDER_TEST")"
if printf '%s' "$nosysmsg_output" | node -e '
const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
if ("systemMessage" in p) process.exit(1);
'; then
    pass "no systemMessage without warnings"
else
    fail "no systemMessage without warnings"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi

echo "STATUS: PASSED"
