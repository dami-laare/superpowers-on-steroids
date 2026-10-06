# Per-role model and effort configuration — design

**Date:** 2026-10-06
**Status:** approved (agent-team brainstorm; two decisions escalated to the project owner, marked below)
**Supersedes:** `2026-08-31-fast-mode-and-plugin-config-design.md` (tier config), `2026-09-24-agent-tier-enforcement-design.md` (tier gate)
**Release:** `feat!` — MAJOR bump to 7.0.0

## Problem

The plugin config shows four fields: `Execution mode`, `Cheap tier model`, `Standard tier model`, `Capable tier model`. Nothing tells the user which caveman agent a tier drives, and effort cannot be configured at all. The owner's requirement: set **model and effort per caveman agent type** (implementer, reviewer, investigator, final reviewer).

## Verified harness constraints (Claude Code docs, 2026-10-06)

- Agent frontmatter supports `model:` (`haiku|sonnet|opus|fable|inherit|<full id>`) and `effort:` (`low|medium|high|xhigh|max`). No variable substitution in frontmatter.
- The Agent tool input has **no `effort` field**. Effort is settable only in frontmatter.
- PreToolUse `updatedInput` can rewrite tool input but replaces the whole `tool_input` (requires re-serializing the prompt in bash). Not used here.
- Agent precedence: managed settings > `--agents` > `.claude/agents/` > `~/.claude/agents/` > plugin `agents/`. Not used here (hooks must not write into user directories).
- `userConfig` supports `type: string|number|boolean|directory|file` and an `options: [...]` array rendering a dropdown in `/config` (Claude Code ≥ 2.1.271). Options export as `CLAUDE_PLUGIN_OPTION_<UPPER_KEY>`.
- `settings.json` `modelSettings[<model>].effortLevel` / `maxEffortLevel` can clamp effort globally. Documented as a possible clamp, not integrated.

## Design

### Architecture

```
plugin.json userConfig ──► CLAUDE_PLUGIN_OPTION_<KEY>
SUPERPOWERS_<ROLE>_<FIELD> env ─┐
                                ▼
                 hooks/lib-config (single resolver: env → plugin option → builtin default)
                 ├──► hooks/session-start ──► <SUPERPOWERS_CONFIG> block (+ warnings)
                 ├──► hooks/agent-config-gate (PreToolUse Agent|Task, Claude Code only)
                 └──► scripts/gen-agent-variants (role list + builtin defaults)
agents-src/caveman-<role>.md (4 templates) ──gen──► agents/caveman-<role>-<effort>.md (12, checked in)
skills (SDD, requesting-code-review, brainstorming, re-review-prompt) read the block, dispatch variant by name
```

### 1. Config surface — `.claude-plugin/plugin.json` `userConfig`

Replace the four tier keys with ten role keys. Layout and defaults approved verbatim by the owner (**user decision**):

| Key | Title | Type | Default |
|---|---|---|---|
| `mode` | Execution mode | string, options `standard\|fast` | `standard` |
| `implementer_mechanical_model` | Implementer model (mechanical) | string | `haiku` |
| `implementer_judgment_model` | Implementer model (judgment) | string | `sonnet` |
| `implementer_effort` | Implementer effort | string, options `low\|medium\|high` | `low` |
| `reviewer_model` | Reviewer model | string | `sonnet` |
| `reviewer_effort` | Reviewer effort | string, options `low\|medium\|high` | `medium` |
| `investigator_model` | Investigator model | string | `sonnet` |
| `investigator_effort` | Investigator effort | string, options `low\|medium\|high` | `medium` |
| `final_reviewer_model` | Final reviewer model | string | `opus` |
| `final_reviewer_effort` | Final reviewer effort | string, options `low\|medium\|high` | `high` |

Every key ships with a **real default**, so a role is always configured. Each description states: (a) the fast-mode agent it drives (`caveman-<role>-*`), (b) the standard-mode inline template it drives, (c) the env override that wins. Effort descriptions add "fast mode only" and that `modelSettings.effortLevel` / `maxEffortLevel` in `settings.json` may clamp the value. Model fields are free text (alias or full model id); `config_value`'s `[A-Za-z0-9._-]` whitelist still applies.

Env overrides (win over plugin options): `SUPERPOWERS_MODE`, `SUPERPOWERS_IMPLEMENTER_MECHANICAL_MODEL`, `SUPERPOWERS_IMPLEMENTER_JUDGMENT_MODEL`, `SUPERPOWERS_IMPLEMENTER_EFFORT`, `SUPERPOWERS_REVIEWER_MODEL`, `SUPERPOWERS_REVIEWER_EFFORT`, `SUPERPOWERS_INVESTIGATOR_MODEL`, `SUPERPOWERS_INVESTIGATOR_EFFORT`, `SUPERPOWERS_FINAL_REVIEWER_MODEL`, `SUPERPOWERS_FINAL_REVIEWER_EFFORT`.

### 2. Resolver — `hooks/lib-config`

- `config_value` unchanged.
- `SP_ROLES="implementer reviewer investigator final-reviewer"`.
- Builtin defaults in one `case` table; values equal the plugin.json defaults (enforced by the wiring test).
- `sp_resolve_mode` prints `fast` or `standard`, never empty.
- `sp_role_model ROLE [mechanical|judgment]` — env → plugin option → builtin. Whitelist runs on each source; a rejected value falls through and records a warning.
- `sp_role_effort ROLE` — same order; value must be one of `low|medium|high`, else fall through + warning.
- `sp_config_warnings` — one line per rejected value, plus one line per legacy variable present (`SUPERPOWERS_MODEL_CHEAP|STANDARD|CAPABLE`, `CLAUDE_PLUGIN_OPTION_MODEL_CHEAP|STANDARD|CAPABLE`): `"<VAR> ignored since 7.0 — use SUPERPOWERS_<ROLE>_MODEL; see release notes"`. No mapping code.
- Delete `sp_resolve_tier`.

### 3. Injection — `hooks/session-start`

Always emits the full block, both modes, one code path:

```
<SUPERPOWERS_CONFIG>
mode: fast
implementer: mechanical=haiku judgment=sonnet effort=low
reviewer: model=sonnet effort=medium
investigator: model=sonnet effort=medium
final-reviewer: model=opus effort=high
</SUPERPOWERS_CONFIG>
```

Warnings appear as `warning: …` lines inside the block (controller relays them) and, on Claude Code, also as top-level `systemMessage`. Planning verifies SessionStart honours `systemMessage`; if not, the in-block line suffices. The three output shapes (Claude Code / Cursor / Copilot) are unchanged.

### 4. Gate — `hooks/agent-tier-gate` renamed `hooks/agent-config-gate`

Rename touches `hooks/hooks.json` and the shell-lint file set. Keeps the existing JSON parser and fail-open policy (non-Claude-Code harness, malformed JSON, non-caveman subagent → `exit 0`).

Algorithm:
1. `exit 0` unless `subagent_type` starts with `superpowers-on-steroids:caveman-`.
2. Match `caveman-(implementer|reviewer|investigator|final-reviewer)-(low|medium|high)`. No match → deny: "unknown caveman agent; dispatch caveman-<role>-<effort>, see <SUPERPOWERS_CONFIG>".
3. Build the allowed `(model, effort)` set per role from lib-config:
   - implementer: `{(mechanical_model, effort), (judgment_model, effort), (final_reviewer_model, high)}` — the third pair is the fix-loop round-3 escalation.
   - reviewer / investigator / final-reviewer: single pair.
4. `model` missing or null → deny, naming the allowed dispatch(es): `pass subagent_type "…caveman-reviewer-medium" with model "sonnet"`.
5. `(model, suffix)` not in the set → deny with the same message.
6. Otherwise allow.

Exact string comparison. Delete `tier_rank`, `builtin_rank`, `builtin_name`, floor logic. No `updatedInput`.

### 5. Agent variants

- Naming: `caveman-<role>-<effort>` (e.g. `caveman-final-reviewer-high`). `@` is invalid in agent names. Suffix after the last hyphen is from a fixed set, so parsing is unambiguous.
- Variant set `low|medium|high` for all four roles → 12 files (**user decision**; xhigh/max deferred to limit agent-list bloat).
- Templates in `agents-src/caveman-<role>.md` (outside `agents/`, so the harness never loads them). Placeholders: `{{EFFORT}}` in `name`, `effort:`, and the description tail. `model:` pinned to the role's builtin default (implementer → judgment default); it only matters where the gate does not run.
- Variant description = base description + "Effort: <e>. Dispatch only the variant matching <SUPERPOWERS_CONFIG>."
- `scripts/gen-agent-variants` (bash, zero deps) regenerates all 12 files and deletes any `agents/caveman-*.md` not in the generated set (removes the 4 bare-name files). Output checked in; nothing generated at runtime.

### 6. Skills (behaviour-shaping; eval evidence required per CLAUDE.md)

- `skills/subagent-driven-development/SKILL.md` "Model Selection": heuristics stay but choose mechanical vs judgment. Replace "Tier names resolve…" with "Roles resolve from <SUPERPOWERS_CONFIG>" plus: "Model names are Claude Code aliases; on other harnesses use the closest model this harness offers." Canonical table becomes `| Role | Fast-mode agent | Model | Effort | When |` with rows implementer (`caveman-implementer-<effort>`, model mechanical or judgment), reviewer, investigator, final-reviewer.
- SDD fix loop: round 3 dispatches with the final reviewer's model — fast mode `caveman-implementer-high`, standard mode inline implementer template. Delete the "effort cannot be raised at dispatch" sentence. Re-review uses the configured reviewer variant. Announce line always states the mode.
- `skills/requesting-code-review/SKILL.md`: `caveman-final-reviewer-<effort>` with the final reviewer model.
- `skills/brainstorming/SKILL.md`: `caveman-investigator-<effort>` with the investigator model.
- `skills/subagent-driven-development/re-review-prompt.md`: replace tier wording.
- Planning greps the repo for bare `caveman-<role>` references and `cheap|standard|capable` tier wording. `writing-plans` "Review tier" (transcription/judgment) is a different concept — untouched.

### 7. Docs and release

- README config section updated.
- Superseded specs get a short header note pointing here.
- Release notes carry the legacy mapping: cheap → implementer-mechanical; standard → implementer-judgment, reviewer, investigator; capable → final-reviewer.
- Commit `feat!:` with `BREAKING CHANGE:` footer → 7.0.0.

## Data flow (one fast-mode task)

1. Session start: lib-config resolves config; block injected.
2. Controller classifies the task as mechanical.
3. Dispatches `superpowers-on-steroids:caveman-implementer-low` with `model: haiku`.
4. Gate re-resolves from env, finds the pair in the allowed set, allows.
5. Reviewer dispatched as `caveman-reviewer-medium` on `sonnet`.
6. Fix round 3: `caveman-implementer-high` on `opus`, allowed via the escalation pair.

## Error handling

| Case | Behaviour |
|---|---|
| Invalid env/option value (whitelist or effort set) | Builtin default + warning line. Gate and session-start agree (same resolver). |
| Legacy variables present | Warning only; values ignored. |
| Unknown caveman name, missing model, pair mismatch | Deny, naming the exact correct dispatch. |
| Malformed hook JSON, non-Claude-Code harness, non-caveman subagent | Fail open (`exit 0`). |
| Bare `caveman-<role>` from a stale prompt | Deny naming the right variant. |
| Claude Code < 2.1.271 | `options` renders as free text; resolver validation still applies. |

## Testing strategy

All bash. One test-running agent at a time; controller runs the full `tests/` suite once at the end.

- **`tests/hooks/test-session-start.sh`:** precedence env > option > builtin for each of the 9 role fields; block always present with exact lines; invalid values → default + warning; legacy vars → warning; injection safety preserved; three output shapes.
- **`tests/hooks/test-agent-config-gate.sh`** (renamed): allow each role's pair; all 3 implementer pairs allowed; deny on wrong suffix, wrong model, missing/null model, unknown caveman name; escaped `"model"` inside the prompt not mistaken for the field; non-caveman passthrough; fail open on malformed JSON.
- **Wiring test** (replaces tier-table diff): role list and defaults agree across plugin.json, lib-config builtin table, generator role list, gate role regex, SDD canonical table rows.
- **Generator sync test** (new): generator into a temp dir `diff -r` identical to checked-in `agents/caveman-*`; exactly 12 caveman files, no bare names; each `name` equals filename stem; `effort:` equals suffix; `model:` pinned.
- **`tests/agents/test-fast-mode-contract.sh`:** rewritten for new table rows and env names; investigator `effort: medium` check becomes the per-variant effort/suffix check.
- **Evals:** if the drill harness in `evals/` is available, run a fast-mode SDD session before/after; verifier checks every caveman dispatch names a variant, each model matches the block, round-3 uses `-high` with the final reviewer's model, brainstorming acceptance test still auto-triggers. Otherwise record a manual fast-mode session transcript in the PR.

## Decisions log

1. Split into per-role model and per-role effort as separable components; both ship.
2. Effort mechanism: checked-in effort-variant agents — Agent tool has no effort field, frontmatter has no substitution.
3. Variant set `low|medium|high`, 12 files; xhigh/max deferred. **User decision.**
4. Skills dispatch the variant by name; gate denies mismatch; no `updatedInput`.
5. Bare-name agents deleted; fast mode reachable only via skills rewritten in this change.
6. Tiers deleted; config keyed by role. Models apply in both modes; effort fast-mode only.
7. Every key has a real default → always configured → gate has one path, no ranks/floors. Explicit user choice is authoritative.
8. Gate checks an allowed-pair set per role; implementer set includes the escalation pair.
9. Two implementer model keys, one implementer effort key; round 3 borrows the final reviewer's model with `-high`. **User decision** (layout).
10. Hard cut, `feat!` 7.0.0; legacy vars warn only; mapping in release notes; no fallback code.
11. Env names `SUPERPOWERS_<ROLE>_<MODEL|EFFORT>`; plugin keys same stems lowercase.
12. UI layout, labels, defaults as approved; `options` dropdowns for mode and effort. **User decision.**
13. Block always emitted in full, both modes.
14. Variant naming `caveman-<role>-<effort>`.
15. Templates in `agents-src/`, generated by `scripts/gen-agent-variants`, output checked in, sync test.
16. Gate renamed `agent-config-gate`.
17. Rejected values → builtin default + warning (block line + `systemMessage` on Claude Code).
18. Non-Claude-Code harnesses get the same defaults plus an alias-mapping sentence in SDD.
19. `modelSettings.effortLevel` / `maxEffortLevel` documented as a clamp, not integrated.

## Rejected alternatives

- Tiers alongside per-role keys — 13 fields, two overlapping systems; the exact confusion complained about.
- Tiers as aliases/defaults for roles — invisible indirection.
- `subagent_type` redirect via `updatedInput` — undocumented behaviour; whole-input re-serialization in bash.
- Writing agent files into `.claude/agents` / `~/.claude/agents` from a hook — mutates user dirs.
- Rewriting plugin agent files at SessionStart — mutates plugin cache; clobbered on update; load timing undocumented.
- Effort fields that silently do nothing — lie to the user.
- One implementer model — loses the main cost lever.
- Separate escalation-model key — YAGNI; final reviewer's model is the most capable configured.
- Env-only legacy fallback for one release — half-migration that cannot recover UI-set values.
- Description-only defaults — keeps the "unconfigured" gate branch alive.
- xhigh/max variants — deferred by the user.
- Runtime variant generation — drift and load-timing risk.
- Harness-aware defaults in the resolver — second code path for harnesses where fast mode does not run.
