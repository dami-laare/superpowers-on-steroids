# Blitz Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-on-steroids:subagent-driven-development (recommended) or superpowers-on-steroids:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mode: blitz`. It runs every plan task at once in file-ownership lanes, then one integration pass, then a mandatory final review.

**Architecture:**
- Config accepts the new mode value. No new role or key is added.
- A new deterministic script, `plan-lanes`, partitions a plan into lanes using union-find over file paths, and writes the lane briefs and a commit map.
- The implementer agent gains a blitz-lane clause.
- The SDD skill gets a `## Blitz Mode` section that replaces the wave loop.
- writing-plans, brainstorming and requesting-code-review treat blitz as a superset of ultra.

**Tech Stack:** bash 3.2, POSIX awk, markdown skills, node (existing test harness only).

**Spec:** `docs/specs/2026-11-05-blitz-mode-design.md`

## Global Constraints

- Shell is bash 3.2, as macOS ships it. Use POSIX awk only, as `/usr/bin/awk` on macOS runs it. Do not use gawk extensions: no `asort`, `gensub`, `PROCINFO` or arrays of arrays.
- No new dependencies: no jq, yq or gawk. Do not install anything.
- Sort with `LC_ALL=C sort`, so output is byte-identical across machines.
- Run tests with `bash <file>`. Only ONE agent runs tests at a time. Implementers in a parallel wave do NOT run test suites: they write code and tests, then report the Run commands as "left to controller". The controller runs each task's listed suites itself, one suite at a time, and resumes the implementer with any failures. Implementers may still run non-test checks: `grep`, `scripts/lint-shell.sh` and `scripts/gen-agent-variants`.
- Every commit uses Conventional Commits and an explicit pathspec: `git commit -m "msg" -- paths`.
- Skill prose says "your human partner", never "the user".
- The release version is `7.2.0`, and the release date is `2026-11-05`.
- Agents in `agents/` are generated files. Edit `scripts/agent-templates/caveman-implementer.md`, then run `scripts/gen-agent-variants`. Never hand-edit `agents/*.md`.

## Execution Waves

- Wave 1: Tasks 1, 2, 3, 4 (no dependencies, disjoint files)
- Wave 2: Tasks 5, 6, 8 (8 depends on 1)
- Wave 3: Task 7 (contract test, depends on 1, 3, 4, 5, 6)

---

### Task 1: Accept `mode: blitz` in config

**Files:**
- Modify: `hooks/lib-config:54`
- Modify: `.claude-plugin/plugin.json:17-28`
- Test: `tests/hooks/test-plugin-config.sh`
- Test: `tests/hooks/test-session-start.sh`

**Depends on:** none

**Review tier:** transcription

**Interfaces:**
- Consumes: none
- Produces:
  - With `CLAUDE_PLUGIN_OPTION_MODE=blitz` or `SUPERPOWERS_MODE=blitz`, the session-start hook emits `mode: blitz` in `<SUPERPOWERS_CONFIG>`. The role lines are unchanged, and there is no warning.
  - `.claude-plugin/plugin.json` has `userConfig.mode.options` equal to `["standard","fast","ultra","blitz"]`.

- [ ] **Step 1: Write the failing tests**

In `tests/hooks/test-plugin-config.sh`, replace the line

```js
if (JSON.stringify(cfg.mode.options) !== JSON.stringify(["standard","fast","ultra"])) fail("mode.options");
```

with

```js
if (JSON.stringify(cfg.mode.options) !== JSON.stringify(["standard","fast","ultra","blitz"])) fail("mode.options");
if (!cfg.mode.description.includes("blitz (experimental)")) fail("mode.description lacks blitz (experimental)");
```

In `tests/hooks/test-session-start.sh`, insert this block directly after the `ultra_home` block (the one ending `CLAUDE_PLUGIN_OPTION_MODE=ultra \` / `bash "$HOOK_UNDER_TEST"`):

```bash
blitz_home="$(make_home config-blitz)"
assert_command_output \
    "mode=blitz emits mode: blitz with role lines unchanged" \
    "nested" \
    "<SUPERPOWERS_CONFIG>"$'\n'"mode: blitz"$'\037'"implementer: mechanical=haiku judgment=sonnet effort=low"$'\037'"test-writer: model=sonnet effort=low" \
    "warning:" \
    "$blitz_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=blitz \
    bash "$HOOK_UNDER_TEST"
```

Then insert this block directly after the `env_ultra_home` block:

```bash
env_blitz_home="$(make_home config-env-blitz)"
assert_command_output \
    "SUPERPOWERS_MODE=blitz wins over an ultra plugin option" \
    "nested" \
    "<SUPERPOWERS_CONFIG>"$'\n'"mode: blitz" \
    "mode: ultra" \
    "$env_blitz_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PLUGIN_OPTION_MODE=ultra \
    SUPERPOWERS_MODE=blitz \
    bash "$HOOK_UNDER_TEST"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/hooks/test-plugin-config.sh; bash tests/hooks/test-session-start.sh`
Expected: FAIL. The first suite fails on `mode.options`. The second fails the two blitz cases with `mode: standard`, because `blitz` is not whitelisted yet.

- [ ] **Step 3: Implement**

In `hooks/lib-config`, change

```bash
        mode) case "$val" in standard|fast|ultra) printf '%s' "$val" ;; esac ;;
```

to

```bash
        mode) case "$val" in standard|fast|ultra|blitz) printf '%s' "$val" ;; esac ;;
```

In `.claude-plugin/plugin.json`, make two edits to `userConfig.mode`.

Change the `options` array to:

```json
      "options": [
        "standard",
        "fast",
        "ultra",
        "blitz"
      ],
```

In `description`, replace the substring `TDD RED evidence is dropped for those tasks. Env override:` with `TDD RED evidence is dropped for those tasks. blitz (experimental) = every task at once in file-ownership lanes, no per-task tests or review, one integration pass and a mandatory final review; not for migrations with backfills or auth-critical work. Env override:`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/hooks/test-plugin-config.sh; bash tests/hooks/test-session-start.sh; bash tests/hooks/test-config-wiring.sh`
Expected: all three PASS. config-wiring is unchanged and stays green, because mode is not a role.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib-config .claude-plugin/plugin.json tests/hooks/test-plugin-config.sh tests/hooks/test-session-start.sh
git commit -m "feat(config): accept mode: blitz" -- hooks/lib-config .claude-plugin/plugin.json tests/hooks/test-plugin-config.sh tests/hooks/test-session-start.sh
```

### Task 2: `plan-lanes` script

**Files:**
- Create: `skills/subagent-driven-development/scripts/plan-lanes`
- Test: `tests/claude-code/test-plan-lanes.sh`
- Test: `tests/codex/test-package-codex-plugin.sh`

**Depends on:** none

**Review tier:** judgment

**Interfaces:**
- Consumes:
  - `skills/subagent-driven-development/scripts/sdd-workspace PLAN` prints the plan's workspace directory.
  - `skills/subagent-driven-development/scripts/task-brief PLAN N OUTFILE` writes task N's text to OUTFILE.
- Produces: `plan-lanes PLAN_FILE [MAX_LANES]`, an executable bash script.
  - **Exit 0 (success).** It writes `<workspace>/lanes.md` and one `<workspace>/lane-<X>-brief.md` per lane, after first deleting stale `lane-*-brief.md` files. stdout gets one `lane <X>: tasks <n> <n> ...` line per lane, then `wrote <workspace>/lanes.md`.
  - **Exit 2.** Bad usage: no arguments, more than 2 arguments, a missing plan file, or MAX_LANES outside the integers 1–26.
  - **Exit 3.** A task lacks a `**Interfaces:**` block with both a `- Consumes:` line and a `- Produces:` line. stderr names the task, e.g. `Task 2`.
  - **Exit 4.** `## Global Constraints` lacks a `typecheck:` line or a `unit:` line. stderr names the missing key, as `typecheck:` or `unit:`.
  - **Exit 5.** A Depends-on cycle among one lane's tasks. stderr contains `cycle`.
  - On exits 2–5, it writes no `lanes.md` and no lane briefs. Output is byte-identical across runs.

**Behaviour (exact rules):**

1. **Task boundaries.** Use task-brief's rule. Toggle fence state on lines matching `^```` `. Outside a fence, a line matching `^#+[ \t]+Task[ \t]+[0-9]+` starts task N, where N is the first integer after `Task`.
2. **Files.** Within a task and outside fences, read every line matching `^[[:space:]]*- (Create|Modify|Test):[[:space:]]*`.
   - The path is the text between the first two backticks.
   - Strip a trailing `:<digits>` or `:<digits>-<digits>`.
   - Drop leading `./` (repeatedly), collapse runs of `/`, and drop a trailing `/`.
   - The path is **shared** if the text after the closing backtick contains `(shared)` on ANY task's line for that path.
3. **Depends on.** On the task line starting `**Depends on:**`, every integer that is a task number in the plan (other than the task itself) is an edge `dep → task`.
4. **Interfaces.** Outside fences, the task must have a line starting `**Interfaces:**`, a line matching `^[[:space:]]*- Consumes:`, and a line matching `^[[:space:]]*- Produces:`. Otherwise exit 3, naming `Task N`.
5. **Commands.** In `## Global Constraints` (up to the next `## ` heading), read one line per key, with an optional leading `- `:
   - `typecheck:` followed by `` `cmd` `` or the word `none`;
   - `unit:` followed by `` `cmd` ``.

   A missing line means exit 4.
6. **Union-find.** Tasks that share any path that is not shared form one component.
7. **Component order.** Sort components by task count descending, then by lowest task number ascending.
8. **Packing.**
   - Each of the first MAX_LANES components opens lanes A, B, C and so on.
   - Every later component joins a lane whose prefix set intersects its own. Prefix sets are built from non-shared paths only. A prefix is the first two `/`-segments of a path, or the whole path if it has fewer than two segments. Among matching lanes, it joins the one with the fewest tasks, with ties going to the lowest letter.
   - If no lane matches, the component joins the lane with the fewest tasks, ties to the lowest letter.
9. **Lane order.** Within a lane, order tasks topologically on edges between tasks of that lane. Among ready tasks, pick the lowest task number first. A leftover cycle means exit 5.
10. **Shared owner.** A shared path is owned by the lane of the lowest-numbered task listing it.
11. **Allowlist.** A lane's allowlist is the non-shared paths of its tasks plus the shared paths it owns, deduplicated and `LC_ALL=C` sorted.
12. **Commit map.**
    - Each path belongs to the commit of the highest-numbered task listing it.
    - A task's message is the text between the quotes on the first line in the task containing `git commit -m "`. With no such line, use `<none — controller writes>`.
    - A task that ends up with no paths is `folded into Task M`, where M is the task that commits the task's first listed path.

**Output formats (exact):**

`lanes.md`:

```text
# Blitz lanes — <plan basename without .md>

- typecheck: `<cmd>`          (or "- typecheck: none")
- unit: `<cmd>`

## Lanes

| Lane | Tasks | Files | Owns shared |
|---|---|---|---|
| A | 2, 1 | 4 | `pkg/index.ts` |
| B | 4, 5 | 1 | - |

## Commit map

| Task | Message | Paths |
|---|---|---|
| 1 | feat(a): util | `pkg/a/test/util.test.ts` |
| 4 | folded into Task 5 | - |
```

Here are the column rules:

- **Tasks** lists tasks in lane order, joined by `, `.
- **Files** is the allowlist count.
- **Owns shared** lists the owned shared paths, each in backticks and space-separated and sorted, or `-` when there are none.
- **Commit map** rows go in task-number order.
- **Paths** lists the paths, each in backticks and space-separated and sorted, or `-` for a folded task.

`lane-<X>-brief.md`, with sections in this order. Omit `## Do not touch` and `## Shared-file duties` when they would be empty.

```text
# Blitz lane A — Tasks 2, 1 (in this order)

## Allowlist

- `pkg/a/src/extra.ts`
- `pkg/index.ts`

## Do not touch

- `pkg/index.ts` is owned by lane A; skip your task's edits to it.

## Tasks

<task-brief output for each task, in lane order, separated by a blank line>

## Shared-file duties

Reference only — apply ONLY the edits to `pkg/index.ts`; do not touch any other file these tasks list.

<task-brief output of every task in ANOTHER lane that lists that path, in task order>
```

Repeat the duties heading line and its tasks once per owned shared path that has foreign tasks. A lane's `## Do not touch` lists each shared path that one of its tasks names but another lane owns.

- [ ] **Step 1: Write the failing tests**

Create `tests/claude-code/test-plan-lanes.sh`. The fixtures write `@@@` where a markdown fence belongs, and `write_plan` turns it into a fence. Do not put literal fence lines in this file.

```bash
#!/usr/bin/env bash
# Tests for scripts/plan-lanes: blitz-mode partition of a plan into
# file-ownership lanes, lane briefs, and the commit map.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SDD_SCRIPTS="$REPO_ROOT/skills/subagent-driven-development/scripts"
PLAN_LANES="$SDD_SCRIPTS/plan-lanes"

FAILURES=0
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

contains() {
    if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1"; echo "    missing: $3"; fi
}
lacks() {
    if grep -qF -- "$3" "$2"; then fail "$1"; echo "    unexpected: $3"; else pass "$1"; fi
}
has_line() {
    if grep -qxF -- "$3" "$2"; then pass "$1"; else fail "$1"; echo "    missing line: $3"; fi
}
lacks_line() {
    if grep -qxF -- "$3" "$2"; then fail "$1"; echo "    unexpected line: $3"; else pass "$1"; fi
}
same_text() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1"; echo "    want: $3"; echo "    got:  $2"; fi
}
expect_exit() {
    local label="$1" want="$2" token="$3"
    shift 3
    local rc=0 err
    err="$(cd "$REPO" && "$@" 2>&1 >/dev/null)" || rc=$?
    if [[ "$rc" -eq "$want" && "$err" == *"$token"* ]]; then
        pass "$label"
    else
        fail "$label"
        echo "    exit $rc (want $want); stderr: $err"
    fi
}
line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

git init -q -b main "$TEST_ROOT/repo"
REPO="$(cd "$TEST_ROOT/repo" && git rev-parse --show-toplevel)"
WS="$REPO/.superpowers/sdd"

write_plan() { sed 's/^@@@/```/' > "$REPO/$1"; }
run_lanes() { (cd "$REPO" && "$PLAN_LANES" "$@"); }

gc_both() {
    printf '# Plan\n\n## Global Constraints\n\n- typecheck: `true`\n- unit: `true`\n\n'
}
simple_task() {
    printf '### Task %s: T%s\n\n**Files:**\n- Modify: `%s`\n\n**Depends on:** %s\n\n' "$1" "$1" "$2" "$3"
    printf '**Interfaces:**\n- Consumes: none\n- Produces: `t%s()` returns %s\n\n' "$1" "$1"
}

echo "=== Test: plan-lanes ==="

# --- main fixture: union, normalisation, topo order, shared owner, commit map ---
write_plan main.md <<'PLAN'
# Main plan

## Global Constraints

- typecheck: `npx tsc --noEmit`
- unit: `npx vitest run --maxWorkers=2`

## Execution Waves

- Wave 1: Tasks 2, 3, 4

---

### Task 1: Util

**Files:**
- Create: `pkg/a/src/util.ts`
- Test: `pkg/a/test/util.test.ts`

**Depends on:** 2

**Interfaces:**
- Consumes: `extra(): string` from Task 2
- Produces: `util(): number` returns 1

@@@bash
git commit -m "feat(a): util"
@@@

### Task 2: Extra

**Files:**
- Modify: `./pkg/a/src/util.ts:10-20`
- Create: `pkg/a/src/extra.ts`
- Modify: `pkg/index.ts` (shared)

**Depends on:** none

**Interfaces:**
- Consumes: none
- Produces: `extra(): string` returns "x"

@@@bash
git commit -m "feat(a): extra"
@@@

### Task 3: B module

**Files:**
- Create: `pkg/b/src/b.ts`
- Modify: `pkg/index.ts` (shared)

**Depends on:** 2

**Interfaces:**
- Consumes: `extra(): string`
- Produces: `b(): string` returns "b"

### Task 4: C module

**Files:**
- Create: `pkg/c/src/c.ts`

**Depends on:** none

**Interfaces:**
- Consumes: none
- Produces: `c(): number` returns 3

### Task 5: C tweak

**Files:**
- Modify: `pkg/c/src/c.ts`

**Depends on:** 4

**Interfaces:**
- Consumes: `c(): number`
- Produces: `c()` returns 4

@@@bash
git commit -m "fix(c): tweak"
@@@
PLAN

out="$(run_lanes main.md)" || { fail "main fixture exits 0"; out=""; }
d="$WS/main"
same_text "stdout lists lanes then lanes.md" "$out" "$(printf 'lane A: tasks 2 1\nlane B: tasks 4 5\nlane C: tasks 3\nwrote %s/lanes.md' "$d")"

L="$d/lanes.md"
has_line "lanes.md title" "$L" "# Blitz lanes — main"
has_line "typecheck command" "$L" '- typecheck: `npx tsc --noEmit`'
has_line "unit command" "$L" '- unit: `npx vitest run --maxWorkers=2`'
has_line "lane A row (union via range strip + ./, topo order, owns shared)" "$L" '| A | 2, 1 | 4 | `pkg/index.ts` |'
has_line "lane B row" "$L" '| B | 4, 5 | 1 | - |'
has_line "lane C row (shared path not owned)" "$L" '| C | 3 | 1 | - |'
has_line "commit map: task 1 keeps only its last-touched path" "$L" '| 1 | feat(a): util | `pkg/a/test/util.test.ts` |'
has_line "commit map: task 2 takes util.ts as last toucher" "$L" '| 2 | feat(a): extra | `pkg/a/src/extra.ts` `pkg/a/src/util.ts` |'
has_line "commit map: shared file goes to last toucher; no message" "$L" '| 3 | <none — controller writes> | `pkg/b/src/b.ts` `pkg/index.ts` |'
has_line "commit map: folded task" "$L" '| 4 | folded into Task 5 | - |'
has_line "commit map: task 5" "$L" '| 5 | fix(c): tweak | `pkg/c/src/c.ts` |'

A="$d/lane-A-brief.md"
has_line "lane A header" "$A" "# Blitz lane A — Tasks 2, 1 (in this order)"
has_line "lane A allowlist has owned shared path" "$A" '- `pkg/index.ts`'
has_line "lane A allowlist has normalised util path" "$A" '- `pkg/a/src/util.ts`'
lacks "lane A allowlist has no range suffix" "$A" '- `pkg/a/src/util.ts:10-20`'
t2="$(line_of "$A" "### Task 2: Extra")"
t1="$(line_of "$A" "### Task 1: Util")"
if [[ -n "$t2" && -n "$t1" && "$t2" -lt "$t1" ]]; then pass "lane A tasks in topo order (2 before 1)"; else fail "lane A tasks in topo order (2 before 1)"; fi
contains "lane A has shared-file duties" "$A" "## Shared-file duties"
contains "duties heading" "$A" 'Reference only — apply ONLY the edits to `pkg/index.ts`; do not touch any other file these tasks list.'
contains "duties carry foreign task text" "$A" "### Task 3: B module"
lacks "owner lane has no do-not-touch" "$A" "## Do not touch"

C="$d/lane-C-brief.md"
has_line "lane C do-not-touch line" "$C" '- `pkg/index.ts` is owned by lane A; skip your task'"'"'s edits to it.'
lacks_line "lane C allowlist excludes shared path" "$C" '- `pkg/index.ts`'
lacks "lane C has no duties" "$C" "## Shared-file duties"
contains "lane C carries its task" "$C" "### Task 3: B module"

# --- determinism ---
cp "$L" "$TEST_ROOT/lanes.1"
cp "$A" "$TEST_ROOT/laneA.1"
run_lanes main.md >/dev/null
if cmp -s "$L" "$TEST_ROOT/lanes.1" && cmp -s "$A" "$TEST_ROOT/laneA.1"; then
    pass "two runs produce byte-identical output"
else
    fail "two runs produce byte-identical output"
fi

# --- task-brief keeps the (shared) suffix verbatim ---
(cd "$REPO" && "$SDD_SCRIPTS/task-brief" main.md 2 "$TEST_ROOT/t2.md" >/dev/null)
has_line "task-brief preserves (shared)" "$TEST_ROOT/t2.md" '- Modify: `pkg/index.ts` (shared)'

# --- cap packing with prefix preference (MAX_LANES=2) ---
{
    gc_both
    simple_task 1 web/ui/x.ts none
    simple_task 2 svc/api/y.ts none
    simple_task 3 svc/api/z.ts none
    simple_task 4 svc/api/w.ts none
    simple_task 5 docs/z.md none
} | write_plan pack.md
out="$(run_lanes pack.md 2)" || out=""
same_text "packing prefers prefix match, else fewest tasks" "$out" "$(printf 'lane A: tasks 1 5\nlane B: tasks 2 3 4\nwrote %s/lanes.md' "$WS/pack")"

# --- re-run with fewer lanes: stale briefs removed, no-match component joins fewest-tasks lane ---
out="$(run_lanes main.md 2)" || out=""
same_text "main with MAX_LANES=2 folds lane C into A" "$out" "$(printf 'lane A: tasks 2 1 3\nlane B: tasks 4 5\nwrote %s/lanes.md' "$WS/main")"
if [[ ! -e "$WS/main/lane-C-brief.md" ]]; then pass "stale lane-C brief removed"; else fail "stale lane-C brief removed"; fi

# --- cycle inside a lane ---
{
    gc_both
    simple_task 1 a/x.ts 2
    simple_task 2 a/x.ts:5 1
} | write_plan cycle.md
expect_exit "cycle inside a lane exits 5" 5 "cycle" "$PLAN_LANES" cycle.md

# --- missing Interfaces / Produces ---
{
    gc_both
    simple_task 1 a/x.ts none
    printf '### Task 2: Bare\n\n**Files:**\n- Modify: `b/y.ts`\n\n**Depends on:** none\n\n'
} | write_plan nointerfaces.md
expect_exit "missing Interfaces exits 3 naming the task" 3 "Task 2" "$PLAN_LANES" nointerfaces.md
if [[ ! -e "$WS/nointerfaces/lanes.md" ]]; then pass "reject writes no lanes.md"; else fail "reject writes no lanes.md"; fi

{
    gc_both
    printf '### Task 1: Half\n\n**Files:**\n- Modify: `a/x.ts`\n\n**Depends on:** none\n\n**Interfaces:**\n- Consumes: none\n\n'
} | write_plan noproduces.md
expect_exit "missing Produces exits 3" 3 "Task 1" "$PLAN_LANES" noproduces.md

# --- integration commands ---
{
    printf '# Plan\n\n## Global Constraints\n\n- typecheck: `true`\n\n'
    simple_task 1 a/x.ts none
} | write_plan nounit.md
expect_exit "missing unit: exits 4" 4 "unit:" "$PLAN_LANES" nounit.md

{
    printf '# Plan\n\n## Global Constraints\n\n- unit: `true`\n\n'
    simple_task 1 a/x.ts none
} | write_plan notypecheck.md
expect_exit "missing typecheck: exits 4" 4 "typecheck:" "$PLAN_LANES" notypecheck.md

{
    printf '# Plan\n\n## Global Constraints\n\n- typecheck: none\n- unit: `make test`\n\n'
    simple_task 1 a/x.ts none
} | write_plan tcnone.md
if run_lanes tcnone.md >/dev/null; then pass "typecheck: none accepted"; else fail "typecheck: none accepted"; fi
has_line "typecheck none recorded" "$WS/tcnone/lanes.md" "- typecheck: none"

# --- usage errors ---
expect_exit "no arguments exits 2" 2 "" "$PLAN_LANES"
expect_exit "missing plan exits 2" 2 "" "$PLAN_LANES" no-such-plan.md
expect_exit "MAX_LANES 0 exits 2" 2 "" "$PLAN_LANES" main.md 0
expect_exit "MAX_LANES 27 exits 2" 2 "" "$PLAN_LANES" main.md 27
expect_exit "MAX_LANES non-numeric exits 2" 2 "" "$PLAN_LANES" main.md x

echo ""
if [[ "$FAILURES" -ne 0 ]]; then
    echo "FAILED: $FAILURES assertion(s)."
    exit 1
fi
echo "PASS"
```

In `tests/codex/test-package-codex-plugin.sh`, find the block that starts `if [[ -x "$extracted/skills/subagent-driven-development/scripts/task-brief" ]]; then`. Directly after its closing `fi`, add:

```bash
if [[ -x "$extracted/skills/subagent-driven-development/scripts/plan-lanes" ]]; then
  pass "archive ships plan-lanes executable"
else
  fail "archive ships plan-lanes executable"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/claude-code/test-plan-lanes.sh`
Expected: FAIL. The assertions fail because `plan-lanes` does not exist yet ("No such file or directory").

- [ ] **Step 3: Implement `plan-lanes`**

Create `skills/subagent-driven-development/scripts/plan-lanes` and run `chmod +x` on it. Follow the structure of `task-brief`:

- the `#!/usr/bin/env bash` shebang;
- a header comment explaining what it does and why it is deterministic;
- `set -euo pipefail`.

Then implement it:

1. **Validate arguments.**
   - Accept 1–2 args, otherwise exit 2.
   - The plan file must exist, otherwise exit 2.
   - MAX_LANES defaults to 6 and must match `^[0-9]+$` with a value from 1 to 26, otherwise exit 2.
   - Prefix every error message with `plan-lanes: `.
2. **Parse in one POSIX awk pass.** Emit tab-separated records to a temp file under `mktemp -d`, cleaned up with `trap`:
   - `T<TAB>n` for each task;
   - `F<TAB>n<TAB>path<TAB>shared(0|1)` for each Files line;
   - `D<TAB>n<TAB>dep` for each dependency;
   - `I<TAB>n<TAB>ok(0|1)`;
   - `M<TAB>n<TAB>message`;
   - `C<TAB>typecheck|unit<TAB>value`.

   Apply the rules in Behaviour 1–5 above. Validate rules 4 and 5 from these records and exit 3 or 4 before computing anything.
3. **Compute in a second awk program over the records.** It handles Behaviour 6–12: union-find with path compression, component ordering, packing, per-lane topological sort, shared owners, allowlists and the commit map. It emits:
   - lane table rows;
   - lane task order;
   - allowlist, do-not-touch and duties entries;
   - commit-map rows.

   Exit 5 on a cycle. Sort any list with `LC_ALL=C sort` in bash, or with deterministic index loops in awk. Never rely on `for (k in arr)` order.
4. **Write the outputs.**
   1. Only after computation succeeds, resolve `dir=$("$(dirname "$0")/sdd-workspace" "$plan")`.
   2. Delete `"$dir"/lane-*-brief.md`.
   3. Write `lanes.md` and each lane brief in the exact formats above. Get each task's text with `"$(dirname "$0")/task-brief" "$plan" N "$tmp/task-N.md" >/dev/null`.
   4. Print the stdout lines.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/claude-code/test-plan-lanes.sh; bash tests/claude-code/test-sdd-workspace.sh; bash scripts/lint-shell.sh skills/subagent-driven-development/scripts/plan-lanes`
Expected: all PASS, and lint is clean. Then commit (Step 5) and run `bash tests/codex/test-package-codex-plugin.sh`. Expected: PASS, including "archive ships plan-lanes executable". The package script archives committed files.

- [ ] **Step 5: Commit**

```bash
git add skills/subagent-driven-development/scripts/plan-lanes tests/claude-code/test-plan-lanes.sh tests/codex/test-package-codex-plugin.sh
git commit -m "feat(sdd): add plan-lanes for blitz file-ownership lanes" -- skills/subagent-driven-development/scripts/plan-lanes tests/claude-code/test-plan-lanes.sh tests/codex/test-package-codex-plugin.sh
```

### Task 3: Implementer blitz-lane clause

**Files:**
- Modify: `scripts/agent-templates/caveman-implementer.md`
- Modify: `agents/caveman-implementer-low.md` (generated)
- Modify: `agents/caveman-implementer-medium.md` (generated)
- Modify: `agents/caveman-implementer-high.md` (generated)

**Depends on:** none

**Review tier:** judgment (fast fallback)

**Interfaces:**
- Consumes: none
- Produces:
  - Every `caveman-implementer-<effort>` agent contains the section `## Blitz lane (blitz mode)`, activated by the dispatch line "Blitz lane: no tests, no typecheck, no git.".
  - The clause tells the agent to execute every task in the lane brief in order and to touch only `## Allowlist`. It also tells the agent to run no tests, typecheck or git writes, and to report skipped steps as "not run (blitz)".

- [ ] **Step 1: Add the clause to the template**

In `scripts/agent-templates/caveman-implementer.md`, insert this section directly after the `## Test-writer lane (ultra mode)` paragraph, before `## Git discipline — a shared checkout`:

```markdown
## Blitz lane (blitz mode)

When your dispatch says "Blitz lane: no tests, no typecheck, no git.", your brief is a lane: several tasks plus an Allowlist. This clause overrides "exactly one task", the TDD steps, and "Commit with an explicit pathspec".

- Execute every task in the brief's `## Tasks` section, in the order given.
- Touch ONLY the files in `## Allowlist`. Skip your tasks' edits to any `## Do not touch` path — another lane owns it. Under `## Shared-file duties`, apply only the edits to the named path; those tasks are reference only.
- Other lanes are writing upstream symbols right now, exactly as the plan's Interfaces state. Import them as if they exist. Never stub, mock out, or redefine them.
- Write the code AND the test files exactly as the plan specifies.
- Do not run tests, typecheck, build, lint, or formatters: every lane sees the others half-written, so results are noise. Do not run any git command that writes (`add`, `commit`, `stash`, `restore`, `checkout`). Skip each Run/Verify step and the Commit step, and record it as "not run (blitz)" — never fake output.
- If resumed with integration failures ("Blitz integration fix: still no tests, no git."), fix only Allowlist files, still without running tests or git. If a fix needs another file, report NEEDS_CONTEXT.
- Never weaken a test to make it fit your code. Report a contract conflict instead, citing the Interfaces line.
```

In the `## Report` section, replace the sentence `In a test-writer lane, replace the TDD evidence with the checks you ran.` with:

```markdown
In a test-writer lane, replace the TDD evidence with the checks you ran. In a blitz lane, replace TDD evidence and commits with: files changed per task, "not run (blitz)" for each Run/Verify step, and every deviation from or assumption beyond the Interfaces block, citing the line.
```

- [ ] **Step 2: Regenerate the agents**

Run: `bash scripts/gen-agent-variants`
Expected: `agents/caveman-implementer-{low,medium,high}.md` change, and no other agent file changes (`git status --porcelain agents/` lists only those 3).

- [ ] **Step 3: Verify**

Run: `bash tests/agents/test-agent-variants.sh; grep -c 'Blitz lane (blitz mode)' agents/caveman-implementer-*.md`
Expected: PASS, and a count of 1 per file.

- [ ] **Step 4: Commit**

```bash
git add scripts/agent-templates/caveman-implementer.md agents/caveman-implementer-low.md agents/caveman-implementer-medium.md agents/caveman-implementer-high.md
git commit -m "feat(agents): add blitz lane clause to implementer" -- scripts/agent-templates/caveman-implementer.md agents/caveman-implementer-low.md agents/caveman-implementer-medium.md agents/caveman-implementer-high.md
```

### Task 4: SDD `## Blitz Mode`

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`

**Depends on:** none

**Review tier:** judgment (fast fallback)

**Interfaces:**
- Consumes: `plan-lanes` exits and outputs as specified in Task 2. The implementer clause's activation line from Task 3, "Blitz lane: no tests, no typecheck, no git.".
- Produces: an SDD `## Blitz Mode` section containing these exact tokens:
  - `Mode: blitz —`
  - `falling back to ultra`
  - `scripts/plan-lanes`
  - `only test runner`
  - `--maxWorkers=2`
  - `Never revert a stray automatically`
  - `folded into Task M`
  - `Check every cross-lane seam against the plan's Interfaces`

  It also adds a role-table row, a wave-loop pointer and a File Handoffs bullet.

- [ ] **Step 1: Wave-loop pointer**

In `skills/subagent-driven-development/SKILL.md`, directly under the heading `## Wave-Based Parallel Execution`, insert this paragraph followed by a blank line:

```markdown
In blitz mode none of this section runs: tasks run in file-ownership lanes instead of waves. See Blitz Mode.
```

- [ ] **Step 2: Pre-flight policy line**

In `## Pre-Flight Plan Review`, replace

```markdown
at 3 rounds`. With no block at all (a harness
```

with

```markdown
at 3 rounds`. In blitz mode the policy line comes from `scripts/plan-lanes` (see Blitz Mode). With no block at all (a harness
```

- [ ] **Step 3: Role-table row**

In the Model Selection table, insert this row directly after the `| \`test-writer\` | ...` row:

```markdown
| implementer, blitz lane | `caveman-implementer-<effort>` | `judgment=` | `implementer: effort=` | blitz mode only: one lane of tasks, no tests, no git |
```

- [ ] **Step 4: Blitz Mode section**

Insert this section directly before `## Handling Implementer Status`:

```markdown
## Blitz Mode

`mode: blitz` replaces the wave loop. It does not extend fast or ultra execution: every task runs at once in file-ownership lanes, with no per-task tests or review, then one integration pass. The planning and review skills treat blitz as a superset of ultra; execution is the only place it differs.

Blitz is experimental. It trades TDD red-before-green, per-task review gates, early detection of a bad Interfaces contract, and bisectable history for wall-clock time. A wrong contract surfaces at integration, and every lane built on it pays. Do not use blitz for schema migrations with data backfills, security- or auth-critical changes that need a gate per change, or plans with vague tasks.

**Still applies:** Model Selection, caveman agent dispatch, Handling Implementer Status, the 3-round fix bound, File Handoffs, the final whole-branch review and its single fix subagent, verification-before-completion, finishing-a-development-branch.

**Dropped:** Execution Waves (the plan keeps them as the fallback path), per-task review and re-review, the Review tier gate, test-writer lanes, the per-task converge loop, and the per-wave suite.

**1. Lanes.** After the Pre-Flight Plan Review scan, run `scripts/plan-lanes PLAN_FILE`. It unions tasks that share a file, packs them into at most 6 lanes, orders each lane by Depends on, and writes `lanes.md` (lane table, `typecheck:`/`unit:` commands, commit map) plus one `lane-<X>-brief.md` per lane into the plan's workspace.
- Exit 0: announce `Mode: blitz — <N> lanes dispatched at once; no per-task review; one integration pass (controller is the only test runner); final review mandatory`.
- Exit 3, 4 or 5 (a task lacks Interfaces, the plan lacks `typecheck:`/`unit:` lines, or a lane has a dependency cycle): announce `Mode: blitz — falling back to ultra: <plan-lanes stderr>` and run Ultra Mode for the whole plan. Never carve out single tasks.
- Exit 2 (usage error or missing plan): stop and report it.

**2. Baseline.** Record `BLITZ_BASE=$(git rev-parse HEAD)` and save `git status --porcelain` to `<workspace>/blitz-baseline.txt`. The repo may already have untracked files.

**3. Dispatch every lane in ONE message.** Each lane runs `superpowers-on-steroids:caveman-implementer-<effort>` on `implementer: judgment=`: a lane is multi-task work against code being written concurrently. The dispatch carries the lane brief path, a report path (`lane-<X>-report.md`), and the line "Blitz lane: no tests, no typecheck, no git." Answer questions as they arrive. A BLOCKED or NEEDS_CONTEXT lane goes through Handling Implementer Status. Integration waits until every lane is DONE or DONE_WITH_CONCERNS.

**4. Stray check.** Take `git status --porcelain` again and drop the baseline entries. A changed path outside every lane's Allowlist is a stray. Read its diff and decide: attribute it to a task's commit-map entry, or revert it. Record the decision in the ledger. Never revert a stray automatically — it may be a needed seam fix.

**5. Integration run.** The controller is the only test runner for the whole blitz run. Check `ps` for stray jest, vitest, temporal or test-server processes and wait for or kill them. Run the `typecheck:` command from `lanes.md` unless it is `none`. Run the `unit:` command once, capped: jest `--maxWorkers=2`, vitest `--maxWorkers=2`, or the equivalent flag for other runners. Redirect output to workspace files and read only the failure summaries.

**6. Integration fix loop (max 3 rounds).** Map each failure to the lane whose Allowlist holds the failing file; a seam failure across lanes goes to the consumer-side lane.
- Rounds 1–2: resume the owning lanes in parallel with only their failures and the line "Blitz integration fix: still no tests, no git." If a lane agent is gone, dispatch a fresh `caveman-implementer-<effort>` on `judgment=` with its lane brief and failures, and note it in the ledger. Between rounds, re-run typecheck and only the failing specs, capped.
- Round 3: dispatch `superpowers-on-steroids:caveman-implementer-high` on `final-reviewer: model=` with every remaining failure, the lane reports and `lanes.md`. It is now the only test runner, and its brief carries verbatim: "Cap test runner parallelism: jest `--maxWorkers=2`, vitest `--maxWorkers=2`, equivalent flags for other runners. You are the only agent running tests. Check `ps` for stray jest/vitest/temporal/test-server processes first and wait or kill them." It makes no git writes.
- Still red after round 3: BLOCKED. Report the failure list to your human partner. Commit nothing while red.
- Green: run typecheck and the full capped `unit:` command one last time, because a fix can regress a spec that was not re-run.

**7. Commits.** Follow the `lanes.md` commit map in plan order. For each task: `git add -- <paths>`, then `git commit -m "<message>" -- <paths>`. The add is needed because a pathspec commit skips new untracked files. Write a Conventional message from the task title where the map says `<none — controller writes>`. A task marked `folded into Task M` gets no commit, only a ledger note. Integration fixes ride in the commit of the task that owns the file. Ledger line per task: `Task N: complete (blitz lane X, commit <sha7>)`.

**8. Final whole-branch review — mandatory.** It is the only review gate blitz keeps. Run `scripts/review-package MERGE_BASE HEAD` and dispatch the final reviewer as in requesting-code-review. Add the ultra line "Tests assert the contract's behaviours, not the implementation's incidental output; flag tautological tests as Important." and the seam line "Blitz: no per-task review ran. Check every cross-lane seam against the plan's Interfaces (names, types, optional vs required, error behaviour); flag drift as Important." Findings go to one fix subagent; it is then the only test runner and gets the caps verbatim. Then run verification-before-completion and finishing-a-development-branch.
```

- [ ] **Step 5: File Handoffs bullet**

In `## File Handoffs`, insert this bullet directly after the `- **Report file:**` bullet:

```markdown
- **Blitz lanes:** `scripts/plan-lanes PLAN_FILE` writes `lanes.md` and one
  `lane-<X>-brief.md` per lane into the plan's workspace. Dispatch each lane
  with its brief path and a report path `lane-<X>-report.md`; the commit
  map in `lanes.md` drives the commits after integration.
```

- [ ] **Step 6: Verify**

Run: `for t in '## Blitz Mode' 'Blitz lane: no tests, no typecheck, no git.' 'Mode: blitz —' 'falling back to ultra' 'scripts/plan-lanes' 'only test runner' -- '--maxWorkers=2' 'Never revert a stray automatically' 'folded into Task M' "Check every cross-lane seam against the plan's Interfaces" 'implementer, blitz lane'; do [ "$t" = -- ] && continue; grep -qF -- "$t" skills/subagent-driven-development/SKILL.md && echo "ok: $t" || echo "MISSING: $t"; done; bash tests/agents/test-fast-mode-contract.sh`
Expected: every token prints `ok:`, and the contract test still PASSES (the existing ultra and fast tokens are untouched).

- [ ] **Step 7: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat(sdd): add blitz mode execution" -- skills/subagent-driven-development/SKILL.md
```

### Task 5: writing-plans blitz requirements

**Files:**
- Modify: `skills/writing-plans/SKILL.md`

**Depends on:** none

**Review tier:** judgment (fast fallback)

**Interfaces:**
- Consumes: the `plan-lanes` input rules from Task 2: the `(shared)` suffix, the `- typecheck:` and `- unit:` lines, and the Interfaces lines.
- Produces: the section `## Blitz Mode Plans`, containing the blitz superset rule `` `mode: blitz` includes all of ultra mode. Every ultra-mode instruction applies to blitz too``, plus self-review item `**7. Blitz contracts:**`.

- [ ] **Step 1: Add the section**

In `skills/writing-plans/SKILL.md`, insert this section directly before `## No Placeholders`:

```markdown
## Blitz Mode Plans

`mode: blitz` includes all of ultra mode. Every ultra-mode instruction applies to blitz too, plus the blitz additions in this section.

Blitz execution runs every task at once in file-ownership lanes, computed by subagent-driven-development's `scripts/plan-lanes`, then integrates once. Implementers import each other's symbols before those exist, so the plan's contracts carry the whole run. When `<SUPERPOWERS_CONFIG>` says `mode: blitz`:
- **Every task**, transcription included, has an **Interfaces:** block with a `- Consumes:` line and a `- Produces:` line (`none` is allowed), and Produces states behaviours, not just names.
- **Shared append-only files** — barrel exports, migration journals, registries that several tasks only add lines to — are marked on every task that lists them: ``- Modify: `src/index.ts` (shared)``. One lane owns the file and applies every task's edits to it. A file that tasks edit in overlapping regions stays unmarked; those tasks then share a lane.
- **Global Constraints** names both integration commands, each on its own line: ``- typecheck: `<command>` `` (or `- typecheck: none`) and ``- unit: `<command>` ``.

Keep the Execution Waves map: if `plan-lanes` rejects the plan, execution falls back to ultra and runs the waves. Keep every task's Step 5 commit message: the controller makes the commits after integration and uses them.
```

- [ ] **Step 2: Add self-review item 7**

In `## Self-Review`, directly after the line starting `**6. Ultra contracts:**`, insert a blank line and then:

```markdown
**7. Blitz contracts:** In `mode: blitz`, every task has an Interfaces block with Consumes and Produces lines; every file several tasks only append to is marked `(shared)` on each of them, and no file edited in overlapping regions is marked; Global Constraints has `- typecheck:` and `- unit:` lines.
```

- [ ] **Step 3: Verify**

Run: `grep -nF -e '## Blitz Mode Plans' -e '`mode: blitz` includes all of ultra mode' -e '**7. Blitz contracts:**' -e '(shared)' -e '- typecheck:' -e '- unit:' skills/writing-plans/SKILL.md`
Expected: at least one hit for each pattern.

- [ ] **Step 4: Commit**

```bash
git add skills/writing-plans/SKILL.md
git commit -m "feat(skills): blitz plan requirements in writing-plans" -- skills/writing-plans/SKILL.md
```

### Task 6: Blitz superset rule in brainstorming and requesting-code-review

**Files:**
- Modify: `skills/brainstorming/SKILL.md`
- Modify: `skills/requesting-code-review/SKILL.md`

**Depends on:** none

**Review tier:** judgment (fast fallback)

**Interfaces:**
- Consumes: none
- Produces:
  - Both skills contain `` `mode: blitz` includes all of ultra mode. Every ultra-mode instruction applies to blitz too``.
  - requesting-code-review also contains the seam line `Check every cross-lane seam against the plan's Interfaces`.

- [ ] **Step 1: brainstorming**

In `skills/brainstorming/SKILL.md`, directly after the bullet starting ``- `mode: ultra` includes all of fast mode.``, insert:

```markdown
- `mode: blitz` includes all of ultra mode. Every ultra-mode instruction applies to blitz too — both fast-mode rules in this skill apply unchanged.
```

- [ ] **Step 2: requesting-code-review**

In `skills/requesting-code-review/SKILL.md`, directly after the paragraph starting ``  `mode: ultra` includes all of fast mode.``, insert a blank line and then:

```markdown
`mode: blitz` includes all of ultra mode. Every ultra-mode instruction applies to blitz too. Blitz has no per-task review step: this final review is the only review gate, and it is mandatory. In blitz, also tell the reviewer: "Blitz: no per-task review ran. Check every cross-lane seam against the plan's Interfaces (names, types, optional vs required, error behaviour); flag drift as Important."
```

- [ ] **Step 3: Verify**

Run: `grep -cF '`mode: blitz` includes all of ultra mode' skills/brainstorming/SKILL.md skills/requesting-code-review/SKILL.md; grep -cF "Check every cross-lane seam against the plan's Interfaces" skills/requesting-code-review/SKILL.md`
Expected: a count of 1 for each.

- [ ] **Step 4: Commit**

```bash
git add skills/brainstorming/SKILL.md skills/requesting-code-review/SKILL.md
git commit -m "feat(skills): blitz superset rule in brainstorming and review" -- skills/brainstorming/SKILL.md skills/requesting-code-review/SKILL.md
```

### Task 7: Blitz contract assertions

**Files:**
- Modify: `tests/agents/test-fast-mode-contract.sh`

**Depends on:** 1, 3, 4, 5, 6

**Review tier:** transcription

**Interfaces:**
- Consumes:
  - the `mode: blitz` emission (Task 1);
  - the `## Blitz lane (blitz mode)` and `not run (blitz)` tokens in the implementer agents (Task 3);
  - the SDD tokens (Task 4);
  - the writing-plans tokens (Task 5);
  - the superset rule and seam line (Task 6).
- Produces: the contract suite fails if any blitz token drifts out of the hook, the skills or the generated implementer agents.

- [ ] **Step 1: Add the assertions**

In `tests/agents/test-fast-mode-contract.sh`, insert this block directly before the line `if [[ "$FAILURES" -gt 0 ]]; then`:

```bash
# --- Blitz: superset of ultra in planning/review skills; SDD replaces the wave loop ---
BLITZ_RULE='`mode: blitz` includes all of ultra mode. Every ultra-mode instruction applies to blitz too'
SEAM_LINE="Check every cross-lane seam against the plan's Interfaces"
blitz_home="$(mktemp -d)"
blitz_emitted="$(env -i PATH="${PATH:-}" HOME="$blitz_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PLUGIN_OPTION_MODE=blitz \
    bash "$REPO_ROOT/hooks/session-start" 2>/dev/null)" || blitz_emitted=""
rm -rf "$blitz_home"
if printf '%s' "$blitz_emitted" | grep -qF -- "mode: blitz"; then
    pass "blitz wiring: hook emits 'mode: blitz'"
else
    fail "blitz wiring: hook does not emit 'mode: blitz'"
fi
for skill in requesting-code-review brainstorming writing-plans; do
    assert_in_file "blitz superset rule" "$BLITZ_RULE" "$REPO_ROOT/skills/$skill/SKILL.md"
done
for token in "## Blitz Mode" "Blitz lane: no tests, no typecheck, no git." "Mode: blitz —" \
    "falling back to ultra" "scripts/plan-lanes" "only test runner" "--maxWorkers=2" \
    "Never revert a stray automatically" "folded into Task M" "$SEAM_LINE" \
    "implementer, blitz lane"; do
    assert_in_file "blitz SDD" "$token" "$sdd_skill"
done
assert_in_file "blitz review" "$SEAM_LINE" "$REPO_ROOT/skills/requesting-code-review/SKILL.md"
for token in "## Blitz Mode Plans" "(shared)" "- typecheck:" "- unit:" "**7. Blitz contracts:**"; do
    assert_in_file "blitz plans" "$token" "$plans_skill"
done
for effort in low medium high; do
    for token in "## Blitz lane (blitz mode)" "not run (blitz)"; do
        assert_in_file "blitz implementer" "$token" "$AGENTS_DIR/caveman-implementer-$effort.md"
    done
done
```

- [ ] **Step 2: Run it**

Run: `bash tests/agents/test-fast-mode-contract.sh`
Expected: `STATUS: PASSED`, with every `blitz` assertion PASS. A failure means the token drifted in Tasks 1 and 3–6; fix the token there, never by loosening this test.

- [ ] **Step 3: Commit**

```bash
git add tests/agents/test-fast-mode-contract.sh
git commit -m "test(agents): assert blitz mode contract tokens" -- tests/agents/test-fast-mode-contract.sh
```

### Task 8: Release notes and version 7.2.0

**Files:**
- Modify: `RELEASE-NOTES.md`
- Modify: `package.json`
- Modify: `.hermes-plugin/plugin.yaml`
- Modify: `.claude-plugin/plugin.json`
- Modify: `.cursor-plugin/plugin.json`
- Modify: `.codex-plugin/plugin.json`
- Modify: `.devin-plugin/plugin.json`
- Modify: `.kimi-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `gemini-extension.json`

**Depends on:** 1

**Review tier:** judgment (fast fallback)

**Interfaces:**
- Consumes: the `.claude-plugin/plugin.json` mode edits from Task 1. Do not revert them; edit only the `version` field.
- Produces: every manifest listed in `.version-bump.json` reads `7.2.0`, and `RELEASE-NOTES.md` opens with `## v7.2.0 (2026-11-05)`.

- [ ] **Step 1: Bump the manifests**

Run: `grep -n '7\.1\.1' package.json .hermes-plugin/plugin.yaml .claude-plugin/plugin.json .cursor-plugin/plugin.json .codex-plugin/plugin.json .devin-plugin/plugin.json .kimi-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json`
Expected: exactly one hit per file, each a version field. If any file has a non-version hit, edit that file by hand instead of using the next command.

Run: `perl -pi -e 's/\b7\.1\.1\b/7.2.0/' package.json .hermes-plugin/plugin.yaml .claude-plugin/plugin.json .cursor-plugin/plugin.json .codex-plugin/plugin.json .devin-plugin/plugin.json .kimi-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json`

- [ ] **Step 2: Release notes**

In `RELEASE-NOTES.md`, insert this directly after the `# Superpowers Release Notes` line and its blank line, before `## v7.1.1 (2026-10-28)`:

```markdown
## v7.2.0 (2026-11-05)

### Blitz mode (experimental)

- **What.** `mode: blitz` (plugin option or `SUPERPOWERS_MODE=blitz`) runs
  every plan task at once. A new `plan-lanes` script groups tasks that share
  a file into at most 6 lanes; each lane is one implementer that runs its
  tasks in dependency order, imports other lanes' symbols as the plan's
  Interfaces describe them, and runs no tests and no git. The controller
  then does one integration pass as the only test runner (typecheck, one
  capped unit run, a fix loop of at most 3 rounds), commits per task from a
  commit map, and runs a mandatory final whole-branch review.
- **Trade-off.** Blitz gives up TDD red-before-green, per-task review gates,
  early detection of a wrong Interfaces contract, and bisectable history
  (intermediate commits may not build alone). The plan's contracts decide
  how well it goes. Do not use it for migrations with data backfills,
  security- or auth-critical changes, or vague plans. A plan without
  Interfaces on every task, or without `typecheck:`/`unit:` lines in Global
  Constraints, falls back to ultra as a whole.
- **Config.** No new keys or roles. Lanes reuse
  `caveman-implementer-<effort>` on the judgment model; the implementer
  agents learned a "blitz lane" clause. Plans mark append-only shared files
  (barrels, migration journals) with `(shared)` so one lane owns them.
- **Not yet done (recommended next).** A measured blitz vs ultra acceptance
  run, and worktree-per-lane isolation. Blitz stays experimental until that
  run exists.

### Internal

- Tests cover the new mode value, `plan-lanes` (union, shared owners,
  packing, topological order, rejects, determinism), the implementer clause,
  and the blitz superset rule in each mode-aware skill.

```

- [ ] **Step 3: Verify**

Run: `grep -rn '7\.1\.1' package.json .hermes-plugin .claude-plugin .cursor-plugin .codex-plugin .devin-plugin .kimi-plugin gemini-extension.json; grep -c '7\.2\.0' package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json; bash tests/hooks/test-plugin-config.sh`
Expected: no 7.1.1 hits, each count is 1, and plugin-config PASSES.

- [ ] **Step 4: Commit**

```bash
git add RELEASE-NOTES.md package.json .hermes-plugin/plugin.yaml .claude-plugin/plugin.json .cursor-plugin/plugin.json .codex-plugin/plugin.json .devin-plugin/plugin.json .kimi-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json
git commit -m "chore: release notes and version bump to 7.2.0" -- RELEASE-NOTES.md package.json .hermes-plugin/plugin.yaml .claude-plugin/plugin.json .cursor-plugin/plugin.json .codex-plugin/plugin.json .devin-plugin/plugin.json .kimi-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json
```
