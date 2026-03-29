#!/usr/bin/env bash
# recipe-check.sh — mechanical checks for recipe/ directory integrity
# Validates internal links and detects orphaned files.
# Exit 0 = all checks pass, Exit 1 = issues found.

RECIPE_DIR="$(git rev-parse --show-toplevel)/recipe"
ERRORS=0

if [ ! -d "$RECIPE_DIR" ]; then
    echo "ERROR: recipe/ directory not found"
    exit 1
fi

echo "=== Recipe Mechanical Checks ==="
echo ""

# --- Check 1: Broken internal links ---
echo "Checking internal links..."

while IFS= read -r -d '' file; do
    dir="$(dirname "$file")"
    # Extract markdown link targets: [text](relative/path.md) — strip #anchor fragments
    while IFS= read -r target; do
        [ -z "$target" ] && continue
        # Skip external URLs
        case "$target" in http*) continue ;; esac
        resolved="$(cd "$dir" && realpath "$target" 2>/dev/null || echo "")"
        if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
            rel="${file#$RECIPE_DIR/}"
            echo "  BROKEN LINK: $rel -> $target"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(grep -oE '\]\([^)]+\.md[^)]*\)' "$file" 2>/dev/null | sed 's/^](\(.*\))$/\1/' | sed 's/#.*//' || true)
done < <(find "$RECIPE_DIR" -name '*.md' -type f -print0)

# --- Check 2: Orphaned techniques (referenced by zero jobs) ---
echo "Checking for orphaned techniques..."

if [ -d "$RECIPE_DIR/techniques" ]; then
    for technique in "$RECIPE_DIR/techniques"/*.md; do
        [ -f "$technique" ] || continue
        bname="$(basename "$technique")"
        refs=$(grep -rl "techniques/$bname" "$RECIPE_DIR/jobs/" "$RECIPE_DIR/recipe.md" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$refs" -eq 0 ]; then
            echo "  ORPHAN TECHNIQUE: techniques/$bname (referenced by 0 jobs or recipe.md)"
            ERRORS=$((ERRORS + 1))
        fi
    done
fi

# --- Check 3: Orphaned constraints (referenced by zero jobs) ---
echo "Checking for orphaned constraints..."

if [ -d "$RECIPE_DIR/constraints" ]; then
    for constraint in "$RECIPE_DIR/constraints"/*.md; do
        [ -f "$constraint" ] || continue
        bname="$(basename "$constraint")"
        refs=$(grep -rl "constraints/$bname" "$RECIPE_DIR/jobs/" "$RECIPE_DIR/recipe.md" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$refs" -eq 0 ]; then
            echo "  ORPHAN CONSTRAINT: constraints/$bname (referenced by 0 jobs or recipe.md)"
            ERRORS=$((ERRORS + 1))
        fi
    done
fi

# --- Check 4: Audit staleness ---
echo "Checking audit freshness..."

last_audit=$(grep -m1 'last-audit:' "$RECIPE_DIR/recipe.md" 2>/dev/null | sed 's/.*last-audit: *//' | tr -d ' ')
if [ -n "$last_audit" ]; then
    # Portable date arithmetic — parse YYYY-MM-DD without platform-specific date flags
    if date -j -f "%Y-%m-%d" "$last_audit" "+%s" >/dev/null 2>&1; then
        audit_epoch=$(date -j -f "%Y-%m-%d" "$last_audit" "+%s")
    elif date -d "$last_audit" "+%s" >/dev/null 2>&1; then
        audit_epoch=$(date -d "$last_audit" "+%s")
    else
        audit_epoch=0
    fi
    now_epoch=$(date "+%s")
    days_ago=$(( (now_epoch - audit_epoch) / 86400 ))
    if [ "$days_ago" -gt 14 ]; then
        echo "  STALE AUDIT: last audit was $days_ago days ago ($last_audit)"
        ERRORS=$((ERRORS + 1))
    else
        echo "  Audit is fresh ($days_ago days ago)"
    fi
else
    echo "  WARNING: No last-audit timestamp found in recipe.md"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo "FAILED: $ERRORS issue(s) found"
    exit 1
else
    echo "PASSED: All checks clean"
    exit 0
fi
