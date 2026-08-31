# Fast Mode, Per-Plugin Config, and Docs Base Dir — Design

**Date:** 2026-08-31
**Status:** Consensus reached (agent-team brainstorm)

## Problem

Three requests, from the fork owner:

1. Import the four `caveman-*` agents from `henosys/overwatch/.claude/agents/` into this plugin so the skills can run a **fast mode**.
2. Make models and effort **configurable from the user's `settings.json`**, as plugin-specific config.
3. Stop using `docs/superpowers/` as the docs base dir — write to `docs/specs/`, `docs/plans/` instead.

## Decomposition

Three independent units sharing one version bump.

| Unit | What | Risk |
|---|---|---|
| **C** | `docs/superpowers/{plans,specs}` → `docs/{plans,specs}` | Mechanical; changes a user-visible output path |
| **B** | Per-plugin config via `userConfig` → hook → injected context | Platform plumbing; zero-dep |
| **A** | Four agents + additive fast lane + drift tripwire + Codex guards | Behaviour-shaping |

**They must land C → B → A, serially.** This is a constraint, not a preference: all three edit overlapping skill files. `skills/subagent-driven-development/SKILL.md` is touched by A and B; `skills/brainstorming/SKILL.md` and `skills/requesting-code-review/SKILL.md` by A and C. They are **not file-disjoint** and must not be dispatched as a parallel wave.

---

## Platform facts (verified against Claude Code 2.1.251)

These were established by disassembling the installed binary, not from documentation. Two of them eliminate design options outright, and public docs were wrong or silent on several.

The plugin-agent loader, deobfuscated:

```js
let {frontmatter: O, content: F} = ni(R, e, {normalizeKeys: true});  // parse first
let ge = O.model;                     // model  <- RAW frontmatter
let xe = H4(F.trim(), {...});         // ${CLAUDE_PLUGIN_ROOT} etc. on BODY
if (d.userConfig) xe = d4(xe, ...);   // ${user_config.X} on BODY ONLY
let ze = O.effort;                    // effort <- RAW frontmatter
```

| Question | Answer |
|---|---|
| `agents/` auto-discovered in plugins | Yes — no `plugin.json` key required |
| Scoped name | `[plugin, ...path, name].join(":")` |
| `effort:` frontmatter | Real — named levels **or an integer** |
| `model:` frontmatter | Any string, or `inherit` (case-insensitive) |
| `${user_config.X}` in **frontmatter** | **No.** Frontmatter is parsed before substitution; body only |
| Per-dispatch `model` override | **Yes** — Agent tool `model` parameter |
| Per-dispatch `effort` override | **No such parameter exists** |
| Config → hooks | `CLAUDE_PLUGIN_OPTION_<KEY>` env vars |
| Env name transform | `key.replace(/[^A-Za-z0-9_]/g,"_").toUpperCase()` |
| `${user_config.X}` in shell-form hook commands | **Blocked** by an explicit guard; must read the env var |
| `userConfig` option fields | `type,title,description,required,default,multiple,sensitive,min,max` — schema is `.strict()`, **no `enum`** |
| Ignored-with-warning in plugin agents | `permissionMode`, `hooks`, `mcpServers` |
| Agent file size cap | 1 MiB |

**Consequence that reshapes the request:** effort is not runtime-configurable by *any* route — not by frontmatter interpolation (body-only), not by dispatch override (no parameter). Models are fully configurable. So "configurable models and effort" splits: **models are configured per tier; effort is selected by choosing which agent gets dispatched — a `mode` switch.**

Our `hooks.json` uses shell-form commands, so the `CLAUDE_PLUGIN_OPTION_*` env route is not merely preferable — it is the only one available.

---

## Unit A — Fast lane

### Architecture

A top-level `agents/` directory holds the four overwatch files **verbatim, under their original names**, auto-discovered as `superpowers-on-steroids:caveman-{implementer,reviewer,final-reviewer,investigator}`.

Nothing existing is removed. Skills keep their inline `Subagent (general-purpose):` templates as the default. Fast mode is a **substitution table**, not a rewrite.

| Role | Standard path | Fast path |
|---|---|---|
| Implementer | `implementer-prompt.md` | `caveman-implementer` |
| Task reviewer | `task-reviewer-prompt.md` | `caveman-reviewer` |
| Final whole-branch review | `requesting-code-review/code-reviewer.md` | `caveman-final-reviewer` |
| Brainstorming context exploration | *(no dispatch guidance today)* | `caveman-investigator` |

**Governing rule, stated once:** roles without a shipped counterpart stay on the template path in *both* modes. That one sentence covers re-review, the spec-document reviewer, the plan-document reviewer, the Brainstormer, and fix subagents — no per-role exceptions, no invented agents.

### Edit sites

1. `skills/subagent-driven-development/SKILL.md` — one "Fast mode" block with the mapping table; plus one clause appended to the `BLOCKED` branch of `Handling Implementer Status`: *"…and, in fast mode, re-dispatch on the inline template path rather than the fast agent — its effort is pinned low and cannot be raised at dispatch."*
2. `skills/requesting-code-review/SKILL.md` — one sentence, so the standalone entry point honours fast mode too.
3. `skills/brainstorming/SKILL.md` — checklist step 2 gains one sentence dispatching `caveman-investigator` in fast mode.
4. `scripts/sync-to-codex-plugin.sh` + `scripts/package-codex-plugin.sh` — see Portability.

Prompt templates are **not edited**. Fast-mode logic concentrates in SKILL.md: one edit site per skill, tuned template bodies left byte-identical.

### Portability — two independent leak paths

`agents/` is top-level and would otherwise be copied into the embedded Codex plugin as inert dead weight (Codex has no agents mechanism).

- `scripts/sync-to-codex-plugin.sh` EXCLUDES gains anchored `"/agents/"`.
- `scripts/package-codex-plugin.sh:336` source-only archive guard gains `^agents/`. It currently lists `^\.agents/` — the dotted sibling — so the undotted directory passes silently.

**Patching only one ships the leak.**

### Frontmatter — settled

Effort stays as authored: `low` / `medium` / `high` / `high`. `high` is retained on the final reviewer for two reasons: effort has **no dispatch-time escape hatch**, so an unavailable higher value cannot be corrected; and raising a field-tested value without eval evidence is what this repo explicitly rejects. Trivially reversible if evals later justify it.

No role takes `model: inherit`. The pins (`sonnet`/`sonnet`/`opus`/`sonnet`) are defaults for **ad-hoc invocation only** — skill-driven dispatch always passes an explicit resolved model. `inherit` is the exact failure the tuned prose names: *"an omitted model silently inherits the session's most expensive one."*

### Accepted exposure

`caveman-reviewer`, `caveman-final-reviewer`, and `caveman-investigator` declare read-only behaviour in prose while holding `Bash`. `disallowedTools` is tool-granular, not command-granular, so this is unenforceable. **Identical to the exposure in today's inline templates — not a regression.** Recorded; unchanged.

Conversely the "you do not dispatch subagents" rule *is* already enforced mechanically — every agent's `tools:` allowlist excludes the Agent tool. That is why it is excluded from the drift assertions below.

---

## Unit B — Configuration

### Data flow

```
plugin.json userConfig declaration
  -> user configures (Claude Code dialog; user/managed scope)
  -> harness exports CLAUDE_PLUGIN_OPTION_<KEY> into the hook environment
  -> hooks/session-start reads, whitelists, validates
  -> appends a config block inside the escaped additionalContext string
  -> controller resolves tier->model at each dispatch, and template-vs-agent by mode
```

No JSON is parsed anywhere. The hook reads shell variables. Zero deps, no jq — consistent with the `SUPERPOWERS_DISABLE_TELEMETRY` precedent at `skills/brainstorming/scripts/server.cjs:108`.

### Schema — four keys

| Key | Env var | Type | Default | Meaning |
|---|---|---|---|---|
| `mode` | `CLAUDE_PLUGIN_OPTION_MODE` | string | `"standard"` | `standard` \| `fast` — selects agent set, and therefore effort |
| `model_cheap` | `CLAUDE_PLUGIN_OPTION_MODEL_CHEAP` | string | *(empty)* | Concrete model for the cheap tier |
| `model_standard` | `CLAUDE_PLUGIN_OPTION_MODEL_STANDARD` | string | *(empty)* | Concrete model for the standard tier |
| `model_capable` | `CLAUDE_PLUGIN_OPTION_MODEL_CAPABLE` | string | *(empty)* | Concrete model for the most-capable tier |

Keys are **snake_case deliberately**. They must satisfy `^[A-Za-z_]\w*$`, and the confirmed transform uppercases without inserting separators — so camelCase would collapse (`modelCheap` → `MODELCHEAP`). Snake_case survives it readably.

`mode` is a free-form string with a `default`, because the option schema is `.strict()` with no `enum` field. **Validation is the hook's job, not the schema's.**

### Why tiers, not roles

The tuned Model Selection prose (`subagent-driven-development/SKILL.md:154-186`) never names a concrete model — only tiers: *"a fast, cheap model"*, *"a standard model"*, *"the most capable available model"*, *"mid-tier as the floor for reviewers"*.

- The **heuristic** answers *which tier does this task need* — per-task, judgment, tuned.
- **Config** answers *what model is each tier on this machine* — static, per-user, mechanical.

Orthogonal questions, so no precedence rule is needed and no conflict is possible. A per-role knob (`implementer=haiku`) would collapse a per-task decision into a constant and collide with the reviewer floor; the tier framing makes that collision structurally impossible.

**Consequence: not one tuned sentence is rewritten.** Model Selection gains a single appended paragraph pointing at the config block for tier resolution, restating the already-present "always pass `model:` explicitly."

It also scales without new keys — fix subagents, the Brainstormer, the spec reviewer and the plan reviewer all resolve through the same three tiers.

### Effort is not configurable, and the surface says so

No `effort_*` key is declared. A knob wired to nothing is worse than an absent one. The honest surface is: **`mode` selects effort, tier keys select models.**

### Injected block

Data-only; semantics live in SKILL.md, which loads on demand.

```
<SUPERPOWERS_CONFIG>
mode: fast
tier models: cheap=<m> standard=<m> capable=<m>
</SUPERPOWERS_CONFIG>
```

Lines for unset tiers are omitted. **When nothing is configured, no block is emitted and the hook's output is byte-identical to today's.**

### Error handling

| Condition | Behaviour |
|---|---|
| All vars unset | No block; byte-identical output |
| Value fails `^[A-Za-z0-9._-]+$` | Silently dropped, as if unset |
| `mode` not `fast`/`standard` | Falls back to `standard` |
| Value contains `"`, newline, `$(…)` | Dropped by the whitelist before reaching the JSON string |
| Configured model doesn't exist | Out of scope — surfaced by the harness at dispatch |

Whitelist rather than escape. `escape_for_json` would technically handle quoting, but a positive-match filter makes corruption *impossible* rather than *handled*, and excludes nothing legitimate. The hook's three-way platform branch (Cursor / Claude Code / Copilot) is untouched.

### Scope limitation, accepted

`userConfig` resolves at **user/managed scope only** — project and `.local` entries are ignored by design. Fast mode is therefore machine-wide, not per-repository.

Accepted, because this is **not a one-way door**: the hook reads a shell variable, and where it originates sits behind a seam. If per-project demand appears, an env fallback is a `${SUPERPOWERS_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-standard}}`-shaped change — purely additive, no migration. **Preserve the seam; do not build the second surface now.**

---

## Unit C — Docs base dir

`git mv` throughout, so history follows:

- `docs/superpowers/plans/*` (15 files) → `docs/plans/` — merging with 4 pre-existing legacy docs; **zero filename collisions verified**.
- `docs/superpowers/specs/*` → `docs/specs/`.
- Remove the emptied `docs/superpowers/`.

**Historical bodies are not rewritten.** Project convention, not preference — `2026-05-05-platform-neutral-prose-design.md:25`: *"These are dated, point-in-time documents; rewriting them rewrites history."* Stale internal links inside moved artifacts stay intact. `RELEASE-NOTES.md` likewise untouched.

**Live references are rewritten** — 7 in skills, ~18 in tests:

- `skills/brainstorming/SKILL.md:33,125`
- `skills/brainstorming/spec-document-reviewer-prompt.md:7`
- `skills/writing-plans/SKILL.md:18,178`
- `skills/requesting-code-review/SKILL.md:60`
- `skills/subagent-driven-development/SKILL.md:334`
- `tests/explicit-skill-requests/` — 4 runner scripts, 5 fixture prompts
- `tests/claude-code/test-helpers.sh:152`
- `tests/claude-code/test-subagent-driven-development-integration.sh` (4 refs)

**Easy-to-miss case:** `tests/claude-code/test-worktree-path-policy.sh:12-13` reads two historical documents **by absolute path**. Those are live references *to* files that move, so the test breaks unless updated — even though the documents themselves stay frozen. Verified present.

Clean break, no dual-path fallback: "look in both locations" is exactly the conditional prose that degrades skill compliance. The resulting permanent divergence on 5 skill files widens the `scripts/sync-upstream` conflict surface — already-priced fork cost.

### Version and commit type

Per the repo's Conventional Commits rules, C changes where the plugin tells user projects to write plans and specs, **with no fallback**. For anyone mid-plan on this fork that breaks the contract, which on a standalone project would argue for `feat!:` → MAJOR.

**Decision (owner, superseding the above): ship as `feat:` → MINOR, 6.3.0 → 6.4.0.** This fork tracks upstream `obra/superpowers`, whose latest tag is v6.3.0, and `scripts/sync-upstream` rebases the customization layer onto it. Jumping to 7.0.0 would leapfrog the repo we rebase onto and make the fork's version meaningless as a signal of which upstream it carries. The breaking migration is communicated in `RELEASE-NOTES.md` instead of through the version number.

Flagged explicitly because commit type *is* the release decision here. Version lives in 9 files driven by `.version-bump.json`; use `scripts/bump-version.sh`.

---

## Testing strategy

Plain bash, `mktemp`, pass/fail counters — the existing idiom in `tests/hooks/test-session-start.sh` (225 lines). No new infrastructure. Tests may use `python3` for JSON validation (dev-only, as `sync-to-codex-plugin.sh` already does); **the hook itself stays bash + coreutils.**

**1. Drift tripwire — `tests/agents/test-fast-mode-contract.sh` (new).**

Governing principle for what counts as an invariant: **tokens the controller branches on, plus safety contracts.** Prose duplication is acceptable; contract divergence is not.

- *Implementer pair* (`implementer-prompt.md` ↔ `caveman-implementer.md`): the four status tokens `DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, `NEEDS_CONTEXT`; and the forbidden-git-command list (`git reset`, `git stash`, `git checkout --`, `git clean`, `git add .`, `git add -A`, `git commit -a`).
- *Reviewer pairs* (`task-reviewer-prompt.md` ↔ `caveman-reviewer.md`; `code-reviewer.md` ↔ `caveman-final-reviewer.md`): severity buckets `Critical`/`Important`/`Minor` and the verdict strings.
- The no-subagent rule is **excluded** — the `tools:` allowlist enforces it mechanically, so asserting the prose would test the wrong thing.

**2. Agent file validity** (same test, all four): `name` matches filename; `model` present and not `inherit`; `effort` is a named level or an integer; no `permissionMode`/`hooks`/`mcpServers`; `tools` excludes the Agent tool; file under 1 MiB.

**3. Hook config — extend `tests/hooks/test-session-start.sh`:**
- **Byte-identical when unset**, asserted against a baseline captured *before* the change lands. This is the eval-baseline guard and the single most important assertion in the change.
- Valid values → block present, values echoed correctly.
- Unrecognised `mode` → falls back to `standard`.
- Injection attempt (`"`, newline, `$(id)`) → dropped, JSON still parses.
- Output valid JSON across all three platform branches.
- Pins the `CLAUDE_PLUGIN_OPTION_<KEY>` casing transform.

**4. Codex leak — extend `tests/codex-plugin-sync/test-sync-to-codex-plugin.sh`:** assert no `agents/` path in the synced destination, and that the packaging guard covers `^agents/`.

**Explicitly not tested:** whether fast mode produces better or cheaper *outcomes*. That is an eval question for `evals/` via Drill. These tests verify the mechanism is wired and cannot silently rot — not that it helps.

---

## Decisions log

| # | Decision | Rationale |
|---|---|---|
| 1 | Three units, sequential commits | Independent risk profiles; overlapping skill files make parallel landing unsafe |
| 2 | Additive fast lane; templates remain default | An agent-first rewrite breaks 7 harness ports and invalidates the eval baseline — debt *with* a regression attached |
| 3 | Config schema is tier→model, not role→model | Tuned prose is already tier-based and names no model; role keys collapse a per-task decision into a constant |
| 4 | Model Selection gains one appended paragraph | Follows from #3 — orthogonal questions cannot conflict, so no precedence rule is needed |
| 5 | `mode` selects effort; config selects models | Frontmatter parsed before substitution, and no dispatch `effort` parameter exists |
| 6 | No `effort_*` config key | A knob wired to nothing is worse than an absent one |
| 7 | `userConfig` in `plugin.json` as the single surface | Literally the feature requested; values arrive as env vars, so still zero-parse |
| 8 | Accept user/managed-only scope | Tier preference belongs to the payer, not the repo; the seam makes a later env fallback purely additive |
| 9 | Whitelist `^[A-Za-z0-9._-]+$` | Makes JSON corruption impossible rather than handled |
| 10 | `mode` validated in the hook | Option schema is `.strict()` with no `enum` |
| 11 | Byte-identical output when unset, as an assertion | Preserves the eval baseline; makes unit B a true no-op by default |
| 12 | Ship all four agents under original names | User pointed at specific files; the "competing cavecrew family" concern was verified false |
| 13 | `caveman-investigator` wired to brainstorming step 2 only | Additive to an existing step with no dispatch guidance; SDD ⚠️-resolution rejected as scope creep |
| 14 | Roles without a counterpart stay on templates in both modes | One rule covers every remaining role; no per-role exceptions |
| 15 | Reactive BLOCKED handling for capable-tier tasks in fast mode | Reuses tuned machinery built for exactly this; a predictive gate adds a second classification to save one dispatch |
| 16 | Final reviewer stays at `effort: high` | No escape hatch if a higher value is unavailable; changing tuned values without evals is what this repo rejects |
| 17 | No `inherit` on any role | The tuned prose names it as the failure mode |
| 18 | Both Codex guards patched | Independent paths; patching one ships the leak |
| 19 | Drift invariants = controller-branched tokens + safety contracts | Separates acceptable prose duplication from unacceptable contract divergence |
| 20 | Docs: move only, merge into `docs/plans/`, clean break | Project convention; zero collisions verified; dual-path prose degrades compliance |
| 21 | **Proxy amendment:** no harness-availability guard clause in the fast-mode block | The design admitted it was non-load-bearing — config env vars never exist on other harnesses, so `mode` is never `fast` there. Adding a conditional clause would contradict #20's own rationale |
| 22 | **Proxy amendment:** env-name transform treated as confirmed, not an implementation unknown | Verified in the binary: `key.replace(/[^A-Za-z0-9_]/g,"_").toUpperCase()`. Still pinned by a test |

## Rejected alternatives

- **Agents become canonical, templates reduced to stubs** — breaks 7 harness ports, invalidates the eval baseline.
- **Ship `agents/` inert with no wiring** — a fast-mode claim with no mechanism behind it.
- **Route to externally-provided agents instead of shipping our own** — creates a cross-plugin dependency; CLAUDE.md forbids third-party dependencies outright.
- **Prose drift policy** ("re-derive when canonical changes") — comments rot silently; a test fails loudly.
- **Factor shared rules into one file both paths read** — destroys the compression that is fast mode's entire point.
- **Per-role model config (`implementer=haiku`)** — malformed knob; collides with the reviewer floor.
- **Config-overrides-heuristic / heuristic-clamps-config / rewrite Model Selection** — all three presuppose a conflict the tier framing eliminates.
- **Templated frontmatter (`model: ${user_config.x}`)** — frontmatter is parsed before substitution; yields a literal string, and an interpolated `effort` hard-fails validation.
- **Per-dispatch `effort` parameter** — does not exist in this runtime's Agent tool schema.
- **`enum` on the `mode` option** — no such field; `.strict()` would reject it.
- **JSON config file parsed in bash** — needs a parser this project has deliberately avoided.
- **`userConfig` for the dialog plus env as the real transport** — two surfaces for one setting, guaranteed drift. Seam preserved instead.
- **`SUPERPOWERS_DOCS_DIR`** — the user asked to change a default, not parameterise it.
- **Raising the final reviewer above `high`** — untested change to tuned content with no dispatch-time fallback.
- **A second `caveman-final-reviewer-max` agent** — the correct shape *if* higher effort is ever wanted; YAGNI until a session wants it.
- **Cutting `caveman-investigator`** — narrowing an explicit "add these agents" is deciding for the user.
- **Pre-emptive capable-tier gate in fast mode** — adds a predictive rule to tuned machinery to save one dispatch.
- **Rewriting `docs/superpowers/…` strings inside historical artifacts** — rewrites history; 30 files of churn against explicit convention.
- **Dual-path docs lookup for back-compat** — conditional prose that degrades skill compliance.
