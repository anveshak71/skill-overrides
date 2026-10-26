#!/usr/bin/env bash
# Re-apply local customizations to third-party agent skills. See README.md.
set -euo pipefail
shopt -s nullglob

DEFAULT_BASE_URL="https://raw.githubusercontent.com/anveshak71/skill-overrides/main"

BASE_URL=""
TARGET_DIR=""
CHECK_ONLY=0
DRY_RUN=0
SKILL_FILTER=()

usage() { cat <<'EOF'
Re-apply local customizations to third-party agent skills.

  curl -fsSL https://raw.githubusercontent.com/anveshak71/skill-overrides/main/apply-overrides.sh | bash

  --base-url URL   store to fetch from (default: $OVERRIDES_BASE_URL, else the URL above)
  --dir DIR        repository to patch (default: its git worktree, else $PWD)
  --check          apply nothing; exit 1 if any override is not applied
  --dry-run        report what would change, then stop
  -h, --help       this text
  <skill>...       only patch these skills

Exit: 0 ok, 1 action needed/conflict, 2 usage or fetch error.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="${2:?--base-url needs a value}"; shift 2 ;;
    --dir)      TARGET_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --check)    CHECK_ONLY=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)          SKILL_FILTER+=("$1"); shift ;;
  esac
done

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

# --- resolve the repository to patch ------------------------------------------
ROOT="${TARGET_DIR:-$PWD}"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  ROOT="$(git -C "$ROOT" rev-parse --show-toplevel)"
elif [ -z "$TARGET_DIR" ]; then
  echo "not inside a git worktree; pass --dir" >&2
  exit 2
fi

# --- resolve the override store: local checkout first, then remote -------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STORE=""
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/manifest.tsv" ]; then
  STORE="$SCRIPT_DIR"
else
  BASE_URL="${BASE_URL:-${OVERRIDES_BASE_URL:-$DEFAULT_BASE_URL}}"
  BASE_URL="${BASE_URL%/}"
  STORE="$WORK/store"
  mkdir -p "$STORE/patches" "$STORE/full"
  curl -fsSL "$BASE_URL/manifest.tsv" -o "$STORE/manifest.tsv" ||
    { echo "cannot fetch $BASE_URL/manifest.tsv" >&2; exit 2; }
fi

fetch() {  # fetch <relative path>; echoes the local path of the file
  local rel="$1" dest
  if [ "$STORE" != "$WORK/store" ]; then
    printf '%s\n' "$STORE/$rel"
    return
  fi
  dest="$STORE/$rel"
  [ -f "$dest" ] || curl -fsSL "$BASE_URL/$rel" -o "$dest" ||
    { echo "cannot fetch $BASE_URL/$rel" >&2; exit 2; }
  printf '%s\n' "$dest"
}

want() {
  [ ${#SKILL_FILTER[@]} -eq 0 ] && return 0
  local s
  for s in "${SKILL_FILTER[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# --- apply --------------------------------------------------------------------
todo=0
while IFS=$'\t' read -r skill target upstream_url upstream patched patch full; do
  case "${skill:-}" in ''|'#'*|skill) continue ;; esac
  want "$skill" || continue

  dest="$ROOT/$target"
  if [ ! -f "$dest" ]; then
    echo "absent     $skill ($target not installed)"
    continue
  fi

  current="$(sha256 "$dest")"
  if [ "$current" = "$patched" ]; then
    echo "unchanged  $skill (override already applied)"
    continue
  fi

  todo=$((todo + 1))
  if [ "$current" = "$upstream" ]; then
    source_file="$(fetch "$patch")"
    how="patch $patch"
  else
    echo "drifted    $skill (installed ${current:0:12} is neither upstream nor patched; using $full)"
    echo "           upstream moved? refresh with: tools/refresh.sh $skill" >&2
    echo "           upstream file: $upstream_url" >&2
    source_file="$(fetch "$full")"
    how="full $full"
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "needs      $skill ($how)"
    continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would      $skill ($how)"
    continue
  fi

  if [ "$how" = "full $full" ]; then
    cp "$source_file" "$dest"
  elif git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$ROOT" apply --check "$source_file" 2>/dev/null &&
      git -C "$ROOT" apply "$source_file" ||
      { echo "CONFLICT   $skill -> $source_file; run: git -C $ROOT apply --3way $source_file" >&2; exit 1; }
  else
    patch -p1 --forward --batch -s -d "$ROOT" -i "$source_file" ||
      { echo "CONFLICT   $skill -> $source_file" >&2; exit 1; }
  fi

  result="$(sha256 "$dest")"
  if [ "$result" != "$patched" ]; then
    echo "MISMATCH   $skill applied but hash is ${result:0:12}, expected ${patched:0:12}" >&2
    echo "           fix: tools/refresh.sh $skill" >&2
    exit 1
  fi
  echo "applied    $skill ($how)"
done < "$STORE/manifest.tsv"

if [ "$CHECK_ONLY" -eq 1 ] && [ "$todo" -gt 0 ]; then
  echo "-> $todo override(s) not applied" >&2
  exit 1
fi
exit 0
