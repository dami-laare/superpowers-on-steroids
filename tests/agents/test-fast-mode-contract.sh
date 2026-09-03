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
for token in "git reset" "git stash" "git clean" "git checkout --" "git add ." "git add -A" "git commit -a"; do
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

# --- Reviewer pairs: verdict strings the controller branches on ---
for token in "Approved" "Needs fixes" "⚠️ Cannot verify from diff"; do
    assert_in_both "task reviewer verdict" "$token" "$rev_agent" "$rev_tmpl"
done
for token in "Ready to merge?" "With fixes"; do
    assert_in_both "final reviewer verdict" "$token" "$final_agent" "$final_tmpl"
done

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

# --- Review tiering: plan writes the field, SDD reads it in fast mode ---
plans_skill="$REPO_ROOT/skills/writing-plans/SKILL.md"
assert_in_file "review tier" "**Review tier:**" "$plans_skill"
assert_in_file "review tier" "Review tier gate" "$sdd_skill"
assert_in_file "review tier" "transcription" "$sdd_skill"
assert_in_file "review tier" "fix loop capped at 3 rounds" "$sdd_skill"

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

# --- Wiring: the hook's emitted trigger must match what the skills look for ---
# This is the failure mode that would make fast mode silently inert: the hook
# keeps emitting a block nobody reads, or the skills watch for a string nobody
# emits. Both sides stay green under prose-only tests, so assert the real
# emitted output against the real skill text.

wiring_home="$(mktemp -d)"
emitted="$(env -i PATH="${PATH:-}" HOME="$wiring_home" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PLUGIN_OPTION_MODE=fast \
    bash "$REPO_ROOT/hooks/session-start" 2>/dev/null)" || emitted=""
rm -rf "$wiring_home"

if [ -z "$emitted" ]; then
    fail "wiring: hook produced no output to check"
else
    for token in "<SUPERPOWERS_CONFIG>" "mode: fast" "</SUPERPOWERS_CONFIG>"; do
        if printf '%s' "$emitted" | grep -qF -- "$token"; then
            pass "wiring: hook emits '$token'"
        else
            fail "wiring: hook does not emit '$token'"
        fi
    done

    for skill in subagent-driven-development requesting-code-review brainstorming; do
        skill_file="$REPO_ROOT/skills/$skill/SKILL.md"
        for token in "<SUPERPOWERS_CONFIG>" "mode: fast"; do
            if ! grep -qF -- "$token" "$skill_file"; then
                fail "wiring: $skill does not look for '$token'"
            elif printf '%s' "$emitted" | grep -qF -- "$token"; then
                pass "wiring: $skill trigger '$token' is actually emitted"
            else
                fail "wiring: $skill looks for '$token' but the hook never emits it"
            fi
        done
    done
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi

echo "STATUS: PASSED"
