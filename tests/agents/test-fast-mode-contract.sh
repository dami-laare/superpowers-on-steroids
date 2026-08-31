#!/usr/bin/env bash
# Fast-mode agents and their inline-template counterparts state the same
# contract. Prose may differ; the tokens the controller branches on may not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"
SDD_DIR="$REPO_ROOT/skills/subagent-driven-development"

FAILURES=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

assert_in_both() {
    local label="$1" token="$2" file_a="$3" file_b="$4"
    if grep -qF -- "$token" "$file_a" && grep -qF -- "$token" "$file_b"; then
        pass "$label: '$token' in both"
    else
        fail "$label: '$token' missing from one side"
    fi
}

echo "Fast-mode contract tests"

# --- Implementer pair: status contract the controller branches on ---
impl_agent="$AGENTS_DIR/caveman-implementer.md"
impl_tmpl="$SDD_DIR/implementer-prompt.md"
for token in DONE_WITH_CONCERNS NEEDS_CONTEXT BLOCKED DONE; do
    assert_in_both "implementer status" "$token" "$impl_agent" "$impl_tmpl"
done

# --- Implementer pair: repo-destroying commands both sides must forbid ---
for token in "git reset" "git stash" "git clean" "git add ." "git add -A" "git commit -a"; do
    assert_in_both "implementer git safety" "$token" "$impl_agent" "$impl_tmpl"
done

# --- Reviewer pairs: severity buckets the review loop branches on ---
rev_agent="$AGENTS_DIR/caveman-reviewer.md"
rev_tmpl="$SDD_DIR/task-reviewer-prompt.md"
final_agent="$AGENTS_DIR/caveman-final-reviewer.md"
final_tmpl="$REPO_ROOT/skills/requesting-code-review/code-reviewer.md"
for token in Critical Important Minor; do
    assert_in_both "task reviewer severity" "$token" "$rev_agent" "$rev_tmpl"
    assert_in_both "final reviewer severity" "$token" "$final_agent" "$final_tmpl"
done

# --- Agent file validity: what the plugin loader will accept ---
for f in "$AGENTS_DIR"/caveman-*.md; do
    base="$(basename "$f" .md)"
    fm="$(sed -n '/^---$/,/^---$/p' "$f")"

    if printf '%s' "$fm" | grep -qE "^name: ${base}\$"; then
        pass "$base: name matches filename"
    else
        fail "$base: name does not match filename"
    fi

    model="$(printf '%s' "$fm" | sed -n 's/^model: *//p')"
    if [ -n "$model" ] && [ "$model" != "inherit" ]; then
        pass "$base: model pinned ($model)"
    else
        fail "$base: model must be pinned and not 'inherit'"
    fi

    effort="$(printf '%s' "$fm" | sed -n 's/^effort: *//p')"
    case "$effort" in
        low|medium|high|xhigh|max|*[0-9]) pass "$base: effort valid ($effort)" ;;
        *) fail "$base: invalid effort '$effort'" ;;
    esac

    if printf '%s' "$fm" | grep -qE '^(permissionMode|hooks|mcpServers):'; then
        fail "$base: sets a key plugin agents ignore"
    else
        pass "$base: no ignored keys"
    fi

    if printf '%s' "$fm" | sed -n 's/^tools: *//p' | grep -qw "Agent"; then
        fail "$base: tools grants the Agent tool"
    else
        pass "$base: tools withholds the Agent tool"
    fi
done

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi

echo "STATUS: PASSED"
