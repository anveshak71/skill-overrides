#!/usr/bin/env bash
# Refresh skill overrides against updated upstream sources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=0
SKILL_FILTER=()

usage() { cat <<'EOF'
Check upstream sources and rebase local overrides when upstream changes.

Usage:
  tools/refresh.sh [options] [skill]...

Options:
  --dry-run       Check for upstream changes without modifying files
  -h, --help      Show this help message

Exit: 0 on success, 1 on conflict or error.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
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
processed=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  case "$raw_line" in
    ''|'#'*) continue ;;
  esac

  IFS=$'\t' read -r skill target upstream_url upstream patched patch full extra <<< "$raw_line"
  [ "$skill" = "skill" ] && continue

  want "$skill" || continue
  processed=$((processed + 1))

  patch_file="$ROOT_DIR/$patch"
  full_file="$ROOT_DIR/$full"

  if [ ! -f "$patch_file" ] || [ ! -f "$full_file" ]; then
    echo "ERROR      $skill (missing patch or full file)" >&2
    errors=$((errors + 1))
    continue
  fi

  new_upstream_tmp="$WORK/new_upstream-$skill.tmp"
  if ! curl -fsSL "$upstream_url" -o "$new_upstream_tmp"; then
    echo "ERROR      $skill (failed to fetch $upstream_url)" >&2
    errors=$((errors + 1))
    continue
  fi

  new_upstream_hash="$(sha256 "$new_upstream_tmp")"

  if [ "$new_upstream_hash" = "$upstream" ]; then
    echo "up to date $skill (upstream hash matches $upstream)"
    continue
  fi

  echo "drifted    $skill (upstream changed from ${upstream:0:12} to ${new_upstream_hash:0:12})"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would      $skill (rebase override against new upstream)"
    continue
  fi

  # 1. Recreate the base upstream from full snapshot + reverse patch
  base_dir="$WORK/base-$skill"
  mkdir -p "$base_dir/$(dirname "$target")"
  base_file="$base_dir/$target"
  cp "$full_file" "$base_file"

  base_ready=0
  if git -C "$base_dir" apply --reverse "$patch_file" 2>/dev/null; then
    recreated_base_hash="$(sha256 "$base_file")"
    if [ "$recreated_base_hash" = "$upstream" ]; then
      base_ready=1
    fi
  fi

  # 2. Perform 3-way merge
  merged_file="$WORK/merged-$skill.md"
  cp "$full_file" "$merged_file"

  merge_ok=0
  if [ "$base_ready" -eq 1 ]; then
    # Standard 3-way merge: ours=merged_file, base=base_file, theirs=new_upstream_tmp
    if git merge-file -q -L "local override" -L "upstream baseline" -L "new upstream" \
        "$merged_file" "$base_file" "$new_upstream_tmp"; then
      merge_ok=1
    fi
  else
    # Fallback: try git apply against new upstream
    test_repo="$WORK/fallback-repo-$skill"
    mkdir -p "$test_repo/$(dirname "$target")"
    cp "$new_upstream_tmp" "$test_repo/$target"
    git -C "$test_repo" init -q
    if git -C "$test_repo" apply "$patch_file" 2>/dev/null; then
      cp "$test_repo/$target" "$merged_file"
      merge_ok=1
    fi
  fi

  if [ "$merge_ok" -eq 0 ]; then
    echo "CONFLICT   $skill (upstream changes conflict with current override)" >&2
    echo "           Manual resolution required. Run git merge-file or inspect upstream changes." >&2
    errors=$((errors + 1))
    continue
  fi

  # 3. Check if merged result is identical to new upstream (meaning override was subsumed)
  if cmp -s "$new_upstream_tmp" "$merged_file"; then
    echo "NOTICE     $skill (new upstream already includes your changes; override is now a no-op)"
  fi

  # 4. Generate new patch and save new full snapshot
  diff -u --label "a/$target" --label "b/$target" "$new_upstream_tmp" "$merged_file" > "$patch_file" || true
  cp "$merged_file" "$full_file"

  new_patched_hash="$(sha256 "$full_file")"

  # 5. Update manifest.tsv
  manifest_tmp="$WORK/manifest.tsv"
  while IFS= read -r mline || [ -n "$mline" ]; do
    case "$mline" in
      ''|'#'*)
        printf '%s\n' "$mline" >> "$manifest_tmp"
        continue
        ;;
    esac

    first_col=$(printf '%s\n' "$mline" | cut -f1)
    if [ "$first_col" = "$skill" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$skill" "$target" "$upstream_url" "$new_upstream_hash" "$new_patched_hash" "$patch" "$full" \
        >> "$manifest_tmp"
    else
      printf '%s\n' "$mline" >> "$manifest_tmp"
    fi
  done < "$MANIFEST"

  mv "$manifest_tmp" "$MANIFEST"
  echo "refreshed  $skill (patch rebased cleanly, manifest updated)"

done < "$MANIFEST"

if [ "$processed" -eq 0 ]; then
  echo "No matching skills found to refresh."
  exit 0
fi

if [ "$errors" -gt 0 ]; then
  echo "Refresh finished with $errors conflict(s) or error(s)." >&2
  exit 1
fi

echo "Done."
exit 0
