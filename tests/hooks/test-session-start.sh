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

const expectedText = process.env.EXPECT_CONTAINS || "";
if (expectedText && !context.includes(expectedText)) {
  fail(`context did not contain expected text: ${expectedText}`);
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

# Default configuration must not perturb the injected context at all: the
# eval baseline depends on this output staying byte-identical.
baseline_home="$(make_home config-baseline)"
unconfigured="$(env -i PATH="${PATH:-}" HOME="$baseline_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$HOOK_UNDER_TEST")"
default_configured="$(env -i PATH="${PATH:-}" HOME="$baseline_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PLUGIN_OPTION_MODE=standard \
    bash "$HOOK_UNDER_TEST")"
if [[ "$unconfigured" == "$default_configured" ]]; then
    pass "mode=standard emits byte-identical output to no config"
else
    fail "mode=standard emits byte-identical output to no config"
fi

if printf '%s' "$unconfigured" | grep -q "SUPERPOWERS_CONFIG"; then
    fail "unconfigured hook omits the config block"
else
    pass "unconfigured hook omits the config block"
fi

fast_home="$(make_home config-fast)"
assert_command_output \
    "mode=fast emits the config block" \
    "nested" \
    "<SUPERPOWERS_CONFIG>"$'\n'"mode: fast" \
    "" \
    "$fast_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=fast \
    bash "$HOOK_UNDER_TEST"

tiers_home="$(make_home config-tiers)"
assert_command_output \
    "tier models line lists only the tiers that are set, in fixed order" \
    "nested" \
    "tier models: cheap=haiku capable=opus" \
    "" \
    "$tiers_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODEL_CHEAP=haiku \
    CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE=opus \
    bash "$HOOK_UNDER_TEST"

bogus_home="$(make_home config-bogus-mode)"
assert_command_output \
    "unrecognised mode falls back to standard (no block)" \
    "nested" \
    "" \
    "SUPERPOWERS_CONFIG" \
    "$bogus_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=turbo \
    bash "$HOOK_UNDER_TEST"

inject_home="$(make_home config-injection)"
assert_command_output \
    "values failing the whitelist are dropped and JSON stays valid" \
    "nested" \
    "" \
    "SUPERPOWERS_CONFIG"$'\037'"\$(id)" \
    "$inject_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODEL_CHEAP='he" + $(id) + "llo' \
    bash "$HOOK_UNDER_TEST"

copilot_config_home="$(make_home config-copilot)"
assert_command_output \
    "config block also reaches the Copilot CLI output shape" \
    "sdk" \
    "mode: fast" \
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
    "mode: fast" \
    "" \
    "$cursor_config_home" \
    CURSOR_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=fast \
    bash "$HOOK_UNDER_TEST"

# --- SUPERPOWERS_MODE env override (per-project opt-in; env wins) ---
env_fast_home="$(make_home config-env-fast)"
assert_command_output \
    "SUPERPOWERS_MODE=fast alone emits the config block" \
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
    "" \
    "SUPERPOWERS_CONFIG" \
    "$env_override_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=fast \
    SUPERPOWERS_MODE=standard \
    bash "$HOOK_UNDER_TEST"

env_bogus_home="$(make_home config-env-bogus)"
assert_command_output \
    "SUPERPOWERS_MODE failing the whitelist is dropped (no block)" \
    "nested" \
    "" \
    "SUPERPOWERS_CONFIG" \
    "$env_bogus_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SUPERPOWERS_MODE='fast; $(id)' \
    bash "$HOOK_UNDER_TEST"

env_unset_home="$(make_home config-env-unset)"
env_unset_output="$(env -i PATH="${PATH:-}" HOME="$env_unset_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" SUPERPOWERS_MODE= bash "$HOOK_UNDER_TEST")"
if [[ "$env_unset_output" == "$unconfigured" ]]; then
    pass "empty SUPERPOWERS_MODE emits byte-identical output to no config"
else
    fail "empty SUPERPOWERS_MODE emits byte-identical output to no config"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi

echo "STATUS: PASSED"
