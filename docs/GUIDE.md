# Token saver Guide

This guide contains the details that are intentionally kept out of the GitHub landing README.

## Architecture

Token saver has three layers:

- `codex-token-kit.ps1`: the user-facing context generation entry point.
- `codex-slim.ps1`: the lightweight context packer that writes `.codex/context.md` and `.codex/stats.json`.
- `token-helper.ps1` / `token-helper-panel.ps1`: the local usage tracker and floating Windows panel.

Agent installers are thin wrappers around `install.ps1`. They choose which adapter files to write:

- Codex: `%USERPROFILE%\.codex\AGENTS.md`
- Claude Code: `CLAUDE.md`
- Cursor: `.cursor/rules/token-saver.mdc`
- Aider: `.aider.token-saver.md`
- Generic: `TOKEN_SAVER.md`

Each adapter uses the same marker block:

```text
<!-- BEGIN TOKEN SAVER AUTO ATTACH -->
...
<!-- END TOKEN SAVER AUTO ATTACH -->
```

Uninstall removes only this marker block and helper-created project files that did not exist before install.

## Context Generation

`codex-slim.ps1` scans the project, skips noisy folders and large binary files, then prioritizes:

1. Changed files
2. Explicitly included files
3. README and agent instruction files
4. Config files
5. Entry points
6. Tests
7. Recent normal files

The generated context is written to:

```text
.codex/context.md
```

The metrics file is written to:

```text
.codex/stats.json
```

The stats file includes:

- `originalTokens`
- `outputTokens`
- `savedTokens`
- selected file metadata
- coverage risk
- context cache hit count
- stable-reference saved token estimates

## Context Cache

Token saver stores a small cache at:

```text
.codex/context-cache.json
```

On later runs, unchanged low-priority normal files can be represented by cached summaries. Protected files are not replaced by cache references:

- changed files
- explicitly included files
- README / essential instruction files
- entry points
- tests

This protects quality while still reducing repeated context.

## Usage Tracking

The floating panel reads local observable metrics. It can track:

- Codex helper-generated `.codex/stats.json`
- context file token estimates
- generic logs containing common token fields
- manual observations passed through CLI

Examples:

```powershell
token-helper refresh -ProjectPath .
token-helper refresh -ProjectPath . -ContextPath ".\context.md"
token-helper refresh -ProjectPath . -LogPath ".\logs"
token-helper refresh -ProjectPath . -ManualUsageTokens 12000 -ManualSavedTokens 3000
```

This is not billing data. It is a local estimate for workflow feedback.

## Panel Behavior

The panel is a Windows Forms floating window.

- `X` closes the panel only.
- Closing the panel does not disable Token saver.
- Settings > `Helper enabled` controls online/offline state.
- Pinning locks the panel and enables click-through outside caption buttons.
- Install creates a desktop shortcut and Start Menu entry named `Token saver`.

## Development Checks

Run the MVP test:

```powershell
powershell -ExecutionPolicy Bypass -File .\test-token-helper-mvp.ps1
```

Run the panel smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File .\test-token-helper-panel-smoke.ps1
```

Run context regression:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-context-regression.ps1
```

Sync global scripts after local changes:

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sync-global-bin.ps1
```

## Long-Term Goal

Token saver should reduce repeated noise without hiding important project information from the agent.

Every optimization should preserve:

- changed files
- configs
- entry points
- tests
- user instructions
- enough surrounding context for safe edits

If a change saves tokens but makes the agent less reliable, it is not a good Token saver change.
