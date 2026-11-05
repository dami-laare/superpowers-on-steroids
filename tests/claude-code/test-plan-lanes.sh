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

# --- zero-task plan is rejected, not silently truncated ---
gc_both | write_plan zerotasks.md
expect_exit "zero-task plan exits 3 naming no tasks" 3 "no tasks" "$PLAN_LANES" zerotasks.md
if [[ ! -e "$WS/zerotasks/lanes.md" ]]; then pass "zero-task plan writes no lanes.md"; else fail "zero-task plan writes no lanes.md"; fi

# --- malformed Global Constraints values count as missing ---
{
    printf '# Plan\n\n## Global Constraints\n\n- typecheck: `true`\n- unit: garbage\n\n'
    simple_task 1 a/x.ts none
} | write_plan badunit.md
expect_exit "unit: without a backticked command exits 4" 4 "unit:" "$PLAN_LANES" badunit.md

{
    printf '# Plan\n\n## Global Constraints\n\n- typecheck: whatever\n- unit: `true`\n\n'
    simple_task 1 a/x.ts none
} | write_plan badtypecheck.md
expect_exit "typecheck: with neither backticks nor none exits 4" 4 "typecheck:" "$PLAN_LANES" badtypecheck.md

# --- Depends-on parser: only pure integers and ranges before the first "(" count ---
{
    gc_both
    simple_task 1 shared/notes.ts "none (reads the v1 config)"
    simple_task 2 shared/notes.ts "none (reads the v1 config)"
} | write_plan dep-prose.md
if run_lanes dep-prose.md >/dev/null; then pass "prose Depends-on line is not a false cycle"; else fail "prose Depends-on line is not a false cycle"; fi

{
    gc_both
    simple_task 1 shared/seam.ts "Task 2, parseV3"
    simple_task 2 shared/seam.ts none
    simple_task 3 shared/seam.ts none
} | write_plan dep-noise.md
out="$(run_lanes dep-noise.md)" || out=""
has_line "non-numeric noise (parseV3) is not mistaken for an edge to Task 3" "$WS/dep-noise/lane-A-brief.md" "# Blitz lane A — Tasks 2, 1, 3 (in this order)"

{
    gc_both
    simple_task 1 shared/range.ts "Tasks 2-4"
    simple_task 2 shared/range.ts none
    simple_task 3 shared/range.ts none
    simple_task 4 shared/range.ts none
} | write_plan dep-range.md
out="$(run_lanes dep-range.md)" || out=""
has_line "Tasks 2-4 Depends-on is honoured (Task 1 runs after 2, 3 and 4)" "$WS/dep-range/lanes.md" '| A | 2, 3, 4, 1 | 1 | - |'

# Task 3 waits on Task 5, so Task 1 lands last only if the range expands to
# include its middle (3). Endpoint-only parsing would give 2, 4, 1, 5, 3.
{
    gc_both
    simple_task 1 shared/midrange.ts "Tasks 2-4"
    simple_task 2 shared/midrange.ts none
    simple_task 3 shared/midrange.ts 5
    simple_task 4 shared/midrange.ts none
    simple_task 5 shared/midrange.ts none
} | write_plan dep-midrange.md
out="$(run_lanes dep-midrange.md)" || out=""
has_line "Tasks 2-4 expands to an edge from mid-range Task 3 into Task 1" "$WS/dep-midrange/lanes.md" '| A | 2, 4, 5, 3, 1 | 1 | - |'

# --- Depends-on token normalisation: trailing "." / ":" stripped, en-dash range accepted ---
{
    gc_both
    simple_task 1 shared/punct.ts "Task 4., Tasks 2–3"
    simple_task 2 shared/punct.ts none
    simple_task 3 shared/punct.ts none
    simple_task 4 shared/punct.ts none
} | write_plan dep-punct.md
out="$(run_lanes dep-punct.md)" || out=""
has_line "trailing punctuation stripped and en-dash range accepted" "$WS/dep-punct/lanes.md" '| A | 2, 3, 4, 1 | 1 | - |'

# --- commit-map message with a literal "|" is escaped, not a broken table row ---
{
    printf '# Plan\n\n## Global Constraints\n\n- typecheck: `true`\n- unit: `true`\n\n'
    printf '### Task 1: Pipe\n\n**Files:**\n- Modify: `a/pipe.ts`\n\n**Depends on:** none\n\n'
    printf '**Interfaces:**\n- Consumes: none\n- Produces: `pipe()` returns 1\n\n'
    printf '@@@bash\ngit commit -m "feat: b | c"\n@@@\n'
} | write_plan pipemsg.md
run_lanes pipemsg.md >/dev/null
has_line "commit message with | is escaped in the table row" "$WS/pipemsg/lanes.md" '| 1 | feat: b \| c | `a/pipe.ts` |'

# --- exit 3 names every offending task, not only the first ---
{
    gc_both
    printf '### Task 1: Bare one\n\n**Files:**\n- Modify: `a/x.ts`\n\n**Depends on:** none\n\n'
    printf '### Task 2: Bare two\n\n**Files:**\n- Modify: `b/y.ts`\n\n**Depends on:** none\n\n'
} | write_plan twobad.md
rc=0
err="$(cd "$REPO" && "$PLAN_LANES" twobad.md 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" -eq 3 && "$err" == *"Task 1"* && "$err" == *"Task 2"* ]]; then
    pass "exit 3 names every offending task"
else
    fail "exit 3 names every offending task"
    echo "    exit $rc (want 3); stderr: $err"
fi

# --- task-brief extraction failure exits 2 before any output file is written ---
{
    gc_both
    printf '### Task 01: Weird heading\n\n**Files:**\n- Modify: `a/weird.ts`\n\n**Depends on:** none\n\n'
    printf '**Interfaces:**\n- Consumes: none\n- Produces: `weird()` returns 1\n\n'
} | write_plan weirdheading.md
expect_exit "task-brief extraction failure exits 2" 2 "Task 1" "$PLAN_LANES" weirdheading.md
if [[ ! -e "$WS/weirdheading/lanes.md" ]]; then
    pass "task-brief extraction failure writes no lanes.md"
else
    fail "task-brief extraction failure writes no lanes.md"
fi

echo ""
if [[ "$FAILURES" -ne 0 ]]; then
    echo "FAILED: $FAILURES assertion(s)."
    exit 1
fi
echo "PASS"
