# Changelog

## Unreleased

### Added

- Full release gate script: `test-token-saver-release.ps1`.
- MVP guards for immediate, race-safe panel reset behavior.
- Release gate checks for stale installed runtime files.
- Release gate dependencies are included in installed runtimes.
- Regression coverage for corrupt runtime data, transient missing usage data, locked history files, panel child-process cleanup, and uninstall preservation of user agent-rule files.
- Regression coverage for uninstall keep-flags that preserve agent rules and auto-attached project data while removing the installed runtime.
- Regression coverage for Codex session `token_count` parsing so live usage does not silently drop to zero.
- Release gate self-test mode verifies structured failure JSON and nonzero exits without recursively running the full gate.
- Regression coverage for `install-all-agents.ps1` detected-agent and `-ForceAll` behavior.

### Changed

- Panel reset now clears immediately and ignores refresh results that started before reset.
- Panel duplicate-launch mutex is acquired before WinForms loads.
- Release gate now reports structured JSON with failed and skipped counts.
- Global history writes are best-effort and no longer fail context generation when the history file is locked.
- Auto-attach now processes recent history newest-first before applying the project limit, so active projects are less likely to be skipped when many old projects exist.
- Panel charts now anchor their 15-minute buckets to the latest refresh time, reducing visual drift when the window repaints without new data.
- `install-all-agents.ps1 -DetectedAgents` now accepts comma-separated values as well as array-style input.

### Fixed

- Prevented transient missing data from resetting usage baselines and creating false token deltas when data returns.
- Ensured panel refresh child processes are waited on during cleanup.
- Refused custom install-root uninstall unless `-RemoveData` is explicit, with regression coverage that the target directory stays untouched.
- Helper saved history now recognizes `atUtc`, `generatedAtUtc`, and legacy `generatedAt` timestamps, so saved-token peaks and latest source projects are not dropped from the panel.

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
