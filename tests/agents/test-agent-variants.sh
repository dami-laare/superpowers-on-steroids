#!/usr/bin/env bash
# The checked-in caveman-* agents are exactly what the generator produces
# from scripts/agent-templates: one file per role x effort, nothing else.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"
GEN="$REPO_ROOT/scripts/gen-agent-variants"
TEMPLATES="$REPO_ROOT/scripts/agent-templates"

FAILURES=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "agent variant tests"

ROLES="implementer reviewer investigator final-reviewer"
EFFORTS="low medium high"

# --- Generator output matches the checked-in files byte for byte ---
if bash "$GEN" "$TMP/agents" >/dev/null 2>&1; then
    pass "generator runs"
else
    fail "generator runs"
fi
mkdir -p "$TMP/checked-in"
cp "$AGENTS_DIR"/caveman-*.md "$TMP/checked-in/" 2>/dev/null || true
if diff -r "$TMP/agents" "$TMP/checked-in" >/dev/null 2>&1; then
    pass "checked-in agents match generator output"
else
    fail "checked-in agents differ from generator output (run scripts/gen-agent-variants)"
    diff -r "$TMP/agents" "$TMP/checked-in" | head -20 | sed 's/^/    /'
fi

# --- Exactly 12 variants, no bare names ---
count="$(find "$AGENTS_DIR" -maxdepth 1 -name 'caveman-*.md' | wc -l | tr -d ' ')"
if [ "$count" = "12" ]; then
    pass "exactly 12 caveman agent files"
else
    fail "expected 12 caveman agent files, found $count"
fi
for role in $ROLES; do
    if [ -e "$AGENTS_DIR/caveman-$role.md" ]; then
        fail "bare-name agent caveman-$role.md still present"
    else
        pass "no bare-name agent caveman-$role.md"
    fi
    for effort in $EFFORTS; do
        f="$AGENTS_DIR/caveman-$role-$effort.md"
        if [ ! -f "$f" ]; then
            fail "missing $f"
            continue
        fi
        fm="$(sed -n '/^---$/,/^---$/p' "$f")"
        if printf '%s' "$fm" | grep -qE "^name: caveman-$role-$effort\$"; then
            pass "caveman-$role-$effort: name matches filename"
        else
            fail "caveman-$role-$effort: name does not match filename"
        fi
        if printf '%s' "$fm" | grep -qE "^effort: $effort\$"; then
            pass "caveman-$role-$effort: effort matches suffix"
        else
            fail "caveman-$role-$effort: effort does not match suffix"
        fi
        model="$(printf '%s' "$fm" | sed -n 's/^model: *//p')"
        if [ -n "$model" ] && [ "$model" != "inherit" ]; then
            pass "caveman-$role-$effort: model pinned ($model)"
        else
            fail "caveman-$role-$effort: model must be pinned"
        fi
        if grep -q '{{EFFORT}}' "$f"; then
            fail "caveman-$role-$effort: unexpanded placeholder"
        else
            pass "caveman-$role-$effort: no unexpanded placeholder"
        fi
        if printf '%s' "$fm" | grep -q 'Dispatch only the variant named by <SUPERPOWERS_CONFIG>'; then
            pass "caveman-$role-$effort: description steers dispatch to the configured variant"
        else
            fail "caveman-$role-$effort: description lacks the variant-dispatch sentence"
        fi
    done
done

# --- Templates: one per role, placeholder present, no colon-space in description ---
for role in $ROLES; do
    t="$TEMPLATES/caveman-$role.md"
    if [ -f "$t" ] && grep -qE "^name: caveman-$role-\{\{EFFORT\}\}\$" "$t" && grep -qE '^effort: \{\{EFFORT\}\}$' "$t"; then
        pass "template caveman-$role carries the placeholders"
    else
        fail "template caveman-$role missing or lacks placeholders"
    fi
    desc="$(sed -n 's/^description: //p' "$t" 2>/dev/null || true)"
    case "$desc" in
        *": "*) fail "template caveman-$role description contains ': ' (breaks YAML)" ;;
        *) pass "template caveman-$role description is YAML-safe" ;;
    esac
done

if [[ "$FAILURES" -gt 0 ]]; then
    echo "STATUS: FAILED ($FAILURES failure(s))"
    exit 1
fi
echo "STATUS: PASSED"
