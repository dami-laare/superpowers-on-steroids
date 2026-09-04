# Fast Mode Speed: Fewer Dispatches Per Task

**Date:** 2026-09-04
**Status:** Implemented — `docs/plans/2026-09-04-fast-mode-speed.md`
**Ships as:** v6.5.0 (MINOR)

## Problem

Fast mode (v6.4.0) substitutes four bundled `caveman-*` agents for four inline
prompt templates and changes nothing structural. Measured against
get-shit-done (GSD) and similar plugins, the structural gap is:

| Cost center | Superpowers fast mode today | GSD |
|---|---|---|
| Clean task | 3 hops: implementer, review-package, reviewer | 1 executor dispatch |
| Per-task LLM review | Every task, no triviality skip (`subagent-driven-development/SKILL.md` Red Flags) | None; plan-check once before, verify once after |
| Any finding in a wave | Fix + re-review run on the slow inline template path (`SKILL.md:212-214`) | n/a |
| Fix loop | Unbounded "repeat until approved" — upstream five-round breaker deleted by fork commit `876960a` (no spec, no eval) | n/a |
| Brainstorm | Up to 8 serial rounds even for bounded requests | `skip_discuss` when priors exist |

Prior measurement (`docs/specs/2026-06-09-sdd-task-scoped-review-dispatch-design.md`)
established that dispatches-per-task is the lever that moves wall-clock;
scheduling tricks landed inside ±6 min noise. Fast mode itself has zero eval
evidence of saving time.

## Success criterion

In fast mode:

- Clean transcription task = **1 dispatch** (implementer only).
- Clean judgment task = **2 dispatches** (implementer, reviewer).
- Fix loop **≤ 3 rounds**, then adjudicated.
- Untouched, all modes: final whole-branch review, per-wave test suite, TDD
  inside the implementer, verification-before-completion.

## Architecture

Three units. Land in this order; later units read fields earlier units add.

| Unit | Scope | Applies to |
|---|---|---|
| **U1 Fix loop** | Restore 3-round breaker, resume semantics, re-wire scoped re-review, fast-path fix/re-review agent mapping | Breaker/resume/re-review: all modes. Agent mapping: fast only |
| **U2 Review tiering** | Plan-time `Review tier` field, transcription gate in SDD, promotion triggers, mode announcement | Field: all modes (inert in standard). Gate: fast only |
| **U3 Brainstorm + config** | Shorten dialogue when priors exist; `SUPERPOWERS_MODE` env override | Fast only |

Fast-only behaviour is written as short conditional paragraphs adjacent to the
standard text ("If `mode: fast` …"), never as a parallel control-flow section.
This bounds divergence from upstream `obra/superpowers`.

## Components

### writing-plans/SKILL.md (U2, all modes)

- Task template gains one line after **Depends on:**
  `**Review tier:** transcription | judgment`
- Transcription criteria, stated inline in the template: brief carries the
  complete code to write; ≤ 2 non-test files created or edited; no new public
  interface; no schema, auth, payment, or concurrency touch; covering tests
  present in the brief. Anything else is judgment.
- Self-Review gains **check 5, tier claims**: every `transcription` task meets
  all five criteria; demote to judgment if not.
- `scripts/task-brief` extracts the whole task text, so the field reaches the
  implementer and controller with no script change.

### subagent-driven-development/SKILL.md

**All modes (U1):**

- Process diagram: "Dispatch fix subagents" node replaced by a fix-round loop
  with a breaker node; re-review node points at `./re-review-prompt.md`.
- New subsection **Fix Loop** under "Running a wave":
  - Rounds 1–2: resume the task's original implementer via SendMessage with the
    findings list. If the agent is no longer addressable, dispatch a fresh fix
    subagent carrying the findings **and** the original brief at the same tier.
    Never a silent skip; ledger notes the fallback.
  - Round 3: fresh implementer on the capable tier (`model_capable` from the
    config block when set, else the harness's most capable model) via inline
    `implementer-prompt.md` in both modes. Fast agents are model/effort-pinned,
    so escalation always uses the template.
  - After each round: scoped re-review via `re-review-prompt.md` (cheap-to-mid
    tier), limited to the findings and the fix diff.
  - **Trip after round 3:** any open Critical → task BLOCKED (existing failure
    isolation: wave-mates finish, dependents wait). Important-only → ledger the
    findings with a `breaker-tripped` marker and continue. Minor dropped at
    trip. The final review dispatch names every `breaker-tripped` entry and
    must triage each.
- Delete every "dispatch fix subagents" phrasing; the Red Flags entry already
  says the same implementer fixes. One story: resume.
- Model Selection: restore "scoped re-reviews of small fix diffs take a
  cheap-to-mid tier" and "round-3 escalation uses the capable tier".
- Pre-Flight: if a `<SUPERPOWERS_CONFIG>` block is present, announce once before
  wave 1: `Mode: <mode> — <review policy>; fix loop capped at 3 rounds`.
  No block → nothing printed.

**Fast only (U1 + U2):**

- Fast Mode table gains rows: fix rounds 1–2 → `caveman-implementer` (resumed);
  re-review → `caveman-reviewer` (re-review mode). The "roles with no fast
  counterpart" sentence drops "re-review, fix subagents".
- New paragraph **Review tier gate**: for `Review tier: transcription`, skip
  `review-package` and the reviewer when the implementer's report **file**
  shows status DONE, the GREEN test command, and its passing output. The gate
  reads the file, not the one-line reply.
- Promote to judgment (dispatch the reviewer normally) on any of:
  1. status ≠ DONE;
  2. report file lacks GREEN command + output;
  3. commits touch a file outside the brief's Files list;
  4. implementer reports a plumbing deviation from the brief's literal code;
  5. the per-wave suite fails on a test touching the task's files →
     retroactive promotion before the wave closes.
  Missing or malformed field → judgment. Controller never downgrades a tier.
- Red Flags: "Skip task review" becomes "Skip task review for a judgment task,
  or for a transcription task without gate evidence in the report file".

### subagent-driven-development/re-review-prompt.md (U1)

Re-wired, not rewritten. Only edit: placeholders aligned to current
file-handoff names (brief path, report path, fix-diff package path).

### agents/caveman-reviewer.md (U1, fast)

Add a **Re-review mode** section: when the dispatch names a prior findings
list, verdict each finding `ADDRESSED | NOT ADDRESSED` with file:line evidence,
flag new Critical/Important in the fix diff, end with the round verdict. Same
caveman compression. `caveman-implementer.md` needs no change; it already
carries the resume contract.

### brainstorming/SKILL.md (U3, fast)

One paragraph at the Dispatching bullet: in fast mode, when spec-shaped input
exists (a design doc path is supplied, or the request is bounded to ≤ 2
non-test files with clear acceptance), set `MAX_ROUNDS` to 2. HARD-GATE
unchanged; brainstorming is shortened, never skipped. `brainstormer-prompt.md`
unchanged.

### hooks/session-start + .claude-plugin/plugin.json (U3)

`sp_mode` resolves from `${SUPERPOWERS_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-}}`
through the existing whitelist. Env wins. Only `fast` emits a block, so
`SUPERPOWERS_MODE=standard` force-disables fast mode on a fast-configured
machine. Tier resolution unchanged. `plugin.json` mode description gains one
clause naming the env override.

### Docs

- This spec, including the Acceptance run section below.
- README fast-mode section: tiering, breaker, env override.
- RELEASE-NOTES entry.

## Data flow (fast mode, one wave)

```
plan (Review tier) → task-brief → implementer dispatch → report file
  → controller reads file
      ├─ transcription + gate passes → ledger line, no reviewer
      └─ judgment or promoted → review-package → reviewer → findings
            → resume implementer (R1–2) → scoped re-review
            → … → R3 capable inline → trip adjudication
  → per-wave suite (trigger 5 may re-open a transcription task)
  → ledger incl. breaker-tripped → final review (package + ledger list)
  → finishing-a-development-branch
```

## Error handling

| Condition | Behaviour |
|---|---|
| Implementer agent not resumable | Fresh fix dispatch with findings + brief, same tier; ledger notes fallback |
| `model_capable` unset at round 3 | Harness's most capable model; never a fast agent |
| Breaker trips with open Critical | BLOCKED; wave-mates finish; dependents wait |
| Breaker trips, Important only | Ledger `breaker-tripped`; final review triages each |
| `Review tier` missing or malformed | judgment |
| Transcription report lacks GREEN evidence | Promote; no acceptance on trust |
| Wave suite fails on a transcription task's files | Retroactive promotion before wave closes |
| `SUPERPOWERS_MODE` fails whitelist or ≠ `fast` | Whitelist failure: dropped, fails closed, no block even if the plugin option is fast. Empty: deferred to the plugin option. Any other value (incl. `standard`): no block |
| No config block at all | Hook output byte-identical; no mode announcement |

## Testing strategy

- **tests/hooks/test-session-start.sh** (extend): env alone emits `mode: fast`;
  env `standard` overrides option `fast` (no block); option `fast` with env
  unset still emits; invalid env value dropped; all unset → byte-identical
  (existing assertion).
- **tests/agents/test-fast-mode-contract.sh** (extend): Fast Mode table maps
  fix → `caveman-implementer` and re-review → `caveman-reviewer`;
  `ADDRESSED` / `NOT ADDRESSED` present in both `re-review-prompt.md` and
  `caveman-reviewer.md`; SDD SKILL.md carries `Review tier`, `transcription`,
  `breaker-tripped`, round-3 text; writing-plans carries `Review tier:`; SDD
  SKILL.md no longer contains "dispatch fix subagents"; existing frontmatter,
  token, and hook-wiring checks unchanged.
- **tests/codex-plugin-sync/**: run unchanged; `agents/` stays excluded.
- **Acceptance run**: below. Not a PR blocker.

## Acceptance run

`evals/` is gitignored and no harness clone exists on the owner's machine, so
the protocol lives here rather than as a scenario file.

- Scenario: go-fractals (the baseline used in the 2026-06-09 SDD review spec).
- Config: `SUPERPOWERS_MODE=fast` exported for the session.
- Arms: fast mode at v6.4.0 (before) vs fast mode with this design (after).
- Metrics: dispatches per task (from transcript), wall-clock, tokens, dollars.
- Runs: ≥ 2 per arm; ±6 min variance observed previously.
- Pass: median dispatches per clean transcription task = 1; wall-clock lower
  than before-arm median; final-review verdict quality not lower on blind read.
- Contribute the scenario to superpowers-evals once cloned.

## Commit types

- U1 breaker restoration and re-review re-wiring: `fix:`
- U2 review tiering, U3 brainstorm shortening and env override: `feat:`
- Net bump: MINOR.

## Decisions log

| # | Decision | Rationale |
|---|---|---|
| 1 | SDD loop is the center of mass; brainstorm gets one cut; config only what SDD forces | User said "implementation speed"; prior eval says dispatches/task is the lever |
| 2 | No measurement gate before levers | Lever already identified by prior eval; measurement is the acceptance run |
| 3 | Sacred gates: final review, per-wave suite, TDD, verification-before-completion | "High quality" rules out GSD yolo-style gate removal |
| 4 | Review tier set at plan time, never downgraded by controller | Auditable in plan doc; mirrors GSD acceptance criteria; one field, one branch, no new agent |
| 5 | Transcription = complete code + ≤ 2 non-test files + no interface/schema/auth/payment/concurrency + tests in brief | Test files excluded or every TDD task is 4 files and the tier is dead |
| 6 | Gate reads report file, not short reply | Only the file carries GREEN command + output |
| 7 | Five promotion triggers incl. plumbing deviation and wave-suite failure | Plumbing is where transcription silently drifts; suite is the independent check the reviewer would have been |
| 8 | Breaker restored, 3 rounds, all modes | Unbounded loop is a defect deleted without spec or eval; bug fix, not policy |
| 9 | Rounds 1–2 resume, round 3 fresh capable inline | Resume keeps context; fast agents pinned so escalation uses template |
| 10 | Explicit non-resumable fallback | No silent skip |
| 11 | Capable tier from `model_capable` else harness default | No new config key |
| 12 | Scoped re-review re-wired in all modes | Breaker without it restores half a mechanism; orphan stays on disk otherwise |
| 13 | Fix/re-review get fast counterparts by reuse | No new agents; implementer already contracted for resume |
| 14 | `caveman-reviewer` gains re-review mode | Parity test needs the vocabulary on both sides |
| 15 | Trip: Critical → BLOCKED; Important → ledger + final triage; Minor dropped | Opus/high final reviewer beats a third sonnet/low round; continuous flow |
| 16 | Wave cap stays 4, no worktree isolation | Cap exists for controller load; scheduling gains were in the noise |
| 17 | Batching: YAGNI | Same-wave tasks already parallel; saves tokens not wall-clock |
| 18 | Fast-only changes as adjacent conditional paragraphs | Bounds divergence; no parallel control flow |
| 19 | `Review tier` written in all modes | Plan template must not fork; inert in standard |
| 20 | "Byte-identical" applies to hook output only | That is the tested baseline guard; SKILL.md already diverged at 876960a |
| 21 | Brainstorm shorten (MAX_ROUNDS 2), never skip | HARD-GATE stands; writing-plans with a spec path already bypasses |
| 22 | `SUPERPOWERS_MODE` env override, env wins | Forced by acceptance run; spec's own seam; `standard` force-disables |
| 23 | Acceptance protocol in spec only | `evals/` gitignored; a file with no harness is a knob wired to nothing |
| 24 | Mode announcement only when a config block exists | Self-describing fast transcripts; zero change to unconfigured sessions |
| 25 | Parity test asserts table rows + re-review tokens, not briefs | No brief templates exist to compare |

## Rejected alternatives

- **GSD-yolo gate removal**: trades quality; user asked for high quality.
- **Controller-judged review tiering**: unauditable; invites self-serving downgrades.
- **Universal per-task review, constant factors only**: leaves the 3-hop structure GSD beats.
- **Wave cap > 4 / worktree per implementer**: scheduling gains inside ±6 min noise; cap is about controller load.
- **Transcription batching**: token saving, not wall-clock; revisit if > 4 transcription tasks per wave observed.
- **New `caveman-fixer` / `caveman-re-reviewer` agents**: reuse covers both; two more agents to keep in parity.
- **Fast-only breaker**: a defect is mode-independent.
- **Fresh fixer every round (current text)**: re-derives context; contradicts Red Flags.
- **Important findings block at trip**: weaker judge than final reviewer; breaks continuous flow.
- **Full brainstorm skip when priors exist**: violates HARD-GATE; existing path covers user-supplied specs.
- **Committed `evals/scenarios/` file**: directory is gitignored.
- **Measurement gate before design**: lever already known from prior eval.
- **New `effort_*` or `model_fix` config keys**: knobs wired to nothing.
- **Deleting dead `spec-document-reviewer-prompt.md` / `plan-document-reviewer-prompt.md`**: out of scope; separate chore.
