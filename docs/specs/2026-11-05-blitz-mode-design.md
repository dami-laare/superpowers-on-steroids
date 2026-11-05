# Blitz mode — design

**Date:** 2026-11-05
**Status:** approved (agent-team brainstorm; nothing escalated)
**Release:** `feat` — MINOR bump, 7.1.1 → 7.2.0
**Source proposal:** `aieng/proposals/superpowers-blitz-mode.md`

## Problem

Ultra mode still serializes work by dependency waves. Each task also pays for its own test run and its own review gate. A 15-task plan with 7 waves runs as 7 sequential rounds.

Sometimes the owner explicitly chooses speed ("as fast as possible, I'll fix bugs after"). Then that per-task ceremony is cost with no buyer.

A plan's Interfaces blocks already state every seam. An implementer can write against that contract without the upstream code existing. So dependency order does not stop parallel *writing*. What stops it is two agents editing the same file. Blitz partitions the work on that instead.

## Trade-off (stated plainly to users)

Blitz gives up four things:

- **TDD red-before-green.** Tests are written, but they first run at the end.
- **Per-task review gates.** Only the final review remains.
- **Early detection of a bad contract.** A wrong Interfaces block surfaces at integration, and every lane built on it pays for it.
- **Bisectable history.** The controller makes the per-task commits after everything is green. An intermediate commit may not build on its own.

In return:

- every lane starts at once;
- nothing waits between waves;
- there are no `index.lock` races;
- there is no noise from partially compiled code.

The bottleneck is the correctness of the plan's Interfaces blocks. Blitz is **experimental** until a measured run compares it with ultra.

Do not use blitz for the following. This guidance is documentation only; nothing detects these cases.

- schema migrations with data backfills;
- security- or auth-critical changes that need a gate per change;
- plans with vague tasks.

## Design

### Architecture

The planning and review skills are brainstorming, writing-plans and requesting-code-review. In each of them, `mode: blitz` is a strict superset of ultra (and therefore of fast). Each of those skills gets this rule:

> `mode: blitz` includes all of ultra mode. Every ultra-mode instruction applies to blitz too, plus the blitz additions in this section.

subagent-driven-development (SDD) is different. There, blitz **replaces** the wave loop instead of extending it. Its section states explicitly what still applies and what is dropped.

```
plugin.json userConfig / SUPERPOWERS_MODE=blitz
  → hooks/lib-config (whitelist standard|fast|ultra|blitz; no new role or key)
  → hooks/session-start (<SUPERPOWERS_CONFIG> mode: blitz; role lines unchanged)
  → writing-plans: ultra rules + blitz requirements (Interfaces on every task, (shared) markers, typecheck:/unit: lines)
  → SDD pre-flight: scripts/plan-lanes PLAN → lanes.md + lane-<X>-brief.md, or exit 3–5 → whole-plan fallback to ultra
  → dispatch ALL lanes in one message (caveman-implementer-<effort> on judgment=, "Blitz lane: …" line)
  → integration pass (controller is the only test runner): stray check → typecheck → capped unit run → fix loop ≤3 → final capped run
  → per-task commits (commit map) → mandatory final whole-branch review → verification-before-completion → finishing-a-development-branch
```

`hooks/agent-config-gate` is mode-agnostic and stays unchanged. It already allows these two dispatches:

- `caveman-implementer-<effort>` on `judgment=`;
- `caveman-implementer-high` on `final-reviewer: model=`.

### plan-lanes (new deterministic script)

| Property | Value |
|---|---|
| Path | `skills/subagent-driven-development/scripts/plan-lanes` |
| Usage | `plan-lanes PLAN_FILE [MAX_LANES]` |
| `MAX_LANES` | Defaults to 6. Must be an integer from 1 to 26. The argument exists so tests can override it. |
| Shell | bash 3.2 and awk only. No jq or yq. |
| Task parse | The same fence-aware `### Task N` heading parse as `task-brief` |
| Output location | The plan's sdd-workspace directory |

**Input parsing, per task:**

- **Files.** Read the `Create:`, `Modify:` and `Test:` lines. From each line:
  - Take the backticked path.
  - Strip a trailing `:<digits>` or `:<digits>-<digits>` line range.
  - Normalise the path: drop a leading `./`, collapse `//`, and drop a trailing `/`.
  - Detect the literal ` (shared)` suffix after the closing backtick. A path counts as shared if any task marks it.
- **Depends on.** Take the text after `**Depends on:**` and cut it at the first `(`. Split what remains on commas, spaces, semicolons and the words `and`/`Task`/`Tasks`. Strip a trailing `.` or `:` from each token, and treat an en-dash (`–`) the same as a hyphen. A token counts only if it is a pure integer (`^[0-9]+$`) or a range `^[0-9]+-[0-9]+$` (expanded inclusively); ignore every other token, including `none`. Edges apply only to numbers that are tasks in the plan.
- **Interfaces.** Require a `**Interfaces:**` block that contains both a `Consumes:` line and a `Produces:` line. The value `none` is allowed on either line.
- **Global Constraints.** Inside `## Global Constraints`, read two lines. A leading `- ` is tolerated on both.
  - `typecheck:` takes a backticked command or the word `none`.
  - `unit:` takes a backticked command.

**Exits.** Each reject prints the offending items on stderr and writes no output files.

| Exit | Cause | Controller action |
|---|---|---|
| 0 | lanes computed | run blitz |
| 2 | usage error, a missing plan file, or a task's text could not be extracted | **hard stop**: report it; do not fall back |
| 3 | the plan has no tasks, or a task lacks the Interfaces block, or its Consumes or Produces line | whole-plan fallback to ultra |
| 4 | the `unit:` line or the `typecheck:` line is missing or malformed (`unit:` needs a backticked command; `typecheck:` a backticked command or `none`) | whole-plan fallback to ultra |
| 5 | a Depends-on cycle among one lane's tasks | whole-plan fallback to ultra |

**Algorithm.**

1. **Union-find over tasks.** Two tasks are joined when they share any path that is not shared. A task's files never split across lanes. Shared paths are left out of the union step completely.
2. **Order the components.** Sort them by task count, descending. Break ties by lowest task number, ascending.
3. **Pack the components into lanes.**
   1. The first `MAX_LANES` components open lanes A, B, C and onward, in that order.
   2. Every remaining component goes to a lane that shares a prefix with it. A prefix is the first two path segments of any of its files.
   3. If several lanes match, pick the one with the fewest tasks. Break ties by the lowest letter.
   4. If no lane matches, pick the lane with the fewest tasks. Break ties by the lowest letter.
4. **Order tasks inside each lane.** Sort them topologically on Depends-on edges, counting only edges between tasks in that lane. Break ties by task number. A cycle exits 5.
5. **Assign shared ownership.** Each shared path is owned by the lane that holds the lowest-numbered task touching it.
6. **Build the commit map.**
   - Each path is committed by the **last task in plan order** that lists it. This one rule covers both multi-task files and shared files. The lane that **edits** a shared file (its owner) and the task whose **commit** carries it are deliberately independent.
   - Each task's commit message is the first `git commit -m "<msg>"` found in the task's text. If a task has none, the map records `<none — controller writes>`.
   - A task left with no paths is marked `folded into Task M`.

**Outputs.** All output is deterministic: the same plan always produces byte-identical files. stdout prints one line per lane, then the path of `lanes.md`.

`lanes.md` contains:

- the lane table: lane, tasks in order, allowlist count, and shared paths owned;
- the resolved `typecheck:` and `unit:` commands;
- the commit map: task, message, and pathspec.

`lane-<X>-brief.md` contains these sections, in order:

1. **Header.** For example, `# Blitz lane X — Tasks 1, 2, 4 (in this order)`.
2. **`## Allowlist`.** The lane's own files that are not shared, plus the shared paths this lane owns.
3. **`## Do not touch`.** One line for each shared path that one of the lane's tasks lists but another lane owns:
   ``- `<path>` is owned by lane Y; skip your task's edits to it.``
4. **`## Tasks`.** The full text of each task, in lane order. The script produces it by running `task-brief PLAN N` for each task and joining the results, so it reuses task-brief instead of duplicating it.
5. **`## Shared-file duties`.** This section appears once in owner lanes that have at least one foreign duty, never per path. For each shared path the lane owns, it carries a "Reference only — apply ONLY the edits to `<path>`; do not touch any other file these tasks list." line, followed by the full text of every *foreign* task that touches that path. A foreign task is one in another lane.

**Other Files-line parsers.** No other script parses `Create:`/`Modify:`/`Test:` lines. `task-brief` and `review-package` treat task text and git ranges as opaque. So they tolerate the ` (shared)` suffix by construction. test-plan-lanes asserts that `task-brief` keeps the suffix verbatim.

### Lane implementer contract

Lanes reuse the existing role `caveman-implementer-<effort>`:

- **Model:** always `implementer: judgment=`. A lane is multi-task work against symbols that other lanes are writing at the same time.
- **Effort:** `implementer: effort=`.

The implementer template gains a `## Blitz lane (blitz mode)` clause. The dispatch activates it with this line:

"Blitz lane: no tests, no typecheck, no git."

The clause says:

- Execute every task in the brief, in the order given. This overrides "exactly one task".
- Touch ONLY the Allowlist.
  - Never apply your tasks' edits to the Do-not-touch paths.
  - For Shared-file duties, apply only the edits to the owned path.
- Upstream symbols are being written concurrently, exactly as the plan's Interfaces state. Import them as if they exist. Never stub them or redefine them.
- Write the code AND the test files exactly as the plan specifies.
- Do not run tests, typecheck, build, lint or formatters.
- Do not run any git command that writes, such as `add`, `commit` or `stash`.
- The plan's Run/Verify steps and the Commit step are skipped, not faked. Record each one as "not run (blitz)".
- The report replaces TDD evidence and commits with three things:
  - the files changed, per task;
  - "not run (blitz)" for each Run/Verify step;
  - every contract deviation or assumption beyond the Interfaces block, citing the line.
- If the lane is resumed with integration failures:
  - Fix only files in the Allowlist.
  - Still run no tests and no git.
  - If a fix needs another file, report NEEDS_CONTEXT.
- If resumed or dispatched for round 3 with "Blitz integration round 3: you may run tests; no git writes.", it is the only test runner. It may run the failing specs, capped as the dispatch says, but it still makes no git write.

The existing git-discipline rules still hold, and so does "never weaken a test". When the dispatch activates the clause, the clause overrides "Commit with an explicit pathspec". This follows the ultra lane-clause precedent.

### SDD `## Blitz Mode` (replaces the wave loop)

**Still applies:**

- Model Selection;
- caveman agent dispatch;
- status handling (DONE, DONE_WITH_CONCERNS, NEEDS_CONTEXT, BLOCKED);
- Fix Loop bounds;
- File Handoffs rules;
- the final whole-branch review and its single-fixer rule;
- verification-before-completion;
- finishing-a-development-branch.

**Dropped:**

- Execution Waves (the plan still carries them, as the fallback path);
- the per-task task reviewer and re-review;
- the Review tier gate;
- test-writer lanes;
- the per-task converge loop;
- the per-wave suite.

**Steps:**

1. **Pre-flight.** The existing Pre-Flight Plan Review scan runs first. Then run `scripts/plan-lanes PLAN`.
   - **Exit 0:** announce
     `Mode: blitz — <N> lanes dispatched at once; no per-task review; one integration pass (controller is the only test runner); final review mandatory`
   - **Exit 3, 4 or 5:** announce `Mode: blitz — falling back to ultra: <plan-lanes stderr>`. Then run Ultra Mode unchanged. The fallback covers the whole plan; no individual tasks are carved out.
   - **Exit 2:** stop and report it.
2. **Baseline.**
   1. Record `BLITZ_BASE=$(git rev-parse HEAD)`.
   2. Write `git status --porcelain` to `<workspace>/blitz-baseline.txt`. Repos can already have untracked files, such as `.serena/`.
   3. Check every lane's Allowlist against that baseline. If any Allowlist path is already modified or untracked, stop and report it to your human partner before dispatch — its pre-existing edits would be swept into a task commit at step 8.
3. **Dispatch.** Send all lanes in ONE message. Each dispatch carries:
   - the lane brief path;
   - the report path;
   - the line "Blitz lane: no tests, no typecheck, no git."

   Answer lane questions as they arrive.
4. **Lane status.** A BLOCKED or NEEDS_CONTEXT lane goes through the existing status handling: re-dispatch with more context or a more capable model. The re-dispatch — to the same lane or a fresh one — carries the same line, "Blitz lane: no tests, no typecheck, no git."; without it the agent falls back to its default contract (TDD, run tests, commit). Every lane must be DONE or DONE_WITH_CONCERNS before integration starts.
5. **Stray check.**
   1. Run `git status --porcelain` again.
   2. Remove the baseline entries.
   3. Any remaining changed path outside the union of all lane allowlists is a stray.
   4. For each stray, the controller inspects the diff and makes an explicit decision. It either attributes the path to a task's commit-map entry, or reverts it. Either way it notes the decision in the ledger.
   5. Never revert a stray automatically.
6. **Integration run.** The controller is the only test runner for the whole blitz run.
   1. Check `ps` for stray jest, vitest, temporal or test-server processes. Wait for them or kill them.
   2. Run `typecheck:`, unless it is `none`.
   3. Run `unit:` once, with the runner's parallelism capped: `--maxWorkers=2` for jest and vitest, or the equivalent flag for other runners.
   4. Redirect the output to workspace files, and read only the failure summaries.
7. **Integration fix loop, at most 3 rounds.**
   1. Map each failure to the lane whose allowlist owns the failing file. A seam failure that spans lanes goes to the consumer-side lane.
   2. **Rounds 1–2:**
      - Resume the owning lane implementers in parallel via SendMessage. Their allowlists are disjoint, so they cannot collide.
      - Each lane gets only its own failures, plus the line "Blitz integration fix: still no tests, no git."
      - If a lane implementer is no longer addressable, dispatch a fresh `caveman-implementer-<effort>` on `judgment=` with the lane brief and the failures, carrying both "Blitz lane: no tests, no typecheck, no git." and "Blitz integration fix: still no tests, no git." Note this in the ledger.
      - Between rounds, the controller re-runs typecheck and only the failing specs, capped.
   3. **Round 3:**
      - Dispatch one `caveman-implementer-high` on `final-reviewer: model=`. It gets every remaining failure, the lane reports and `lanes.md`.
      - It may run tests, because it is now the only runner.
      - It still makes no git writes.
      - Its brief carries, verbatim, the quoted line "Blitz integration round 3: you may run tests; no git writes." together with the caps:
        "Cap test runner parallelism: jest `--maxWorkers=2`, vitest `--maxWorkers=2`, equivalent flags for other runners. You are the only agent running tests. Check `ps` for stray jest/vitest/temporal/test-server processes first and wait or kill them."
   4. **Still red after round 3:** the run is BLOCKED. Report it to the human with the failure list. Commit nothing while the tests are red.
   5. **Green:** run typecheck and the full capped unit suite one final time. This catches a fix that regressed a spec that was not re-run.
8. **Commits.** Before committing, confirm `git rev-parse HEAD` still equals `BLITZ_BASE`. If it does not, some lane committed mid-run; stop and report it to your human partner, because the commit map below assumes an untouched HEAD. Otherwise follow the commit map in plan order.
   1. For each task, run `git add -- <paths>`, then `git commit -m "<message>" -- <paths>`. The add is needed because a pathspec commit cannot pick up new untracked files.
   2. If the map says `<none — controller writes>`, the controller writes a Conventional message from the task title.
   3. A task marked `folded into Task M` gets no commit, only a ledger note.
   4. Integration fixes go into the commit of the task that owns their file.
   5. Write one ledger line per task: `Task N: complete (blitz lane X, commit <sha7>)`.
9. **Final whole-branch review. This step is mandatory.**
   1. Build the package with `scripts/review-package MERGE_BASE HEAD`.
   2. Dispatch `caveman-final-reviewer-<effort>` on `final-reviewer: model=`.
   3. The dispatch adds the ultra tautological-tests line and this seam line:
      "Blitz: no per-task review ran. Check every cross-lane seam against the plan's Interfaces (names, types, optional vs required, error behaviour); flag drift as Important."
   4. Findings go to the existing single fix subagent. It is the only test runner at that point, and its brief carries the caps verbatim.
10. **Close.** Run verification-before-completion, then finishing-a-development-branch.

SDD also gets three smaller changes:

- a role-table note that blitz lanes run `implementer` on `judgment=`;
- a pointer from the wave-loop text to `## Blitz Mode`;
- File Handoffs entries for `plan-lanes`, `lanes.md` and the lane briefs.

### Components (every file touched)

1. **`.claude-plugin/plugin.json`**
   - The `mode` options become `["standard","fast","ultra","blitz"]`.
   - The description gains: "blitz (experimental): every task at once in file-ownership lanes, no per-task tests or review, one integration pass and a mandatory final review. Not for migrations with backfills or auth-critical work."
   - No new keys.
2. **`hooks/lib-config`:** the `mode)` whitelist becomes `standard|fast|ultra|blitz`. `SP_ROLES`, `SP_KEYS` and `SP_EFFORTS` are unchanged.
3. **`hooks/session-start`:** no code change. It already emits `mode: $(sp_resolve_mode)`.
4. **`hooks/agent-config-gate`:** unchanged.
5. **`scripts/agent-templates/caveman-implementer.md`**
   - Add the `## Blitz lane (blitz mode)` clause.
   - Add one sentence to the Report section about the blitz report shape.
   - Regenerate the agents with `scripts/gen-agent-variants`. The 3 implementer variants change; there are still 15 agents in total.
6. **`skills/subagent-driven-development/scripts/plan-lanes`:** new and executable, as specified above.
7. **`skills/subagent-driven-development/SKILL.md`**
   - a `## Blitz Mode` section after Ultra Mode;
   - the announcement strings in Pre-Flight;
   - the File Handoffs entries;
   - the role-table note;
   - the wave-loop pointer.
8. **`skills/writing-plans/SKILL.md`:** a `## Blitz Mode Plans` section containing the superset-of-ultra rule and these requirements:
   - (a) Every task, transcription tasks included, has an Interfaces block with Consumes and Produces lines (`none` allowed), and Produces states behaviours.
   - (b) A file that several tasks only append to is marked ``- Modify: `path` (shared)`` on every task that lists it. Examples are barrel exports, migration journals and registries. A file that tasks edit in overlapping regions stays unmarked.
   - (c) Global Constraints carries `- typecheck: \`<cmd>\`` or `- typecheck: none`, plus `- unit: \`<cmd>\``.

   The section also notes two things. Execution Waves are still required, as the fallback path. Step 5 commit messages still matter, because the controller uses them. Finally, add self-review item 7, "Blitz contracts", which checks (a), (b) and (c).
9. **`skills/brainstorming/SKILL.md`:** the blitz superset rule.
10. **`skills/requesting-code-review/SKILL.md`:** the blitz superset rule, the seam line, and a note that blitz has no per-task review step.
11. **`README.md`:** a blitz entry wherever modes are listed, with the trade-off and the do-not-use list.
12. **Packaging and lint:**
    - Confirm that the codex packaging scripts ship `plan-lanes` executable, the same way they ship `task-brief`. Add it to any explicit file list.
    - Confirm that the shell lint picks up the new script.
13. **Release**
    - `RELEASE-NOTES.md` gets `## v7.2.0 (2026-11-05)` with **What.**, **Trade-off.**, **Config.** and `### Internal`.
    - The 9 manifests in `.version-bump.json` are edited by hand to 7.2.0. To verify, grep that no 7.1.1 remains outside RELEASE-NOTES.

### Error handling

| Situation | Handling |
|---|---|
| plan-lanes exits 3, 4 or 5 | Whole-plan fallback to ultra, with stderr in the announcement. |
| plan-lanes exits 2 | Hard stop and report. No fallback. |
| Invalid mode value | The existing lib-config warning applies, and the mode resolves to standard. |
| A lane is BLOCKED or NEEDS_CONTEXT | Existing status handling. Integration waits for all lanes. |
| Strays | An explicit attribute-or-revert decision, recorded in the ledger. Never automatic. |
| Still red after round 3 | BLOCKED. Escalate to the human. Nothing is committed while red. |
| The plan has a wrong contract | It shows up as seam failures, routed to the consumer lane, escalating through round 3. This is the stated, accepted risk. |
| `index.lock` races | Impossible. Lanes make no git writes, and only the controller writes during the commit step. |

### Testing

Every suite is plain bash. Run each one with `bash <file>`, one at a time.

- **`tests/hooks/test-plugin-config.sh`:** the mode options include `blitz`, and the description says experimental.
- **`tests/hooks/test-session-start.sh`:**
  - blitz resolves through the plugin option and through the env var;
  - an invalid mode still warns and falls back;
  - the role lines are unchanged under blitz.
- **`tests/hooks/test-config-wiring.sh`:** stays green unchanged. The mode is not a role.
- **`tests/agents/test-agent-variants.sh`:** after regeneration, the 15 generated files match the checked-in files.
- **`tests/agents/test-fast-mode-contract.sh`** asserts that:
  - the hook emits `mode: blitz`;
  - the blitz superset rule appears in brainstorming, writing-plans and requesting-code-review;
  - SDD contains each of these tokens: `## Blitz Mode`, `Blitz lane: no tests, no typecheck, no git.`, `Mode: blitz —`, `falling back to ultra`, `plan-lanes`, `only test runner`, `--maxWorkers=2`, and the seam line;
  - requesting-code-review contains the seam line;
  - writing-plans contains `(shared)`, `typecheck:`, `unit:` and the self-review item 7 token;
  - every implementer variant contains `## Blitz lane (blitz mode)` and `not run (blitz)`.
- **New `tests/claude-code/test-plan-lanes.sh`**, run against fixture plans in a temp dir. It covers these cases:
  1. Line-range stripping: `a.ts:10-20` and `a.ts` are unioned.
  2. Path normalisation: `./a.ts` is the same path as `a.ts`.
  3. Shared files:
     - a shared path is left out of the union;
     - the owner is the lane with the lowest-numbered task;
     - the owner brief has `## Shared-file duties`, the foreign task's full text and the "Reference only" heading.
  4. A non-owner lane gets the do-not-touch line.
  5. Packing with `MAX_LANES=2` and 4 components follows the prefix preference.
  6. Topological order inside a lane can differ from task-number order.
  7. A Depends-on cycle inside a lane exits 5.
  8. A missing Interfaces block, or a missing Produces line, exits 3.
  9. A missing `unit:` line exits 4, and so does a missing `typecheck:` line.
  10. `typecheck: none` is accepted.
  11. The commit map follows the last-toucher rule and handles the `folded into` case.
  12. Two runs produce byte-identical outputs.
  13. `task-brief` keeps the ` (shared)` suffix verbatim.
  14. A missing plan file exits 2.
- **Shell lint:** `plan-lanes` passes the repo's shell lint.
- **Codex packaging:** `plan-lanes` is shipped and executable, wherever the codex packaging tests enumerate the SDD scripts.
- **Evals:** none in this release. The recommended follow-up is a measured acceptance run comparing blitz and ultra.

## Decisions log

1. **Lanes come from a deterministic script, `plan-lanes`.** A wrong lane means two agents race on one file. That is the one failure blitz cannot tolerate, and a script is testable.
2. **A `(shared)` marker plus an owner lane handles append-only files.** Without it, one barrel file collapses every lane into one. Unmarked files fall back to plain union, which is safe.
3. **The owner is the lane holding the lowest-numbered task that touches the path.** This is deterministic.
4. **The owner brief carries foreign tasks' full text under "Reference only".** Otherwise the owner cannot see edits that tasks in other lanes need. *(Proxy audit amendment.)*
5. **A task's files never split across lanes.** YAGNI: `(shared)` covers the real need.
6. **No new config key or role; `MAX_LANES=6` is the script default.** This avoids churn in validation, the gate, the generator and the wiring checks.
7. **Lanes reuse `caveman-implementer-<effort>` on `judgment=`.** Lane work is multi-task and integration-shaped.
8. **A lane clause goes in the implementer template, following the ultra precedent.** Skipped steps are reported as "not run (blitz)", never faked.
9. **The controller is the only test runner, with a `ps` check and `--maxWorkers=2` or equivalent.** This is the owner's machine-safety rule, applied verbatim.
10. **Both `typecheck: <cmd|none>` and `unit: <cmd>` are required, and a missing one triggers fallback.** An explicit `none` makes skipping typecheck a deliberate choice. *(Proxy amendment.)*
11. **The stray check runs against a pre-dispatch baseline, and every stray gets an explicit attribute-or-revert decision.** An auto-revert could destroy a needed seam fix. *(Proxy rejection of auto-revert.)*
12. **The integration fix loop runs at most 3 rounds.**
    - Rounds 1–2 resume the owning lanes in parallel, and seam failures go to the consumer lane.
    - Round 3 is implementer-high as the sole runner.
    - This mirrors the existing Fix Loop.
13. **A final full capped run happens before any commit.** A fix can regress a spec that was not re-run.
14. **There is one commit per task, using its Step 5 message.**
    - A multi-task or shared file goes into the commit of the last task that touches it, a single uniform rule. *(Proxy corrected its first answer.)*
    - `git add --` runs first, so new files are included.
15. **The final review is mandatory, with the seam line.** It is the only review gate left, and it reviews code no agent ran while writing. This overrides the proposal's "optional".
16. **Blitz is a superset of ultra in the planning and review skills, and a replacement in SDD.** Planning rules compose, but execution works fundamentally differently.
17. **Fallback to ultra applies to the whole plan.** Mixing serial tasks back in would reintroduce barriers and complicate the commits.
18. **Exit 2 is a hard stop, not a fallback.** A missing plan or a bad usage line is an operator error, not an unsuitable plan. *(Proxy audit fix: the draft contradicted itself here.)*
19. **The do-not-use list is documentation only, and blitz is labelled experimental.** No reliable heuristic exists, and the user opts in explicitly.
20. **Execution Waves are still emitted.** They are the fallback path.

## Rejected alternatives

- **A `## Lanes` section in the plan:** it drifts away from the Files lines and ties the mode to planning time.
- **The controller computing lanes in prose:** least reliable, and it uses controller context.
- **A new `blitz-implementer` role:** 3 more agents plus changes to the gate, generator and wiring, for behaviour one clause covers.
- **A `blitz_lanes` config key:** YAGNI, and it would need a new integer validation path.
- **The controller adding shared-file lines during integration:** this moves edit work into controller context, and every barrel line would fail typecheck first.
- **Auto-reverting strays:** destructive.
- **An optional final review:** it would leave zero review on code that never ran.
- **Per-task fallback carve-outs:** they reintroduce barriers.
- **Splitting a task's files across lanes:** it breaks task atomicity, and `(shared)` covers the need.
- **Lanes running focused tests:** every lane sees the others half-written, so results are noise, and it breaks the one-runner rule.
- **Lanes committing:** `index.lock` races, and commits that do not compile.
- **A heuristic detector for migrations or auth changes:** unreliable.
- **Installing yq:** it adds a tool dependency without the owner's permission.

## Recommended follow-ups (not implemented)

- A measured acceptance run comparing blitz and ultra on a fixed plan, tracking integration fix rounds and final-review defects.
- A worktree per lane, which would allow focused per-lane runs without noise.
