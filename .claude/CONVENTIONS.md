# Working Conventions

Overrides default Claude Code behavior.

## Commits
- Group by theme; split unrelated concerns into separate commits with verbose messages.
- Never push, tag, or set remote refs without explicit user permission.

## Code Changes
- Hard stop and explain before writing code that breaks an established convention. Seek permission.
- No rearchitecting for improvement/cleanup without asking first. Keep changes small and focused.
- Explain what's changing, why, and how it affects complexity/performance before implementing.
- Do not start coding without ~95% confidence in approach. When uncertain, ask.
- "Could we X?" is a question, not a directive — do not execute without confirming direction.

## Visual Changes
- Read the relevant `docs/*.md` before editing any view — they are the source of truth.
- Alert before removing or changing any visual element (layout, colors, icons, badges, spacing).
- If doc contradicts code, immediately flag it and stop — do not silently reconcile.

## Deploy & Scripts
- Update `deploy.sh` to compensate for build issues rather than working around manually.
- Add unexpected build artifacts to `.gitignore` (targeted wildcard if parent scope is too broad).
- Script any multi-step repeatable task; add `--help` flag; document in CLAUDE.md's `## Tools` table.

## Issue Tracking
- Unrelated bugs found during work → `ISSUES.md` at repo root. Note commit hash on resolution.
- `ISSUES.md` is a historical "don't repeat this" reference used during code reviews.

## Logs
- Always limit log output (e.g., `tail -n 100`). Never open-ended tail.
