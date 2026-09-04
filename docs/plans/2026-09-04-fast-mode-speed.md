# Fast Mode Speed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-on-steroids:subagent-driven-development (recommended) or superpowers-on-steroids:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut dispatches per task in fast mode: 1 for clean transcription tasks, 2 for judgment tasks, fix loop capped at 3 rounds, without touching the final review, wave test suite, TDD, or verification gates.

**Architecture:** Three units over skill text, one bundled agent, one hook. U1 restores the fix-loop breaker and scoped re-review in `subagent-driven-development` (all modes) and maps fix/re-review onto the existing caveman agents (fast). U2 adds a plan-time `Review tier` field in `writing-plans` and a transcription gate in `subagent-driven-development` (fast). U3 shortens brainstorming when priors exist (fast) and adds a `SUPERPOWERS_MODE` env override to the session-start hook. Fast-only behaviour is written as short conditional paragraphs next to standard text, never as a parallel section.

**Tech Stack:** Markdown skill files, bash hook, bash test scripts (`tests/agents/test-fast-mode-contract.sh`, `tests/hooks/test-session-start.sh`).

**Spec:** `docs/specs/2026-09-04-fast-mode-speed-design.md`

**Deviation from spec, recorded here:** the spec asks for a README fast-mode section. README.md has no fast-mode section today (v6.4.0 documented fast mode only in RELEASE-NOTES.md). This plan documents in RELEASE-NOTES.md only; adding a README section is a separate docs change.

## Global Constraints

- Zero third-party dependencies (repo CLAUDE.md).
- Hook output with no `SUPERPOWERS_MODE`, no `CLAUDE_PLUGIN_OPTION_*` set must stay byte-identical to today (`tests/hooks/test-session-start.sh` "mode=standard emits byte-identical output to no config").
- Caveman agents must keep token parity with their templates (`tests/agents/test-fast-mode-contract.sh`); no agent may grant the `Agent` tool; `model` pinned, `effort` valid.
- Fast-only text is gated on the literal phrase `mode: fast` inside a `<SUPERPOWERS_CONFIG>` block — both strings must remain in `skills/subagent-driven-development/SKILL.md`, `skills/requesting-code-review/SKILL.md`, `skills/brainstorming/SKILL.md` (wiring test).
- Fix loop cap is exactly 3 rounds. Rounds 1–2 resume the implementer; round 3 is a fresh implementer on the capable tier via the inline template in both modes.
- Trip adjudication: open Critical → BLOCKED; Important-only → ledger marker `breaker-tripped`; Minor dropped.
- Transcription criteria (verbatim, all five): complete code in the task steps; ≤2 non-test files created or edited; no new public interface; no schema, auth, payment, or concurrency touch; covering tests written out in the task.
- Five promotion triggers (verbatim): (1) status ≠ DONE; (2) report file lacks GREEN command + output; (3) commits touch a file outside the brief's Files list; (4) implementer reports a plumbing deviation from the brief's literal code; (5) the per-wave suite fails on a test touching the task's files.
- Commit types: U1 `fix:`; U2, U3 `feat:`; docs `docs:`; version `chore:`. Commit messages normal prose, not caveman.
- All `sed -n` reads in this plan use `rtk proxy sed` only if the `rtk` shim is present; plain `sed` otherwise. Do not depend on rtk.

## Execution Waves

- Wave 1: Tasks 1, 2, 3, 4 (no dependencies; disjoint files)
- Wave 2: Task 5 (depends on 1 and 3 — edits `subagent-driven-development/SKILL.md` and the contract test after Task 1; asserts the field Task 3 adds)
- Wave 3: Task 6 (docs + version; depends on all)

---

### Task 1: Restore the fix-loop breaker and scoped re-review (U1)

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md` (diagram lines 46–88; "Running a wave" step 6 at ~121–123; new "Fix Loop" subsection after line 138; Model Selection ~175–177; Fast Mode table and counterpart sentence ~195–214; Handling Reviewer ⚠️ ~244–245; Constructing Reviewer Prompts bullets ~284, ~298–303; File Handoffs ~333–334; Example Workflow ~396–402; Red Flags ~487–494)
- Modify: `skills/subagent-driven-development/re-review-prompt.md` (placeholder list, lines 101–112; description line 9)
- Modify: `agents/caveman-reviewer.md` (new section before `## Output`)
- Test: `tests/agents/test-fast-mode-contract.sh`

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: nothing.
- Produces: SDD `SKILL.md` subsection heading `### Fix Loop`; ledger marker string `breaker-tripped`; Fast Mode table rows beginning `| Fix rounds 1–2 |` and `| Re-review |`; contract-test helpers `assert_in_file LABEL TOKEN FILE` and `assert_not_in_file_ci LABEL TOKEN FILE` (Task 5 reuses both).

- [ ] **Step 1: Add the failing contract-test assertions**

Insert after the `for token in "Ready to merge?" "With fixes"; do ... done` loop in `tests/agents/test-fast-mode-contract.sh` (before the `# --- Agent file validity` comment):

```bash
# --- Re-review pair: per-finding verdict tokens the fix loop branches on ---
rereview_tmpl="$SDD_DIR/re-review-prompt.md"
for token in "ADDRESSED" "NOT ADDRESSED" "Fix round:"; do
    assert_in_both "re-review verdict" "$token" "$rev_agent" "$rereview_tmpl"
done

# --- Fix loop: the SDD skill carries the breaker and one fix story ---
assert_in_file() {
    local label="$1" token="$2" file="$3"
    if grep -qF -- "$token" "$file"; then
        pass "$label: '$token' present"
    else
        fail "$label: '$token' missing from $(basename "$file")"
    fi
}

assert_not_in_file_ci() {
    local label="$1" token="$2" file="$3"
    if grep -qiF -- "$token" "$file"; then
        fail "$label: '$token' still present in $(basename "$file")"
    else
        pass "$label: '$token' absent"
    fi
}

sdd_skill="$SDD_DIR/SKILL.md"
assert_in_file "fix loop" "### Fix Loop" "$sdd_skill"
assert_in_file "fix loop" "breaker-tripped" "$sdd_skill"
assert_in_file "fix loop" "Round 3" "$sdd_skill"
assert_in_file "fix loop" "re-review-prompt.md" "$sdd_skill"
assert_not_in_file_ci "fix loop" "dispatch fix subagents" "$sdd_skill"

if grep -qE '^\| Fix rounds 1–2 \|.*caveman-implementer' "$sdd_skill"; then
    pass "fast mode table: fix rounds map to caveman-implementer"
else
    fail "fast mode table: fix rounds row missing or not mapped to caveman-implementer"
fi
if grep -qE '^\| Re-review \|.*caveman-reviewer' "$sdd_skill"; then
    pass "fast mode table: re-review maps to caveman-reviewer"
else
    fail "fast mode table: re-review row missing or not mapped to caveman-reviewer"
fi
```

- [ ] **Step 2: Run the contract test to verify it fails**

Run: `bash tests/agents/test-fast-mode-contract.sh`
Expected: `STATUS: FAILED` with failures for `re-review verdict: 'ADDRESSED'`, `fix loop: '### Fix Loop' missing`, `breaker-tripped missing`, `'dispatch fix subagents' still present`, and both table-row failures. Existing assertions stay green.

- [ ] **Step 3: Rewrite the process diagram in SKILL.md**

In `skills/subagent-driven-development/SKILL.md`, inside the `digraph process` block, replace this node line:

```
        "Dispatch fix subagents in parallel for Critical/Important findings (file-disjoint by construction)" [shape=box];
```

with these three lines:

```
        "Fix round R (max 3): resume implementer with findings; R3 = fresh capable-tier implementer; scoped re-review (./re-review-prompt.md)" [shape=box];
        "Re-review clean?" [shape=diamond];
        "Round 3 tripped: open Critical → task BLOCKED; Important-only → ledger breaker-tripped, continue" [shape=box];
```

Replace these two edge lines:

```
    "Every reviewer reports spec ✅ and quality approved?" -> "Dispatch fix subagents in parallel for Critical/Important findings (file-disjoint by construction)" [label="no"];
    "Dispatch fix subagents in parallel for Critical/Important findings (file-disjoint by construction)" -> "Write path-scoped diff per task, dispatch ALL task reviewers in ONE message (./task-reviewer-prompt.md)" [label="re-review failed tasks only"];
```

with these five:

```
    "Every reviewer reports spec ✅ and quality approved?" -> "Fix round R (max 3): resume implementer with findings; R3 = fresh capable-tier implementer; scoped re-review (./re-review-prompt.md)" [label="no"];
    "Fix round R (max 3): resume implementer with findings; R3 = fresh capable-tier implementer; scoped re-review (./re-review-prompt.md)" -> "Re-review clean?";
    "Re-review clean?" -> "Run full test suite once for the wave" [label="yes"];
    "Re-review clean?" -> "Fix round R (max 3): resume implementer with findings; R3 = fresh capable-tier implementer; scoped re-review (./re-review-prompt.md)" [label="no, R < 3"];
    "Re-review clean?" -> "Round 3 tripped: open Critical → task BLOCKED; Important-only → ledger breaker-tripped, continue" [label="no, R = 3"];
    "Round 3 tripped: open Critical → task BLOCKED; Important-only → ledger breaker-tripped, continue" -> "Run full test suite once for the wave";
```

- [ ] **Step 4: Replace "Running a wave" step 6 and add the Fix Loop subsection**

Replace step 6 (currently "6. Dispatch fix subagents for Critical/Important findings in parallel across tasks (their file sets are disjoint by construction), then re-review only the tasks that had findings — again in parallel.") with:

```
6. For every task with Critical/Important findings, run the **Fix Loop**
   below. Rounds run in parallel across tasks (their file sets are
   disjoint by construction); within one task, fix → re-review is serial.
```

Then insert this subsection immediately after the "What never runs in parallel" bullet list (after the line `- A single task's fix → re-review loop (the re-review needs the fix)`) and before `## Pre-Flight Plan Review`:

```markdown
### Fix Loop

A task's review-fix cycle is bounded at three rounds. Count rounds per task.

**Rounds 1–2: resume.** Send the reviewer's Critical/Important findings to
the task's original implementer via SendMessage — it still holds the task
context and takes fewer turns than a fresh fixer re-deriving the diff. In
fast mode that is the same `superpowers-on-steroids:caveman-implementer`
agent. If the implementer is no longer addressable, dispatch a fresh fix
subagent on the same tier carrying the findings **and** the original brief
path — never skip silently, and note the fallback in the ledger.

**Round 3: escalate.** Dispatch a fresh implementer on the capable tier via
the inline [implementer-prompt.md](implementer-prompt.md) in both modes —
fast agents are model/effort-pinned and cannot be raised at dispatch. The
capable tier resolves from `capable=` in the `<SUPERPOWERS_CONFIG>` tier
models line when set, else the most capable model this harness offers.

**After every round: scoped re-review.** Generate a fix package
(`scripts/review-package FIX_BASE HEAD -- <task's files>`, where FIX_BASE is
the head the previous review saw) and dispatch
[re-review-prompt.md](re-review-prompt.md) on a cheap-to-mid tier — in fast
mode, `superpowers-on-steroids:caveman-reviewer` in re-review mode. The
re-review verdicts each finding `ADDRESSED | NOT ADDRESSED` and flags new
breakage in the fix diff only; it is not a fresh review. Before dispatching
it, confirm the fix report names the covering tests, the command run, and
its output.

**Round 3 trips.** If findings remain open after the round-3 re-review:
- Any open **Critical** → mark the task BLOCKED. Failure isolation applies:
  wave-mates finish, dependents wait, resolve per Handling Implementer
  Status (BLOCKED).
- Only **Important** open → append the findings to the ledger under a
  `breaker-tripped` marker and continue the wave. The final whole-branch
  review dispatch must name every `breaker-tripped` entry and triage each.
- Open **Minor** are dropped at trip; the final reviewer sees the diff.

Never accept a Critical finding by exhaustion, and never run a fourth round.
```

- [ ] **Step 5: Update Model Selection, Fast Mode table, and counterpart sentence**

In `## Model Selection`, after the sentence ending `Single-file mechanical fixes also take the cheapest tier.` append to the same paragraph:

```
Scoped re-reviews of small fix diffs take a cheap-to-mid tier. The round-3
fix escalation in the Fix Loop takes the capable tier.
```

In `## Fast Mode`, add two rows to the table after the `| Final whole-branch review |` row:

```
| Fix rounds 1–2 | resume the implementer (contract in [implementer-prompt.md](implementer-prompt.md)) | resume `superpowers-on-steroids:caveman-implementer` |
| Re-review | [re-review-prompt.md](re-review-prompt.md) | `superpowers-on-steroids:caveman-reviewer` (re-review mode) |
```

Replace the paragraph beginning `Roles with no agent counterpart stay on the template path in both modes:` with:

```
Roles with no agent counterpart stay on the template path in both modes: the
round-3 fix implementer (capable tier via the inline template), the
spec-document reviewer, the plan-document reviewer, and the Brainstormer.
```

- [ ] **Step 6: Replace every remaining "fix subagents" phrasing**

Apply these exact replacements in `skills/subagent-driven-development/SKILL.md`:

1. In `## Handling Reviewer ⚠️ Items`, change `send it back to the implementer and re-review.` to `send it back through the Fix Loop.`
2. In `## Constructing Reviewer Prompts`, change the bullet beginning `- Dispatch fix subagents for Critical and Important findings. Record Minor` to begin `- Run the Fix Loop for Critical and Important findings. Record Minor` (rest of bullet unchanged).
3. Same section, change the bullet beginning `- Every fix dispatch carries the implementer contract: the fix subagent` to:

```
- Every fix round carries the implementer contract: the resumed (or
  fresh) implementer re-runs the tests covering its change and appends a
  fix report. Name the covering test files in the message — a one-line fix
  does not need the whole suite. Before dispatching the re-review, confirm
  the fix report contains the covering tests, the command run, and the
  output; dispatch the re-review once all three are present.
```

4. In `## File Handoffs`, change `- Fix dispatches append their fix report (with test results) to the same report file and return a short summary; re-reviews read the updated file.` to `- Fix rounds append their fix report (with test results) to the same report file and return a short summary; re-reviews read the updated file.`
5. In `## Red Flags`, replace the block:

```
**If reviewer finds issues:**
- Implementer (same subagent) fixes them
- Reviewer reviews again
- Repeat until approved
- Don't skip the re-review
```

with:

```
**If reviewer finds issues:**
- Fix round 1–2: resume the same implementer with the findings
- Scoped re-review after every round (`re-review-prompt.md`); never skip it
- Round 3: fresh implementer on the capable tier
- Round 3 trips: open Critical → BLOCKED; Important-only → ledger
  `breaker-tripped` and continue; never a fourth round
```

6. Same section, replace:

```
**If subagent fails task:**
- Dispatch fix subagent with specific instructions
- Don't try to fix manually (context pollution)
```

with:

```
**If subagent fails task:**
- Follow Handling Implementer Status (BLOCKED) — more context, capable
  tier, or a task split
- Don't try to fix manually (context pollution)
```

7. In `## Example Workflow`, replace:

```
[Dispatch fix subagent for Task 2 findings]
Fixer: Removed --json flag, added progress reporting, extracted PROGRESS_INTERVAL constant

[Re-run review-package for Task 2's files; re-dispatch Reviewer 2 only]
Reviewer 2: Spec ✅. Task quality: Approved.
```

with:

```
[Fix round 1: resume Implementer 2 with Reviewer 2's findings]
Implementer 2: Removed --json flag, added progress reporting, extracted
  PROGRESS_INTERVAL constant. Fix report appended, 9/9 tests passing.

[review-package FIX_BASE HEAD -- <Task 2 files>; dispatch scoped re-review]
Re-reviewer 2: Missing progress reporting — ADDRESSED. Extra --json — ADDRESSED.
  Magic number — ADDRESSED. New breakage: none. Fix round: all findings addressed.
```

Then verify no plural phrasing survives: `grep -in "fix subagents" skills/subagent-driven-development/SKILL.md` must print nothing.

- [ ] **Step 7: Align re-review-prompt.md placeholders**

In `skills/subagent-driven-development/re-review-prompt.md`:

1. Change the description line `description: "Re-review Task N fix round R"` to `description: "Re-review Task N fix round R of 3"`.
2. In the `**Placeholders:**` list, replace the `[DIFF_FILE]` line with:

```
- `[DIFF_FILE]` — the path `scripts/review-package FIX_BASE HEAD -- <task's files>`
  printed (FIX_BASE = the head the previous review saw; drop the path
  filter outside a parallel wave)
```

3. Replace the `[BRIEF_FILE]` line with:

```
- `[BRIEF_FILE]` — the task brief file from `scripts/task-brief` (same file the implementer worked from)
```

Everything else in the file stays as is.

- [ ] **Step 8: Add re-review mode to caveman-reviewer.md**

In `agents/caveman-reviewer.md`, insert this section immediately before `## Output`:

```markdown
## Re-review mode

When the dispatch names a prior findings list, you are re-reviewing one fix round, not reviewing afresh. Scope = that findings list plus the fix diff. Do not re-review code the fix did not touch; anything noticed outside the fix diff goes under Out-of-Scope Observations and does not block. "Attempted" is not addressed — the specific defect must no longer exist.

Re-review output replaces the two-verdict format below:

### Finding Verdicts
- **[finding one-liner]** — ADDRESSED | NOT ADDRESSED, with `file:line` evidence.

### New Breakage in the Fix Diff
Severity (Critical/Important/Minor) and `file:line`. "None" if clean.

### Out-of-Scope Observations
Non-blocking; controller ledgers for final review. "None" if none.

### Verdict
**Fix round:** [All findings addressed, no new Critical/Important breakage | Findings remain open] — list open ones.
```

- [ ] **Step 9: Run the contract test to verify it passes**

Run: `bash tests/agents/test-fast-mode-contract.sh`
Expected: `STATUS: PASSED`, including `re-review verdict: 'ADDRESSED' in both`, `fix loop: '### Fix Loop' present`, `fix loop: 'dispatch fix subagents' absent`, and both `fast mode table:` passes.

Also run: `bash tests/hooks/test-session-start.sh`
Expected: `STATUS: PASSED` (wiring strings untouched).

- [ ] **Step 10: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md skills/subagent-driven-development/re-review-prompt.md agents/caveman-reviewer.md tests/agents/test-fast-mode-contract.sh
git commit -m "fix(sdd): restore three-round fix-loop breaker and scoped re-review

Fork commit 876960a removed the bounded fix loop and left the scoped
re-review template orphaned. Rounds 1-2 resume the implementer, round 3
escalates to the capable tier, and a trip adjudicates instead of looping.
Fast mode maps fix rounds and re-review onto the existing caveman agents."
```

---

### Task 2: `SUPERPOWERS_MODE` env override in the session-start hook (U3)

**Files:**
- Modify: `hooks/session-start:40` (the `sp_mode=` line)
- Modify: `.claude-plugin/plugin.json` (`userConfig.mode.description`)
- Test: `tests/hooks/test-session-start.sh`

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: nothing.
- Produces: environment variable `SUPERPOWERS_MODE` (values pass the existing `config_value` whitelist; only `fast` emits a block; env wins over `CLAUDE_PLUGIN_OPTION_MODE`).

- [ ] **Step 1: Add failing hook tests**

In `tests/hooks/test-session-start.sh`, insert after the `cursor_config_home` assertion block and before `if [[ "$FAILURES" -gt 0 ]]; then`:

```bash
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
```

- [ ] **Step 2: Run the hook test to verify the new assertions fail**

Run: `bash tests/hooks/test-session-start.sh`
Expected: `STATUS: FAILED` with `SUPERPOWERS_MODE=fast alone emits the config block` failing (no block emitted) and `SUPERPOWERS_MODE=standard force-disables a fast plugin option` failing (block still emitted). The whitelist and empty-value cases pass already; the pre-existing assertions stay green.

- [ ] **Step 3: Resolve mode from env first in the hook**

In `hooks/session-start`, replace:

```bash
sp_mode="$(config_value "${CLAUDE_PLUGIN_OPTION_MODE:-}")"
```

with:

```bash
# SUPERPOWERS_MODE (env, e.g. from a project .envrc) wins over the plugin
# option. Only "fast" emits, so SUPERPOWERS_MODE=standard force-disables.
sp_mode="$(config_value "${SUPERPOWERS_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-}}")"
```

- [ ] **Step 4: Name the override in plugin.json**

In `.claude-plugin/plugin.json`, change the `mode` description to:

```json
"description": "standard = inline prompt templates (default). fast = dispatch the bundled caveman-* agents: terser reports, lower reasoning effort, smaller dispatch payloads, plan-tiered task review, 3-round fix loop. The SUPERPOWERS_MODE environment variable overrides this per session (env wins; SUPERPOWERS_MODE=standard force-disables fast).",
```

Validate JSON: `node -e 'JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8"))' && echo ok`
Expected: `ok`

- [ ] **Step 5: Run the hook test and the contract test to verify they pass**

Run: `bash tests/hooks/test-session-start.sh`
Expected: `STATUS: PASSED`; the byte-identical assertion still passes. (Do not run the contract test here — Task 1 edits it in the same wave.)

Also run the shell lint the repo ships: `bash scripts/lint-shell.sh`
Expected: exit 0 (or the same output as before the change; the hook line is a plain parameter expansion).

- [ ] **Step 6: Commit**

```bash
git add hooks/session-start .claude-plugin/plugin.json tests/hooks/test-session-start.sh
git commit -m "feat(config): add SUPERPOWERS_MODE env override for fast mode

Plugin userConfig is user-scope only, so a project could not opt in on its
own. The env var wins over the plugin option and runs through the same
whitelist; only fast emits a block."
```

---

### Task 3: `Review tier` field in the plan task template (U2)

**Files:**
- Modify: `skills/writing-plans/SKILL.md:105-113` (task template, after the **Depends on:** block) and `:158-170` (Self-Review)

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: nothing.
- Produces: plan task field literal `**Review tier:** transcription | judgment` (Task 5's gate reads it; `scripts/task-brief` already copies the whole task text so no script change).

- [ ] **Step 1: Verify the field is absent (baseline)**

Run: `grep -c "Review tier" skills/writing-plans/SKILL.md`
Expected: `0`

- [ ] **Step 2: Add the field to the task template**

In `skills/writing-plans/SKILL.md`, inside the ```` ````markdown ```` task template, insert after the `**Depends on:**` block (the bracketed text ending `runs in parallel with its wave-mates.]`) and before `**Interfaces:**`:

```markdown
**Review tier:** [transcription | judgment. Write `transcription` only when
ALL five hold: the steps below carry the complete code to write; ≤2 non-test
files are created or edited; no new public interface; no schema, auth,
payment, or concurrency touch; the covering tests are written out in this
task. Anything else is `judgment`. Fast-mode execution skips the per-task
reviewer for a transcription task whose implementer report shows green
tests; standard mode ignores this field.]
```

- [ ] **Step 3: Add Self-Review check 5**

In `## Self-Review`, after the `**4. Wave safety:**` paragraph and before `If you find issues, fix them inline.`, insert:

```markdown
**5. Tier claims:** For every task marked `Review tier: transcription`, confirm all five criteria hold — complete code in the steps, ≤2 non-test files created or edited, no new public interface, no schema/auth/payment/concurrency touch, covering tests written out. Demote any task that fails one criterion to `judgment`. A missing field is read as `judgment` at execution time, so fill it in for every task.
```

- [ ] **Step 4: Verify**

Run: `grep -n "Review tier" skills/writing-plans/SKILL.md`
Expected: two matches — one inside the task template, one in Self-Review check 5.

Run: `grep -c "^\*\*5\. Tier claims:\*\*" skills/writing-plans/SKILL.md`
Expected: `1`

- [ ] **Step 5: Commit**

```bash
git add skills/writing-plans/SKILL.md
git commit -m "feat(writing-plans): add plan-time Review tier field per task

Marks each task transcription or judgment against five explicit criteria
so execution can skip the per-task LLM review where the plan already
carries the code and tests. Self-review check 5 audits the claims."
```

---

### Task 4: Shorten brainstorming when priors exist (U3)

**Files:**
- Modify: `skills/brainstorming/SKILL.md:79-82` (Dispatching bullets)

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Verify baseline**

Run: `grep -c "MAX_ROUNDS\` to 2" skills/brainstorming/SKILL.md`
Expected: `0`

- [ ] **Step 2: Add the fast-mode shortening bullet**

In `skills/brainstorming/SKILL.md`, under `**Dispatching:**`, insert a new bullet directly after the bullet that begins `- Fill in the template at \`skills/brainstorming/brainstormer-prompt.md\`` and before the bullet `- Spawn one Brainstormer with the Agent tool.`:

```markdown
- In fast mode (`<SUPERPOWERS_CONFIG>` with `mode: fast`), when spec-shaped input already exists — a design doc path was supplied, or the request is bounded to ≤2 non-test files with clear acceptance criteria — set `MAX_ROUNDS` to 2 and say so in the dispatch. Shorten only: the dialogue and the HARD-GATE still run; the Brainstormer already jumps to `DESIGN — CONSENSUS` once no material question remains.
```

- [ ] **Step 3: Verify wiring strings survive**

Run: `grep -c "mode: fast" skills/brainstorming/SKILL.md && grep -c "<SUPERPOWERS_CONFIG>" skills/brainstorming/SKILL.md`
Expected: `2` and `2` (the existing checklist item plus the new bullet). Both strings are what the fast-mode wiring test greps for; do not run that test here — Task 1 edits it in the same wave.

- [ ] **Step 4: Commit**

```bash
git add skills/brainstorming/SKILL.md
git commit -m "feat(brainstorming): cap dialogue at two rounds in fast mode when priors exist

A bounded request with a design doc or clear acceptance does not need an
eight-round interrogation. The gate and the dialogue stay; only the cap moves."
```

---

### Task 5: Transcription review gate and mode announcement in SDD (U2)

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md` (`## Pre-Flight Plan Review`; `## Fast Mode` section end; `## Handling Implementer Status` DONE paragraph; `## Red Flags` "Skip task review" bullet)
- Test: `tests/agents/test-fast-mode-contract.sh`

**Depends on:** 1, 3

**Review tier:** judgment

**Interfaces:**
- Consumes: `### Fix Loop`, `breaker-tripped`, `assert_in_file`, `assert_not_in_file_ci` from Task 1; `**Review tier:**` field from Task 3.
- Produces: SDD paragraph heading `**Review tier gate.**`; pre-flight announcement line format `Mode: <mode> — <review policy>; fix loop capped at 3 rounds`.

- [ ] **Step 1: Add failing contract-test assertions**

In `tests/agents/test-fast-mode-contract.sh`, insert after the two `fast mode table:` if/else blocks Task 1 added (before `# --- Agent file validity`):

```bash
# --- Review tiering: plan writes the field, SDD reads it in fast mode ---
plans_skill="$REPO_ROOT/skills/writing-plans/SKILL.md"
assert_in_file "review tier" "**Review tier:**" "$plans_skill"
assert_in_file "review tier" "Review tier gate" "$sdd_skill"
assert_in_file "review tier" "transcription" "$sdd_skill"
assert_in_file "review tier" "fix loop capped at 3 rounds" "$sdd_skill"
```

- [ ] **Step 2: Run the contract test to verify it fails**

Run: `bash tests/agents/test-fast-mode-contract.sh`
Expected: `STATUS: FAILED` with `review tier: 'Review tier gate' missing` and `review tier: 'fix loop capped at 3 rounds' missing`. (`**Review tier:**` in writing-plans passes if Task 3 landed; `transcription` already appears in Model Selection and passes.)

- [ ] **Step 3: Add the Review tier gate paragraph to Fast Mode**

In `skills/subagent-driven-development/SKILL.md`, in `## Fast Mode`, insert after the paragraph beginning `Model selection is unchanged in fast mode` (end of the section, before `## Handling Implementer Status`):

```markdown
**Review tier gate.** Each plan task carries `**Review tier:** transcription |
judgment` (writing-plans). In fast mode, a `transcription` task skips
`review-package` and the task reviewer when the implementer's report **file**
(not the short reply) shows status DONE, the GREEN test command, and its
passing output — read the file to check. Ledger it as
`Task N: complete (wave W, commits <base7>..<head7>, transcription gate)`.
Promote the task to judgment — generate the package and dispatch the
reviewer as normal — on any of:

1. status ≠ DONE;
2. the report file lacks the GREEN command or its output;
3. the task's commits touch a file outside the brief's Files list
   (`git diff --stat WAVE_BASE HEAD -- <task's files>` vs `git diff --stat WAVE_BASE HEAD`);
4. the implementer reports a plumbing deviation from the brief's literal code;
5. the per-wave test suite fails on a test touching the task's files —
   promote retroactively and review before the wave closes.

A missing or malformed field is `judgment`. Never downgrade a tier the plan
set. Standard mode ignores the field: every task is reviewed.
```

- [ ] **Step 4: Point the DONE handler at the gate**

In `## Handling Implementer Status`, change the start of the `**DONE:**` paragraph from `**DONE:** Generate the review package` to `**DONE:** In fast mode, apply the Review tier gate first (see Fast Mode) — a transcription task with gate evidence is complete here. Otherwise generate the review package` (rest of the paragraph unchanged).

- [ ] **Step 5: Add the pre-flight mode announcement**

In `## Pre-Flight Plan Review`, append a new paragraph after `The review loop remains the net for conflicts that only emerge from implementation.`:

```markdown
If the session context carries a `<SUPERPOWERS_CONFIG>` block, state the
resolved policy once, before wave 1, in one line: `Mode: fast — transcription
tasks skip per-task review on green report evidence, judgment tasks reviewed;
fix loop capped at 3 rounds`, or `Mode: standard — every task reviewed; fix
loop capped at 3 rounds` when the block carries only tier models. With no
block, say nothing.
```

- [ ] **Step 6: Update the Red Flags bullet**

In `## Red Flags`, replace:

```
- Skip task review, or accept a report missing either verdict (spec compliance AND task quality are both required)
```

with:

```
- Skip task review for a judgment task, or for a transcription task whose
  report file lacks the gate evidence; accept a report missing either
  verdict (spec compliance AND task quality are both required)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/agents/test-fast-mode-contract.sh && bash tests/hooks/test-session-start.sh`
Expected: both `STATUS: PASSED`.

- [ ] **Step 8: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md tests/agents/test-fast-mode-contract.sh
git commit -m "feat(sdd): skip per-task review for transcription tasks in fast mode

Reads the plan's Review tier and, when the implementer's report file
carries green test evidence, closes the task on one dispatch. Five
triggers promote a task back to a full review. Pre-flight announces the
resolved mode so fast-mode transcripts describe their own policy."
```

---

### Task 6: Release notes, spec status, and version bump

**Files:**
- Modify: `RELEASE-NOTES.md` (new section above `## v6.4.0 (2026-08-31)`)
- Modify: `docs/specs/2026-09-04-fast-mode-speed-design.md:3-5` (Status/Ships-as lines)
- Modify (via script): `package.json`, `.hermes-plugin/plugin.yaml`, `.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `.devin-plugin/plugin.json`, `.kimi-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json`
- Test: `tests/version-bump/test-bump-version.sh`

**Depends on:** 1, 2, 3, 4, 5

**Review tier:** judgment

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Add the release-notes section**

In `RELEASE-NOTES.md`, insert directly after the `# Superpowers Release Notes` heading (before `## v6.4.0 (2026-08-31)`):

```markdown
## v6.5.0 (2026-09-04)

### Fast Mode — fewer dispatches per task

- **Plan-time review tiers.** writing-plans marks every task
  `Review tier: transcription | judgment` against five criteria (complete code
  in the steps, ≤2 non-test files, no new public interface, no
  schema/auth/payment/concurrency touch, covering tests written out). In fast
  mode a transcription task whose report file shows green tests closes on one
  dispatch — no review package, no per-task reviewer. Five triggers promote a
  task back to a full review, including a plumbing deviation and a wave-suite
  failure on its files. Standard mode ignores the field.
- **Brainstorming shortens to two rounds** in fast mode when a design doc path
  or a bounded, clearly-accepted request already exists. Never skipped.
- **`SUPERPOWERS_MODE` env override.** Plugin config is user-scope only; a
  project can now opt in per session (env wins; `standard` force-disables).
  Same whitelist, same block.
- **Pre-flight announces the resolved mode** once, only when a config block is
  present, so a fast-mode transcript describes its own review policy.

### Subagent-Driven Development — fix loop bounded again

- **Three-round breaker restored.** Fork commit `876960a` had removed the
  bounded fix loop, leaving "repeat until approved". Rounds 1–2 resume the
  task's implementer; round 3 dispatches a fresh implementer on the capable
  tier; a trip adjudicates — open Critical → BLOCKED, Important-only →
  ledgered under `breaker-tripped` for the final review, Minor dropped.
- **Scoped re-review re-wired.** `re-review-prompt.md` (orphaned since the same
  commit) is the re-review in standard mode; `caveman-reviewer` gains a
  re-review mode with `ADDRESSED | NOT ADDRESSED` verdicts in fast mode.
  Fix rounds and re-reviews now have fast-mode counterparts, so a wave with a
  finding no longer drops onto the slow template path.

### Internal

- `tests/agents/test-fast-mode-contract.sh` asserts the re-review token pair,
  the Fast Mode table rows, the breaker text, the tier field, and that no
  "dispatch fix subagents" wording survives.
- `tests/hooks/test-session-start.sh` covers the env override: emits alone,
  overrides a fast option, drops whitelist failures, empty stays byte-identical.
- Acceptance run protocol (go-fractals, ≥2 runs per arm) is recorded in
  `docs/specs/2026-09-04-fast-mode-speed-design.md`; not yet executed.
```

- [ ] **Step 2: Update the spec status lines**

In `docs/specs/2026-09-04-fast-mode-speed-design.md`, change:

```
**Status:** Approved (agent-team brainstorm, Proxy + Brainstormer consensus)
**Ships as:** MINOR (contains `feat:` units) on top of v6.4.0
```

to:

```
**Status:** Implemented — `docs/plans/2026-09-04-fast-mode-speed.md`
**Ships as:** v6.5.0 (MINOR)
```

- [ ] **Step 3: Bump the version**

Run: `bash scripts/bump-version.sh 6.5.0 && bash scripts/bump-version.sh --audit`
Expected: every declared file reports `6.5.0`; audit finds no stray `6.4.0` outside the excluded files.

Run: `bash tests/version-bump/test-bump-version.sh`
Expected: `STATUS: PASSED` (or the script's own all-pass line).

- [ ] **Step 4: Run every affected test suite once**

Run:

```bash
bash tests/agents/test-fast-mode-contract.sh && \
bash tests/hooks/test-session-start.sh && \
bash tests/codex-plugin-sync/test-sync-to-codex-plugin.sh && \
bash scripts/lint-shell.sh
```

Expected: each prints its pass line; no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add RELEASE-NOTES.md docs/specs/2026-09-04-fast-mode-speed-design.md package.json .hermes-plugin/plugin.yaml .claude-plugin/plugin.json .cursor-plugin/plugin.json .codex-plugin/plugin.json .devin-plugin/plugin.json .kimi-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json
git commit -m "chore: release notes and version bump to 6.5.0"
```
