# Agent Tier Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-on-steroids:subagent-driven-development (recommended) or superpowers-on-steroids:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the configured tier models actually govern which model the bundled `caveman-*` agents run on.

**Architecture:** A shared sourced bash library (`hooks/lib-config`) owns config precedence (env over plugin option, whitelisted). `hooks/session-start` uses it and gains `SUPERPOWERS_MODEL_*` support. A new Claude Code PreToolUse hook (`hooks/agent-tier-gate`) denies `caveman-*` Agent dispatches that omit `model:` while their tier is configured, or fall below their tier floor. One canonical tier table in the subagent-driven-development skill tells every harness which tier each agent takes.

**Tech Stack:** bash (3.2-compatible at runtime, zero dependencies), node (tests only), shellcheck (lint).

**Spec:** `docs/specs/2026-09-24-agent-tier-enforcement-design.md`

## Global Constraints

- Runtime hooks are bash only: no jq, python, or node at hook runtime. Must run on macOS `/bin/bash` 3.2 — no associative arrays, no `${v,,}`, no `+=` on arrays.
- `hooks/lib-config` and `hooks/agent-tier-gate` never use `set -e` or `set -u`. The gate fails open: every path ends `exit 0`, never `exit 2`.
- Config values pass the whitelist `[A-Za-z0-9._-]`; anything else is dropped.
- A non-empty `SUPERPOWERS_MODEL_<TIER>` env var wins over `CLAUDE_PLUGIN_OPTION_MODEL_<TIER>`; an invalid non-empty env value is dropped with no fallback (mirrors `SUPERPOWERS_MODE`).
- `hooks/session-start` output must stay byte-identical when nothing is configured (existing test enforces it).
- Hook JSON is emitted with `printf`, never a heredoc (bash 5.3 heredoc hang, issue #571).
- Commits: Conventional Commits, explicit pathspec, author `Temitayo Osunkiyesi <osunkiyesitayo@gmail.com>` — commit with `git -c user.name="Temitayo Osunkiyesi" -c user.email="osunkiyesitayo@gmail.com" commit ...`.
- Lint: `scripts/lint-shell.sh <files>` must pass for every shell file touched.

## Execution Waves

- Wave 1: Tasks 1, 2 (no dependencies, disjoint files)
- Wave 2: Task 3 (consumes `sp_resolve_tier` from Task 1 and the SDD tier table from Task 2)

---

### Task 1: Shared config library and `SUPERPOWERS_MODEL_*` support in session-start

**Files:**
- Create: `hooks/lib-config`
- Modify: `hooks/session-start` (the per-plugin config block, currently lines 27–60)
- Modify: `.gitattributes`
- Test: `tests/hooks/test-session-start.sh`

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: nothing
- Produces: sourced bash functions in `hooks/lib-config`:
  - `config_value RAW` — prints RAW if it matches `[A-Za-z0-9._-]+`, else nothing; always returns 0.
  - `sp_resolve_mode` — prints `fast` or nothing; always returns 0.
  - `sp_resolve_tier NAME` — NAME is `cheap|standard|capable`; prints the resolved whitelisted model or nothing; always returns 0.

- [ ] **Step 1: Write the failing tests**

In `tests/hooks/test-session-start.sh`, insert this block immediately before the final `if [[ "$FAILURES" -gt 0 ]]; then` line:

```bash
# --- SUPERPOWERS_MODEL_* env override (env wins, like SUPERPOWERS_MODE) ---
env_tiers_home="$(make_home config-env-tiers)"
assert_command_output \
    "SUPERPOWERS_MODEL_* alone emits the tier models line" \
    "nested" \
    "tier models: cheap=haiku standard=sonnet capable=opus" \
    "" \
    "$env_tiers_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    SUPERPOWERS_MODEL_CHEAP=haiku \
    SUPERPOWERS_MODEL_STANDARD=sonnet \
    SUPERPOWERS_MODEL_CAPABLE=opus \
    bash "$HOOK_UNDER_TEST"

env_tier_wins_home="$(make_home config-env-tier-wins)"
assert_command_output \
    "SUPERPOWERS_MODEL_STANDARD wins over the plugin option" \
    "nested" \
    "tier models: standard=opus" \
    "standard=sonnet" \
    "$env_tier_wins_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet \
    SUPERPOWERS_MODEL_STANDARD=opus \
    bash "$HOOK_UNDER_TEST"

env_tier_empty_home="$(make_home config-env-tier-empty)"
assert_command_output \
    "empty SUPERPOWERS_MODEL_STANDARD defers to the plugin option" \
    "nested" \
    "tier models: standard=sonnet" \
    "" \
    "$env_tier_empty_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet \
    SUPERPOWERS_MODEL_STANDARD= \
    bash "$HOOK_UNDER_TEST"

env_tier_bogus_home="$(make_home config-env-tier-bogus)"
assert_command_output \
    "SUPERPOWERS_MODEL_* failing the whitelist is dropped without falling back" \
    "nested" \
    "" \
    "SUPERPOWERS_CONFIG"$'\037'"x/y" \
    "$env_tier_bogus_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODEL_STANDARD=sonnet \
    SUPERPOWERS_MODEL_STANDARD='x/y' \
    bash "$HOOK_UNDER_TEST"
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash tests/hooks/test-session-start.sh`
Expected: `STATUS: FAILED` — the first three new cases fail (session-start ignores `SUPERPOWERS_MODEL_*`); the whitelist case fails too because the option value `sonnet` still emits a block. All pre-existing cases pass.

- [ ] **Step 3: Create `hooks/lib-config`**

```bash
#!/usr/bin/env bash
# Shared config resolution for the superpowers hooks. Sourced, not run.
# No set -e/-u here: each caller picks its own error policy.

# Claude Code exports userConfig options as CLAUDE_PLUGIN_OPTION_<KEY>.
# Whitelist rather than escape: a value that cannot match this pattern
# cannot corrupt the JSON the hooks assemble.
config_value() {
    local raw="${1:-}"
    case "$raw" in
        "") return 0 ;;
        *[!A-Za-z0-9._-]*) return 0 ;;
        *) printf '%s' "$raw" ;;
    esac
}

# SUPERPOWERS_MODE (env, e.g. from a project .envrc) wins over the plugin
# option. Only "fast" prints, so SUPERPOWERS_MODE=standard force-disables.
sp_resolve_mode() {
    local mode
    mode="$(config_value "${SUPERPOWERS_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-}}")"
    if [ "$mode" = "fast" ]; then
        printf 'fast'
    fi
}

# Tier model for cheap|standard|capable. A non-empty SUPERPOWERS_MODEL_<TIER>
# wins over the plugin option, same as SUPERPOWERS_MODE.
sp_resolve_tier() {
    local env_raw="" opt_raw=""
    case "${1:-}" in
        cheap)
            env_raw="${SUPERPOWERS_MODEL_CHEAP:-}"
            opt_raw="${CLAUDE_PLUGIN_OPTION_MODEL_CHEAP:-}"
            ;;
        standard)
            env_raw="${SUPERPOWERS_MODEL_STANDARD:-}"
            opt_raw="${CLAUDE_PLUGIN_OPTION_MODEL_STANDARD:-}"
            ;;
        capable)
            env_raw="${SUPERPOWERS_MODEL_CAPABLE:-}"
            opt_raw="${CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE:-}"
            ;;
        *) return 0 ;;
    esac
    config_value "${env_raw:-$opt_raw}"
}
```

- [ ] **Step 4: Make session-start use the library**

In `hooks/session-start`, replace this exact block:

```bash
# Per-plugin config. Claude Code exports userConfig options as
# CLAUDE_PLUGIN_OPTION_<KEY> (key uppercased, non-alphanumerics -> _).
# Whitelist rather than escape: a value that cannot match this pattern
# cannot corrupt the JSON string assembled below.
config_value() {
    local raw="${1:-}"
    case "$raw" in
        "") return 0 ;;
        *[!A-Za-z0-9._-]*) return 0 ;;
        *) printf '%s' "$raw" ;;
    esac
}

# SUPERPOWERS_MODE (env, e.g. from a project .envrc) wins over the plugin
# option. Only "fast" emits, so SUPERPOWERS_MODE=standard force-disables.
sp_mode="$(config_value "${SUPERPOWERS_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-}}")"
# standard is the absence of fast, so it says nothing and emits nothing.
if [ "$sp_mode" != "fast" ]; then
    sp_mode=""
fi

sp_tiers=""
for tier_name in cheap standard capable; do
    case "$tier_name" in
        cheap)    tier_raw="${CLAUDE_PLUGIN_OPTION_MODEL_CHEAP:-}" ;;
        standard) tier_raw="${CLAUDE_PLUGIN_OPTION_MODEL_STANDARD:-}" ;;
        capable)  tier_raw="${CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE:-}" ;;
        *)        tier_raw="" ;;
    esac
    tier_model="$(config_value "$tier_raw")"
    if [ -n "$tier_model" ]; then
        sp_tiers="${sp_tiers} ${tier_name}=${tier_model}"
    fi
done
```

with:

```bash
# Per-plugin config. Claude Code exports userConfig options as
# CLAUDE_PLUGIN_OPTION_<KEY>; lib-config applies the SUPERPOWERS_* env
# overrides and the whitelist that keeps the JSON below intact.
# shellcheck source=lib-config
. "${SCRIPT_DIR}/lib-config"

# standard is the absence of fast, so it says nothing and emits nothing.
sp_mode="$(sp_resolve_mode)"

sp_tiers=""
for tier_name in cheap standard capable; do
    tier_model="$(sp_resolve_tier "$tier_name")"
    if [ -n "$tier_model" ]; then
        sp_tiers="${sp_tiers} ${tier_name}=${tier_model}"
    fi
done
```

- [ ] **Step 5: Keep LF endings for the new hook files**

In `.gitattributes`, replace:

```
hooks/session-start text eol=lf
```

with:

```
hooks/session-start text eol=lf
hooks/lib-config text eol=lf
hooks/agent-tier-gate text eol=lf
```

- [ ] **Step 6: Run tests and lint**

Run: `bash tests/hooks/test-session-start.sh`
Expected: `STATUS: PASSED` (including "mode=standard emits byte-identical output to no config").

Run: `bash tests/agents/test-fast-mode-contract.sh`
Expected: `STATUS: PASSED` (wiring still sees `mode: fast` emitted).

Run: `scripts/lint-shell.sh hooks/lib-config hooks/session-start tests/hooks/test-session-start.sh`
Expected: exit 0, no findings.

- [ ] **Step 7: Commit**

```bash
git add hooks/lib-config hooks/session-start .gitattributes tests/hooks/test-session-start.sh
git -c user.name="Temitayo Osunkiyesi" -c user.email="osunkiyesitayo@gmail.com" commit -m "feat(hooks): honour SUPERPOWERS_MODEL_* tier overrides" -- hooks/lib-config hooks/session-start .gitattributes tests/hooks/test-session-start.sh
```

---

### Task 2: Canonical tier table, re-review tier, investigator effort, config docs

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md` (Fix Loop re-review paragraph ~line 166; Model Selection ~lines 236 and 244–250; Fast Mode ~line 275)
- Modify: `skills/subagent-driven-development/re-review-prompt.md` (~line 103)
- Modify: `skills/brainstorming/SKILL.md` (checklist step 2, line 29)
- Modify: `skills/requesting-code-review/SKILL.md` (~line 39)
- Modify: `agents/caveman-investigator.md` (frontmatter `effort`)
- Modify: `.claude-plugin/plugin.json` (the three `model_*` descriptions)
- Test: `tests/agents/test-fast-mode-contract.sh`

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: nothing
- Produces: the SDD Model Selection tier table. Task 3's wiring test parses rows of exactly this shape — first cell is the backticked agent name, second the tier(s) joined by ` or `, third the floor tier or `none`:
  `| \`caveman-reviewer\` | standard | standard | ... |`

- [ ] **Step 1: Write the failing contract tests**

In `tests/agents/test-fast-mode-contract.sh`, insert this block immediately after the line `assert_in_file "review tier" "fix loop capped at 3 rounds" "$sdd_skill"`:

```bash

# --- Tier table: every caveman agent has a tier; dispatching skills name theirs ---
assert_in_file "tier table" '| `caveman-implementer` | cheap or standard | none |' "$sdd_skill"
assert_in_file "tier table" '| `caveman-reviewer` | standard | standard |' "$sdd_skill"
assert_in_file "tier table" '| `caveman-investigator` | standard | none |' "$sdd_skill"
assert_in_file "tier table" '| `caveman-final-reviewer` | capable | capable |' "$sdd_skill"
assert_in_file "tier table" 'Every `superpowers-on-steroids:caveman-*`' "$sdd_skill"
assert_in_file "re-review tier" 'in re-review mode on the standard tier' "$sdd_skill"
assert_in_file "re-review tier" "fast mode's \`caveman-reviewer\` re-review takes the standard tier" "$sdd_skill"
assert_in_file "re-review tier" "fast mode's" "$rereview_tmpl"
assert_in_file "investigator tier" '`superpowers-on-steroids:caveman-investigator` on the standard tier' \
    "$REPO_ROOT/skills/brainstorming/SKILL.md"
assert_in_file "final reviewer tier" '`superpowers-on-steroids:caveman-final-reviewer` on the capable tier' \
    "$REPO_ROOT/skills/requesting-code-review/SKILL.md"
for tier in CHEAP STANDARD CAPABLE; do
    assert_in_file "plugin.json env override" "SUPERPOWERS_MODEL_${tier}" "$REPO_ROOT/.claude-plugin/plugin.json"
done

# Fast mode promises lower effort, and effort cannot be raised at dispatch.
if grep -qE '^effort: medium$' "$AGENTS_DIR/caveman-investigator.md"; then
    pass "caveman-investigator: effort medium"
else
    fail "caveman-investigator: effort must be medium"
fi
```

- [ ] **Step 2: Run the contract test to verify it fails**

Run: `bash tests/agents/test-fast-mode-contract.sh`
Expected: `STATUS: FAILED` — every new assertion fails; all pre-existing ones pass.

- [ ] **Step 3: SDD — Fix Loop re-review tier**

In `skills/subagent-driven-development/SKILL.md`, replace:

```
[re-review-prompt.md](re-review-prompt.md) on a cheap-to-mid tier — in fast
mode, `superpowers-on-steroids:caveman-reviewer` in re-review mode. The
```

with:

```
[re-review-prompt.md](re-review-prompt.md) on a cheap-to-mid tier — in fast
mode, `superpowers-on-steroids:caveman-reviewer` in re-review mode on the standard tier
(its floor; see Model Selection). The
```

- [ ] **Step 4: SDD — Model Selection re-review line**

Replace:

```
Scoped re-reviews of small fix diffs take a cheap-to-mid tier. The round-3
fix escalation in the Fix Loop takes the capable tier.
```

with:

```
Scoped re-reviews of small fix diffs take a cheap-to-mid tier on the inline
template; fast mode's `caveman-reviewer` re-review takes the standard tier.
The round-3 fix escalation in the Fix Loop takes the capable tier.
```

- [ ] **Step 5: SDD — the canonical tier table**

Replace:

```
tier a task *needs* — that stays with the heuristics above, including the
mid-tier floor for reviewers.

## Fast Mode
```

with:

```
tier a task *needs* — that stays with the heuristics above, including the
mid-tier floor for reviewers.

**The bundled agents take fixed tiers.** Every `superpowers-on-steroids:caveman-*`
dispatch passes `model:` explicitly, resolved from the tier below. An omitted
model falls back to the agent's pinned frontmatter model and ignores the
configured tiers. On Claude Code a hook denies a `caveman-*` dispatch that
omits `model:` while its tier is configured, or that falls below its floor,
and names the model to pass.

| Agent | Tier | Floor | When |
|---|---|---|---|
| `caveman-implementer` | cheap or standard | none | cheap when the brief carries the complete code or the fix is single-file; standard for integration and judgment |
| `caveman-reviewer` | standard | standard | every task review, and every fast-mode re-review |
| `caveman-investigator` | standard | none | context gathering and design research |
| `caveman-final-reviewer` | capable | capable | the final whole-branch review |

## Fast Mode
```

- [ ] **Step 6: SDD — Fast Mode model sentence**

Replace:

```
Model selection is unchanged in fast mode — resolve the tier as always and pass
`model:` explicitly. Effort is fixed by each agent's definition and cannot be
raised at dispatch.
```

with:

```
Model selection is unchanged in fast mode — resolve each agent's tier from the
table in Model Selection and pass `model:` explicitly. Effort is fixed by each
agent's definition and cannot be raised at dispatch.
```

- [ ] **Step 7: re-review template placeholder**

In `skills/subagent-driven-development/re-review-prompt.md`, replace:

```
- `[MODEL]` — REQUIRED: reviewer model per SKILL.md Model Selection; scoped
  re-reviews of small fix diffs take a cheap-to-mid tier
```

with:

```
- `[MODEL]` — REQUIRED: reviewer model per SKILL.md Model Selection; scoped
  re-reviews of small fix diffs take a cheap-to-mid tier (fast mode's
  `caveman-reviewer` re-review takes the standard tier instead)
```

- [ ] **Step 8: brainstorming step 2**

In `skills/brainstorming/SKILL.md`, replace:

```
dispatch `superpowers-on-steroids:caveman-investigator` to gather this instead of exploring inline.
```

with:

```
dispatch `superpowers-on-steroids:caveman-investigator` on the standard tier (see subagent-driven-development Model Selection) to gather this instead of exploring inline.
```

- [ ] **Step 9: requesting-code-review final reviewer**

In `skills/requesting-code-review/SKILL.md`, replace:

```
package. Then dispatch `superpowers-on-steroids:caveman-final-reviewer` instead,
```

with:

```
package. Then dispatch `superpowers-on-steroids:caveman-final-reviewer` on the capable tier
(see subagent-driven-development Model Selection) instead,
```

- [ ] **Step 10: Investigator effort**

In `agents/caveman-investigator.md` frontmatter, replace `effort: high` with `effort: medium`.

- [ ] **Step 11: plugin.json tier descriptions**

In `.claude-plugin/plugin.json`, replace the three `model_*` description values:

- `model_cheap`: `"Model for mechanical, fully-specified work — single-file transcription tasks. Leave empty to let the agent judge what this harness offers. The SUPERPOWERS_MODEL_CHEAP environment variable overrides this (env wins). On Claude Code, use an Agent-tool model alias such as haiku, sonnet, or opus."`
- `model_standard`: `"Model for integration and judgment work, and the floor for reviewers. Leave empty to let the agent judge. The SUPERPOWERS_MODEL_STANDARD environment variable overrides this (env wins). On Claude Code, use an Agent-tool model alias such as haiku, sonnet, or opus."`
- `model_capable`: `"Model for architecture, design, and the final whole-branch review. Leave empty to let the agent judge. The SUPERPOWERS_MODEL_CAPABLE environment variable overrides this (env wins). On Claude Code, use an Agent-tool model alias such as haiku, sonnet, or opus."`

Verify it still parses: `node -e 'JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8"))'` → no output, exit 0.

- [ ] **Step 12: Run tests**

Run: `bash tests/agents/test-fast-mode-contract.sh`
Expected: `STATUS: PASSED`.

- [ ] **Step 13: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md skills/subagent-driven-development/re-review-prompt.md skills/brainstorming/SKILL.md skills/requesting-code-review/SKILL.md agents/caveman-investigator.md .claude-plugin/plugin.json tests/agents/test-fast-mode-contract.sh
git -c user.name="Temitayo Osunkiyesi" -c user.email="osunkiyesitayo@gmail.com" commit -m "fix(sdd): give every caveman agent a tier and lower investigator effort" -- skills/subagent-driven-development/SKILL.md skills/subagent-driven-development/re-review-prompt.md skills/brainstorming/SKILL.md skills/requesting-code-review/SKILL.md agents/caveman-investigator.md .claude-plugin/plugin.json tests/agents/test-fast-mode-contract.sh
```

---

### Task 3: PreToolUse tier gate for caveman agent dispatches

**Files:**
- Create: `hooks/agent-tier-gate` (executable)
- Modify: `hooks/hooks.json`
- Test: `tests/hooks/test-agent-tier-gate.sh`

**Depends on:** Task 1 (`hooks/lib-config`: `sp_resolve_tier`), Task 2 (SDD tier table rows)

**Review tier:** judgment

**Interfaces:**
- Consumes: `sp_resolve_tier NAME` from `hooks/lib-config` (prints resolved model or nothing). SDD table rows `| \`<agent>\` | <tiers joined by " or "> | <floor or none> | ... |`.
- Produces: Claude Code PreToolUse hook. Stdin: hook JSON with `tool_input.subagent_type` / `tool_input.model`. Stdout on deny: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}`; on allow: nothing. Always exit 0.

- [ ] **Step 1: Write the failing test**

Create `tests/hooks/test-agent-tier-gate.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/hooks/test-agent-tier-gate.sh`
Expected: `STATUS: FAILED` — the registration check fails (no PreToolUse entry), every `expect_deny` fails (gate missing, wrapper errors), and the wiring checks fail (no gate file). Some `expect_allow` cases may pass by accident; that is fine.

- [ ] **Step 3: Create the gate**

Create `hooks/agent-tier-gate`:

```bash
#!/usr/bin/env bash
# PreToolUse gate for Claude Code Agent dispatches of the caveman-* agents.
# Denies a dispatch that would run config-blind (no model: while its tier is
# configured) or below its tier floor. Fails open on anything unexpected:
# a broken gate must never block dispatch. No set -e/-u on purpose.

# Only Claude Code has this contract. Cursor and Copilot CLI may run the
# same hook files; stay out of their way.
[ -n "${CURSOR_PLUGIN_ROOT:-}" ] && exit 0
[ -n "${COPILOT_CLI:-}" ] && exit 0
[ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 0
# shellcheck source=lib-config
. "${SCRIPT_DIR}/lib-config" 2>/dev/null || exit 0

input=""
IFS= read -r -d '' input
[ -n "$input" ] || exit 0

# Walk the JSON one quote at a time with read -d, which stays linear where
# bash 3.2's pattern expansions go quadratic on big prompts. Segments
# alternate structure / string. A quote after an odd run of backslashes is
# escaped and keeps the string open, so prompt text can never pose as a key.
# Only tool_input's own keys (depth 2 under the depth-1 "tool_input") count.
depth=0
ti_state=0 # 0 not seen, 1 inside, 2 closed
in_str=0
str=""
key=""
pending="" # key whose string value comes next
subagent="" subagent_seen=0
model="" model_seen=0
done_reading=0

count_depth() {
    local opens="${1//[^\{\[]/}" closes="${1//[^\}\]]/}"
    depth=$((depth + ${#opens} - ${#closes}))
}

while [ "$done_reading" -eq 0 ]; do
    seg=""
    IFS= read -r -d '"' seg || done_reading=1

    if [ "$in_str" -eq 1 ]; then
        # Input ended inside a string.
        [ "$done_reading" -eq 1 ] && exit 0
        body="$seg"
        slashes=0
        while [ "${body%\\}" != "$body" ]; do
            body="${body%\\}"
            slashes=$((slashes + 1))
        done
        # Keys and model names are short; capping keeps huge prompts linear.
        if [ "${#str}" -lt 256 ]; then
            str="$str$seg"
            [ $((slashes % 2)) -eq 1 ] && str="$str\""
        fi
        [ $((slashes % 2)) -eq 1 ] && continue
        in_str=0
        if [ -n "$pending" ]; then
            case "$pending" in
                subagent_type) subagent="$str" ;;
                model) model="$str" ;;
            esac
            pending=""
        else
            key="$str"
        fi
        str=""
        continue
    fi

    # Structure segment. A string followed by ':' was a key.
    if [ -n "$key" ]; then
        after="${seg#"${seg%%[![:space:]]*}"}"
        case "$after" in
            :*)
                value="${after#:}"
                value="${value#"${value%%[![:space:]]*}"}"
                if [ "$depth" -eq 1 ] && [ "$key" = "tool_input" ]; then
                    [ "$ti_state" -eq 0 ] || exit 0
                    case "$value" in
                        \{*) ti_state=1 ;;
                        *) exit 0 ;;
                    esac
                elif [ "$ti_state" -eq 1 ] && [ "$depth" -eq 2 ]; then
                    case "$key" in
                        subagent_type)
                            [ "$subagent_seen" -eq 0 ] || exit 0
                            subagent_seen=1
                            case "$value" in
                                "") pending="subagent_type" ;;
                                *) exit 0 ;;
                            esac
                            ;;
                        model)
                            [ "$model_seen" -eq 0 ] || exit 0
                            model_seen=1
                            case "$value" in
                                "") pending="model" ;;
                                null*) model="" ;;
                                *) exit 0 ;;
                            esac
                            ;;
                    esac
                fi
                ;;
        esac
        key=""
    fi

    count_depth "$seg"
    if [ "$ti_state" -eq 1 ] && [ "$depth" -lt 2 ]; then
        ti_state=2
    fi
    [ "$done_reading" -eq 0 ] && in_str=1
done <<<"$input"

[ "$depth" -eq 0 ] || exit 0
[ "$ti_state" -eq 2 ] || exit 0
[ -z "$pending" ] || exit 0

# Tier policy. Keep in step with the tier table in
# skills/subagent-driven-development/SKILL.md (Model Selection).
case "$subagent" in
    superpowers-on-steroids:caveman-implementer) agent="caveman-implementer" tiers="cheap standard" floor="" ;;
    superpowers-on-steroids:caveman-reviewer) agent="caveman-reviewer" tiers="standard" floor="standard" ;;
    superpowers-on-steroids:caveman-investigator) agent="caveman-investigator" tiers="standard" floor="" ;;
    superpowers-on-steroids:caveman-final-reviewer) agent="caveman-final-reviewer" tiers="capable" floor="capable" ;;
    *) exit 0 ;;
esac

tier_cheap="$(sp_resolve_tier cheap)"
tier_standard="$(sp_resolve_tier standard)"
tier_capable="$(sp_resolve_tier capable)"

tier_model() {
    case "$1" in
        cheap) printf '%s' "$tier_cheap" ;;
        standard) printf '%s' "$tier_standard" ;;
        capable) printf '%s' "$tier_capable" ;;
    esac
}

tier_rank() {
    case "$1" in
        cheap) printf 1 ;;
        standard) printf 2 ;;
        capable) printf 3 ;;
    esac
}

builtin_rank() {
    case "$1" in
        haiku) printf 1 ;;
        sonnet) printf 2 ;;
        opus) printf 3 ;;
        *) printf 0 ;;
    esac
}

builtin_name() {
    case "$1" in
        standard) printf sonnet ;;
        capable) printf opus ;;
    esac
}

# Reasons carry only fixed text and whitelisted config values, so the only
# JSON escaping needed is around the quoted model names.
q='\"'

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}

if [ -z "$model" ]; then
    offer=""
    for t in $tiers; do
        v="$(tier_model "$t")"
        [ -n "$v" ] || continue
        if [ "$agent" = "caveman-implementer" ]; then
            case "$t" in
                cheap) label="cheap tier, transcription or single-file work" ;;
                standard) label="standard tier, integration or judgment work" ;;
            esac
        else
            label="$t tier"
        fi
        [ -n "$offer" ] && offer="$offer or "
        offer="${offer}${q}${v}${q} (${label})"
    done
    # Nothing configured: the agent's frontmatter model is the default.
    [ -n "$offer" ] || exit 0
    deny "$agent runs config-blind without model: pass model: $offer on this Agent call."
fi

[ -n "$floor" ] || exit 0

# Rank against the configured tiers only when the floor tier itself is
# configured. With it unconfigured the gate names a built-in model, and a
# configured lower tier sharing that name must not deny it again.
floor_model="$(tier_model "$floor")"
rank=0
if [ -n "$floor_model" ]; then
    for t in cheap standard capable; do
        v="$(tier_model "$t")"
        [ -n "$v" ] && [ "$model" = "$v" ] && rank="$(tier_rank "$t")"
    done
fi
[ "$rank" -eq 0 ] && rank="$(builtin_rank "$model")"
# Unknown model: not ours to judge.
[ "$rank" -eq 0 ] && exit 0
[ "$rank" -ge "$(tier_rank "$floor")" ] && exit 0

[ -n "$floor_model" ] || floor_model="$(builtin_name "$floor")"
deny "$agent needs the $floor tier or higher: pass model: ${q}${floor_model}${q} on this Agent call."
```

Then: `chmod +x hooks/agent-tier-gate`

- [ ] **Step 4: Register the hook**

Replace the whole of `hooks/hooks.json` with:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" session-start",
            "shell": "bash",
            "async": false
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Agent|Task",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" agent-tier-gate",
            "shell": "bash",
            "async": false
          }
        ]
      }
    ]
  }
}
```

Do not touch `hooks/hooks-cursor.json`.

- [ ] **Step 5: Run tests and lint**

Run: `bash tests/hooks/test-agent-tier-gate.sh`
Expected: `STATUS: PASSED`.

Run: `bash tests/hooks/test-session-start.sh`
Expected: `STATUS: PASSED` (its SessionStart registration check reads `hooks.SessionStart[0]`, unchanged).

Run on macOS bash 3.2 too (skip if `/bin/bash` is not 3.x): create a shim dir with `ln -s /bin/bash "$SHIM/bash"` and run `PATH="$SHIM:$PATH" bash tests/hooks/test-agent-tier-gate.sh`. Expected: `STATUS: PASSED`, and the ~100 KB case within its 10 s bound.

Run: `scripts/lint-shell.sh hooks/agent-tier-gate tests/hooks/test-agent-tier-gate.sh`
Expected: exit 0, no findings.

- [ ] **Step 6: Commit**

```bash
git add hooks/agent-tier-gate hooks/hooks.json tests/hooks/test-agent-tier-gate.sh
git -c user.name="Temitayo Osunkiyesi" -c user.email="osunkiyesitayo@gmail.com" commit -m "fix(hooks): deny config-blind caveman agent dispatches" -- hooks/agent-tier-gate hooks/hooks.json tests/hooks/test-agent-tier-gate.sh
```
