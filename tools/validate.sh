#!/usr/bin/env bash
# Validate integrity of manifest.tsv, patches, and full snapshots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OFFLINE=0
SKILL_FILTER=()

usage() { cat <<'EOF'
Validate integrity of manifest.tsv, patches, and snapshots.

Usage:
  tools/validate.sh [options] [skill]...

Options:
  --offline       Skip network downloads; only validate local files and hashes
  -h, --help      Show this help message

Exit: 0 on success, 1 on validation error.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --offline) OFFLINE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)         SKILL_FILTER+=("$1"); shift ;;
  esac
done

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

want() {
  [ ${#SKILL_FILTER[@]} -eq 0 ] && return 0
  local s
  for s in "${SKILL_FILTER[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

MANIFEST="$ROOT_DIR/manifest.tsv"
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest.tsv not found at $MANIFEST" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

errors=0
checked=0
line_no=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line_no=$((line_no + 1))
  case "$raw_line" in
    ''|'#'*) continue ;;
  esac

  IFS=$'\t' read -r skill target upstream_url upstream patched patch full extra <<< "$raw_line"

  if [ "$skill" = "skill" ]; then
    # Header row
    continue
  fi

  # Check field count
  if [ -z "$skill" ] || [ -z "$target" ] || [ -z "$upstream_url" ] || \
     [ -z "$upstream" ] || [ -z "$patched" ] || [ -z "$patch" ] || [ -z "$full" ] || [ -n "${extra:-}" ]; then
    echo "ERROR [line $line_no]: malformed row in manifest.tsv (must have exactly 7 tab-separated columns)" >&2
    echo "       line: $raw_line" >&2
    errors=$((errors + 1))
    continue
  fi

  want "$skill" || continue
  checked=$((checked + 1))
  echo "checking   $skill..."

  # 1. Check local files existence
  patch_file="$ROOT_DIR/$patch"
  full_file="$ROOT_DIR/$full"

  if [ ! -f "$patch_file" ]; then
    echo "  FAIL: patch file missing: $patch" >&2
    errors=$((errors + 1))
    continue
  fi

  if [ ! -f "$full_file" ]; then
    echo "  FAIL: full snapshot missing: $full" >&2
    errors=$((errors + 1))
    continue
  fi

  # 2. Check full snapshot hash
  full_hash="$(sha256 "$full_file")"
  if [ "$full_hash" != "$patched" ]; then
    echo "  FAIL: $full hash is $full_hash, expected patched_sha256 $patched" >&2
    errors=$((errors + 1))
  else
    echo "  ok: $full matches patched_sha256"
  fi

  # 3. Check upstream and patch application
  if [ "$OFFLINE" -eq 1 ]; then
    echo "  skip: network check skipped (--offline)"
    continue
  fi

  upstream_tmp="$WORK/upstream-$skill.tmp"
  if ! curl -fsSL "$upstream_url" -o "$upstream_tmp"; then
    echo "  FAIL: unable to fetch upstream_url: $upstream_url" >&2
    errors=$((errors + 1))
    continue
  fi

  actual_upstream_hash="$(sha256 "$upstream_tmp")"
  if [ "$actual_upstream_hash" != "$upstream" ]; then
    echo "  WARN: upstream has moved! Current SHA is $actual_upstream_hash, manifest has $upstream" >&2
    echo "        run: tools/refresh.sh $skill" >&2
  else
    echo "  ok: upstream SHA matches manifest"
  fi

  # Test patch application against upstream_sha256 state
  test_repo="$WORK/repo-$skill"
  rm -rf "$test_repo"
  mkdir -p "$test_repo/$(dirname "$target")"
  cp "$upstream_tmp" "$test_repo/$target"
  git -C "$test_repo" init -q
  git -C "$test_repo" config user.email "test@example.com"
  git -C "$test_repo" config user.name "Test"
  git -C "$test_repo" add "$target"
  git -C "$test_repo" commit -qm "upstream baseline"

  if git -C "$test_repo" apply --check "$patch_file" 2>/dev/null; then
    git -C "$test_repo" apply "$patch_file"
    applied_hash="$(sha256 "$test_repo/$target")"
    if [ "$applied_hash" != "$patched" ]; then
      echo "  FAIL: patch applied but hash is $applied_hash, expected $patched" >&2
      errors=$((errors + 1))
    elif ! cmp -s "$test_repo/$target" "$full_file"; then
      echo "  FAIL: patched result does not match $full byte-for-byte" >&2
      errors=$((errors + 1))
    else
      echo "  ok: patch applies cleanly and reproduces $full"
    fi
  else
    echo "  FAIL: patch does not apply cleanly to current upstream" >&2
    errors=$((errors + 1))
  fi

done < "$MANIFEST"

if [ "$checked" -eq 0 ]; then
  echo "No matching skills found to validate."
  exit 0
fi

if [ "$errors" -gt 0 ]; then
  echo "Validation failed with $errors error(s)." >&2
  exit 1
fi

echo "Validation passed ($checked skill(s) checked)."
exit 0
