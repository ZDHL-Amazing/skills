#!/usr/bin/env bash
# next_filename.sh
# Usage: bash next_filename.sh <migration_dir> <description>
# Output: the full migration filename, e.g. V20260508_001__add_order_table.sql
#
# Compatible with: Linux, macOS (bash 3+, no GNU-only tools)
# No Python, no perl-regex grep required.

set -euo pipefail

MIGRATION_DIR="${1:?Usage: next_filename.sh <migration_dir> <description>}"
DESCRIPTION="${2:?Usage: next_filename.sh <migration_dir> <description>}"

# ── 1. Today's date ─────────────────────────────────────────────────────────
TODAY=$(date +%Y%m%d)

# ── 2. Ensure migration directory exists ────────────────────────────────────
mkdir -p "$MIGRATION_DIR"

# ── 3. Find highest sequence number for today ───────────────────────────────
# Matches files like: V20260508_001__xxx.sql
# Uses sed BRE (POSIX, works on macOS and Linux without GNU grep -P)
EXISTING=$(
  ls "$MIGRATION_DIR"/V${TODAY}_[0-9][0-9][0-9]__*.sql 2>/dev/null \
  | sed 's|.*V[0-9]*_\([0-9][0-9][0-9]\)__.*|\1|' \
  | sort -n \
  | tail -1
) || true

# ── 4. Calculate next sequence (octal-safe: strip leading zeros before math) ─
if [ -z "$EXISTING" ]; then
  NEXT_NUM=1
else
  # Strip leading zeros to avoid octal interpretation in $(( ))
  STRIPPED=$(echo "$EXISTING" | sed 's/^0*//')
  [ -z "$STRIPPED" ] && STRIPPED=0
  NEXT_NUM=$(( STRIPPED + 1 ))
fi

# Zero-pad to 3 digits
NEXT_SEQ=$(printf '%03d' "$NEXT_NUM")

# ── 5. Output filename ───────────────────────────────────────────────────────
echo "V${TODAY}_${NEXT_SEQ}__${DESCRIPTION}.sql"