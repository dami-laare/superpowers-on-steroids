# Fast Mode, Per-Plugin Config, and Docs Base Dir — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-on-steroids:subagent-driven-development (recommended) or superpowers-on-steroids:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a fast mode backed by four bundled `caveman-*` agents, make tier→model selection configurable per-plugin from `settings.json`, and move the docs base dir from `docs/superpowers/` to `docs/`.

**Architecture:** Three units land serially. Unit C is a mechanical path move. Unit B adds a `userConfig` declaration whose values reach `hooks/session-start` as `CLAUDE_PLUGIN_OPTION_*` env vars and become a `<SUPERPOWERS_CONFIG>` block in the injected context. Unit A adds a top-level `agents/` directory and wires three skills to substitute named agents for inline templates when `mode: fast`. Nothing existing is removed; the template path stays the default on every harness.

**Tech Stack:** Bash + coreutils (hooks, scripts, tests), node (test JSON assertions — the existing idiom in `tests/hooks/test-session-start.sh`), Markdown (skills, agents), JSON (plugin manifests).

**Spec:** `docs/specs/2026-08-31-fast-mode-and-plugin-config-design.md` — read it before starting any task.

## Global Constraints

- **Zero third-party dependencies in shipped code.** `hooks/session-start` stays bash + coreutils. No `jq`, no node, no python in the hook. Tests may use node (existing idiom).
- **Hook output must be byte-identical to today's when no config is set.** This preserves the eval baseline. Asserted in Task 2.
- **`mode: standard` emits no config block.** Standard is the absence of fast, so a default-configured plugin produces byte-identical output.
- **Config values are whitelisted, not escaped:** accept only `^[A-Za-z0-9._-]+$`; silently drop anything else.
- **Env var names are `CLAUDE_PLUGIN_OPTION_<KEY>`** where `<KEY>` = `key.replace(/[^A-Za-z0-9_]/g,"_").toUpperCase()`. Option keys are snake_case so they survive that transform readably. Verified against Claude Code 2.1.251.
- **Agent frontmatter is never interpolated.** `${user_config.X}` reaches the agent body only. Do not template `model:` or `effort:`.
- **Never rewrite historical artifacts.** Files under `docs/plans/` and `docs/specs/` that predate this change, and `RELEASE-NOTES.md`, keep their bodies verbatim including now-stale `docs/superpowers/...` strings. Path rewrites are restricted to `skills/` and `tests/`.
- **Codex has no agents mechanism.** `agents/` must not reach the embedded Codex plugin, via either the rsync excludes or the archive guard.
- **New bash must pass `./scripts/lint-shell.sh`** (shellcheck `--severity=warning` plus `check-extra-masked-returns,check-set-e-suppressed,quote-safe-variables,deprecate-which,avoid-nullary-conditions`).
- **`set -euo pipefail` is active in the hook.** Never use bare `[ -n "$x" ] && y=z` at statement level — a false test returns non-zero and kills the script. Use `if` blocks.
- Commit messages follow Conventional Commits. Per-task types are given in each task's commit step.

## Execution Waves

Units C → B → A are strictly serial: all three edit overlapping skill files (`subagent-driven-development/SKILL.md` is touched by C, B, and A; `brainstorming/SKILL.md` and `requesting-code-review/SKILL.md` by C and A). Do not collapse these waves.

- Wave 1: Task 1 (Unit C — docs move + reference rewrite)
- Wave 2: Task 2 (Unit B — config substrate: manifest + hook + tests)
- Wave 3: Task 3 (Unit B — Model Selection consumption paragraph)
- Wave 4: Task 4 (agents/ directory), Task 5 (Codex leak guards) — disjoint files
- Wave 5: Task 6 (drift + validity tests), Task 7 (skill wiring) — disjoint files; both depend on Task 4
- Wave 6: Task 8 (version bump)

---

### Task 1: Move docs base dir to `docs/`

**Files:**
- Modify (move): `docs/superpowers/plans/*.md` → `docs/plans/`, `docs/superpowers/specs/*.md` → `docs/specs/`
- Modify: `skills/brainstorming/SKILL.md`, `skills/brainstorming/spec-document-reviewer-prompt.md`, `skills/writing-plans/SKILL.md`, `skills/requesting-code-review/SKILL.md`, `skills/subagent-driven-development/SKILL.md`
- Modify: `tests/claude-code/test-helpers.sh`, `tests/claude-code/test-subagent-driven-development-integration.sh`, `tests/claude-code/test-worktree-path-policy.sh`, `tests/explicit-skill-requests/run-test.sh`, `tests/explicit-skill-requests/run-multiturn-test.sh`, `tests/explicit-skill-requests/run-haiku-test.sh`, `tests/explicit-skill-requests/run-extended-multiturn-test.sh`, `tests/explicit-skill-requests/prompts/*.txt` (6 files)
- Modify: `docs/testing.md`

**Depends on:** none

**Interfaces:**
- Produces: the canonical docs paths `docs/plans/` and `docs/specs/`. Every later task and all future skill output uses these.

- [ ] **Step 1: Verify the pre-move state**

```bash
git grep -c "docs/superpowers" -- skills tests | awk -F: '{s+=$2} END {print s" live refs in "NR" files"}'
ls docs/superpowers/plans/*.md | wc -l   # expect 15
ls docs/superpowers/specs/*.md | wc -l   # expect 19
comm -12 <(ls docs/plans) <(ls docs/superpowers/plans)   # expect empty (no collisions)
```

Expected: `28 live refs in 18 files`, `15`, `19`, and empty collision output.

- [ ] **Step 2: Move the files with `git mv` so history follows**

`docs/specs/` already exists (it holds this change's spec), so move file-by-file rather than moving the directory — `git mv docs/superpowers/specs docs/specs` would nest it as `docs/specs/specs`.

```bash
mkdir -p docs/plans docs/specs
for f in docs/superpowers/specs/*.md; do git mv "$f" docs/specs/; done
for f in docs/superpowers/plans/*.md; do git mv "$f" docs/plans/; done
rmdir docs/superpowers/specs docs/superpowers/plans docs/superpowers
```

- [ ] **Step 3: Rewrite live references only**

The pathspec restriction to `skills tests` is load-bearing — it is what keeps historical bodies and `RELEASE-NOTES.md` untouched.

```bash
git grep -l 'docs/superpowers/' -- skills tests | xargs sed -i 's|docs/superpowers/|docs/|g'
```

- [ ] **Step 4: Verify the rewrite is complete and correctly scoped**

```bash
git grep -n 'docs/superpowers' -- skills tests   # expect NO output
git grep -c 'docs/superpowers' -- docs RELEASE-NOTES.md | head   # expect unchanged historical refs
test -d docs/superpowers && echo "FAIL: dir still exists" || echo "OK: docs/superpowers removed"
```

Expected: empty output from the first command, historical counts still present in the second, `OK` from the third.

- [ ] **Step 5: Confirm the two path-reading tests still resolve their files**

`tests/claude-code/test-worktree-path-policy.sh` reads two historical documents by absolute path. Those files moved, so this is the test most likely to break.

```bash
bash tests/claude-code/test-worktree-path-policy.sh
```

Expected: PASS. If it reports a missing file, the sed in Step 3 missed lines 12–13 — check them by hand.

- [ ] **Step 6: Register the new spec directory in the testing docs**

In `docs/testing.md`, the plugin-tests list is an inventory. No test directory changed, so this step is only the one-line inventory fix if `docs/testing.md` referenced the old path. Verify:

```bash
grep -n "docs/superpowers" docs/testing.md || echo "no change needed"
```

If it prints a match, rewrite that line to `docs/`. If it prints `no change needed`, skip.

- [ ] **Step 7: Commit**

```bash
git add docs skills tests
git commit -m "feat!: move docs base dir from docs/superpowers to docs

Skills wrote plans and specs to docs/superpowers/{plans,specs}. Now
docs/{plans,specs}. Historical artifacts move but keep bodies verbatim
per project convention; only skills/ and tests/ references rewritten.

BREAKING CHANGE: plans and specs now resolve under docs/plans and
docs/specs. No fallback lookup — existing docs/superpowers/ content in
consuming projects must be moved by hand.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" -- docs skills tests
```

---

### Task 2: Config substrate — manifest declaration, hook emission, tests

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `hooks/session-start`
- Test: `tests/hooks/test-session-start.sh`

**Depends on:** none (file-disjoint from Task 1, but sequenced after it)

**Interfaces:**
- Produces: the `<SUPERPOWERS_CONFIG>` context block. Exact emitted shape, consumed by Task 3 and Task 7:
  ```
  <SUPERPOWERS_CONFIG>
  mode: fast
  tier models: cheap=haiku standard=sonnet capable=opus
  </SUPERPOWERS_CONFIG>
  ```
  The `mode:` line appears only when mode is `fast`. The `tier models:` line appears only when at least one tier is set, and lists only the tiers that are set, space-separated, in the fixed order cheap → standard → capable. When neither line would appear, the whole block is omitted.
- Produces: option keys `mode`, `model_cheap`, `model_standard`, `model_capable` → env vars `CLAUDE_PLUGIN_OPTION_MODE`, `CLAUDE_PLUGIN_OPTION_MODEL_CHEAP`, `CLAUDE_PLUGIN_OPTION_MODEL_STANDARD`, `CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE`.

- [ ] **Step 1: Capture the byte-identical baseline BEFORE touching the hook**

This baseline is the eval-baseline guard. It must be captured from the unmodified hook.

```bash
env -i PATH="$PATH" HOME="$(mktemp -d)" CLAUDE_PLUGIN_ROOT="$PWD" \
  bash hooks/session-start > /tmp/session-start-baseline.json
wc -c /tmp/session-start-baseline.json
```

Expected: a non-empty byte count. Keep this file for Step 5.

- [ ] **Step 2: Write the failing tests**

Append to `tests/hooks/test-session-start.sh`, immediately before the final `if [[ "$FAILURES" -gt 0 ]]` block. `assert_command_output` already accepts extra `KEY=value` arguments as the command environment, so config vars pass straight through.

```bash
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/hooks/test-session-start.sh`

Expected: FAIL. `mode=fast emits the config block`, `tier models line…`, and `config block also reaches the Cursor output shape` all fail because no block is emitted yet. The two negative assertions (`unconfigured hook omits…`, `unrecognised mode falls back…`) and the byte-identical check pass trivially — that is expected and correct; they are regression guards, not drivers.

- [ ] **Step 4: Declare the options in the plugin manifest**

Add a top-level `userConfig` key to `.claude-plugin/plugin.json`, after `"keywords"`:

```json
  "userConfig": {
    "mode": {
      "type": "string",
      "title": "Execution mode",
      "description": "standard = inline prompt templates (default). fast = dispatch the bundled caveman-* agents: terser reports, lower reasoning effort, smaller dispatch payloads.",
      "default": "standard"
    },
    "model_cheap": {
      "type": "string",
      "title": "Cheap tier model",
      "description": "Model for mechanical, fully-specified work — single-file transcription tasks. Leave empty to let the agent judge what this harness offers.",
      "default": ""
    },
    "model_standard": {
      "type": "string",
      "title": "Standard tier model",
      "description": "Model for integration and judgment work, and the floor for reviewers. Leave empty to let the agent judge.",
      "default": ""
    },
    "model_capable": {
      "type": "string",
      "title": "Capable tier model",
      "description": "Model for architecture, design, and the final whole-branch review. Leave empty to let the agent judge.",
      "default": ""
    }
  }
```

Verify it parses: `node -e 'JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8"))' && echo OK`

- [ ] **Step 5: Emit the config block from the hook**

In `hooks/session-start`, insert this block after the `using_superpowers_escaped=$(...)` line and before `session_context=`:

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

sp_mode="$(config_value "${CLAUDE_PLUGIN_OPTION_MODE:-}")"
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

config_block=""
if [ -n "$sp_mode" ] || [ -n "$sp_tiers" ]; then
    config_block="\n\n<SUPERPOWERS_CONFIG>"
    if [ -n "$sp_mode" ]; then
        config_block="${config_block}\nmode: ${sp_mode}"
    fi
    if [ -n "$sp_tiers" ]; then
        config_block="${config_block}\ntier models:${sp_tiers}"
    fi
    config_block="${config_block}\n</SUPERPOWERS_CONFIG>"
fi
```

Then append `${config_block}` to the end of the `session_context` assignment, so the line becomes:

```bash
session_context="<EXTREMELY_IMPORTANT>\nYou have superpowers.\n\n**Below is the full content of your 'superpowers-on-steroids:using-superpowers' skill - your introduction to using skills. For all other skills, use the 'Skill' tool with the 'superpowers-on-steroids:' prefix:**\n\n${using_superpowers_escaped}\n</EXTREMELY_IMPORTANT>${config_block}"
```

Note the `\n` sequences are literal two-character sequences that become JSON escapes when `printf '%s'` writes them into the JSON string — this is the file's existing convention. Config values are whitelisted to `[A-Za-z0-9._-]`, so they can contain no backslash or quote and need no escaping.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/hooks/test-session-start.sh`

Expected: `STATUS: PASSED`, all assertions passing.

- [ ] **Step 7: Verify the baseline is genuinely byte-identical**

```bash
env -i PATH="$PATH" HOME="$(mktemp -d)" CLAUDE_PLUGIN_ROOT="$PWD" \
  bash hooks/session-start | diff -q - /tmp/session-start-baseline.json \
  && echo "OK: byte-identical to pre-change baseline"
```

Expected: `OK: byte-identical to pre-change baseline`. If diff reports a difference, the config block is leaking into the unconfigured path — fix before proceeding.

- [ ] **Step 8: Lint the shell**

Run: `./scripts/lint-shell.sh`

Expected: clean. If shellcheck reports anything, fix it in the new code — never silence a rule file-wide.

- [ ] **Step 9: Commit**

```bash
git add .claude-plugin/plugin.json hooks/session-start tests/hooks/test-session-start.sh
git commit -m "feat: add per-plugin model and mode config via userConfig

Declare mode and three tier model options. Hook reads them from
CLAUDE_PLUGIN_OPTION_* env vars and emits a SUPERPOWERS_CONFIG block.
Values whitelisted to [A-Za-z0-9._-] so they cannot corrupt the JSON.
Unconfigured output stays byte-identical.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" -- .claude-plugin/plugin.json hooks/session-start tests/hooks/test-session-start.sh
```

---

### Task 3: Teach Model Selection to resolve tiers from config

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md` (Model Selection section, currently lines 154–186)

**Depends on:** Task 2

**Interfaces:**
- Consumes: the `<SUPERPOWERS_CONFIG>` block shape produced by Task 2.

- [ ] **Step 1: Append the tier-resolution paragraph**

The existing Model Selection prose is tuned and expresses everything in tiers, never naming a concrete model. Do not edit any existing sentence. Append this paragraph as the last paragraph of the section, immediately before the `## Handling Implementer Status` heading:

```markdown
**Tier names resolve to concrete models.** If the session context carries a
`<SUPERPOWERS_CONFIG>` block with a `tier models:` line, use its mapping —
`cheap=`, `standard=`, and `capable=` name the model for each tier above. For
tiers the block does not name, and when there is no block at all, judge what
this harness offers. Config decides what each tier *is*; it never decides which
tier a task *needs* — that stays with the heuristics above, including the
mid-tier floor for reviewers.
```

- [ ] **Step 2: Verify nothing else in the section changed**

```bash
git diff --stat skills/subagent-driven-development/SKILL.md
git diff skills/subagent-driven-development/SKILL.md | grep '^-' | grep -v '^---'
```

Expected: the stat shows insertions only. The second command prints NO removed lines — if it prints any, a tuned sentence was altered; revert and re-apply as a pure append.

- [ ] **Step 3: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat: resolve model tiers from plugin config in SDD

Model Selection prose is tier-based and names no model. Append one
paragraph mapping tiers to configured models. Config says what a tier
is, heuristic still says which tier a task needs.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" -- skills/subagent-driven-development/SKILL.md
```

---

### Task 4: Add the four bundled agents

**Files:**
- Create: `agents/caveman-implementer.md`, `agents/caveman-reviewer.md`, `agents/caveman-final-reviewer.md`, `agents/caveman-investigator.md`

**Depends on:** none

**Interfaces:**
- Produces: agent types `superpowers-on-steroids:caveman-implementer`, `…:caveman-reviewer`, `…:caveman-final-reviewer`, `…:caveman-investigator`. Task 6 asserts their contract; Task 7 dispatches them by these names.

- [ ] **Step 1: Copy the source files verbatim**

The four files are copied unmodified from the source directory. Do not reword, restructure, or "improve" them — their compression is the point of fast mode, and their contract is asserted in Task 6.

```bash
mkdir -p agents
cp /home/nexus/work/henosys/overwatch/.claude/agents/caveman-implementer.md agents/
cp /home/nexus/work/henosys/overwatch/.claude/agents/caveman-reviewer.md agents/
cp /home/nexus/work/henosys/overwatch/.claude/agents/caveman-final-reviewer.md agents/
cp /home/nexus/work/henosys/overwatch/.claude/agents/caveman-investigator.md agents/
```

If the source path does not exist, STOP and report NEEDS_CONTEXT — do not reconstruct the files from memory.

- [ ] **Step 2: Verify the frontmatter the loader will read**

Claude Code parses frontmatter before any substitution, so these values must be literal. Confirm each file's `name` matches its filename and the model/effort pins are intact:

```bash
for f in agents/*.md; do
  echo "== $f"
  sed -n '/^---$/,/^---$/p' "$f" | grep -E '^(name|model|effort|tools):'
done
```

Expected, exactly:
- `caveman-implementer` — `model: sonnet`, `effort: low`, tools `Read, Write, Edit, Bash, Glob, Grep`
- `caveman-reviewer` — `model: sonnet`, `effort: medium`, tools `Read, Bash, Glob, Grep`
- `caveman-final-reviewer` — `model: opus`, `effort: high`, tools `Read, Bash, Glob, Grep`
- `caveman-investigator` — `model: sonnet`, `effort: high`, tools `Read, Bash, Glob, Grep, WebFetch, WebSearch`

- [ ] **Step 3: Confirm no keys the loader ignores**

Plugin agents silently ignore `permissionMode`, `hooks`, and `mcpServers` (warning only). None should be present:

```bash
grep -nE '^(permissionMode|hooks|mcpServers):' agents/*.md && echo "FAIL: remove these keys" || echo "OK: no ignored keys"
```

Expected: `OK: no ignored keys`.

- [ ] **Step 4: Commit**

```bash
git add agents
git commit -m "feat: bundle four caveman agents for fast mode

Implementer, reviewer, final reviewer, investigator. Copied verbatim
from overwatch. Effort pinned per file since no dispatch override
exists. Auto-discovered as superpowers-on-steroids:caveman-*.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" -- agents
```

---

### Task 5: Stop `agents/` leaking into the Codex plugin

**Files:**
- Modify: `scripts/sync-to-codex-plugin.sh` (EXCLUDES array, around lines 45–82)
- Modify: `scripts/package-codex-plugin.sh:336`
- Test: `tests/codex-plugin-sync/test-sync-to-codex-plugin.sh`

**Depends on:** none

**Interfaces:**
- Consumes: nothing. Guards a directory Task 4 creates, but does not read it.

- [ ] **Step 1: Write the failing test**

Append to `tests/codex-plugin-sync/test-sync-to-codex-plugin.sh`, before its final status block. Read the surrounding 30 lines first and match whatever `pass`/`fail` helpers and root-path variable that file already defines — substitute its names for `pass`/`fail`/`REPO_ROOT` below if they differ.

```bash
# A top-level agents/ directory is Claude-Code-only and must never reach the
# embedded Codex plugin, via either the rsync excludes or the archive guard.
if grep -q '"/agents/"' "$REPO_ROOT/scripts/sync-to-codex-plugin.sh"; then
    pass "sync excludes top-level agents/ (anchored)"
else
    fail "sync excludes top-level agents/ (anchored)"
fi

if grep -q '\^agents/' "$REPO_ROOT/scripts/package-codex-plugin.sh"; then
    pass "package archive guard rejects top-level agents/"
else
    fail "package archive guard rejects top-level agents/"
fi
```

These assert the guards are present rather than executing a full sync — a real sync needs network and `gh` auth. That is a deliberate, cheaper proxy; note it in your report so the reviewer does not read it as a missed requirement.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/codex-plugin-sync/test-sync-to-codex-plugin.sh`

Expected: FAIL on both new assertions — neither guard exists yet. Every pre-existing assertion still passes.

- [ ] **Step 3: Add the anchored rsync exclude**

Codex has no agents mechanism, so a top-level `agents/` would ship as inert dead weight. In `scripts/sync-to-codex-plugin.sh`, add to the `EXCLUDES` array under the `# Directories not shipped by canonical Codex plugins` comment, keeping alphabetical order (before `"/commands/"`):

```bash
  "/agents/"
```

The leading `/` is load-bearing. The destination legitimately contains nested `skills/*/agents/` directories holding OpenAI-owned metadata — an unanchored `agents/` would match and delete those.

- [ ] **Step 4: Add the archive guard**

`scripts/package-codex-plugin.sh:336` is a second, independent check asserting source-only paths never reach the archive. It lists `^\.agents/` (the dotted sibling) but not the undotted directory. Add `^agents/|` to the alternation, immediately after the opening `(`:

```bash
    grep -E '(^agents/|^superpowers/|^\.agents/|^hooks/|package\.json$|^\.git|^\.pytest_cache|^\.ruff_cache|^scripts/|^tests/|^docs/|^evals/|^lib/|^\.claude|^\.cursor|^\.kimi|^\.opencode|^\.pi|^AGENTS\.md$|^CLAUDE\.md$|^GEMINI\.md$|^RELEASE-NOTES\.md$|^CHANGELOG\.md$)' || true
```

Patching only one of these two paths ships the leak.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/codex-plugin-sync/test-sync-to-codex-plugin.sh`

Expected: both new assertions pass; no pre-existing assertion regresses.

- [ ] **Step 6: Lint and commit**

```bash
./scripts/lint-shell.sh
git add scripts/sync-to-codex-plugin.sh scripts/package-codex-plugin.sh tests/codex-plugin-sync/test-sync-to-codex-plugin.sh
git commit -m "ci: keep top-level agents/ out of the Codex plugin

Codex has no agents mechanism. Anchored rsync exclude plus the archive
guard, which listed .agents/ but not agents/. Both paths needed —
patching one still ships the leak.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" -- scripts/sync-to-codex-plugin.sh scripts/package-codex-plugin.sh tests/codex-plugin-sync/test-sync-to-codex-plugin.sh
```

---

### Task 6: Drift tripwire and agent validity tests

**Files:**
- Create: `tests/agents/test-fast-mode-contract.sh`
- Modify: `docs/testing.md`

**Depends on:** Task 4

**Interfaces:**
- Consumes: `agents/caveman-*.md` from Task 4, and the existing prompt templates.

The fast path and the template path now state the same contract twice. Prose duplication is fine; **contract divergence is not**. This test asserts only the tokens the controller branches on, plus the git-safety list. It deliberately does NOT assert the "you do not dispatch subagents" rule — every agent's `tools:` allowlist already excludes the Agent tool, so asserting the prose would test the wrong thing.

- [ ] **Step 1: Write the test**

Create `tests/agents/test-fast-mode-contract.sh`:

```bash
#!/usr/bin/env bash
# Fast-mode agents and their inline-template counterparts state the same
# contract. Prose may differ; the tokens the controller branches on may not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"
SDD_DIR="$REPO_ROOT/skills/subagent-driven-development"

FAILURES=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

assert_in_both() {
    local label="$1" token="$2" file_a="$3" file_b="$4"
    if grep -qF -- "$token" "$file_a" && grep -qF -- "$token" "$file_b"; then
        pass "$label: '$token' in both"
    else
        fail "$label: '$token' missing from one side"
    fi
}

echo "Fast-mode contract tests"

# --- Implementer pair: status contract the controller branches on ---
impl_agent="$AGENTS_DIR/caveman-implementer.md"
impl_tmpl="$SDD_DIR/implementer-prompt.md"
for token in DONE_WITH_CONCERNS NEEDS_CONTEXT BLOCKED DONE; do
    assert_in_both "implementer status" "$token" "$impl_agent" "$impl_tmpl"
done

# --- Implementer pair: repo-destroying commands both sides must forbid ---
for token in "git reset" "git stash" "git clean" "git add ." "git add -A" "git commit -a"; do
    assert_in_both "implementer git safety" "$token" "$impl_agent" "$impl_tmpl"
done

# --- Reviewer pairs: severity buckets the review loop branches on ---
rev_agent="$AGENTS_DIR/caveman-reviewer.md"
rev_tmpl="$SDD_DIR/task-reviewer-prompt.md"
final_agent="$AGENTS_DIR/caveman-final-reviewer.md"
final_tmpl="$REPO_ROOT/skills/requesting-code-review/code-reviewer.md"
for token in Critical Important Minor; do
    assert_in_both "task reviewer severity" "$token" "$rev_agent" "$rev_tmpl"
    assert_in_both "final reviewer severity" "$token" "$final_agent" "$final_tmpl"
done

# --- Agent file validity: what the plugin loader will accept ---
for f in "$AGENTS_DIR"/caveman-*.md; do
    base="$(basename "$f" .md)"
    fm="$(sed -n '/^---$/,/^---$/p' "$f")"

    if printf '%s' "$fm" | grep -qE "^name: ${base}\$"; then
        pass "$base: name matches filename"
    else
        fail "$base: name does not match filename"
    fi

    model="$(printf '%s' "$fm" | sed -n 's/^model: *//p')"
    if [ -n "$model" ] && [ "$model" != "inherit" ]; then
        pass "$base: model pinned ($model)"
    else
        fail "$base: model must be pinned and not 'inherit'"
    fi

    effort="$(printf '%s' "$fm" | sed -n 's/^effort: *//p')"
    case "$effort" in
        low|medium|high|xhigh|max|*[0-9]) pass "$base: effort valid ($effort)" ;;
        *) fail "$base: invalid effort '$effort'" ;;
    esac

    if printf '%s' "$fm" | grep -qE '^(permissionMode|hooks|mcpServers):'; then
        fail "$base: sets a key plugin agents ignore"
    else
        pass "$base: no ignored keys"
    fi

    if printf '%s' "$fm" | sed -n 's/^tools: *//p' | grep -qw "Agent"; then
        fail "$base: tools grants the Agent tool"
    else
        pass "$base: tools withholds the Agent tool"
    fi
done

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi

echo "STATUS: PASSED"
```

```bash
chmod +x tests/agents/test-fast-mode-contract.sh
```

- [ ] **Step 2: Run it — expect PASS**

Run: `bash tests/agents/test-fast-mode-contract.sh`

Expected: `STATUS: PASSED`. The files are consistent right now, so a green run here is correct — but a test that has never failed proves nothing, which Step 3 fixes.

- [ ] **Step 3: Prove the tripwire actually catches drift**

This is the RED step for a regression guard. Break one token, confirm the test fails, restore.

Restore from a file copy, not from git — `git checkout -- <path>` is forbidden in a shared checkout.

```bash
cp agents/caveman-implementer.md /tmp/caveman-implementer.bak
sed -i 's/DONE_WITH_CONCERNS/DONE_WITH_WORRIES/' agents/caveman-implementer.md
bash tests/agents/test-fast-mode-contract.sh; echo "exit=$?"
cp /tmp/caveman-implementer.bak agents/caveman-implementer.md
rm /tmp/caveman-implementer.bak
bash tests/agents/test-fast-mode-contract.sh; echo "exit=$?"
```

Expected: first run `STATUS: FAILED` with `exit=1`; second run `STATUS: PASSED` with `exit=0`. If the first run passes, the assertion is not wired to anything — fix it before continuing.

- [ ] **Step 4: Register the test in the testing docs**

In `docs/testing.md`, add to the plugin-tests bullet list, after the `tests/codex-plugin-sync/` line:

```markdown
- `tests/agents/` — bash contract test asserting the bundled `caveman-*` agents and their inline-template counterparts keep the same status tokens, git-safety rules, and severity buckets, plus agent-frontmatter validity.
```

- [ ] **Step 5: Lint and commit**

```bash
./scripts/lint-shell.sh
git add tests/agents/test-fast-mode-contract.sh docs/testing.md
git commit -m "test: assert fast-mode agents match template contract

Agents and inline templates state the same contract twice. Prose can
drift, tokens cannot. Assert status set, forbidden git commands,
severity buckets, plus frontmatter validity.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" -- tests/agents/test-fast-mode-contract.sh docs/testing.md
```

---

### Task 7: Wire fast mode into the three skills

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md` (new Fast Mode section; `Handling Implementer Status` BLOCKED branch)
- Modify: `skills/requesting-code-review/SKILL.md` (step 2, around line 34)
- Modify: `skills/brainstorming/SKILL.md` (checklist step 2, line 31)

**Depends on:** Task 4

**Interfaces:**
- Consumes: agent names from Task 4; the `<SUPERPOWERS_CONFIG>` block shape from Task 2.

- [ ] **Step 1: Add the Fast Mode section to SDD**

Insert immediately after the `## Model Selection` section (i.e. before `## Handling Implementer Status`), so it reads as a modifier on dispatch:

```markdown
## Fast Mode

If the session context carries a `<SUPERPOWERS_CONFIG>` block with `mode: fast`,
dispatch the bundled agents instead of pasting the inline templates:

| Role | Standard path | Fast path |
|---|---|---|
| Implementer | [implementer-prompt.md](implementer-prompt.md) | `superpowers-on-steroids:caveman-implementer` |
| Task reviewer | [task-reviewer-prompt.md](task-reviewer-prompt.md) | `superpowers-on-steroids:caveman-reviewer` |
| Final whole-branch review | [code-reviewer.md](../requesting-code-review/code-reviewer.md) | `superpowers-on-steroids:caveman-final-reviewer` |

Each agent carries its role contract in its own system prompt, so a fast
dispatch passes only the task-specific material: the brief path, the report
path, the review package path, interfaces from earlier tasks, and the global
constraints that bind the task. Do not paste the template body as well — that
duplicates the contract and throws away the context saving that is the point.

Roles with no agent counterpart stay on the template path in both modes: the
re-review, fix subagents, the spec-document reviewer, the plan-document
reviewer, and the Brainstormer.

Model selection is unchanged in fast mode — resolve the tier as always and pass
`model:` explicitly. Effort is fixed by each agent's definition and cannot be
raised at dispatch.
```

- [ ] **Step 2: Amend the BLOCKED branch**

In `## Handling Implementer Status`, the `**BLOCKED:**` list currently reads:

```markdown
2. If the task requires more reasoning, re-dispatch with a more capable model
```

Replace that single line with:

```markdown
2. If the task requires more reasoning, re-dispatch with a more capable model. In fast mode, re-dispatch on the inline template path rather than the fast agent — its effort is pinned low and cannot be raised at dispatch.
```

- [ ] **Step 3: Wire the standalone code-review entry point**

`skills/requesting-code-review/SKILL.md` is also invoked outside SDD, so it needs its own line. After the existing sentence at line 34 (`Dispatch a `general-purpose` subagent, filling the template at [code-reviewer.md](code-reviewer.md)`), add:

```markdown
If the session context carries `<SUPERPOWERS_CONFIG>` with `mode: fast`, dispatch
`superpowers-on-steroids:caveman-final-reviewer` instead — it carries the reviewer
contract already, so pass it only the four placeholder values below.
```

- [ ] **Step 4: Wire brainstorming's exploration step**

In `skills/brainstorming/SKILL.md`, checklist item 2 currently reads:

```markdown
2. **Explore project context** — check files, docs, recent commits (share findings in the dispatch prompt, or tell the Brainstormer to explore itself)
```

Replace with:

```markdown
2. **Explore project context** — check files, docs, recent commits (share findings in the dispatch prompt, or tell the Brainstormer to explore itself). In fast mode (`<SUPERPOWERS_CONFIG>` with `mode: fast`), dispatch `superpowers-on-steroids:caveman-investigator` to gather this instead of exploring inline.
```

- [ ] **Step 5: Verify the edits are additive and the agent names are exact**

```bash
git diff skills/ | grep '^-' | grep -v '^---'
grep -o 'superpowers-on-steroids:caveman-[a-z-]*' skills/*/SKILL.md | sort -u
```

Expected: the only removed lines are the two whose replacements are given verbatim in Steps 2 and 4 — no other tuned sentence is touched. The second command lists exactly four names, each matching a file in `agents/`:

```bash
for n in implementer reviewer final-reviewer investigator; do
  test -f "agents/caveman-$n.md" && echo "OK caveman-$n" || echo "MISSING caveman-$n"
done
```

- [ ] **Step 6: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md skills/requesting-code-review/SKILL.md skills/brainstorming/SKILL.md
git commit -m "feat: dispatch bundled agents when mode is fast

SDD gains a Fast Mode substitution table; code-review and brainstorming
each gain one line. Templates stay the default, so harnesses without
named agents are untouched. BLOCKED branch now says to fall back to the
template path, since agent effort cannot be raised at dispatch.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>" -- skills/subagent-driven-development/SKILL.md skills/requesting-code-review/SKILL.md skills/brainstorming/SKILL.md
```

---

### Task 8: Version bump

**Files:**
- Modify: `package.json`, `.hermes-plugin/plugin.yaml`, `.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `.devin-plugin/plugin.json`, `.kimi-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json` (all nine driven by `.version-bump.json`)

**Depends on:** Tasks 1–7

- [ ] **Step 1: Confirm the current version is consistent**

Run: `./scripts/bump-version.sh --check`

Expected: every declared file reports `6.3.0` with no drift.

- [ ] **Step 2: Bump**

Task 1 removed the `docs/superpowers/` path with no fallback lookup, which breaks the contract for any project already using this fork — a `feat!:` change, so the bump is MAJOR.

Run: `./scripts/bump-version.sh 6.4.0`

The script rewrites all nine files and then runs its own audit for undeclared version references.

- [ ] **Step 3: Verify**

Run: `./scripts/bump-version.sh --audit`

Expected: all nine files at `6.4.0`, no undeclared references reported.

- [ ] **Step 4: Run the full plugin test suite**

```bash
bash tests/hooks/test-session-start.sh
bash tests/agents/test-fast-mode-contract.sh
bash tests/codex-plugin-sync/test-sync-to-codex-plugin.sh
bash tests/claude-code/test-worktree-path-policy.sh
./scripts/lint-shell.sh
```

Expected: every script reports PASSED and the linter is clean. The LLM-driven suites under `tests/explicit-skill-requests/` and `tests/claude-code/test-subagent-driven-development*.sh` need API credentials and are not part of this gate; skip them and say so in the report.

- [ ] **Step 5: Commit**

```bash
git add package.json .hermes-plugin/plugin.yaml .claude-plugin/plugin.json \
  .cursor-plugin/plugin.json .codex-plugin/plugin.json .devin-plugin/plugin.json \
  .kimi-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json
git commit -m "chore: bump version to 6.4.0

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```
