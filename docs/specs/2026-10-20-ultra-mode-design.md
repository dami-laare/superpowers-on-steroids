# Ultra mode — design

**Date:** 2026-10-20
**Status:** approved (agent-team brainstorm; nothing escalated)
**Release:** `feat` — MINOR bump to 7.1.0

## Problem

The owner wants a mode where tests are written in parallel with implementation, and test-and-fix iteration happens afterwards. Today one implementer owns the whole RED → GREEN chain (write test, watch fail, implement, watch pass) before review can start. The owner asked for an `ultra` mode that splits that chain across two concurrent agents so implementation never waits on test authoring, plus recommendations for other speed optimizations.

## Trade-off (stated plainly to users)

Ultra drops TDD RED evidence for judgment tasks. Tests are written blind from the plan's contract, without seeing the implementation. A test that encodes a wrong API assumption shows up as a converge-round cost. In ultra mode the bottleneck is the quality of the plan's Interfaces contract. Ultra is **experimental** until a measured acceptance run compares it with fast mode.

## Design

### Architecture

`mode: ultra` is a strict superset of `fast`. Each skill that has fast-mode branches gets one superset rule, and the existing `mode: fast` literals stay untouched:

> `mode: ultra` includes all of fast mode. Every fast-mode instruction applies to ultra too, plus the ultra additions in this section.

The rule goes into `subagent-driven-development`, `requesting-code-review`, `brainstorming` and `writing-plans`.

```
plugin.json userConfig / SUPERPOWERS_MODE=ultra
  → hooks/lib-config (whitelist standard|fast|ultra; new test-writer role)
  → hooks/session-start (<SUPERPOWERS_CONFIG>: mode: ultra, test-writer: model=… effort=…)
  → SDD controller: per judgment task, dispatch implementer + test-writer in the same message
  → hooks/agent-config-gate verifies both variants against config
  → per task, streamed: converge (run tests, fix loop) → review → wave suite barrier → final review
```

### Lane split (judgment tasks)

- **Implementer** (`caveman-implementer-<effort>`, existing role): implements only. It does not create or edit the task's listed test files and does not wait for them or run them, because they may not exist yet. It may run build, type or lint checks that the brief names. It commits its own paths with an explicit pathspec.
- **Test-writer** (`caveman-test-writer-<effort>`, new role): writes only the task's listed test files, from the brief's Files and Interfaces contract. It never reads the task's implementation files. It commits only its test paths with an explicit pathspec, and reports any assumption it made beyond the contract.

Both lanes commit disjoint paths with explicit pathspecs. Concurrent implementers already do this today, so no controller-commit mechanism is needed.

**Transcription-tier tasks** get no test-writer lane, because the brief already carries the test and implementation code. In ultra the implementer writes both and skips the RED run.

**Fallback:** if a task has no disjoint Test path or no Interfaces contract, it runs as fast mode: a single implementer doing full TDD.

### Per-task streaming and converge

Per wave (cap 4, unchanged): record WAVE_BASE, then dispatch all lanes in one message. For each task, **as soon as both of its lanes return** (the controller does not wait for the wave):

1. The controller runs that task's listed tests once.
2. If any fail, the **converge loop** runs. The controller resumes the implementer with the failing output and the test-writer's stated assumptions. The implementer may edit implementation or tests. Editing a test requires citing, in the report, the contract line the test contradicted. The loop runs at most 3 rounds, with round 3 on `caveman-implementer-high` at `final-reviewer: model=` (same as the fast fix loop). After that, the existing BLOCKED handling applies.
3. Once the tests are green: review-package, task reviewer (the transcription skip is honoured), then the existing review fix loop.
4. At the wave barrier, the full suite runs once (unchanged).
5. After all waves: final whole-branch review, verification-before-completion and finishing-a-development-branch (all unchanged).

Ultra adds one line to the reviewer checklist: *tests assert the contract's behaviours, not the implementation's incidental output; flag tautological tests.*

Streaming is safe because tasks in a wave touch disjoint files, which plans already require. Reviews use per-task commit ranges.

### Components

1. **`.claude-plugin/plugin.json`**: `mode` options become `standard|fast|ultra`, and the description states the trade-off. New keys `test_writer_model` (default `sonnet`, Agent-tool aliases only) and `test_writer_effort` (default `low`, options `low|medium|high`), with descriptions modelled on the reviewer keys. New env overrides `SUPERPOWERS_TEST_WRITER_MODEL` and `SUPERPOWERS_TEST_WRITER_EFFORT`.
2. **`hooks/lib-config`**: mode whitelist becomes `standard|fast|ultra`. Add `test-writer` to the roles, add both keys, and add the builtin defaults. Validation reuses the existing model and effort paths.
3. **`hooks/session-start`**: emit `test-writer: model=… effort=…` in the same format as `reviewer:`.
4. **`hooks/agent-config-gate`**: gate `caveman-test-writer-*` against the role's model and effort. It stays mode-agnostic.
5. **Agents**: new template `scripts/agent-templates/caveman-test-writer.md`. It gets the same tools, git discipline and caveman report style as the implementer, and is scoped to test files only. The implementer template gains the lane clause. `scripts/gen-agent-variants` gets the new role, and regenerating produces 15 agents.
6. **Skills**:
   - SDD gets an `## Ultra Mode` section covering: the superset rule, lane split, dispatch pair, fallback, transcription exception, streaming, converge loop and citation rule, reviewer checklist line, trade-off, pre-flight announcement string, and a role-table row for the test-writer.
   - requesting-code-review gets the superset rule and the checklist line.
   - brainstorming gets the superset rule.
   - writing-plans gets the superset rule plus an ultra requirement: judgment tasks carry a disjoint Test path and an Interfaces contract (signatures and behaviours they produce). The self-review checks this, and a task that cannot meet it is marked fast-fallback.
   - `test-driven-development` is untouched. SDD states the deviation explicitly.
7. **Release**: a `RELEASE-NOTES.md` `## v7.1.0 (2026-10-20)` section, and the 9 manifests in `.version-bump.json` bumped to 7.1.0.

### Error handling

- Invalid mode or test-writer values: the existing warning and fallback behaviour applies.
- A test-writer contract ambiguity: the controller resolves it before running the tests, or passes it in as converge input.
- No new failure paths beyond the existing BLOCKED handling.

### Testing

All in the existing bash suites:

- `test-plugin-config.sh`: mode options; the test-writer keys, defaults and env names.
- `test-session-start.sh`: ultra resolves via the option and via env; the test-writer line is defaulted and overridable.
- `test-config-wiring.sh`: role, key and effort lists in sync across plugin.json, lib-config, the generator and the gate.
- `test-agent-config-gate.sh`: a matching test-writer variant is allowed and a mismatched one is denied.
- `test-agent-variants.sh`: 15 generated files equal the checked-in files.
- `test-fast-mode-contract.sh`: the superset rule is present in all 4 skills; emitted `mode: ultra` maps to the skills; the implementer lane clause exists; the SDD ultra section names the fallback, the transcription exception and the citation rule.

### Version bump

7.0.0 → 7.1.0. `yq` is not installed and installing tools is out of scope, so the 9 manifests are edited by hand. To verify, grep each manifest for 7.1.0 and confirm no 7.0.0 remains outside RELEASE-NOTES.

## Decisions log

1. Ultra is a superset of fast, wired by one rule per skill. The existing branches are not rewritten (least churn, no drift).
2. The test-writer is a new uniform role (low/medium/high through the generator), defaulting to sonnet at low effort. Blind test authoring needs judgment, and low effort keeps it fast.
3. The implementer template gets a lane clause, so the agent contract never contradicts the brief.
4. The implementer does not run the test-writer's tests; the controller runs them at converge. *(Proxy audit amendment: the tests may not exist when the implementer finishes.)*
5. Disjoint pathspec commits by both lanes, with no controller-commit mechanism (existing practice).
6. The spec source is the plan's existing Files and Interfaces fields. writing-plans adds only the ultra requirement.
7. Transcription tasks get no test-writer lane.
8. A task without a disjoint test path or a contract falls back to fast mode.
9. RED is dropped in ultra and documented. The reviewer checklist guards against tautological tests.
10. Converge is per task and streamed. The wave suite, final review and verification are unchanged.
11. A test edit during converge must cite the contract line it contradicted.
12. No new fixer agent; round 3 escalates to implementer-high.
13. Version 7.1.0, with manual manifest edits.

## Rejected alternatives

- Independent ultra mode with its own agents and branches: doubles the surface and drifts.
- End-of-plan test-and-fix: failures detected late, a large blast radius, and it breaks the wave-suite gate.
- Reusing the implementer with a test-only override brief: contradicts the agent's own TDD contract.
- A single-effort test-writer: becomes a special case in the generator and gate.
- A controller-commits mechanism: the existing pathspec practice suffices.
- A "test fails without impl" RED spot-check: costs a run per task, against the speed goal.
- Caching the baseline test command: too vague, and plans already name their commands.
- Passing the review package as a file path: already implemented (SDD File Handoffs).
- Installing `yq` to run `bump-version.sh`: adds a tool dependency without the owner's permission.

## Recommended further speed optimizations (not implemented)

- **Cross-wave pipelining:** start the next wave's lanes while the previous wave's reviews run, when the plan marks the waves independent. This changes the wave-barrier semantics and depends on a correct dependency graph.
- **Raise the wave cap above 4**, or **batch tiny tasks** into one dispatch. Both were rejected in the 2026-09-04 speed spec, so they need evidence first.
- **Worktree per lane**, which removes all shared-index contention.
- **A measured acceptance run** comparing standard, fast and ultra on a fixed plan (wall time, converge and fix rounds, defects found at final review). No eval evidence exists for fast mode yet.
- **Skip the final reviewer on very small plans.** This is a sacred gate, so it is not recommended without evidence.
