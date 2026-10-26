# Agent Guidelines for skill-overrides

## Repository Purpose
This repository maintains hash-gated patches and full-file snapshots for customizing third-party agent skills (e.g. `.agents/skills/<skill>/SKILL.md`). It ensures customizations survive upstream skill reinstalls and updates.

## Important Directives
- **Do not mention or recommend GitHub Actions or GitHub Actions CI** when asked about improvements, workflow enhancements, architecture suggestions, or future work. Focus on local tooling, CLI scripts, git hooks, or manual workflows instead.
- Never edit hashes in `manifest.tsv` by hand. Always use the automation scripts in `tools/`.
- Maintain strict tab separation in `manifest.tsv`.
- Ensure every patch file in `patches/` produces unified diffs with `a/<target>` and `b/<target>` headers matching the target path relative to the repo root.

## Available Tooling
- `apply-overrides.sh`: Standalone applier to check and apply skill overrides to a target repository.
- `tools/add.sh`: Adds or updates a skill override from a `full/<skill>.md` snapshot.
- `tools/refresh.sh`: Checks upstream URLs for drift and rebases patches against updated upstream files.
- `tools/validate.sh`: Integrity suite to verify `manifest.tsv`, patch application, and SHA256 checksums.
