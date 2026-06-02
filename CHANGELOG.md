# Changelog

## Unreleased

### Added

- Full release gate script: `test-token-saver-release.ps1`.
- MVP guards for immediate, race-safe panel reset behavior.

## v0.1.0 - 2026-06-02

Initial lightweight Windows release.

### Added

- Token saver floating panel for local token usage and savings estimates.
- Agent-specific installers for Codex, Claude Code, Cursor, Aider, and generic coding agents.
- `install-all-agents.ps1` with installed-agent detection and `-ForceAll`.
- Compact `.codex/context.md` generation through `codex-token-kit.ps1` and `codex-slim.ps1`.
- Local `.codex/stats.json` metrics and context-cache support.
- Safe uninstall that removes Token saver marker blocks and preserves pre-existing user files.
- GitHub-friendly README, preview image, MIT license, and detailed guide.

### Notes

Token saver is a local workflow and estimation tool. It is not a billing reader and does not claim exact ChatGPT, Codex App, or OpenAI account usage totals.
