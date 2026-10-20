# Ultra Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-on-steroids:subagent-driven-development (recommended) or superpowers-on-steroids:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mode: ultra`: fast mode plus a parallel test-writer lane, with per-task streamed converge (test-and-fix) loops. Then bump to 7.1.0.

**Architecture:** Ultra is a strict superset of fast. It needs a new uniform `test-writer` role across config (plugin.json, lib-config, session-start, gate), a new generated agent `caveman-test-writer-<effort>`, a lane clause in the implementer template, and one superset rule per skill plus an `## Ultra Mode` section in SDD.

**Tech Stack:** bash hooks (bash 3.2 compatible), JSON manifests, Markdown skills and agents, and bash test scripts that use `node` for JSON checks.

**Spec:** `docs/specs/2026-10-20-ultra-mode-design.md`

## Global Constraints

- Role name `test-writer`. Config keys `test_writer_model` (default `sonnet`) and `test_writer_effort` (default `low`). Env vars `SUPERPOWERS_TEST_WRITER_MODEL` and `SUPERPOWERS_TEST_WRITER_EFFORT`. Agent `caveman-test-writer-<effort>`.
- Mode values: `standard|fast|ultra`. The default stays `standard`.
- Superset rule, verbatim in each of SDD, requesting-code-review, brainstorming and writing-plans: ``mode: ultra` includes all of fast mode. Every fast-mode instruction applies to ultra too`
- Existing `mode: fast` text stays untouched.
- No new dependencies. bash 3.2: no `${var^^}`, no associative arrays.
- Agent frontmatter `description:` must not contain `: `.
- Never hand-edit `agents/caveman-*.md`. Edit `scripts/agent-templates/` and run `bash scripts/gen-agent-variants`.
- Version 7.1.0. Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Execution Waves

- Wave 1: Tasks 1, 2 (no dependencies, disjoint files)
- Wave 2: Tasks 3, 4 (3 depends on 1, 2; 4 depends on 1 because both touch `.claude-plugin/plugin.json`)

Note: `tests/hooks/test-config-wiring.sh` cross-checks Task 1 against Task 2 and is updated in Task 3. Do not run it in wave 1, because it fails until both wave-1 tasks have landed.

---

### Task 1: Config, resolver, session-start and gate learn `ultra` and `test-writer`

**Files:**
- Modify: `.claude-plugin/plugin.json` (userConfig only, not `version`)
- Modify: `hooks/lib-config:19-54`
- Modify: `hooks/session-start:37`
- Modify: `hooks/agent-config-gate:147-152`
- Test: `tests/hooks/test-plugin-config.sh`, `tests/hooks/test-session-start.sh`, `tests/hooks/test-agent-config-gate.sh`

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: none
- Produces:
  - `sp_role_model test-writer` → `sonnet` by default.
  - `sp_role_effort test-writer` → `low` by default.
  - `sp_resolve_mode` accepts `ultra`.
  - `<SUPERPOWERS_CONFIG>` gains a final role line `test-writer: model=<m> effort=<e>`, after `final-reviewer:`.
  - The gate allows `caveman-test-writer-<effort>` only at the configured effort and model.

- [ ] **Step 1: Update the tests**

`tests/hooks/test-plugin-config.sh`. Replace lines 13, 16, 24, 27, 30 and 43 as follows:

```js
const expectedOrder = ["mode","implementer_mechanical_model","implementer_judgment_model","implementer_effort","reviewer_model","reviewer_effort","investigator_model","investigator_effort","final_reviewer_model","final_reviewer_effort","test_writer_model","test_writer_effort"];
```
```js
const defaults = { mode: "standard", implementer_mechanical_model: "haiku", implementer_judgment_model: "sonnet", implementer_effort: "low", reviewer_model: "sonnet", reviewer_effort: "medium", investigator_model: "sonnet", investigator_effort: "medium", final_reviewer_model: "opus", final_reviewer_effort: "high", test_writer_model: "sonnet", test_writer_effort: "low" };
```
```js
if (JSON.stringify(cfg.mode.options) !== JSON.stringify(["standard","fast","ultra"])) fail("mode.options");
if (!cfg.mode.description.includes("ultra")) fail("mode.description lacks ultra");
```
Line 27 becomes:
```js
  const modeNote = k === "test_writer_effort" ? "ultra mode only" : "fast mode only";
  if (!cfg[k].description.includes(modeNote)) fail(`${k}.description lacks "${modeNote}"`);
```
```js
const agentOf = { implementer: "caveman-implementer-", reviewer: "caveman-reviewer-", investigator: "caveman-investigator-", final_reviewer: "caveman-final-reviewer-", test_writer: "caveman-test-writer-" };
```
```bash
    echo "  [PASS] userConfig has the twelve role-keyed fields with defaults, options, and env names"
```

`tests/hooks/test-session-start.sh`:
- Line 226 `defaults_block`: insert `$'\n'"test-writer: model=sonnet effort=low"` between the `final-reviewer: model=opus effort=high` line and `</SUPERPOWERS_CONFIG>`.
- In `default_configured` (around line 233), add after the `FINAL_REVIEWER_EFFORT=high \` line:
  ```bash
      CLAUDE_PLUGIN_OPTION_TEST_WRITER_MODEL=sonnet \
      CLAUDE_PLUGIN_OPTION_TEST_WRITER_EFFORT=low \
  ```
- In the `roles_home` assertion, append `$'\037'"test-writer: model=haiku effort=medium"` to the expected string, and add these env lines before `bash "$HOOK_UNDER_TEST"`:
  ```bash
      CLAUDE_PLUGIN_OPTION_TEST_WRITER_MODEL=haiku \
      CLAUDE_PLUGIN_OPTION_TEST_WRITER_EFFORT=medium \
  ```
- Directly after the `fast_home` assertion block, add:
  ```bash
  ultra_home="$(make_home config-ultra)"
  assert_command_output \
      "mode=ultra emits mode: ultra with the test-writer line" \
      "nested" \
      "<SUPERPOWERS_CONFIG>"$'\n'"mode: ultra"$'\037'"test-writer: model=sonnet effort=low" \
      "warning:" \
      "$ultra_home" \
      CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
      CLAUDE_PLUGIN_OPTION_MODE=ultra \
      bash "$HOOK_UNDER_TEST"
  ```
- Directly after the `env_fast_home` assertion block, add:
  ```bash
  env_ultra_home="$(make_home config-env-ultra)"
  assert_command_output \
      "SUPERPOWERS_MODE=ultra wins over a fast plugin option" \
      "nested" \
      "<SUPERPOWERS_CONFIG>"$'\n'"mode: ultra" \
      "mode: fast" \
      "$env_ultra_home" \
      CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
      CLAUDE_PLUGIN_OPTION_MODE=fast \
      SUPERPOWERS_MODE=ultra \
      bash "$HOOK_UNDER_TEST"
  ```
- Grep the file for any other literal block ending `effort=high"$'\n'"</SUPERPOWERS_CONFIG>` and give it the test-writer line too.

`tests/hooks/test-agent-config-gate.sh`. After the `implementer-high on opus (round-3 escalation)` allow, add:
```bash
expect_allow "test-writer-low on sonnet is allowed by default" \
    "$(payload "$P:caveman-test-writer-low" sonnet "write tests")" "$ROOT"
expect_deny "test-writer at the wrong effort is denied" 'caveman-test-writer-low + model "sonnet" (configured)' \
    "$(payload "$P:caveman-test-writer-medium" sonnet "write tests")" "$ROOT"
expect_allow "configured test-writer effort and model are allowed" \
    "$(payload "$P:caveman-test-writer-high" opus "write tests")" "$ROOT" \
    SUPERPOWERS_TEST_WRITER_MODEL=opus SUPERPOWERS_TEST_WRITER_EFFORT=high
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `bash tests/hooks/test-plugin-config.sh; bash tests/hooks/test-session-start.sh; bash tests/hooks/test-agent-config-gate.sh`
Expected: FAIL. plugin-config fails on keys/order; session-start fails on the defaults block and ultra (falls back to standard with a warning); the gate denies test-writer with "unknown caveman agent".

- [ ] **Step 3: Implement**

`.claude-plugin/plugin.json`. Change `mode.options` to `["standard", "fast", "ultra"]` (one per line, matching the existing style). Set `mode.description` to:
```
standard = inline prompt templates. fast = dispatch the bundled caveman-* agents: terser reports, configurable effort, smaller dispatch payloads, plan-tiered task review, 3-round fix loop. ultra (experimental) = fast plus a parallel test-writer lane: a judgment task's tests are written from the plan's contract alongside its implementation, then each task runs a test-and-fix converge loop; TDD RED evidence is dropped for those tasks. Env override: SUPERPOWERS_MODE (env wins).
```
Append two keys after `final_reviewer_effort`, keeping the existing formatting:
```json
    "test_writer_model": {
      "type": "string",
      "title": "Test writer model",
      "options": [
        "haiku",
        "sonnet",
        "opus",
        "fable"
      ],
      "description": "Model for writing a judgment task's tests from the plan's contract, in parallel with its implementer. Drives caveman-test-writer-<effort> in ultra mode; standard and fast mode never dispatch it. Agent-tool alias: haiku, sonnet, opus, or fable. Env override: SUPERPOWERS_TEST_WRITER_MODEL (env wins).",
      "default": "sonnet"
    },
    "test_writer_effort": {
      "type": "string",
      "title": "Test writer effort",
      "options": [
        "low",
        "medium",
        "high"
      ],
      "description": "Reasoning effort for caveman-test-writer-<effort>; ultra mode only. Harness settings modelSettings.effortLevel / maxEffortLevel may clamp this. Env override: SUPERPOWERS_TEST_WRITER_EFFORT (env wins).",
      "default": "low"
    }
```

`hooks/lib-config`:
```bash
SP_ROLES="implementer reviewer investigator final-reviewer test-writer"
```
```bash
SP_KEYS="mode implementer_mechanical_model implementer_judgment_model implementer_effort reviewer_model reviewer_effort investigator_model investigator_effort final_reviewer_model final_reviewer_effort test_writer_model test_writer_effort"
```
In `sp_default`, after `final_reviewer_effort) printf high ;;`:
```bash
        test_writer_model) printf sonnet ;;
        test_writer_effort) printf low ;;
```
In `sp_accept`:
```bash
        mode) case "$val" in standard|fast|ultra) printf '%s' "$val" ;; esac ;;
```

`hooks/session-start:37`:
```bash
for role_name in reviewer investigator final-reviewer test-writer; do
```

`hooks/agent-config-gate:148` and `:152`:
```bash
    implementer|reviewer|investigator|final-reviewer|test-writer) ;;
```
```bash
[ -n "$role" ] || deny "unknown caveman agent: dispatch superpowers-on-steroids:caveman-<role>-<effort> with <role> one of implementer, reviewer, investigator, final-reviewer, test-writer and <effort> from <SUPERPOWERS_CONFIG>."
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `bash tests/hooks/test-plugin-config.sh && bash tests/hooks/test-session-start.sh && bash tests/hooks/test-agent-config-gate.sh && bash tests/shell-lint/test-lint-shell.sh`
Expected: every script prints `STATUS: PASSED` (shell-lint may skip if shellcheck is absent; that is fine).

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(config): add ultra mode and test-writer role config" -- .claude-plugin/plugin.json hooks/lib-config hooks/session-start hooks/agent-config-gate tests/hooks/test-plugin-config.sh tests/hooks/test-session-start.sh tests/hooks/test-agent-config-gate.sh
```
(Stage first with `git add <those paths>`. The message ends with the Co-Authored-By trailer.)

---

### Task 2: `caveman-test-writer` agent and the implementer lane clause

**Files:**
- Create: `scripts/agent-templates/caveman-test-writer.md`
- Modify: `scripts/agent-templates/caveman-implementer.md`
- Modify: `scripts/gen-agent-variants:15`
- Create/Modify (generated): `agents/caveman-test-writer-{low,medium,high}.md`, `agents/caveman-implementer-{low,medium,high}.md`
- Test: `tests/agents/test-agent-variants.sh`

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: none
- Produces:
  - Agent `superpowers-on-steroids:caveman-test-writer-<effort>`, pinned `model: sonnet`. Status contract DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT.
  - Implementer section heading `## Test-writer lane (ultra mode)`, containing the phrase `implement only`.

- [ ] **Step 1: Update the test**

`tests/agents/test-agent-variants.sh`:
```bash
ROLES="implementer reviewer investigator final-reviewer test-writer"
```
Replace the 12-count block with:
```bash
# --- Exactly 15 variants, no bare names ---
count="$(find "$AGENTS_DIR" -maxdepth 1 -name 'caveman-*.md' | wc -l | tr -d ' ')"
if [ "$count" = "15" ]; then
    pass "exactly 15 caveman agent files"
else
    fail "expected 15 caveman agent files, found $count"
fi
```
Append before the final `FAILURES` check:
```bash
# --- Ultra lanes: implementer knows the lane, test-writer stays in its files ---
if grep -qF '## Test-writer lane (ultra mode)' "$TEMPLATES/caveman-implementer.md" \
    && grep -qF 'implement only' "$TEMPLATES/caveman-implementer.md"; then
    pass "implementer template carries the test-writer lane clause"
else
    fail "implementer template lacks the test-writer lane clause"
fi
for token in "Do not read, open, or wait for the task's implementation files" "Never edit an implementation file" "DONE_WITH_CONCERNS" "NEEDS_CONTEXT" "git add -A"; do
    if grep -qF -- "$token" "$TEMPLATES/caveman-test-writer.md"; then
        pass "test-writer template: '$token'"
    else
        fail "test-writer template lacks '$token'"
    fi
done
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `bash tests/agents/test-agent-variants.sh`
Expected: FAIL (missing test-writer template and files, count 12).

- [ ] **Step 3: Implement**

`scripts/gen-agent-variants:15`:
```bash
ROLES="implementer reviewer investigator final-reviewer test-writer"
```

Create `scripts/agent-templates/caveman-test-writer.md`:
````markdown
---
name: caveman-test-writer-{{EFFORT}}
description: Writes the tests for one ultra-mode task from its plan brief, in parallel with the implementer and without seeing the implementation. Tests the brief's Interfaces contract, touches only the brief's Test files, commits with an explicit pathspec, and reports in caveman style. Effort {{EFFORT}} variant. Dispatch only the variant named by <SUPERPOWERS_CONFIG>.
tools: Read, Write, Edit, Bash, Glob, Grep
model: sonnet
effort: {{EFFORT}}
color: yellow
---

You write the tests for exactly one task from a written brief while another agent implements the same task in this checkout. The brief is your requirements. Its **Interfaces** block is your contract, and the exact values in it are verbatim, not suggestions.

## Speech

Report in caveman style: terse, fragments fine, drop articles and filler. Keep ALL technical substance exact — file paths, symbol names, line numbers, error strings, test counts. Code, code comments and commit messages are always normal, careful English. Never compress those.

## Working rules

1. Read your brief first. Your contract is its Interfaces block (the names, signatures and behaviours the task produces), its requirements, and any test code it carries. If the contract is ambiguous, test the most literal reading and record the assumption in your report. Do not stop to ask: the controller resolves assumptions when it runs your tests.
2. Do not read, open, or wait for the task's implementation files — the brief's Create/Modify entries that are not tests. Test the contract, not an implementation. You may read existing code the task consumes to learn its real API.
3. Assert the contract's behaviours: one behaviour per test, real inputs and outputs, and the edge cases and error paths the brief names. No tautological tests, no mocks that restate the code under test, no assertions on incidental output the contract does not promise.
4. Follow the repo's existing test layout, helpers and naming.
5. Run your tests once if the runner allows. Failures caused by a missing or partial implementation are expected. Do not bend a test to pass against what is there. Fix only faults in the test itself: syntax, helper imports, fixture paths.
6. Commit with the test commit message the brief gives, or `test: <task name>` if it gives none.
7. Self-review before reporting. Is every contract behaviour covered? Is any assertion unsupported by the contract?

## Git discipline — a shared checkout

The implementer and other agents are working in this same checkout on different files.

- Touch ONLY the test files your brief lists. Never edit an implementation file, even to make a test pass. If a test seems to need another file, stop and report NEEDS_CONTEXT.
- **Commit with an explicit pathspec**: `git commit -m "msg" -- path/one path/two`. A plain `git commit -m` commits the whole index, including a wave-mate's staged work.
- **NEVER run** `git reset`, `git stash`, `git checkout -- <path>`, `git clean`, `git add .`, `git add -A`, or `git commit -a`. These are repo-wide and destroy other agents' work.
- If `git commit` fails on `index.lock`, wait 2 seconds and retry.
- Never run repo-wide formatters, linters with `--fix`, or codemods.

## You do not dispatch subagents

Do all the work yourself. Never spawn a subagent.

Never disable, skip, or loosen a test.

## Report

Write the full report to the file path your dispatch names: each test written (file, test name, the Interfaces line it covers), the command that runs them, the run result if you ran them, every assumption beyond the contract, and concerns.

Then reply with ONLY, under 15 lines:
- **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
- Commits created (short SHA + subject)
- Test command
- Assumptions, if any
- The report file path
````

`scripts/agent-templates/caveman-implementer.md`. Insert this section directly before `## Git discipline — a shared checkout`:
```markdown
## Test-writer lane (ultra mode)

When your dispatch says the task's tests belong to a test-writer lane, implement only. Do not create or edit the brief's Test files, and do not wait for them or run them — they may not exist yet. Skip the TDD steps that write or run those tests; run any build, type or lint check the brief names instead. The controller runs the tests once both lanes finish and may resume you with failures. Fix the implementation, or fix a test that contradicts the brief's Interfaces contract and cite that contract line in your report. Never weaken a test to reach green.

```
In `## Report`, after the sentence that begins `Write the full report`, add: `In a test-writer lane, replace the TDD evidence with the checks you ran.`

Then regenerate: `bash scripts/gen-agent-variants`

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `bash tests/agents/test-agent-variants.sh && bash tests/agents/test-fast-mode-contract.sh`
Expected: both print `STATUS: PASSED`.

- [ ] **Step 5: Commit**

```bash
git add scripts/agent-templates/caveman-test-writer.md scripts/agent-templates/caveman-implementer.md scripts/gen-agent-variants agents/caveman-test-writer-low.md agents/caveman-test-writer-medium.md agents/caveman-test-writer-high.md agents/caveman-implementer-low.md agents/caveman-implementer-medium.md agents/caveman-implementer-high.md tests/agents/test-agent-variants.sh
git commit -m "feat(agents): add caveman-test-writer and implementer lane clause" -- <same paths>
```

---

### Task 3: Skills wire ultra mode; contract and wiring tests

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`
- Modify: `skills/requesting-code-review/SKILL.md`
- Modify: `skills/brainstorming/SKILL.md`
- Modify: `skills/writing-plans/SKILL.md`
- Test: `tests/agents/test-fast-mode-contract.sh`, `tests/hooks/test-config-wiring.sh`

**Depends on:** 1, 2

**Review tier:** judgment

**Interfaces:**
- Consumes: the `test-writer:` block line and `mode: ultra` (Task 1); `caveman-test-writer-<effort>` and the implementer lane heading (Task 2).
- Produces: the SDD `## Ultra Mode` section and its role-table row `` | `test-writer` | `caveman-test-writer-<effort>` | ``.

- [ ] **Step 1: Update the tests**

`tests/hooks/test-config-wiring.sh`:
- Line 49 regex: `'^[[:space:]]+implementer\|reviewer\|investigator\|final-reviewer\|test-writer\) ;;'`
- In the emitted-lines loop, after the `final-reviewer:` line, add:
  `"test-writer: model=$(sp_default test_writer_model) effort=$(sp_default test_writer_effort)"; do` (moving the `; do` from the previous line).

`tests/agents/test-fast-mode-contract.sh`. After the existing `final-reviewer` role-table assert (line 111), add:
```bash
assert_in_file "role table" '| `test-writer` | `caveman-test-writer-<effort>` |' "$sdd_skill"
```
Add `TEST_WRITER_MODEL TEST_WRITER_EFFORT` to the env-override key loop at line 120. Before the final `FAILURES` check, append:
```bash
# --- Ultra: superset rule in every mode-aware skill, wired to the emitted block ---
ULTRA_RULE='`mode: ultra` includes all of fast mode. Every fast-mode instruction applies to ultra too'
ultra_home="$(mktemp -d)"
ultra_emitted="$(env -i PATH="${PATH:-}" HOME="$ultra_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PLUGIN_OPTION_MODE=ultra \
    bash "$REPO_ROOT/hooks/session-start" 2>/dev/null)" || ultra_emitted=""
rm -rf "$ultra_home"
for token in "mode: ultra" "test-writer: model="; do
    if printf '%s' "$ultra_emitted" | grep -qF -- "$token"; then
        pass "ultra wiring: hook emits '$token'"
    else
        fail "ultra wiring: hook does not emit '$token'"
    fi
done
for skill in subagent-driven-development requesting-code-review brainstorming writing-plans; do
    assert_in_file "ultra superset rule" "$ULTRA_RULE" "$REPO_ROOT/skills/$skill/SKILL.md"
done
for token in "## Ultra Mode" "Lane split" "Transcription tasks" "fast fallback" "Converge loop" \
    "the Interfaces line the test contradicted" '`superpowers-on-steroids:caveman-test-writer-<effort>`' \
    "Tests belong to a test-writer lane: implement only." "flag tautological tests" "Mode: ultra —"; do
    assert_in_file "ultra SDD" "$token" "$sdd_skill"
done
assert_in_file "ultra review" "flag tautological tests" "$REPO_ROOT/skills/requesting-code-review/SKILL.md"
assert_in_file "ultra plans" "(fast fallback)" "$plans_skill"
assert_in_file "ultra implementer" "## Test-writer lane (ultra mode)" "$AGENTS_DIR/caveman-implementer-low.md"
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `bash tests/agents/test-fast-mode-contract.sh; bash tests/hooks/test-config-wiring.sh`
Expected: FAIL on the role table, superset rule, ultra SDD tokens, and the SDD table row for test-writer.

- [ ] **Step 3: Implement**

`skills/subagent-driven-development/SKILL.md`:

(a) Pre-flight announcement paragraph (`State the resolved policy once…`). After `` `Mode: standard — every task reviewed; fix loop capped at 3 rounds` `` insert ``, or `Mode: ultra — fast-mode rules plus a parallel test-writer lane on judgment tasks; per-task converge loop capped at 3 rounds` `` so that all three strings are listed. Keep the sentence grammatical: "…`Mode: fast — …`, `Mode: ultra — …`, or `Mode: standard — …`."

(b) In the Model Selection example block, add the line `test-writer: model=sonnet effort=low` after `final-reviewer: model=opus effort=high`.

(c) In the role table, add this after the `final-reviewer` row:
```markdown
| `test-writer` | `caveman-test-writer-<effort>` | `test-writer: model=` | `test-writer: effort=` | ultra mode only: a judgment task's tests, written in parallel with its implementer |
```

(d) Insert this section directly before `## Handling Implementer Status`:
```markdown
## Ultra Mode

`mode: ultra` includes all of fast mode. Every fast-mode instruction applies to ultra too, plus the additions in this section.

Ultra is experimental. It trades TDD RED evidence for wall-clock time. A judgment task's tests are written by a second agent, in parallel with its implementer, from the plan's contract, without seeing the implementation. A test that encodes a wrong API assumption costs a converge round, so the plan's Interfaces block is the bottleneck. This is a deliberate, scoped deviation from superpowers-on-steroids:test-driven-development.

**Lane split.** A judgment task needs two things to run as two lanes: a **Test:** path disjoint from its Create/Modify files, and an Interfaces **Produces:** contract (the names, signatures and behaviours it produces). Both lanes go out in the wave's single dispatch message:

| Lane | Agent | Dispatch carries | Touches |
|---|---|---|---|
| Implementer | `superpowers-on-steroids:caveman-implementer-<effort>` | brief path, report path, and the line "Tests belong to a test-writer lane: implement only." | the task's non-test files |
| Test-writer | `superpowers-on-steroids:caveman-test-writer-<effort>` on `test-writer: model=` | brief path, its own report path | the task's Test files only |

Each lane commits its own paths with an explicit pathspec, as wave-mates already do.

**No lane split.** In these cases the task runs exactly as in fast mode:
- **Transcription tasks.** The brief already carries the test and implementation code, so a second agent buys nothing. One implementer writes both and skips the RED run. It runs the tests once, after implementing.
- **fast fallback.** A judgment task with no disjoint Test path or no Produces contract runs as one implementer with full TDD. Ledger it as `fast fallback`.

**Per-task streaming.** Do not wait for the whole wave. As soon as both lanes of a task have reported:

1. If the test-writer reports an assumption that contradicts the brief, resume it with the correction first. Then run that task's Test files once.
2. **Converge loop** if anything fails: resume the implementer with the failing output and the test-writer's stated assumptions. It may fix the implementation or a test. A test edit must cite, in its report, the Interfaces line the test contradicted; an uncited test edit is rejected and the round repeats. Rounds 1–2 resume `caveman-implementer-<effort>`. Round 3 dispatches `superpowers-on-steroids:caveman-implementer-high` on `final-reviewer: model=` with the brief, both reports and the failing output. If it is still red after round 3, handle the task as BLOCKED.
3. Once the task is green, generate its path-scoped review package and dispatch its reviewer right away (the Review tier gate still applies). Then run the normal Fix Loop.

The task's wave-mates keep running meanwhile. Their file sets are disjoint and every review package is path-scoped. The wave suite (Running a wave, step 7), the final whole-branch review and verification-before-completion are unchanged.

**Reviewer checklist addition.** Every ultra task-reviewer dispatch adds: "Tests assert the contract's behaviours, not the implementation's incidental output; flag tautological tests as Important."
```

`skills/requesting-code-review/SKILL.md`. Directly after the fast-mode paragraph (the one ending `passing it the printed package path plus the four placeholder values below.`), add:
```markdown

`mode: ultra` includes all of fast mode. Every fast-mode instruction applies to ultra too. In ultra, also tell the reviewer: "Tests assert the contract's behaviours, not the implementation's incidental output; flag tautological tests as Important."
```

`skills/brainstorming/SKILL.md`. Directly after the `MAX_ROUNDS` fast-mode bullet (line 82), add the bullet:
```markdown
- `mode: ultra` includes all of fast mode. Every fast-mode instruction applies to ultra too — both fast-mode rules in this skill apply unchanged.
```

`skills/writing-plans/SKILL.md`. Insert this section directly before `## No Placeholders`:
```markdown
## Ultra Mode Plans

`mode: ultra` includes all of fast mode. Every fast-mode instruction applies to ultra too. Ultra execution has a separate agent write a judgment task's tests in parallel with its implementer, working only from the plan. So when the session's `<SUPERPOWERS_CONFIG>` says `mode: ultra`, every judgment task must carry:
- a **Test:** path disjoint from its Create/Modify paths, and
- an Interfaces **Produces:** line that states each behaviour to test (inputs, outputs, errors), not just names and types.

A judgment task that cannot meet both runs as a single TDD implementer. Mark it `**Review tier:** judgment (fast fallback)`.
```
In Self-Review, after item 5, add:
```markdown
**6. Ultra contracts:** In `mode: ultra`, every judgment task has a disjoint Test path and a behavioural Produces line, or is marked `(fast fallback)`.
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `bash tests/agents/test-fast-mode-contract.sh && bash tests/hooks/test-config-wiring.sh`
Expected: both print `STATUS: PASSED`.

- [ ] **Step 5: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md skills/requesting-code-review/SKILL.md skills/brainstorming/SKILL.md skills/writing-plans/SKILL.md tests/agents/test-fast-mode-contract.sh tests/hooks/test-config-wiring.sh
git commit -m "feat(skills): wire ultra mode lanes, streaming, and converge loop" -- <same paths>
```

---

### Task 4: Release notes and version bump to 7.1.0

**Files:**
- Modify: `RELEASE-NOTES.md`, `package.json`, `.hermes-plugin/plugin.yaml`, `.claude-plugin/plugin.json` (`version` only), `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `.devin-plugin/plugin.json`, `.kimi-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json`

**Depends on:** 1

**Review tier:** judgment

**Interfaces:**
- Consumes: none
- Produces: version `7.1.0` in every manifest listed in `.version-bump.json`

- [ ] **Step 1: Write the failing check**

Run: `grep -c '7\.1\.0' package.json .hermes-plugin/plugin.yaml .claude-plugin/plugin.json .cursor-plugin/plugin.json .codex-plugin/plugin.json .devin-plugin/plugin.json .kimi-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json`
Expected: every count is 0.

- [ ] **Step 2: Bump the version**

In each of the 9 files, replace the one `7.0.0` version value with `7.1.0` (`version: 7.0.0` in the yaml; `"version": "7.0.0"` elsewhere). Use `sed -i 's/"version": "7\.0\.0"/"version": "7.1.0"/'` on the JSON files and `sed -i 's/^version: 7\.0\.0$/version: 7.1.0/'` on the yaml.

- [ ] **Step 3: Add release notes**

Insert directly after the `# Superpowers Release Notes` heading and its blank line:
```markdown
## v7.1.0 (2026-10-20)

### Ultra mode (experimental)

- **What.** `mode: ultra` (plugin option or `SUPERPOWERS_MODE=ultra`) is fast
  mode plus a parallel test-writer lane. For each judgment task, a new
  `caveman-test-writer-<effort>` agent writes the task's tests from the plan's
  Interfaces contract while the implementer writes the code, so neither waits
  for the other. As soon as both lanes of a task report, the controller runs
  its tests and, if they fail, runs a converge loop (implementer fixes code,
  or fixes a test by citing the contract line it contradicted; max 3 rounds,
  round 3 on `caveman-implementer-high`), then reviews that task, without
  waiting for the rest of the wave.
- **Trade-off.** Ultra drops TDD RED evidence for those tasks, and tests are
  written blind to the implementation. A wrong API assumption costs a
  converge round, so the plan's Interfaces block decides how fast ultra is.
  Transcription tasks and tasks without a disjoint Test path or contract run
  exactly as in fast mode. The wave suite, final review and verification
  gates are unchanged.
- **Config.** New keys `test_writer_model` (default `sonnet`) and
  `test_writer_effort` (default `low`), env overrides
  `SUPERPOWERS_TEST_WRITER_MODEL` / `SUPERPOWERS_TEST_WRITER_EFFORT`.
  `<SUPERPOWERS_CONFIG>` gains a `test-writer:` line, and the config gate
  covers the new agent. The implementer agents learned a "test-writer lane"
  clause.
- **Not yet done (recommended next).** Cross-wave pipelining, a wave cap
  above 4, batching tiny tasks, worktree-per-lane isolation, and a measured
  standard vs fast vs ultra acceptance run. Ultra stays experimental until
  that run exists.

### Internal

- Tests cover the new mode value, role keys, config line, gate pairs,
  15 generated agents, and the ultra superset rule in each mode-aware skill.

```

- [ ] **Step 4: Verify**

Run: `grep -c '7\.1\.0' package.json .hermes-plugin/plugin.yaml .claude-plugin/plugin.json .cursor-plugin/plugin.json .codex-plugin/plugin.json .devin-plugin/plugin.json .kimi-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json && ! grep -rn '7\.0\.0' --include=*.json --include=*.yaml . | grep -v node_modules && bash tests/hooks/test-plugin-config.sh`
Expected: every count is 1, no `7.0.0` hits remain, and `STATUS: PASSED`.

- [ ] **Step 5: Commit**

```bash
git add RELEASE-NOTES.md package.json .hermes-plugin/plugin.yaml .claude-plugin/plugin.json .cursor-plugin/plugin.json .codex-plugin/plugin.json .devin-plugin/plugin.json .kimi-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json
git commit -m "chore: release notes and version bump to 7.1.0" -- <same paths>
```
