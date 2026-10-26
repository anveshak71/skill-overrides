#!/usr/bin/env bash
# Add or update a skill override in the store.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SKILL=""
UPSTREAM_URL=""
CUSTOM_FILE=""
TARGET=""

usage() { cat <<'EOF'
Add or update a skill override in the store.

Overrides are authored in the full/ directory as full/<skill>.md.

Usage:
  # Update an existing override (after editing full/<skill>.md):
  tools/add.sh <skill>

  # Add a new override (after creating full/<skill>.md):
  tools/add.sh <skill> <upstream-url> [target-path]

  # Flag-based options:
  tools/add.sh -s <name> [-u <url>] [-t <target-path>]

Options:
  -s, --skill <name>       Skill identifier (e.g. grilling)
  -u, --upstream <url>     Raw URL of the upstream file (required for new skills)
  -t, --target <path>      Target path relative to repo root (default: .agents/skills/<skill>/SKILL.md)
  -h, --help               Show this help message

Examples:
  # Update an existing override after editing full/grilling.md:
  tools/add.sh grilling

  # Add a new skill after placing customized file in full/my-skill.md:
  tools/add.sh my-skill https://raw.githubusercontent.com/.../SKILL.md
EOF
}

positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--skill)    SKILL="${2:?--skill needs a value}"; shift 2 ;;
    -u|--upstream) UPSTREAM_URL="${2:?--upstream needs a value}"; shift 2 ;;
    -f|--file)     CUSTOM_FILE="${2:?--file needs a value}"; shift 2 ;;
    -t|--target)   TARGET="${2:?--target needs a value}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)             positional+=("$1"); shift ;;
  esac
done

if [ ${#positional[@]} -gt 0 ]; then
  [ -z "$SKILL" ] && [ ${#positional[@]} -ge 1 ] && SKILL="${positional[0]}"

  if [ ${#positional[@]} -ge 2 ]; then
    case "${positional[1]}" in
      http://*|https://*)
        [ -z "$UPSTREAM_URL" ] && UPSTREAM_URL="${positional[1]}"
        [ -z "$CUSTOM_FILE" ] && [ ${#positional[@]} -ge 3 ] && CUSTOM_FILE="${positional[2]}"
        [ -z "$TARGET" ] && [ ${#positional[@]} -ge 4 ] && TARGET="${positional[3]}"
        ;;
      *)
        [ -z "$CUSTOM_FILE" ] && CUSTOM_FILE="${positional[1]}"
        [ -z "$TARGET" ] && [ ${#positional[@]} -ge 3 ] && TARGET="${positional[2]}"
        ;;
    esac
  fi
fi

if [ -z "$SKILL" ]; then
  echo "ERROR: skill name is required." >&2
  usage >&2
  exit 2
fi

MANIFEST="$ROOT_DIR/manifest.tsv"

# Auto-detect existing skill details from manifest.tsv if registered
manifest_target=""
manifest_upstream=""
manifest_full=""
if [ -f "$MANIFEST" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac

    IFS=$'\t' read -r m_skill m_target m_upstream m_upstream_sha m_patched_sha m_patch m_full extra <<< "$line"
    if [ "$m_skill" = "$SKILL" ]; then
      manifest_target="$m_target"
      manifest_upstream="$m_upstream"
      manifest_full="$m_full"
      break
    fi
  done < "$MANIFEST"
fi

if [ -z "$TARGET" ] && [ -n "$manifest_target" ]; then
  TARGET="$manifest_target"
fi

if [ -z "$UPSTREAM_URL" ] && [ -n "$manifest_upstream" ]; then
  UPSTREAM_URL="$manifest_upstream"
fi

if [ -z "$CUSTOM_FILE" ]; then
  if [ -n "$manifest_full" ] && [ -f "$ROOT_DIR/$manifest_full" ]; then
    CUSTOM_FILE="$ROOT_DIR/$manifest_full"
  elif [ -f "$ROOT_DIR/full/$SKILL.md" ]; then
    CUSTOM_FILE="$ROOT_DIR/full/$SKILL.md"
  elif [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
    CUSTOM_FILE="$TARGET"
  elif [ -f ".agents/skills/$SKILL/SKILL.md" ]; then
    CUSTOM_FILE=".agents/skills/$SKILL/SKILL.md"
  fi
fi

if [ -z "$UPSTREAM_URL" ]; then
  echo "ERROR: upstream URL is required for new skills (or specify -u/--upstream)." >&2
  usage >&2
  exit 2
fi

if [ -z "$CUSTOM_FILE" ]; then
  echo "ERROR: custom file could not be found. Create 'full/$SKILL.md' or specify -f/--file <path>." >&2
  usage >&2
  exit 2
fi

if [ ! -f "$CUSTOM_FILE" ]; then
  echo "ERROR: custom file does not exist: $CUSTOM_FILE" >&2
  exit 1
fi

TARGET="${TARGET:-.agents/skills/$SKILL/SKILL.md}"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

upstream_tmp="$WORK/upstream.tmp"
echo "Fetching upstream from $UPSTREAM_URL..."
if ! curl -fsSL "$UPSTREAM_URL" -o "$upstream_tmp"; then
  echo "ERROR: Failed to download upstream file from $UPSTREAM_URL" >&2
  exit 2
fi

if cmp -s "$upstream_tmp" "$CUSTOM_FILE"; then
  echo "ERROR: Custom file is identical to upstream. No local override to save." >&2
  exit 1
fi

upstream_hash="$(sha256 "$upstream_tmp")"
patched_hash="$(sha256 "$CUSTOM_FILE")"

mkdir -p "$ROOT_DIR/patches" "$ROOT_DIR/full"

patch_rel="patches/$SKILL.patch"
full_rel="full/$SKILL.md"

patch_file="$ROOT_DIR/$patch_rel"
full_file="$ROOT_DIR/$full_rel"

# Generate unified diff with git/patch-friendly labels
# diff -u returns 1 when files differ, ignore return code with || true
diff -u --label "a/$TARGET" --label "b/$TARGET" "$upstream_tmp" "$CUSTOM_FILE" > "$patch_file" || true

# Copy full snapshot if not already the destination file
if [ "$(realpath "$CUSTOM_FILE")" != "$(realpath "$full_file" 2>/dev/null || true)" ]; then
  cp "$CUSTOM_FILE" "$full_file"
fi

# Verify patch reproduction in sandbox
test_repo="$WORK/repo"
mkdir -p "$test_repo/$(dirname "$TARGET")"
cp "$upstream_tmp" "$test_repo/$TARGET"
git -C "$test_repo" init -q
git -C "$test_repo" apply "$patch_file"

applied_hash="$(sha256 "$test_repo/$TARGET")"
if [ "$applied_hash" != "$patched_hash" ]; then
  echo "ERROR: Generated patch does not reproduce the custom file correctly." >&2
  rm -f "$patch_file" "$full_file"
  exit 1
fi

# Update manifest.tsv
MANIFEST="$ROOT_DIR/manifest.tsv"
new_entry=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "$SKILL" "$TARGET" "$UPSTREAM_URL" "$upstream_hash" "$patched_hash" "$patch_rel" "$full_rel")

updated=0
manifest_tmp="$WORK/manifest.tsv"
if [ -f "$MANIFEST" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*)
        printf '%s\n' "$line" >> "$manifest_tmp"
        continue
        ;;
    esac

    first_col=$(printf '%s\n' "$line" | cut -f1)
    if [ "$first_col" = "$SKILL" ]; then
      printf '%s\n' "$new_entry" >> "$manifest_tmp"
      updated=1
    else
      printf '%s\n' "$line" >> "$manifest_tmp"
    fi
  done < "$MANIFEST"
fi

if [ "$updated" -eq 0 ]; then
  printf '%s\n' "$new_entry" >> "$manifest_tmp"
fi

mv "$manifest_tmp" "$MANIFEST"

echo "Running offline validation..."
"$ROOT_DIR/tools/validate.sh" --offline "$SKILL"

echo ""
echo "Successfully recorded override for '$SKILL':"
echo "  Manifest: $MANIFEST"
echo "  Patch:    $patch_rel"
echo "  Snapshot: $full_rel"
echo "  Upstream SHA: $upstream_hash"
echo "  Patched SHA:  $patched_hash"
echo ""
echo "To commit changes:"
echo "  git add manifest.tsv $patch_rel $full_rel"
echo "  git commit -m \"feat: override $SKILL\""
