# Per-Role Model and Effort Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-on-steroids:subagent-driven-development (recommended) or superpowers-on-steroids:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the cheap/standard/capable tier config with per-role model + effort config, enforced by a simplified gate, with effort delivered through generated agent variants.

**Architecture:** One bash resolver (`hooks/lib-config`) turns plugin options / env into a fully-populated role config (env → plugin option → builtin default, never empty). `hooks/session-start` injects it as `<SUPERPOWERS_CONFIG>`; `hooks/agent-config-gate` denies any `caveman-*` dispatch whose variant suffix or `model:` does not match. Effort is pinned per agent file, so four templates in `scripts/agent-templates/` generate twelve `agents/caveman-<role>-<effort>.md` files via `scripts/gen-agent-variants`; skills dispatch the variant named by the block.

**Tech Stack:** bash 3.2-compatible shell (macOS `/bin/bash`), node (tests only), Claude Code plugin manifest `userConfig`.

**Spec:** `docs/specs/2026-10-06-per-role-agent-config-design.md`

## Global Constraints

- Zero third-party dependencies. Hooks must run on macOS `/bin/bash` 3.2: no `${var^^}`, no associative arrays, no `mapfile`.
- Hook JSON safety: only values that passed `config_value`'s `[A-Za-z0-9._-]` whitelist, or fixed text, may be interpolated into hook JSON. Never echo raw env values or raw `subagent_type` into a deny reason or the config block.
- The gate fails open (`exit 0`) on Cursor (`CURSOR_PLUGIN_ROOT`), Copilot CLI (`COPILOT_CLI`), missing `CLAUDE_PLUGIN_ROOT`, malformed JSON, and non-caveman subagents. Never `set -e/-u` in the gate.
- Variant set is exactly `low medium high`; roles are exactly `implementer reviewer investigator final-reviewer`; builtin defaults: implementer mechanical `haiku`, judgment `sonnet`, effort `low`; reviewer `sonnet`/`medium`; investigator `sonnet`/`medium`; final-reviewer `opus`/`high`. Every one of these literals must agree across plugin.json, lib-config, the generator, the gate, and the SDD table (Task 6 enforces).
- Agent `name:` values use lowercase letters and hyphens only; YAML description values must not contain `: ` (colon-space).
- Templates live in `scripts/agent-templates/` (not `agents-src/` as the spec first said): `scripts/` is already excluded from the Codex sync and no harness loads it. Task 7 amends the spec.
- Skill text uses "your human partner", never "the user". Do not touch `writing-plans` "Review tier" (transcription/judgment) — unrelated concept.
- Commits: Conventional Commits. The plugin.json commit (Task 3) carries `feat!` + `BREAKING CHANGE:` footer; the version bump commit is `chore: release notes and version bump to 7.0.0`.
- Tests are plain bash; run only the task's own test file(s). One test-running agent at a time.

## Execution Waves

- Wave 1: Task 1 (resolver + session-start), Task 2 (templates + generator + variants), Task 3 (plugin.json) — no dependencies, disjoint files
- Wave 2: Task 4 (gate; depends on 1), Task 5 (skills + contract test; depends on 2, 3)
- Wave 3: Task 6 (wiring test; depends on 1–5), Task 7 (docs + release; depends on 1–5) — disjoint files

---

### Task 1: Role resolver and config block

**Files:**
- Modify: `hooks/lib-config` (whole file)
- Modify: `hooks/session-start:28-57, 68-77`
- Test: `tests/hooks/test-session-start.sh:228-417`

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: nothing
- Produces (sourced bash functions in `hooks/lib-config`):
  - `config_value RAW` — unchanged; prints RAW iff it matches `[A-Za-z0-9._-]+`.
  - `SP_ROLES="implementer reviewer investigator final-reviewer"`, `SP_EFFORTS="low medium high"`, `SP_KEYS="mode implementer_mechanical_model implementer_judgment_model implementer_effort reviewer_model reviewer_effort investigator_model investigator_effort final_reviewer_model final_reviewer_effort"`.
  - `sp_default KEY` — prints the builtin default for a key in `SP_KEYS`.
  - `sp_setting KEY` — env `SUPERPOWERS_<UPPER>` → plugin option `CLAUDE_PLUGIN_OPTION_<UPPER>` → `sp_default`; never empty.
  - `sp_resolve_mode` — prints `fast` or `standard`.
  - `sp_role_model ROLE [mechanical|judgment]` — prints the model for a role (implementer defaults to `judgment`).
  - `sp_role_effort ROLE` — prints `low|medium|high`.
  - `sp_config_warnings` — prints zero or more `warning: ...` lines (rejected values, legacy tier vars).
  - Emitted block shape (exact):
    ```
    <SUPERPOWERS_CONFIG>
    mode: fast
    implementer: mechanical=haiku judgment=sonnet effort=low
    reviewer: model=sonnet effort=medium
    investigator: model=sonnet effort=medium
    final-reviewer: model=opus effort=high
    warning: ...            (only when there are warnings)
    </SUPERPOWERS_CONFIG>
    ```

- [ ] **Step 1: Rewrite the config tests**

Replace `tests/hooks/test-session-start.sh` lines 228–417 (from the comment `# --- Per-plugin config ...` through the last `assert_command_output` before the `if [[ "$FAILURES" -gt 0 ]]` footer) with:

```bash
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
    "<SUPERPOWERS_CONFIG>"$'\n'"mode: fast"$'\n'"implementer: mechanical=haiku"$'\037'"final-reviewer: model=opus effort=high"$'\n'"</SUPERPOWERS_CONFIG>" \
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
```

Note: `assert_command_output`'s `contains`/`not_contains` arguments are `$'\037'`-separated lists (see the helper at the top of the file); an empty string means "no constraint".

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/hooks/test-session-start.sh`
Expected: FAIL — "unconfigured hook emits the full defaults block" and the role/warning tests fail (hook still emits `tier models:` or no block).

- [ ] **Step 3: Rewrite `hooks/lib-config`**

Replace the whole file with:

```bash
#!/usr/bin/env bash
# Shared config resolution for the superpowers hooks. Sourced, not run.
# No set -e/-u here: each caller picks its own error policy.
# bash 3.2 compatible: no ${var^^}, no associative arrays.

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

SP_ROLES="implementer reviewer investigator final-reviewer"
SP_EFFORTS="low medium high"
SP_KEYS="mode implementer_mechanical_model implementer_judgment_model implementer_effort reviewer_model reviewer_effort investigator_model investigator_effort final_reviewer_model final_reviewer_effort"

# Builtin defaults. Keep in step with userConfig defaults in
# .claude-plugin/plugin.json (tests/hooks/test-config-wiring.sh checks).
sp_default() {
    case "$1" in
        mode) printf standard ;;
        implementer_mechanical_model) printf haiku ;;
        implementer_judgment_model) printf sonnet ;;
        implementer_effort) printf low ;;
        reviewer_model) printf sonnet ;;
        reviewer_effort) printf medium ;;
        investigator_model) printf sonnet ;;
        investigator_effort) printf medium ;;
        final_reviewer_model) printf opus ;;
        final_reviewer_effort) printf high ;;
    esac
}

# sp_upper KEY — role_key -> ROLE_KEY (hyphens become underscores too).
sp_upper() {
    printf '%s' "$1" | tr 'a-z-' 'A-Z_'
}

# sp_accept KEY RAW — prints RAW when it is a usable value for KEY, else nothing.
sp_accept() {
    local key="$1" val
    val="$(config_value "${2:-}")"
    [ -n "$val" ] || return 0
    case "$key" in
        mode) case "$val" in standard|fast) printf '%s' "$val" ;; esac ;;
        *_effort) case "$val" in low|medium|high) printf '%s' "$val" ;; esac ;;
        *) printf '%s' "$val" ;;
    esac
}

# sp_setting KEY — env SUPERPOWERS_<KEY> wins over the plugin option, which
# wins over the builtin default. Never empty: every role is always configured.
sp_setting() {
    local key="$1" upper env_name opt_name val
    upper="$(sp_upper "$key")"
    env_name="SUPERPOWERS_${upper}"
    opt_name="CLAUDE_PLUGIN_OPTION_${upper}"
    val="$(sp_accept "$key" "${!env_name:-}")"
    [ -n "$val" ] || val="$(sp_accept "$key" "${!opt_name:-}")"
    [ -n "$val" ] || val="$(sp_default "$key")"
    printf '%s' "$val"
}

sp_resolve_mode() {
    sp_setting mode
}

# sp_role_model ROLE [mechanical|judgment] — implementer has two models.
sp_role_model() {
    local role="$1" key
    case "$role" in
        implementer) key="implementer_${2:-judgment}_model" ;;
        *) key="$(printf '%s' "$role" | tr - _)_model" ;;
    esac
    sp_setting "$key"
}

sp_role_effort() {
    sp_setting "$(printf '%s' "$1" | tr - _)_effort"
}

# One "warning: ..." line per rejected value and per legacy tier variable.
# Only variable names, key names, and whitelisted values are printed, so the
# output is safe to embed in hook JSON.
sp_config_warnings() {
    local key upper src raw legacy
    for key in $SP_KEYS; do
        upper="$(sp_upper "$key")"
        for src in "SUPERPOWERS_${upper}" "CLAUDE_PLUGIN_OPTION_${upper}"; do
            raw="${!src:-}"
            [ -n "$raw" ] || continue
            if [ -z "$(sp_accept "$key" "$raw")" ]; then
                printf 'warning: %s ignored: not a valid value for %s (using %s)\n' \
                    "$src" "$key" "$(sp_setting "$key")"
            fi
        done
    done
    for legacy in SUPERPOWERS_MODEL_CHEAP SUPERPOWERS_MODEL_STANDARD SUPERPOWERS_MODEL_CAPABLE \
        CLAUDE_PLUGIN_OPTION_MODEL_CHEAP CLAUDE_PLUGIN_OPTION_MODEL_STANDARD CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE; do
        if [ -n "${!legacy:-}" ]; then
            printf 'warning: %s ignored since 7.0 - use SUPERPOWERS_<ROLE>_MODEL; see release notes\n' "$legacy"
        fi
    done
}
```

- [ ] **Step 4: Rewrite the config section of `hooks/session-start`**

Replace lines 28–57 (from `# Per-plugin config.` through the `session_context=` line) with:

```bash
# Per-plugin config. Claude Code exports userConfig options as
# CLAUDE_PLUGIN_OPTION_<KEY>; lib-config applies the SUPERPOWERS_* env
# overrides, builtin defaults, and the whitelist that keeps the JSON intact.
# shellcheck source=lib-config
. "${SCRIPT_DIR}/lib-config"

# Always emitted in full: every role is always configured.
config_block="\n\n<SUPERPOWERS_CONFIG>\nmode: $(sp_resolve_mode)"
config_block="${config_block}\nimplementer: mechanical=$(sp_role_model implementer mechanical) judgment=$(sp_role_model implementer judgment) effort=$(sp_role_effort implementer)"
for role_name in reviewer investigator final-reviewer; do
    config_block="${config_block}\n${role_name}: model=$(sp_role_model "$role_name") effort=$(sp_role_effort "$role_name")"
done
sp_warnings="$(sp_config_warnings)"
sp_warnings_escaped=""
if [ -n "$sp_warnings" ]; then
    sp_warnings_escaped="$(escape_for_json "$sp_warnings")"
    config_block="${config_block}\n${sp_warnings_escaped}"
fi
config_block="${config_block}\n</SUPERPOWERS_CONFIG>"

session_context="<EXTREMELY_IMPORTANT>\nYou have superpowers.\n\n**Below is the full content of your 'superpowers-on-steroids:using-superpowers' skill - your introduction to using skills. For all other skills, use the 'Skill' tool with the 'superpowers-on-steroids:' prefix:**\n\n${using_superpowers_escaped}\n</EXTREMELY_IMPORTANT>${config_block}"
```

Then replace the Claude Code branch (the `elif` block, lines 71–73) with:

```bash
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -z "${COPILOT_CLI:-}" ]; then
  # Claude Code sets CLAUDE_PLUGIN_ROOT without COPILOT_CLI. systemMessage is
  # shown to your human partner; only emit it when there is something to say.
  if [ -n "$sp_warnings_escaped" ]; then
    printf '{\n  "systemMessage": "superpowers config: %s",\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$sp_warnings_escaped" "$session_context" | cat
  else
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$session_context" | cat
  fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/hooks/test-session-start.sh`
Expected: `STATUS: PASSED`

- [ ] **Step 6: Lint**

Run: `scripts/lint-shell.sh hooks/lib-config hooks/session-start tests/hooks/test-session-start.sh`
Expected: no findings (if `shellcheck` is not installed, note it in the report and continue).

- [ ] **Step 7: Commit**

```bash
git add hooks/lib-config hooks/session-start tests/hooks/test-session-start.sh
git commit -m "feat(hooks): resolve per-role model and effort config"
```

---

### Task 2: Agent templates, generator, and effort variants

**Files:**
- Create: `scripts/agent-templates/caveman-implementer.md`, `scripts/agent-templates/caveman-reviewer.md`, `scripts/agent-templates/caveman-investigator.md`, `scripts/agent-templates/caveman-final-reviewer.md` (moved from `agents/`)
- Create: `scripts/gen-agent-variants`
- Create: `agents/caveman-{implementer,reviewer,investigator,final-reviewer}-{low,medium,high}.md` (12 generated files)
- Delete: `agents/caveman-implementer.md`, `agents/caveman-reviewer.md`, `agents/caveman-investigator.md`, `agents/caveman-final-reviewer.md`
- Test: `tests/agents/test-agent-variants.sh`

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: nothing
- Produces:
  - `scripts/gen-agent-variants [OUT_DIR]` — regenerates every `caveman-<role>-<effort>.md` into OUT_DIR (default `agents/`), deleting any `caveman-*.md` there that is not in the generated set. Contains the literals `ROLES="implementer reviewer investigator final-reviewer"` and `EFFORTS="low medium high"`.
  - Template placeholder `{{EFFORT}}`; each template's frontmatter pins `model:` to the role's builtin default (implementer → `sonnet`, the judgment default).
  - Agent names `caveman-<role>-<effort>`, dispatched as `superpowers-on-steroids:caveman-<role>-<effort>`.

- [ ] **Step 1: Write the failing test**

Create `tests/agents/test-agent-variants.sh`:

```bash
#!/usr/bin/env bash
# The checked-in caveman-* agents are exactly what the generator produces
# from scripts/agent-templates: one file per role x effort, nothing else.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"
GEN="$REPO_ROOT/scripts/gen-agent-variants"
TEMPLATES="$REPO_ROOT/scripts/agent-templates"

FAILURES=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "agent variant tests"

ROLES="implementer reviewer investigator final-reviewer"
EFFORTS="low medium high"

# --- Generator output matches the checked-in files byte for byte ---
if bash "$GEN" "$TMP/agents" >/dev/null 2>&1; then
    pass "generator runs"
else
    fail "generator runs"
fi
mkdir -p "$TMP/checked-in"
cp "$AGENTS_DIR"/caveman-*.md "$TMP/checked-in/" 2>/dev/null || true
if diff -r "$TMP/agents" "$TMP/checked-in" >/dev/null 2>&1; then
    pass "checked-in agents match generator output"
else
    fail "checked-in agents differ from generator output (run scripts/gen-agent-variants)"
    diff -r "$TMP/agents" "$TMP/checked-in" | head -20 | sed 's/^/    /'
fi

# --- Exactly 12 variants, no bare names ---
count="$(find "$AGENTS_DIR" -maxdepth 1 -name 'caveman-*.md' | wc -l | tr -d ' ')"
if [ "$count" = "12" ]; then
    pass "exactly 12 caveman agent files"
else
    fail "expected 12 caveman agent files, found $count"
fi
for role in $ROLES; do
    if [ -e "$AGENTS_DIR/caveman-$role.md" ]; then
        fail "bare-name agent caveman-$role.md still present"
    else
        pass "no bare-name agent caveman-$role.md"
    fi
    for effort in $EFFORTS; do
        f="$AGENTS_DIR/caveman-$role-$effort.md"
        if [ ! -f "$f" ]; then
            fail "missing $f"
            continue
        fi
        fm="$(sed -n '/^---$/,/^---$/p' "$f")"
        if printf '%s' "$fm" | grep -qE "^name: caveman-$role-$effort\$"; then
            pass "caveman-$role-$effort: name matches filename"
        else
            fail "caveman-$role-$effort: name does not match filename"
        fi
        if printf '%s' "$fm" | grep -qE "^effort: $effort\$"; then
            pass "caveman-$role-$effort: effort matches suffix"
        else
            fail "caveman-$role-$effort: effort does not match suffix"
        fi
        model="$(printf '%s' "$fm" | sed -n 's/^model: *//p')"
        if [ -n "$model" ] && [ "$model" != "inherit" ]; then
            pass "caveman-$role-$effort: model pinned ($model)"
        else
            fail "caveman-$role-$effort: model must be pinned"
        fi
        if grep -q '{{EFFORT}}' "$f"; then
            fail "caveman-$role-$effort: unexpanded placeholder"
        else
            pass "caveman-$role-$effort: no unexpanded placeholder"
        fi
        if printf '%s' "$fm" | grep -q 'Dispatch only the variant named by <SUPERPOWERS_CONFIG>'; then
            pass "caveman-$role-$effort: description steers dispatch to the configured variant"
        else
            fail "caveman-$role-$effort: description lacks the variant-dispatch sentence"
        fi
    done
done

# --- Templates: one per role, placeholder present, no colon-space in description ---
for role in $ROLES; do
    t="$TEMPLATES/caveman-$role.md"
    if [ -f "$t" ] && grep -qE "^name: caveman-$role-\{\{EFFORT\}\}\$" "$t" && grep -qE '^effort: \{\{EFFORT\}\}$' "$t"; then
        pass "template caveman-$role carries the placeholders"
    else
        fail "template caveman-$role missing or lacks placeholders"
    fi
    desc="$(sed -n 's/^description: //p' "$t" 2>/dev/null || true)"
    case "$desc" in
        *": "*) fail "template caveman-$role description contains ': ' (breaks YAML)" ;;
        *) pass "template caveman-$role description is YAML-safe" ;;
    esac
done

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi
echo "STATUS: PASSED"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/agents/test-agent-variants.sh`
Expected: FAIL — "generator runs" fails (no script), count is 4, bare names present.

- [ ] **Step 3: Move the agent files to templates and add placeholders**

```bash
mkdir -p scripts/agent-templates
git mv agents/caveman-implementer.md scripts/agent-templates/caveman-implementer.md
git mv agents/caveman-reviewer.md scripts/agent-templates/caveman-reviewer.md
git mv agents/caveman-investigator.md scripts/agent-templates/caveman-investigator.md
git mv agents/caveman-final-reviewer.md scripts/agent-templates/caveman-final-reviewer.md
```

Edit each template's frontmatter (lines 1–8) to exactly these. Leave every body line (after the closing `---`) untouched.

`scripts/agent-templates/caveman-implementer.md`:
```yaml
---
name: caveman-implementer-{{EFFORT}}
description: Implements one task from a written implementation plan brief. Use for mechanical, well-specified work where the brief carries the code to write. Follows TDD, commits with an explicit pathspec, and reports in caveman style to keep the controller's context small. Effort {{EFFORT}} variant. Dispatch only the variant named by <SUPERPOWERS_CONFIG>.
tools: Read, Write, Edit, Bash, Glob, Grep
model: sonnet
effort: {{EFFORT}}
color: green
---
```

`scripts/agent-templates/caveman-reviewer.md`:
```yaml
---
name: caveman-reviewer-{{EFFORT}}
description: Reviews one task's diff for spec compliance and code quality, returning two verdicts. Read-only. Use as the per-task gate in plan execution. Caveman-compressed report. Effort {{EFFORT}} variant. Dispatch only the variant named by <SUPERPOWERS_CONFIG>.
tools: Read, Bash, Glob, Grep
model: sonnet
effort: {{EFFORT}}
color: yellow
---
```

`scripts/agent-templates/caveman-investigator.md`:
```yaml
---
name: caveman-investigator-{{EFFORT}}
description: Read-only codebase investigation and design research. Use to inventory what exists, trace a mechanism, verify a claim against source, or gather ground truth before planning. Returns findings only, never edits. Caveman-compressed so the controller's context stays small. Effort {{EFFORT}} variant. Dispatch only the variant named by <SUPERPOWERS_CONFIG>.
tools: Read, Bash, Glob, Grep, WebFetch, WebSearch
model: sonnet
effort: {{EFFORT}}
color: cyan
---
```

`scripts/agent-templates/caveman-final-reviewer.md`:
```yaml
---
name: caveman-final-reviewer-{{EFFORT}}
description: Senior whole-branch code review before merge. Use once, after every task in a plan has passed its own task-scoped review, to catch what per-task gates structurally cannot see — cross-task interactions, architectural drift, and defects in the plan itself. Read-only. Runs on the final reviewer model from config, because this is the last gate. Effort {{EFFORT}} variant. Dispatch only the variant named by <SUPERPOWERS_CONFIG>.
tools: Read, Bash, Glob, Grep
model: opus
effort: {{EFFORT}}
color: red
---
```

- [ ] **Step 4: Write the generator**

Create `scripts/gen-agent-variants`:

```bash
#!/usr/bin/env bash
# Regenerate agents/caveman-<role>-<effort>.md from scripts/agent-templates.
# Effort is frontmatter-only in Claude Code, so each effort is its own agent.
# Output is checked in; tests/agents/test-agent-variants.sh keeps it in sync.
#
# Usage: scripts/gen-agent-variants [OUT_DIR]   (default: agents/)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES="$SCRIPT_DIR/agent-templates"
OUT="${1:-$REPO_ROOT/agents}"

# Keep in step with hooks/lib-config SP_ROLES / SP_EFFORTS and the gate.
ROLES="implementer reviewer investigator final-reviewer"
EFFORTS="low medium high"

mkdir -p "$OUT"
for stale in "$OUT"/caveman-*.md; do
    [ -e "$stale" ] && rm -f "$stale"
done

for role in $ROLES; do
    tmpl="$TEMPLATES/caveman-$role.md"
    [ -f "$tmpl" ] || { echo "missing template: $tmpl" >&2; exit 1; }
    for effort in $EFFORTS; do
        sed "s/{{EFFORT}}/$effort/g" "$tmpl" > "$OUT/caveman-$role-$effort.md"
    done
done

echo "generated $(find "$OUT" -maxdepth 1 -name 'caveman-*.md' | wc -l | tr -d ' ') agent files in $OUT"
```

```bash
chmod +x scripts/gen-agent-variants
scripts/gen-agent-variants
```
Expected output: `generated 12 agent files in .../agents`

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/agents/test-agent-variants.sh`
Expected: `STATUS: PASSED`

- [ ] **Step 6: Lint**

Run: `scripts/lint-shell.sh scripts/gen-agent-variants tests/agents/test-agent-variants.sh`
Expected: no findings.

- [ ] **Step 7: Commit**

```bash
git add scripts/gen-agent-variants scripts/agent-templates agents tests/agents/test-agent-variants.sh
git commit -m "feat(agents): generate caveman agents as per-effort variants"
```

---

### Task 3: Plugin config surface

**Files:**
- Modify: `.claude-plugin/plugin.json:17-42` (`userConfig`)
- Test: `tests/hooks/test-plugin-config.sh`

**Depends on:** none

**Review tier:** transcription

**Interfaces:**
- Consumes: nothing
- Produces: `userConfig` keys, in order: `mode`, `implementer_mechanical_model`, `implementer_judgment_model`, `implementer_effort`, `reviewer_model`, `reviewer_effort`, `investigator_model`, `investigator_effort`, `final_reviewer_model`, `final_reviewer_effort`. Claude Code exports them as `CLAUDE_PLUGIN_OPTION_<UPPER_KEY>`.

- [ ] **Step 1: Write the failing test**

Create `tests/hooks/test-plugin-config.sh`:

```bash
#!/usr/bin/env bash
# plugin.json userConfig: role-keyed model + effort fields with real defaults.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "plugin config tests"

if node -e '
const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).userConfig;
const fail = (m) => { console.error("  [FAIL] " + m); process.exit(1); };
const expectedOrder = ["mode","implementer_mechanical_model","implementer_judgment_model","implementer_effort","reviewer_model","reviewer_effort","investigator_model","investigator_effort","final_reviewer_model","final_reviewer_effort"];
const keys = Object.keys(cfg);
if (JSON.stringify(keys) !== JSON.stringify(expectedOrder)) fail("keys/order: " + keys.join(","));
const defaults = { mode: "standard", implementer_mechanical_model: "haiku", implementer_judgment_model: "sonnet", implementer_effort: "low", reviewer_model: "sonnet", reviewer_effort: "medium", investigator_model: "sonnet", investigator_effort: "medium", final_reviewer_model: "opus", final_reviewer_effort: "high" };
for (const [k, v] of Object.entries(defaults)) {
  if (cfg[k].type !== "string") fail(`${k}.type`);
  if (cfg[k].default !== v) fail(`${k}.default = ${cfg[k].default}, want ${v}`);
  if (!cfg[k].title) fail(`${k}.title missing`);
  const envName = "SUPERPOWERS_" + k.toUpperCase();
  if (!cfg[k].description.includes(envName)) fail(`${k}.description lacks ${envName}`);
}
if (JSON.stringify(cfg.mode.options) !== JSON.stringify(["standard","fast"])) fail("mode.options");
for (const k of keys.filter((k) => k.endsWith("_effort"))) {
  if (JSON.stringify(cfg[k].options) !== JSON.stringify(["low","medium","high"])) fail(`${k}.options`);
  if (!cfg[k].description.includes("fast mode only")) fail(`${k}.description lacks "fast mode only"`);
  if (!cfg[k].description.includes("maxEffortLevel")) fail(`${k}.description lacks maxEffortLevel clamp note`);
}
const agentOf = { implementer: "caveman-implementer-", reviewer: "caveman-reviewer-", investigator: "caveman-investigator-", final_reviewer: "caveman-final-reviewer-" };
for (const [role, agent] of Object.entries(agentOf)) {
  for (const k of keys.filter((k) => k.startsWith(role + "_"))) {
    if (!cfg[k].description.includes(agent)) fail(`${k}.description lacks ${agent}`);
  }
}
for (const legacy of ["model_cheap","model_standard","model_capable"]) if (legacy in cfg) fail(`legacy key ${legacy} still present`);
if (Object.keys(cfg.mode).includes("options") === false) fail("mode has no options");
' "$REPO_ROOT/.claude-plugin/plugin.json"; then
    echo "  [PASS] userConfig has the ten role-keyed fields with defaults, options, and env names"
    echo "STATUS: PASSED"
else
    echo "STATUS: FAILED (1 failure(s))"
    exit 1
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/hooks/test-plugin-config.sh`
Expected: `[FAIL] keys/order: mode,model_cheap,model_standard,model_capable`

- [ ] **Step 3: Replace `userConfig` in `.claude-plugin/plugin.json`**

Replace lines 17–42 (the whole `"userConfig": { ... }` object) with:

```json
  "userConfig": {
    "mode": {
      "type": "string",
      "title": "Execution mode",
      "options": ["standard", "fast"],
      "description": "standard = inline prompt templates. fast = dispatch the bundled caveman-* agents: terser reports, configurable effort, smaller dispatch payloads, plan-tiered task review, 3-round fix loop. Env override: SUPERPOWERS_MODE (env wins).",
      "default": "standard"
    },
    "implementer_mechanical_model": {
      "type": "string",
      "title": "Implementer model (mechanical)",
      "description": "Model for implementation tasks whose brief carries the complete code, or single-file fixes. Drives caveman-implementer-<effort> in fast mode and the inline implementer template in standard mode. Claude Code alias (haiku, sonnet, opus) or a full model id. Env override: SUPERPOWERS_IMPLEMENTER_MECHANICAL_MODEL (env wins).",
      "default": "haiku"
    },
    "implementer_judgment_model": {
      "type": "string",
      "title": "Implementer model (judgment)",
      "description": "Model for integration work, multi-file coordination, and prose briefs. Drives caveman-implementer-<effort> in fast mode and the inline implementer template in standard mode. Claude Code alias or full model id. Env override: SUPERPOWERS_IMPLEMENTER_JUDGMENT_MODEL (env wins).",
      "default": "sonnet"
    },
    "implementer_effort": {
      "type": "string",
      "title": "Implementer effort",
      "options": ["low", "medium", "high"],
      "description": "Reasoning effort for caveman-implementer-<effort>; fast mode only. Round-3 fix escalation always uses high. Harness settings modelSettings.effortLevel / maxEffortLevel may clamp this. Env override: SUPERPOWERS_IMPLEMENTER_EFFORT (env wins).",
      "default": "low"
    },
    "reviewer_model": {
      "type": "string",
      "title": "Reviewer model",
      "description": "Model for every per-task review and re-review. Drives caveman-reviewer-<effort> in fast mode and the inline task-reviewer / re-review templates in standard mode. Claude Code alias or full model id. Env override: SUPERPOWERS_REVIEWER_MODEL (env wins).",
      "default": "sonnet"
    },
    "reviewer_effort": {
      "type": "string",
      "title": "Reviewer effort",
      "options": ["low", "medium", "high"],
      "description": "Reasoning effort for caveman-reviewer-<effort>; fast mode only. Harness settings modelSettings.effortLevel / maxEffortLevel may clamp this. Env override: SUPERPOWERS_REVIEWER_EFFORT (env wins).",
      "default": "medium"
    },
    "investigator_model": {
      "type": "string",
      "title": "Investigator model",
      "description": "Model for context gathering and design research. Drives caveman-investigator-<effort> in fast mode; standard mode explores inline. Claude Code alias or full model id. Env override: SUPERPOWERS_INVESTIGATOR_MODEL (env wins).",
      "default": "sonnet"
    },
    "investigator_effort": {
      "type": "string",
      "title": "Investigator effort",
      "options": ["low", "medium", "high"],
      "description": "Reasoning effort for caveman-investigator-<effort>; fast mode only. Harness settings modelSettings.effortLevel / maxEffortLevel may clamp this. Env override: SUPERPOWERS_INVESTIGATOR_EFFORT (env wins).",
      "default": "medium"
    },
    "final_reviewer_model": {
      "type": "string",
      "title": "Final reviewer model",
      "description": "Model for the final whole-branch review and for round-3 fix escalation. Drives caveman-final-reviewer-<effort> in fast mode and the inline code-reviewer template in standard mode. Claude Code alias or full model id. Env override: SUPERPOWERS_FINAL_REVIEWER_MODEL (env wins).",
      "default": "opus"
    },
    "final_reviewer_effort": {
      "type": "string",
      "title": "Final reviewer effort",
      "options": ["low", "medium", "high"],
      "description": "Reasoning effort for caveman-final-reviewer-<effort>; fast mode only. Harness settings modelSettings.effortLevel / maxEffortLevel may clamp this. Env override: SUPERPOWERS_FINAL_REVIEWER_EFFORT (env wins).",
      "default": "high"
    }
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/hooks/test-plugin-config.sh && node -e 'JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8"))'`
Expected: `STATUS: PASSED`, no JSON error.

- [ ] **Step 5: Commit (this is the breaking commit)**

```bash
git add .claude-plugin/plugin.json tests/hooks/test-plugin-config.sh
git commit -m "feat!(config): key model and effort config by agent role

Replaces the cheap/standard/capable tier fields with per-role model and
effort fields. Legacy values are ignored and warned about at session start.

BREAKING CHANGE: userConfig keys model_cheap, model_standard, model_capable
and env vars SUPERPOWERS_MODEL_CHEAP/STANDARD/CAPABLE are removed. Map them
to implementer_mechanical_model (cheap), implementer_judgment_model /
reviewer_model / investigator_model (standard), final_reviewer_model
(capable). Bare caveman-<role> agents are replaced by caveman-<role>-<effort>."
```

---

### Task 4: Config gate

**Files:**
- Create: `hooks/agent-config-gate` (renamed from `hooks/agent-tier-gate`, policy section rewritten)
- Delete: `hooks/agent-tier-gate`
- Modify: `hooks/hooks.json:22`
- Test: `tests/hooks/test-agent-config-gate.sh` (renamed from `tests/hooks/test-agent-tier-gate.sh`)
- Delete: `tests/hooks/test-agent-tier-gate.sh`

**Depends on:** 1

**Review tier:** judgment

**Interfaces:**
- Consumes: `sp_role_model`, `sp_role_effort` from `hooks/lib-config` (Task 1).
- Produces: PreToolUse hook `hooks/agent-config-gate`. Deny reasons (exact prefixes, tests match on them):
  - `unknown caveman agent: dispatch superpowers-on-steroids:caveman-<role>-<effort> ...`
  - `caveman-<role> must match <SUPERPOWERS_CONFIG>: caveman-<role>-<effort> + model "<model>" (<label>)[, ...].` where label is `configured`, or for the implementer `mechanical` / `judgment` / `round-3 escalation`.

- [ ] **Step 1: Rename and rewrite the test**

```bash
git mv tests/hooks/test-agent-tier-gate.sh tests/hooks/test-agent-config-gate.sh
```

Replace the file's contents with:

```bash
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
    "$(payload "$P:caveman-implementer-high" claude-opus-5-5 "fix")" "$ROOT" \
    CLAUDE_PLUGIN_OPTION_FINAL_REVIEWER_MODEL=claude-opus-5-5
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/hooks/test-agent-config-gate.sh`
Expected: FAIL — registration test fails (`hooks.json` still names `agent-tier-gate`), allow/deny tests fail (`run-hook.cmd agent-config-gate` finds no script).

- [ ] **Step 3: Rename the gate and update hooks.json**

```bash
git mv hooks/agent-tier-gate hooks/agent-config-gate
```

In `hooks/hooks.json` line 22 change `agent-tier-gate` to `agent-config-gate`:
```json
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" agent-config-gate || true",
```

- [ ] **Step 4: Rewrite the gate's header and policy section**

In `hooks/agent-config-gate`, replace lines 1–5 (header comment) with:

```bash
#!/usr/bin/env bash
# PreToolUse gate for Claude Code Agent dispatches of the caveman-* agents.
# Every role is always configured (hooks/lib-config), so the rule is exact:
# the variant suffix must equal the role's configured effort and model: must
# equal its configured model. Fails open on anything unexpected: a broken
# gate must never block dispatch. No set -e/-u on purpose.
```

Keep lines 7–122 (platform guard, lib-config sourcing, JSON walk, structural checks) unchanged. Replace everything from line 124 (`# Tier policy.`) to the end of file with:

```bash
# Reasons carry only fixed text and whitelisted config values, so the only
# JSON escaping needed is around the quoted model names.
q='\"'

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}

case "$subagent" in
    superpowers-on-steroids:caveman-*) ;;
    *) exit 0 ;;
esac

# caveman-<role>-<effort>: the suffix after the last hyphen is the effort.
variant="${subagent#superpowers-on-steroids:caveman-}"
effort="${variant##*-}"
role="${variant%-*}"
case "$effort" in
    low|medium|high) ;;
    *) role="" ;;
esac
case "$role" in
    implementer|reviewer|investigator|final-reviewer) ;;
    *) role="" ;;
esac
# subagent is never echoed: it is prompt-controlled text.
[ -n "$role" ] || deny "unknown caveman agent: dispatch superpowers-on-steroids:caveman-<role>-<effort> with <role> one of implementer, reviewer, investigator, final-reviewer and <effort> from <SUPERPOWERS_CONFIG>."

cfg_effort="$(sp_role_effort "$role")"

# Allowed (effort, model, label) triples, one per line. The implementer also
# carries the round-3 fix escalation: final reviewer model at effort high.
case "$role" in
    implementer)
        allowed="$cfg_effort $(sp_role_model implementer mechanical) mechanical
$cfg_effort $(sp_role_model implementer judgment) judgment
high $(sp_role_model final-reviewer) round-3 escalation"
        ;;
    *)
        allowed="$cfg_effort $(sp_role_model "$role") configured"
        ;;
esac

offer=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    a_effort="${line%% *}"
    rest="${line#* }"
    a_model="${rest%% *}"
    a_label="${rest#* }"
    if [ "$effort" = "$a_effort" ] && [ "$model" = "$a_model" ]; then
        exit 0
    fi
    [ -n "$offer" ] && offer="$offer, "
    offer="${offer}caveman-${role}-${a_effort} + model ${q}${a_model}${q} (${a_label})"
done <<EOF
$allowed
EOF

deny "caveman-${role} must match <SUPERPOWERS_CONFIG>: ${offer}."
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/hooks/test-agent-config-gate.sh`
Expected: `STATUS: PASSED`

- [ ] **Step 6: Lint**

Run: `scripts/lint-shell.sh hooks/agent-config-gate tests/hooks/test-agent-config-gate.sh`
Expected: no findings.

- [ ] **Step 7: Commit**

```bash
git add hooks/agent-config-gate hooks/hooks.json tests/hooks/test-agent-config-gate.sh
git rm -q --cached hooks/agent-tier-gate tests/hooks/test-agent-tier-gate.sh 2>/dev/null || true
git commit -m "feat(hooks): gate caveman dispatches on configured model and effort variant"
```

(`git mv` already staged the renames; the `git rm --cached` is a no-op safety net.)

---

### Task 5: Skills dispatch variants; contract test follows

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md:149-176, 203-208, 210-294, 591`
- Modify: `skills/subagent-driven-development/re-review-prompt.md:103-106`
- Modify: `skills/requesting-code-review/SKILL.md:39-41`
- Modify: `skills/brainstorming/SKILL.md:29`
- Test: `tests/agents/test-fast-mode-contract.sh:27-43, 107-129, 131-166`

**Depends on:** 2, 3

**Review tier:** judgment

**Interfaces:**
- Consumes: agent names `caveman-<role>-<effort>` (Task 2); plugin env names `SUPERPOWERS_*` (Task 3).
- Produces: SDD canonical table rows beginning `| \`implementer\` | \`caveman-implementer-<effort>\` |`, `| \`reviewer\` | \`caveman-reviewer-<effort>\` |`, `| \`investigator\` | \`caveman-investigator-<effort>\` |`, `| \`final-reviewer\` | \`caveman-final-reviewer-<effort>\` |` (Task 6's wiring test greps these).

- [ ] **Step 1: Update the contract test**

In `tests/agents/test-fast-mode-contract.sh`:

Replace lines 28, 40, 42 with:
```bash
impl_agent="$AGENTS_DIR/caveman-implementer-low.md"
```
```bash
rev_agent="$AGENTS_DIR/caveman-reviewer-medium.md"
```
```bash
final_agent="$AGENTS_DIR/caveman-final-reviewer-high.md"
```

Replace lines 107–129 (from `# --- Tier table:` through the investigator-effort `fi`) with:

```bash
# --- Role table: every caveman agent has a role row; dispatching skills name their variant ---
assert_in_file "role table" '| `implementer` | `caveman-implementer-<effort>` |' "$sdd_skill"
assert_in_file "role table" '| `reviewer` | `caveman-reviewer-<effort>` |' "$sdd_skill"
assert_in_file "role table" '| `investigator` | `caveman-investigator-<effort>` |' "$sdd_skill"
assert_in_file "role table" '| `final-reviewer` | `caveman-final-reviewer-<effort>` |' "$sdd_skill"
assert_in_file "role table" 'Every `superpowers-on-steroids:caveman-*`' "$sdd_skill"
assert_in_file "round 3" '`superpowers-on-steroids:caveman-implementer-high`' "$sdd_skill"
assert_in_file "re-review model" '`superpowers-on-steroids:caveman-reviewer-<effort>` in re-review mode' "$sdd_skill"
assert_in_file "re-review model" '`caveman-reviewer-<effort>` re-review takes the same reviewer model' "$rereview_tmpl"
assert_in_file "investigator dispatch" '`superpowers-on-steroids:caveman-investigator-<effort>`' \
    "$REPO_ROOT/skills/brainstorming/SKILL.md"
assert_in_file "final reviewer dispatch" '`superpowers-on-steroids:caveman-final-reviewer-<effort>`' \
    "$REPO_ROOT/skills/requesting-code-review/SKILL.md"
for key in IMPLEMENTER_MECHANICAL_MODEL IMPLEMENTER_JUDGMENT_MODEL IMPLEMENTER_EFFORT \
    REVIEWER_MODEL REVIEWER_EFFORT INVESTIGATOR_MODEL INVESTIGATOR_EFFORT \
    FINAL_REVIEWER_MODEL FINAL_REVIEWER_EFFORT; do
    assert_in_file "plugin.json env override" "SUPERPOWERS_${key}" "$REPO_ROOT/.claude-plugin/plugin.json"
done
for skill_file in "$sdd_skill" "$rereview_tmpl" "$REPO_ROOT/skills/brainstorming/SKILL.md" "$REPO_ROOT/skills/requesting-code-review/SKILL.md"; do
    assert_not_in_file_ci "tier wording gone" "capable tier" "$skill_file"
    assert_not_in_file_ci "tier wording gone" "standard tier" "$skill_file"
    assert_not_in_file_ci "tier wording gone" "cheap tier" "$skill_file"
    assert_not_in_file_ci "tier wording gone" "tier models" "$skill_file"
done
assert_not_in_file_ci "effort claim gone" "effort cannot be raised" "$sdd_skill"
```

Inside the agent-validity loop (lines 131–166), after the `effort` case statement, add:

```bash
    suffix="${base##*-}"
    if [ "$effort" = "$suffix" ]; then
        pass "$base: effort matches variant suffix"
    else
        fail "$base: effort '$effort' does not match suffix '$suffix'"
    fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/agents/test-fast-mode-contract.sh`
Expected: FAIL on the role-table, round-3, re-review, dispatch, and tier-wording assertions.

- [ ] **Step 3: Rewrite the SDD Fix Loop paragraphs**

In `skills/subagent-driven-development/SKILL.md` replace lines 153–176 with:

```markdown
**Rounds 1–2: resume.** Send the reviewer's Critical/Important findings to
the task's original implementer via SendMessage — it still holds the task
context and takes fewer turns than a fresh fixer re-deriving the diff. In
fast mode that is the same `superpowers-on-steroids:caveman-implementer-<effort>`
agent. If the implementer is no longer addressable, dispatch a fresh fix
subagent on the same model carrying the findings **and** the original brief
path — never skip silently, and note the fallback in the ledger.

**Round 3: escalate.** Dispatch a fresh implementer on the final reviewer's
model — `final-reviewer: model=` in `<SUPERPOWERS_CONFIG>`, the most capable
model configured. In fast mode dispatch
`superpowers-on-steroids:caveman-implementer-high` (the highest-effort
variant) on that model; in standard mode use the inline
[implementer-prompt.md](implementer-prompt.md).

**After every round: scoped re-review.** Generate a fix package
(`scripts/review-package FIX_BASE HEAD -- <task's files>`, where FIX_BASE is
the head the previous review saw) and dispatch
[re-review-prompt.md](re-review-prompt.md) on the reviewer model — in fast
mode, `superpowers-on-steroids:caveman-reviewer-<effort>` in re-review mode
on `reviewer: model=` (see Model Selection). The re-review verdicts each
finding `ADDRESSED | NOT ADDRESSED` and flags new breakage in the fix diff
only; it is not a fresh review. Before dispatching it, confirm the fix
report names the covering tests, the command run, and its output.
```

- [ ] **Step 4: Rewrite the Pre-Flight policy line**

Replace lines 203–208 with:

```markdown
State the resolved policy once, before wave 1, in one line, from the
`<SUPERPOWERS_CONFIG>` block in the session context: `Mode: fast —
transcription tasks skip per-task review on green report evidence, judgment
tasks reviewed; fix loop capped at 3 rounds`, or `Mode: standard — every task
reviewed; fix loop capped at 3 rounds`. With no block at all (a harness
without the SessionStart hook), treat the mode as standard and say so.
```

- [ ] **Step 5: Rewrite Model Selection and Fast Mode**

Replace lines 210–294 (from `## Model Selection` through the end of the Fast Mode section, i.e. the paragraph ending "...cannot be raised at dispatch.") with:

````markdown
## Model Selection

Use the least powerful model that can handle each role to conserve cost and
increase speed. The `<SUPERPOWERS_CONFIG>` block in the session context names
the model for every role and the effort for every fast-mode agent:

```
<SUPERPOWERS_CONFIG>
mode: fast
implementer: mechanical=haiku judgment=sonnet effort=low
reviewer: model=sonnet effort=medium
investigator: model=sonnet effort=medium
final-reviewer: model=opus effort=high
</SUPERPOWERS_CONFIG>
```

Config decides what each role *runs on*; the heuristics below decide which of
the two implementer models a task *needs*. Model names are Claude Code
Agent-tool aliases; on another harness, use the closest model that harness
offers. With no block at all, use the values shown above.

**Implementer — mechanical or judgment.** When the task's plan text contains
the complete code to write, the implementation is transcription plus
testing: use `mechanical=`. Single-file fixes with a complete spec also take
`mechanical=`. Multi-file coordination, integration concerns, prose briefs,
and debugging take `judgment=`. Turn count beats token price: the cheapest
models routinely take 2-3× the turns on multi-step work and cost more
overall, so do not stretch `mechanical=` to cover judgment work.

**Task complexity signals (implementation tasks):**
- Touches 1-2 files with a complete spec → `mechanical=`
- Touches multiple files with integration concerns → `judgment=`
- Requires design judgment or broad codebase understanding → `judgment=`

**Reviewer, investigator, final reviewer** each run on their own configured
model. The final whole-branch review runs on `final-reviewer: model=` — the
most capable model configured — never the session default. The round-3 fix
escalation in the Fix Loop also runs on `final-reviewer: model=`.

**Always specify the model explicitly when dispatching a subagent.** An
omitted model inherits your session's model on a general-purpose subagent —
often the most capable and most expensive — and the bundled agent's pinned
model on a `caveman-*` agent; either way it silently defeats this section.
On Claude Code a hook denies a `caveman-*` dispatch whose `model:` or effort
variant does not match the block, and names the dispatch to make.

**The bundled agents are effort variants.** Every `superpowers-on-steroids:caveman-*`
dispatch names the variant whose suffix equals the role's `effort=` and
passes `model:` from the same line. Effort lives in each agent's definition
and can be changed only by choosing the variant; the harness settings
`modelSettings.effortLevel` and `maxEffortLevel` may clamp it.

| Role | Fast-mode agent | Model | Effort | When |
|---|---|---|---|---|
| `implementer` | `caveman-implementer-<effort>` | `mechanical=` or `judgment=` | `implementer: effort=` | mechanical when the brief carries the complete code or the fix is single-file; judgment for integration and prose briefs |
| `reviewer` | `caveman-reviewer-<effort>` | `reviewer: model=` | `reviewer: effort=` | every task review, and every fast-mode re-review |
| `investigator` | `caveman-investigator-<effort>` | `investigator: model=` | `investigator: effort=` | context gathering and design research |
| `final-reviewer` | `caveman-final-reviewer-<effort>` | `final-reviewer: model=` | `final-reviewer: effort=` | the final whole-branch review |
| implementer, round 3 | `caveman-implementer-high` | `final-reviewer: model=` | `high` | fix-loop round-3 escalation |

## Fast Mode

If the session context carries a `<SUPERPOWERS_CONFIG>` block with `mode: fast`,
dispatch the bundled agents instead of pasting the inline templates:

| Role | Standard path | Fast path |
|---|---|---|
| Implementer | [implementer-prompt.md](implementer-prompt.md) | `superpowers-on-steroids:caveman-implementer-<effort>` |
| Task reviewer | [task-reviewer-prompt.md](task-reviewer-prompt.md) | `superpowers-on-steroids:caveman-reviewer-<effort>` |
| Final whole-branch review | [code-reviewer.md](../requesting-code-review/code-reviewer.md) | `superpowers-on-steroids:caveman-final-reviewer-<effort>` |
| Fix rounds 1–2 | resume the implementer (contract in [implementer-prompt.md](implementer-prompt.md)) | resume `superpowers-on-steroids:caveman-implementer-<effort>` |
| Fix round 3 | [implementer-prompt.md](implementer-prompt.md) on `final-reviewer: model=` | `superpowers-on-steroids:caveman-implementer-high` on `final-reviewer: model=` |
| Re-review | [re-review-prompt.md](re-review-prompt.md) | `superpowers-on-steroids:caveman-reviewer-<effort>` (re-review mode) |

Each agent carries its role contract in its own system prompt, so a fast
dispatch passes only the task-specific material: the brief path, the report
path, the review package path, interfaces from earlier tasks, and the global
constraints that bind the task. Do not paste the template body as well — that
duplicates the contract and throws away the context saving that is the point.

Roles with no agent counterpart stay on the template path in both modes: the
spec-document reviewer, the plan-document reviewer, and the Brainstormer.

Model and effort both come from the block: resolve the role's line in Model
Selection, name the matching variant, and pass `model:` explicitly.
````

Then replace line 591 (`- Round 3: fresh implementer on the capable tier`) with:
```markdown
- Round 3: fresh implementer on `final-reviewer: model=` (fast mode: `caveman-implementer-high`)
```

- [ ] **Step 6: Update the three other skill files**

`skills/subagent-driven-development/re-review-prompt.md` lines 104–106 → :
```markdown
- `[MODEL]` — REQUIRED: `reviewer: model=` from `<SUPERPOWERS_CONFIG>` (see
  SKILL.md Model Selection; fast mode's `caveman-reviewer-<effort>` re-review
  takes the same reviewer model)
```

`skills/requesting-code-review/SKILL.md` lines 39–41 → :
```markdown
package. Then dispatch `superpowers-on-steroids:caveman-final-reviewer-<effort>`
— the variant whose suffix is `final-reviewer: effort=` — with `model:` set to
`final-reviewer: model=` from the same block (see subagent-driven-development
Model Selection) instead,
```

`skills/brainstorming/SKILL.md` line 29, replace the sentence starting "In fast mode" with:
```markdown
In fast mode (`<SUPERPOWERS_CONFIG>` with `mode: fast`), dispatch `superpowers-on-steroids:caveman-investigator-<effort>` — the variant whose suffix is `investigator: effort=` — with `model:` set to `investigator: model=` (see subagent-driven-development Model Selection) to gather this instead of exploring inline.
```

- [ ] **Step 7: Sweep for stragglers**

Run:
```bash
grep -rnE "caveman-(implementer|reviewer|investigator|final-reviewer)(\`|\b)[^-]" skills | grep -v -- '-<effort>' | grep -v -- '-high`' || echo "clean"
grep -rniE "capable tier|standard tier|cheap tier|tier models|effort cannot be raised|effort-pinned" skills || echo "clean"
```
Expected: both print `clean`. Fix any hit the same way as above (name the variant, drop tier wording).

- [ ] **Step 8: Run the test to verify it passes**

Run: `bash tests/agents/test-fast-mode-contract.sh`
Expected: `STATUS: PASSED`

- [ ] **Step 9: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md skills/subagent-driven-development/re-review-prompt.md skills/requesting-code-review/SKILL.md skills/brainstorming/SKILL.md tests/agents/test-fast-mode-contract.sh
git commit -m "feat(sdd): dispatch caveman effort variants from per-role config"
```

---

### Task 6: Wiring test across all five sources of truth

**Files:**
- Create: `tests/hooks/test-config-wiring.sh`

**Depends on:** 1, 2, 3, 4, 5

**Review tier:** transcription

**Interfaces:**
- Consumes: `sp_default`, `SP_ROLES`, `SP_EFFORTS` (Task 1); `ROLES`/`EFFORTS` literals in `scripts/gen-agent-variants` and template `model:` pins (Task 2); plugin.json defaults/options (Task 3); gate role/effort `case` lines (Task 4); SDD table rows (Task 5).
- Produces: nothing.

- [ ] **Step 1: Write the test**

Create `tests/hooks/test-config-wiring.sh`:

```bash
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
```

- [ ] **Step 2: Run it**

Run: `bash tests/hooks/test-config-wiring.sh`
Expected: `STATUS: PASSED`. If a default disagrees, the failing line names both sides — fix the file that departs from the Global Constraints literals, not the test.

- [ ] **Step 3: Lint and commit**

```bash
scripts/lint-shell.sh tests/hooks/test-config-wiring.sh
git add tests/hooks/test-config-wiring.sh
git commit -m "test(hooks): pin role config literals across plugin, hooks, agents, and skills"
```

---

### Task 7: Docs, release notes, version 7.0.0

**Files:**
- Modify: `RELEASE-NOTES.md:1-3` (insert new entry at top)
- Modify: `docs/specs/2026-10-06-per-role-agent-config-design.md` (template dir amendment)
- Modify: `docs/specs/2026-09-24-agent-tier-enforcement-design.md:1`, `docs/specs/2026-08-31-fast-mode-and-plugin-config-design.md:1` (superseded header)
- Modify: `docs/testing.md:16`
- Modify: version files via `scripts/bump-version.sh` (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `package.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `.kimi-plugin/plugin.json`, `.devin-plugin/plugin.json`, `.hermes-plugin/plugin.yaml`, `gemini-extension.json`)

**Depends on:** 1, 2, 3, 4, 5

**Review tier:** judgment

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Amend the new spec**

In `docs/specs/2026-10-06-per-role-agent-config-design.md`, in the Architecture diagram and in section "5. Agent variants", replace every `agents-src/` with `scripts/agent-templates/`, and append to the templates bullet: "(`scripts/` is already excluded from the Codex sync and no harness loads it, so no new top-level directory is needed)". In the Decisions log item 15 replace `agents-src/` with `scripts/agent-templates/`.

- [ ] **Step 2: Mark the superseded specs**

Insert as line 1 of `docs/specs/2026-09-24-agent-tier-enforcement-design.md` and of `docs/specs/2026-08-31-fast-mode-and-plugin-config-design.md`:

```markdown
> **Superseded (2026-10-06).** Tier config and the tier gate were replaced by per-role model + effort config and `hooks/agent-config-gate`; see `2026-10-06-per-role-agent-config-design.md`. Kept for history.

```

- [ ] **Step 3: Update docs/testing.md**

Replace line 16 with:
```markdown
- `tests/hooks/` — bash tests for the SessionStart hook's context injection and config precedence, the `agent-config-gate` PreToolUse hook, the plugin.json `userConfig` shape, and the cross-file config wiring (role list, effort list, and defaults agreeing across plugin.json, `hooks/lib-config`, the agent generator, the gate, and the SDD table).
```

and extend line 15 with ` plus the generator sync test (`tests/agents/test-agent-variants.sh`) that keeps `agents/caveman-*` identical to `scripts/gen-agent-variants` output.`

- [ ] **Step 4: Write the release notes entry**

Insert after line 1 (`# Superpowers Release Notes`) and its blank line in `RELEASE-NOTES.md`:

```markdown
## v7.0.0 (2026-10-06)

### Per-role model and effort config replaces the tier fields (BREAKING)

- **Why.** The `Cheap/Standard/Capable tier model` fields never said which
  bundled agent they drove, and effort was not configurable at all. Config is
  now keyed by role: implementer (mechanical model, judgment model, effort),
  reviewer, investigator, and final reviewer (model + effort each). Every
  field ships with a real default, so a role is always configured.
- **Effort variants.** Claude Code honours `effort:` only in an agent's
  frontmatter, so each bundled agent now ships as three files:
  `caveman-<role>-low|medium|high`. Skills dispatch the variant named by
  `<SUPERPOWERS_CONFIG>`. Templates live in `scripts/agent-templates/`;
  `scripts/gen-agent-variants` regenerates `agents/` and a test keeps them in
  sync. Bare `caveman-<role>` agents are gone.
- **Config gate.** `hooks/agent-tier-gate` is now `hooks/agent-config-gate`:
  a `caveman-*` dispatch must name the configured effort variant and pass the
  configured `model:`; otherwise it is denied with the exact dispatch to make.
  Floors and rank tables are gone — an explicit choice is authoritative. The
  implementer also accepts the round-3 escalation pair: final reviewer model
  at effort `high`.
- **Config block.** `<SUPERPOWERS_CONFIG>` is always emitted, in both modes,
  one line per role. Rejected values fall back to the default with a
  `warning:` line (also surfaced as a Claude Code `systemMessage`).
- **Migration.** Removed: `model_cheap`, `model_standard`, `model_capable`,
  `SUPERPOWERS_MODEL_CHEAP/STANDARD/CAPABLE`. Legacy variables are ignored
  and warned about. Mapping: cheap → `implementer_mechanical_model`;
  standard → `implementer_judgment_model`, `reviewer_model`,
  `investigator_model`; capable → `final_reviewer_model`. New env overrides:
  `SUPERPOWERS_<ROLE>_MODEL` / `SUPERPOWERS_<ROLE>_EFFORT` with ROLE one of
  `IMPLEMENTER_MECHANICAL` (model only), `IMPLEMENTER_JUDGMENT` (model only),
  `IMPLEMENTER` (effort only), `REVIEWER`, `INVESTIGATOR`, `FINAL_REVIEWER`.
- **Harness note.** `modelSettings.effortLevel` / `maxEffortLevel` in
  `settings.json` may clamp the configured effort. Model names are Claude
  Code aliases; other harnesses map them to the closest model they offer.

```

- [ ] **Step 5: Bump the version**

Run: `scripts/bump-version.sh 7.0.0 && scripts/bump-version.sh --check`
Expected: every declared file reports `7.0.0`, no drift.

- [ ] **Step 6: Run the full test suite (controller only — one runner at a time)**

Run:
```bash
for t in tests/hooks/test-session-start.sh tests/hooks/test-plugin-config.sh tests/hooks/test-agent-config-gate.sh tests/hooks/test-config-wiring.sh tests/agents/test-agent-variants.sh tests/agents/test-fast-mode-contract.sh; do echo "== $t"; bash "$t" | tail -1; done
bash tests/codex-plugin-sync/test-sync-to-codex-plugin.sh | tail -1
scripts/lint-shell.sh --all
```
Expected: every line `STATUS: PASSED`; lint clean.

- [ ] **Step 7: Commit**

```bash
git add RELEASE-NOTES.md docs/specs docs/testing.md .claude-plugin package.json .cursor-plugin .codex-plugin .kimi-plugin .devin-plugin .hermes-plugin gemini-extension.json
git commit -m "chore: release notes and version bump to 7.0.0"
```

---

## Self-Review Notes

- Spec coverage: §1 → Task 3; §2 → Task 1; §3 → Task 1; §4 → Task 4; §5 → Task 2; §6 → Task 5; §7 → Task 7; testing strategy → Tasks 1–6 (evals: drill harness not present in this checkout — recorded in the PR as owed, see memory "v6.5.0 acceptance run still owed").
- Type consistency: function names `sp_default`, `sp_setting`, `sp_role_model`, `sp_role_effort`, `sp_config_warnings` match between Task 1 (definitions), Task 4 (gate), Task 6 (wiring). Deny-reason format in Task 4 Step 4 matches the needles in Task 4 Step 1. Table row format in Task 5 Step 5 matches the greps in Task 5 Step 1 and Task 6.
- Wave safety: Wave 1 files — T1 {lib-config, session-start, test-session-start}, T2 {scripts/gen-agent-variants, scripts/agent-templates/*, agents/*, test-agent-variants}, T3 {plugin.json, test-plugin-config} — disjoint. Wave 2 — T4 {agent-config-gate, hooks.json, test-agent-config-gate}, T5 {4 skill files, test-fast-mode-contract} — disjoint. Wave 3 — T6 {test-config-wiring}, T7 {RELEASE-NOTES, specs, testing.md, version files incl. plugin.json version field} — disjoint (T7 touches plugin.json's `version` only, after T3 is merged).
- Tier claims: Task 3 transcription (1 non-test file, complete JSON, test written out, no interface beyond config keys). Task 6 transcription (test file only, complete code). All others judgment.
