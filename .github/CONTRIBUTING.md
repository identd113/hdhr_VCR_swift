# Contributing

Thanks for considering a contribution to hdhrVCRplus.

## Before you start

- Check [TODO.md](../TODO.md) for already-planned deferred work and [ISSUES.md](../ISSUES.md) for known issues — your idea or bug may already be tracked there.
- For anything nontrivial, open an issue to discuss the approach before writing a PR — saves everyone rework if the direction needs adjusting.

## Building and testing

```bash
swift build          # build only
swift test            # full test suite — requires full Xcode installed (not just Command Line Tools)
```

`./deploy.sh` builds, ad-hoc signs, and launches a local debug copy of the app if you want to run it interactively — see the top of [CLAUDE.md](../CLAUDE.md) for the full build/deploy reference.

## Code conventions

This project's conventions (commit style, doc-update rules, architectural invariants) are documented in [CLAUDE.md](../CLAUDE.md) and [.claude/CONVENTIONS.md](../.claude/CONVENTIONS.md) — originally written for AI-agent-assisted development, but they apply equally to any contributor and are the fastest way to get oriented. In short:

- `docs/*.md` are the source of truth for each view/system's documented behavior — if your change affects documented behavior, update the matching doc in the same PR.
- User-visible fixes and features get a `CHANGELOG.md` entry.
- Keep commits scoped — a feature and an unrelated refactor/cleanup go in separate commits.

## Pull requests

- Make sure `swift build` and `swift test` pass (CI will also check this).
- Fill out the PR template — it's short.
- One logical change per PR is easier to review than several bundled together.

## License

By contributing, you agree your contribution is licensed under the project's [GPLv3 license](../LICENSE).
