# skill-overrides

Keep your edits to third-party agent skills across re-installs and updates.

Skills installed under `.agents/skills/` are owned upstream — installing or updating
one overwrites the file, so hand edits are lost. This repository stores each edit as
a **hash-gated patch** plus a **full-file snapshot**, and ships a one-command applier
that re-applies them to any repository.

## Quick start

In any repository where the skill is installed:

```bash
curl -fsSL https://raw.githubusercontent.com/anveshak71/skill-overrides/main/apply-overrides.sh | bash
```

Output tells you exactly what happened:

```
applied    grilling (patch patches/grilling.patch)
```

Run it again and nothing happens:

```
unchanged  grilling (override already applied)
```

Patch a single skill, preview, or gate a sandbox/CI startup:

```bash
... | bash -s -- grilling        # only grilling
... | bash -s -- --dry-run
bash apply-overrides.sh --check  # exit 1 if anything is not applied (from a checkout)
```

## What's inside

```
apply-overrides.sh     the applier (no checkout needed; also usable from a clone)
manifest.tsv           skill → target file, upstream hash, patched hash, patch, snapshot
patches/<skill>.patch  diff against the upstream file
full/<skill>.md        whole customized file, used when upstream moved
```

`manifest.tsv` is tab-separated:

| field | meaning |
| --- | --- |
| `skill` | identifier; also the CLI filter argument |
| `target` | installed file path, relative to the repository root |
| `upstream_url` | where upstream publishes the file |
| `upstream_sha256` | hash of the pristine upstream file; the patch applies to this |
| `patched_sha256` | hash after the override; used for idempotency and for verifying writes |
| `patch` | patch applied when the installed file matches `upstream_sha256` |
| `full` | snapshot copied when it doesn't (upstream changed) |

## How it decides

The applier hashes the installed file and compares it to the manifest:

| Installed file | Action | Result |
| --- | --- | --- |
| equals `patched_sha256` | nothing | `unchanged`, exit 0 |
| equals `upstream_sha256` | `git apply` (or `patch -p1`) the stored patch | `applied`, exit 0 |
| anything else | copy `full/<skill>.md` | `drifted` + `applied` |
| missing | nothing | `absent`, exit 0 |

Every write is verified against `patched_sha256`, so a stale store fails loudly with
`MISMATCH` instead of silently writing the wrong content.

## Adding or updating an override

1. Install/update the skill, then edit it in your repository until it is what you want.
2. Regenerate the entry (paths below assume you're in the edited repository):

```bash
S=grilling; D=.agents/skills/$S/SKILL.md; P=patches/$S.patch; F=full/$S.md
STORE=/path/to/skill-overrides
curl -fsSL <upstream_url from manifest.tsv> -o /tmp/upstream.md
mkdir -p "$STORE/$(dirname $D)" "$STORE/patches" "$STORE/full"
cp /tmp/upstream.md /tmp/check-$S.md && mkdir -p /tmp/c/$(dirname $D) && cp /tmp/upstream.md /tmp/c/$D
diff -u --label "a/$D" --label "b/$D" /tmp/upstream.md "$D" > "$STORE/$P"
patch -p1 -d /tmp/c -i "$STORE/$P" && cmp /tmp/c/$D "$D"   # must reproduce your file
cp "$D" "$STORE/$F"
sha256sum /tmp/upstream.md "$D"   # paste into manifest.tsv: upstream_sha256, patched_sha256
```

3. Update that row in `manifest.tsv`, then commit and push the store. `diff -u` must
   produce a non-empty patch; if it's empty the skill has no local edits.

Adding a brand-new skill: copy its row shape into `manifest.tsv` (7 tab-separated
fields), then run the same recipe.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `drifted … using full/…` | upstream changed the file | regenerate (see above) |
| `CONFLICT` | upstream text moved under the patch | `git -C <repo> apply --3way <patch>`, then regenerate |
| `MISMATCH` | stale `full/<skill>.md` | regenerate; the hash check caught it |
| `cannot fetch …` | wrong `--base-url`, or repo private | pass `--base-url`, or check visibility |
| `not inside a git worktree` | ran outside a repo | pass `--dir <repo>` |

## Attribution

`patches/` and `full/` contain modifications of skills published by
[mattpocock/skills](https://github.com/mattpocock/skills), MIT licensed,
© Matt Pocock. `upstream_url` in each manifest row points at the original.
