# Agent Tier Enforcement — Design

## Problem

The tier-model configuration (`model_cheap` / `model_standard` / `model_capable`,
surfaced as `tier models:` in `<SUPERPOWERS_CONFIG>`) does not govern which model
the bundled `caveman-*` agents run on. A fast-mode session was observed running
`caveman-investigator` on sonnet at high effort regardless of config.

Evidence from 14 days of real Claude Code transcripts (dispatch `model` param
correlated with the model each subagent actually ran):

- The Agent tool's `model` param overrides agent frontmatter every time it is passed.
- When omitted, the frontmatter pin wins, config-blind. Omissions: 69 implementer,
  83 investigator dispatches. No skill gives the investigator a tier at all.
- 13 `caveman-reviewer` dispatches ran on haiku, violating the mid-tier reviewer floor.
- Effort is frontmatter-only: the Agent tool has no effort parameter. The
  investigator is pinned `effort: high`, contradicting fast mode's "lower
  reasoning effort" promise in `plugin.json`.
- The owner's `settings.json` sets `SUPERPOWERS_MODEL_CHEAP/STANDARD/CAPABLE`;
  `hooks/session-start` never reads them (it reads only `SUPERPOWERS_MODE` from env).

Claude Code facts that bound the design: no variable substitution in agent
frontmatter; no dispatch-time effort override; PreToolUse `updatedInput`
replaces the whole `tool_input` (no merge); model precedence is Agent `model`
param > frontmatter > `CLAUDE_CODE_SUBAGENT_MODEL` > session model.

## Approach

Prose rules alone already failed (SDD says "Always specify the model
explicitly" and was still skipped 69 times). So: one canonical tier table in
skill text for every harness, plus a Claude Code PreToolUse gate that denies a
config-blind or below-floor `caveman-*` dispatch with a message naming the exact
`model:` to pass. Bash only, zero dependency, fails open.

## Architecture

1. **`hooks/lib-config`** (new, sourced, bash 3.2 compatible) — the single
   config-precedence implementation, sourced by both hooks.
2. **`hooks/session-start`** (modified) — sources lib-config instead of its
   inline `config_value` and tier loop. Output unchanged except it now honours
   `SUPERPOWERS_MODEL_*`.
3. **`hooks/agent-tier-gate`** (new, extensionless) — Claude Code PreToolUse
   hook, registered in `hooks.json` with matcher `Agent|Task`, command
   `"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" agent-tier-gate`, `shell: bash`,
   `async: false`. Not registered in `hooks-cursor.json`.
4. **Text** — tier table in SDD, re-review tier change, one clause each in
   brainstorming and requesting-code-review, investigator `effort: medium`,
   `plugin.json` descriptions.

Other harnesses never run the gate (not registered / no Agent tool) or it exits
0 silently (`CURSOR_PLUGIN_ROOT` set, `COPILOT_CLI` set, or `CLAUDE_PLUGIN_ROOT`
unset).

## Components

### `hooks/lib-config`

- `config_value RAW` — moved verbatim. Whitelist `[A-Za-z0-9._-]`; prints
  nothing for empty or invalid input.
- `sp_resolve_mode` — `SUPERPOWERS_MODE` over `CLAUDE_PLUGIN_OPTION_MODE`;
  prints `fast` or nothing.
- `sp_resolve_tier NAME` (`cheap|standard|capable`) — non-empty
  `SUPERPOWERS_MODEL_<NAME>` wins over `CLAUDE_PLUGIN_OPTION_MODEL_<NAME>`;
  result passed through `config_value`.
- No `set -e`/`set -u`, no associative arrays, no `${v,,}`, no external commands.
  `# shellcheck shell=bash` directive.

### `hooks/agent-tier-gate`

Reads stdin with `IFS= read -r -d '' input` (builtin; ignores its end-of-input
return 1).

Policy (mirrors the canonical table):

| subagent_type | Tier(s) named on omission | Floor |
|---|---|---|
| `superpowers-on-steroids:caveman-implementer` | cheap and/or standard, whichever are configured | none |
| `superpowers-on-steroids:caveman-reviewer` | standard | standard |
| `superpowers-on-steroids:caveman-investigator` | standard | none |
| `superpowers-on-steroids:caveman-final-reviewer` | capable | capable |

Any other or missing `subagent_type` → allow.

**Omission rule:** deny when `model` is absent or `null` AND at least one tier
the message would name is configured. Nothing configured → frontmatter pin
applies; that is the designed default.

**Floor rule** (runs when a floor exists and `model` is present):
`rank(v)` = when the floor tier itself is configured, the highest tier index
(cheap=1, standard=2, capable=3) whose configured value equals `v`; otherwise,
or when nothing matches, built-in haiku=1, sonnet=2, opus=3; else unknown →
allow. Deny when `rank(model) < floor`. The named model is the floor tier's
configured value, else the built-in name for that rank. (Ranking against a
configured lower tier while the floor tier is unconfigured could deny the very
built-in name the gate tells the caller to pass — e.g. `cheap=sonnet` with no
standard tier would loop a reviewer on sonnet.)

**Deny output:** exit 0, `printf` (no heredoc — bash 5.3 hang, issue #571):
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}`.
The reason is built only from fixed text and whitelisted config values; the
caller's raw `model` is never echoed, so no JSON escaping is needed.

**Allow output:** nothing, exit 0.

Deny wording (one or two sentences):

- `caveman-reviewer runs config-blind without model: pass model: "sonnet" (standard tier) on this Agent call.`
- `caveman-implementer runs config-blind without model: pass model: "haiku" (cheap — transcription/single-file) or "sonnet" (standard — integration/judgment).` — configured tiers only.
- `caveman-final-reviewer needs the capable tier or higher: pass model: "opus".`

### Text changes

- **SDD Model Selection:** canonical four-row table (agent, tier, floor, when)
  and the rule that every `superpowers-on-steroids:caveman-*` dispatch passes
  `model:` resolved from `<SUPERPOWERS_CONFIG>`. The Fast Mode sentence "Model
  selection is unchanged…" points at the table.
- **Re-review tier, fast mode only:** standard tier via `caveman-reviewer` in
  the Fix Loop "After every round" paragraph, the Model Selection re-review
  line, and `re-review-prompt.md`. The standard-mode inline template path stays
  cheap-to-mid.
- **brainstorming step 2:** "… `caveman-investigator` on the standard tier (see
  subagent-driven-development Model Selection)".
- **requesting-code-review:** "… `caveman-final-reviewer` on the capable tier
  (see subagent-driven-development Model Selection)".
- **`agents/caveman-investigator.md`:** `effort: medium`.
- **`plugin.json`** each `model_*` description: env override
  (`SUPERPOWERS_MODEL_<TIER>`, env wins) and "on Claude Code this must be an
  Agent-tool model alias (e.g. haiku / sonnet / opus)".

## Data flow: JSON handling in bash

1. Read stdin; empty → allow.
2. Environment guard (Cursor / Copilot / no plugin root) → allow.
3. Segment walk: `IFS= read -r -d '"' seg` over a here-string yields the text
   between consecutive quotes. Segments alternate structural, string,
   structural… Inside a string, a quote preceded by an odd run of backslashes
   is escaped and the string continues; an even run (including `\\"`, an
   escaped backslash then the real closing quote) closes it. So prompt text
   like `\"model\": \"haiku\"` can never look like a key. String content is
   accumulated only up to 256 characters — keys and model names are short, and
   the cap keeps prompts full of escaped quotes linear.
   (Prototyping showed bash 3.2's `${s#*\"}` and friends go quadratic — ~1 s
   at 40 KB — while `read -d` stays linear: a 132 KB payload with 8,000
   escaped quotes runs in under a second on macOS `/bin/bash` 3.2.)
4. Track brace depth from structural segments (`{`/`[` vs `}`/`]`). A string
   is a key when the next structural segment starts with optional whitespace
   then `:`. Its value is the next string when the separating structural
   segment is only `:` plus whitespace; a literal `null` there means omitted;
   any other non-string value is ambiguous. Keys count only at depth 2 inside
   the depth-1 `tool_input` object; stop when depth returns to 1.
5. Ambiguity → allow: no `tool_input`, duplicate key inside it, unbalanced walk,
   end of input inside a string.
6. Resolve tiers via lib-config; apply omission rule, then floor rule.

## Error handling

Fail open everywhere. No `set -e`/`set -u`; every path ends `exit 0`; never
`exit 2`. An unexpected abort exits non-zero but not 2, which Claude Code treats
as a non-blocking error — a broken gate can never block dispatch. Windows
without bash: `run-hook.cmd` already exits 0. Garbage config is filtered by
`config_value` and counts as unconfigured. Unknown models are allowed. A
configured non-alias value is documented user error (not detectable without a
hardcoded alias list).

## Testing

**New `tests/hooks/test-agent-tier-gate.sh`** — `env -i`, real JSON payloads,
node (tests only) validates output. Deny → valid JSON, `permissionDecision:
"deny"`, reason names the expected model. Allow → empty stdout, exit 0. Cases:

1. Escaped `"model": "haiku"` inside the prompt, no real model, tier configured → deny.
2. Real model at tier → allow.
3. Nothing configured, model omitted → allow.
4. Reviewer on haiku, with config (cheap=haiku) and without (built-in rank) → deny naming standard.
5. Final-reviewer on sonnet → deny naming capable.
6. Unknown model → allow.
7. Non-caveman `subagent_type`, and missing `subagent_type` → allow.
8. `CURSOR_PLUGIN_ROOT` / `COPILOT_CLI` / no `CLAUDE_PLUGIN_ROOT` → allow.
9. Malformed stdin, empty stdin, duplicate `model` key → allow.
10. `"model": null` → treated as omitted.
11. Implementer with only cheap configured → deny names cheap only.
12. `standard=capable=opus`, final-reviewer on opus → allow.
13. Env over option: `SUPERPOWERS_MODEL_STANDARD` differs from option → deny names env value.
14. `\\"` at a prompt string's end → walk stays in sync.
15. ~100 KB prompt → completes within a generous bound.

Plus: `hooks.json` has a PreToolUse entry with matcher `Agent|Task`, `shell:
"bash"`, command running `run-hook.cmd agent-tier-gate`; `hooks-cursor.json`
does not register it.

**`tests/hooks/test-session-start.sh`:** `SUPERPOWERS_MODEL_*` emitted; env
beats option; empty env falls back to option; whitelist-failing env value dropped.

**`tests/agents/test-fast-mode-contract.sh`:** investigator `effort: medium`;
each caveman agent appears in the SDD tier table with its tier, and the gate's
`case` carries the same agent→tier pairs (table and enforcer cannot drift);
brainstorming and requesting-code-review clauses name their tier; SDD fast-mode
re-review says standard.

**`tests/shell-lint/`:** its file set covers `hooks/agent-tier-gate` and
`hooks/lib-config`.

## Decisions log

- Matcher `Agent|Task` — covers the legacy name; non-matching names cost nothing.
- Enforcement keyed on `subagent_type`, not mode — omission is config-blind in both modes; gate never reads mode.
- One `hooks/lib-config` — single precedence implementation, no drift between hooks.
- Non-empty env wins over plugin option — mirrors `SUPERPOWERS_MODE`; fixes the owner's inert `SUPERPOWERS_MODEL_*`.
- `caveman-reviewer` ≥ standard always, including re-review — one enforceable invariant, no spoofable marker; SDD's "turn count beats token price". Text change scoped to fast mode.
- Implementer: no floor, no ceiling — tier is per-task judgment the gate cannot see; evidence shows legitimate opus runs.
- Investigator standard without floor; final-reviewer capable with capable floor — final review is the last gate; no evidence of cheap-investigator misuse.
- Omission denied only when a named tier is configured — unconfigured frontmatter pin is the designed default.
- Floor always runs: configured values, then haiku < sonnet < opus, unknown allowed — catches haiku reviewers without config and asserts nothing about other aliases.
- Shared value ranks at its highest tier — `standard=capable=opus` satisfies the capable floor.
- `read -d '"'` segment walk with backslash-parity escape detection — exact `tool_input` slice, linear on bash 3.2 (the parameter-expansion walk agreed in dialogue measured quadratic in prototyping).
- Floor ranks against configured tiers only when the floor tier is configured — prevents a deny loop on the built-in name the gate itself suggests.
- Exit 0 + structured deny, never exit 2, fail open — a broken enforcer must never block dispatch.
- Raw passed model never echoed — reason contains only fixed text and whitelisted values.
- Tier table once in SDD; other skills reference it.
- Investigator effort high → medium — fast mode promise; effort not overridable at dispatch.
- `plugin.json` documents the alias requirement — alias set is harness-defined.

## Rejected alternatives

- Pure skill-text rule — already existed and was skipped 69 times.
- `updatedInput` rewrite — replaces the whole `tool_input`; unsafe to rebuild in bash.
- `model: inherit` frontmatter — omission would inherit the session model (usually opus), costlier than today.
- Re-review marker in `description` — fragile, spoofable string contract.
- Presence-only gate, no floor — leaves the observed haiku-reviewer violations unenforced.
- Deny omission without config — friction where nothing is wrong.
- Per-character bash tokenizer — O(n²)-prone on bash 3.2, more code.
- Global `${s//\\\\/}` strip + `${s%%\"*}`/`${s#*\"}` walk — measured quadratic on bash 3.2.
- jq when present, else fail open — machine-dependent behaviour; breaks zero-dependency.
- Hardcoded alias list — goes stale (`fable` already proves it).
- `fable` or other aliases in the built-in rank — their order relative to opus is not ours to assert.
- Tier table copied into each skill — drift.
- Registering in `hooks-cursor.json` — no Agent tool, no PreToolUse contract.
- Exit 2 + stderr — less structured; conflates with debug output.
- Effort-variant agents (`caveman-investigator-deep`) — more surface; medium covers the need.
