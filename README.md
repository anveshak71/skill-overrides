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

Overrides are authored and maintained directly in the `full/` directory as complete markdown files (`full/<skill>.md`).

1. Edit or create the full snapshot at `full/<skill>.md`.
2. Generate or re-generate the patch and manifest entry using `tools/add.sh`:

```bash
# For an existing skill already in manifest.tsv:
tools/add.sh <skill>

# For a new skill (with full/<skill>.md pre-created):
tools/add.sh <skill> <upstream_url>
```

This automatically downloads pristine upstream, calculates hashes, verifies the diff in a sandbox, generates `patches/<skill>.patch`, updates `manifest.tsv`, and validates the patch offline.

### Tooling commands

- **Update an existing override:**
  ```bash
  tools/add.sh grilling
  ```
- **Add a new override:**
  ```bash
  tools/add.sh my-skill https://raw.githubusercontent.com/.../SKILL.md
  ```
- **Refresh overrides when upstream moves:**
  ```bash
  tools/refresh.sh          # checks and rebases all skills against updated upstream
  tools/refresh.sh grilling # refresh a specific skill
  tools/refresh.sh --dry-run
  ```
- **Validate store integrity:**
  ```bash
  tools/validate.sh           # validates manifest syntax, file existence, hashes, and patch application
  tools/validate.sh --offline # validate without network downloads
  ```

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `drifted … using full/…` | upstream changed the file | run `tools/refresh.sh <skill>` |
| `CONFLICT` | upstream text moved under the patch | run `tools/refresh.sh <skill>`, or `git -C <repo> apply --3way <patch>` |
| `MISMATCH` | stale `full/<skill>.md` or wrong hash | run `tools/validate.sh` and `tools/refresh.sh <skill>` |
| `cannot fetch …` | wrong `--base-url`, or repo private | pass `--base-url`, or check visibility |
| `not inside a git worktree` | ran outside a repo | pass `--dir <repo>` |

## Attribution

`patches/` and `full/` contain modifications of skills published by
[mattpocock/skills](https://github.com/mattpocock/skills), MIT licensed,
© Matt Pocock. `upstream_url` in each manifest row points at the original.
