# Codex Slim Context

A lightweight context and token helper for Codex and other coding agents. It builds compact project context, reduces repeated codebase scanning, and provides a local `Token saver` usage panel for estimating token usage and savings.

## Token Usage Helper MVP

This repository includes a small open-source-friendly tool layer called `Token Usage Helper`. It does not depend on a heavy dashboard service. Its main UI is a task-manager-style floating panel named `Token saver`, which tracks local, observable token usage estimates and Token saver savings across attached projects and conversations.

Install the Codex adapter:

```powershell
git clone https://github.com/your-name/token-usage-helper.git
cd token-usage-helper
powershell -ExecutionPolicy Bypass -File .\install-codex.ps1
```

The installer performs two kinds of auto attach:

- Existing projects: scans recent Codex logs, helper history, and common project folders, then initializes `.codex/config.json` and `.codex/state.json` for up to 25 projects. It also attempts to generate `.codex/context.md`.
- New projects: writes or updates the `Token Saver Auto Attach` rule in `%USERPROFILE%\.codex\AGENTS.md`. New Codex coding projects are instructed to run `codex-token-kit.ps1 -ProjectPath .` first, which attaches them to Token saver.

Install commands only, without scanning old projects:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -NoAutoAttach
```

Agent-specific installers:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-codex.ps1
powershell -ExecutionPolicy Bypass -File .\install-claude.ps1
powershell -ExecutionPolicy Bypass -File .\install-cursor.ps1
powershell -ExecutionPolicy Bypass -File .\install-aider.ps1
powershell -ExecutionPolicy Bypass -File .\install-generic.ps1
powershell -ExecutionPolicy Bypass -File .\install-all-agents.ps1
```

`install-all-agents.ps1` only attaches agents detected on the machine by default. Missing adapters are listed in `skippedAgents` and are not written into projects. To force every adapter:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-all-agents.ps1 -ForceAll
```

Advanced users can still call the unified installer directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Agents Codex,Claude,Cursor,Aider,Generic
```

Current adapters write removable marker blocks to:

- Codex: global `%USERPROFILE%\.codex\AGENTS.md`
- Claude Code: project `CLAUDE.md`
- Cursor: project `.cursor/rules/token-saver.mdc`
- Aider: project `.aider.token-saver.md`
- Generic: project `TOKEN_SAVER.md`

Open the floating usage panel:

```powershell
token-helper panel -ProjectPath "C:\path\to\your\project"
```

The panel uses a global scope by default. It aggregates all attached Codex projects and conversations visible in local stats/history. If global history is unavailable, it falls back to the current project.

Command-line status and refresh:

```powershell
token-helper refresh -ProjectPath .
token-helper status -ProjectPath .
token-helper refresh -ProjectPath . -AllProjects
token-helper config -HelperEnabled true -ThresholdTokens 8000 -ContextBudgetChars 12000
token-helper health
token-helper paths
token-helper doctor
token-helper reset
```

Generic mode for other AI tools:

```powershell
# Estimate tokens from a context file by character count.
token-helper refresh -ProjectPath . -ContextPath ".\context.md"

# Read common token fields from a log file or log directory.
token-helper refresh -ProjectPath . -LogPath ".\logs"

# Manually record usage and savings for tools without logs.
token-helper refresh -ProjectPath . -ManualUsageTokens 12000 -ManualSavedTokens 3000
```

Uninstall:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

# Also remove local cumulative data.
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveData
```

## Metrics Model

- `Token Usage`: the panel reads global local Codex request history by default. In project mode, it prefers matched Codex request logs, then falls back to `.codex/stats.json` and `.codex/context.md` estimates.
- `Token Saver Savings`: the panel aggregates savings from attached conversations. In project mode, it prefers valid savings matched to the same project, then falls back to context-compression estimates.
- `Token saver` normally shows one recent 15-minute chart named `Token activity`. The blue line is token usage and the green line is token saver savings. The bottom strip shows usage total, usage peak, saved total, max saved per run, and online/offline state.
- The panel has no system title bar. It has three icon-only controls: settings, pin, and close. When pinned, the panel cannot be dragged, icons are hidden until hover, and click-through is enabled outside the buttons.
- Settings only keep the helper switch, trigger threshold, context character budget, and performance risk estimate. The context menu only keeps `Settings`, `Reset Stats`, and `Exit`.
- `Reset data` resets statistics only. The panel starts near the upper-right area of the screen by default.
- `Context budget` is the character budget for compressed context. Lower values save more tokens but increase performance risk on complex tasks. Low risk is shown in green.
- `Cumulative` stores the previous observation per global/project key and only adds new deltas, avoiding duplicate counting during frequent refreshes.
- `Helper enabled`, `Threshold`, and `Context budget` are local strategy controls. The MVP does not secretly modify projects or read account secrets.
- `Data path` defaults to `%LOCALAPPDATA%\TokenUsageHelper\data`, and can also be overridden by CLI arguments.
- `token-helper health` reads recent health events.
- `token-helper paths` shows the data directory, state, config, and health-event file locations.
- `token-helper doctor` runs a local self-check for data paths, write permissions, state/config readability, current metrics, and diagnostic status.
- Generic log parsing supports fields such as `total_tokens`, `input_tokens`, `output_tokens`, `prompt_tokens`, `completion_tokens`, `saved_tokens`, and `helper_saved_tokens`. This is a reliable local estimate, not exact billing.

MVP smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File .\test-token-helper-mvp.ps1
```

Note: this tool measures local observable requests and context estimates. It is not an exact OpenAI, ChatGPT, or Codex App billing/quota reader.

## Recommended Stack

After reviewing GitHub projects under `token-optimization` and `reduce-token-costs`, the most useful combinations for a Codex workflow are:

- `ai-codex`: generates `.ai-codex/` repository indexes, especially for Next.js, SvelteKit, and TypeScript projects.
- `rtk`: compresses common command output such as `git`, tests, lint, build logs, and container logs.
- `Headroom` / `LeanCTX`: more complete long-term approaches, but they require local services, MCP, or proxies.

This repository takes the lightweight route: it calls `ai-codex` when available, and otherwise uses the local `codex-slim.ps1` script to generate a controlled short context package.

## What It Does

- Generates a compact directory tree while skipping `node_modules`, `.git`, build outputs, caches, and common large files.
- Collects `git status` so the agent understands the current working tree.
- Selects high-value files automatically: README files, configs, entry points, tests, and recently changed files.
- Assigns a character budget per file instead of dumping the whole repository into the conversation.
- Writes a ready-to-read `.codex/context.md` file.

## Quick Start

Run this from the project root you want Codex to work on:

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\token-usage-helper\codex-token-kit.ps1 -ProjectPath "C:\path\to\your\project"
```

It will:

1. Run `npx --yes ai-codex --quiet` when it detects a Node/TypeScript project and `npx` is available.
2. Generate `.codex/context.md`.
3. Generate `.codex/stats.json` and `.codex/dashboard.html`.
4. Include `.ai-codex/` as high-priority context when available.

Open the token dashboard:

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\token-usage-helper\codex-dashboard.ps1 -ProjectPath "C:\path\to\your\project"
```

The dashboard shows estimated current context tokens, estimated raw candidate tokens, estimated token reduction, savings ratio, budget usage, and file contribution.

The usage monitor tracks local Codex model request logs and helper-generated records. It is not a Windows process monitor. Local Python workers such as Quantbot do not consume Codex conversation tokens by themselves; they only count when they call Codex/OpenAI directly, or when Codex analyzes/modifies them in a conversation.

## Plan and API Usage Notes

Add local plan quota notes:

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\token-usage-helper\codex-token-kit.ps1 -ProjectPath "C:\path\to\your\project" -PlanName "My Plan" -PlanTotalTokens 1000000 -PlanUsedTokens 250000
```

This saves plan information to `.codex/token-plan.json`. Later runs continue to display the saved values. These are local notes, not automatic account reads.

Read OpenAI API usage:

```powershell
# Recommended: save a fresh Admin Key encrypted on this machine.
powershell -ExecutionPolicy Bypass -File C:\path\to\token-usage-helper\codex-save-openai-admin-key.ps1

# Then read API usage.
powershell -ExecutionPolicy Bypass -File C:\path\to\token-usage-helper\codex-token-kit.ps1 -ProjectPath "C:\path\to\your\project" -ReadOpenAIUsage -OpenAIUsageDays 31
```

The OpenAI Usage API can read API organization usage and requires an Admin API Key. The script reads `OPENAI_ADMIN_KEY` first, then the encrypted local file `%USERPROFILE%\.codex\openai-admin-key.dpapi`. It cannot guarantee access to ChatGPT/Codex App subscription quota totals, so total quota still comes from `.codex/token-plan.json` or `-PlanTotalTokens`.

## Built-In Context Compression Only

Run from a project root:

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\token-usage-helper\codex-slim.ps1 -ProjectPath "C:\path\to\your\project"
```

Then have the agent read the generated `.codex/context.md`.

## Common Parameters

```powershell
# Limit total output size. Default is 24000 characters.
powershell -ExecutionPolicy Bypass -File .\codex-token-kit.ps1 -ProjectPath "C:\repo" -MaxChars 18000

# Prefer specific files or folders.
powershell -ExecutionPolicy Bypass -File .\codex-token-kit.ps1 -ProjectPath "C:\repo" -Include "src","package.json","README.md"

# Skip ai-codex and only generate .codex/context.md.
powershell -ExecutionPolicy Bypass -File .\codex-token-kit.ps1 -ProjectPath "C:\repo" -SkipAiCodex

# Write built-in script output to a specific file.
powershell -ExecutionPolicy Bypass -File .\codex-slim.ps1 -ProjectPath "C:\repo" -OutputPath "C:\repo\.codex\context.md"
```

## Optional RTK Integration

`rtk` is best for compressing command output. It does not replace repository indexing. After installing and configuring it, prefer:

```powershell
rtk git status
rtk test
rtk tsc
rtk npm test
rtk docker logs <container>
```

This gives the agent failure summaries, important paths, and concise logs instead of full repeated output.

## Recommended Workflow

1. Run `codex-token-kit.ps1`.
2. Tell Codex the goal and ask it to read `.codex/context.md` first.
3. If `.ai-codex/` exists, ask Codex to read relevant indexes before opening specific source files.
4. When Codex runs long commands, wrap them with `rtk` when possible.
5. Regenerate the context package after each large change.

## Global Usage

This tool also installs global shims:

```powershell
codex-token-kit -ProjectPath .
codex-dashboard -ProjectPath .
codex-save-openai-admin-key
codex-helper-health -ProjectPath .
codex-sync-global-bin
```

If a new terminal cannot find the commands, use the full path:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\David\.codex\bin\codex-token-kit.ps1 -ProjectPath .
powershell -ExecutionPolicy Bypass -File C:\Users\David\.codex\bin\codex-dashboard.ps1 -ProjectPath .
```

## Maintenance Checks

After changing scripts, run:

```powershell
.\codex-sync-global-bin.ps1
codex-helper-health -ProjectPath .
```

The health check verifies:

- `.codex/context.md`, `.codex/stats.json`, and `.codex/dashboard.html` can be generated.
- `/api/stats` can read live global history.
- `/api/health` returns machine-readable health status and detects stale stats or dashboard services that need restart.
- `/api/refresh` adds refresh records without creating fake actual records.
- Dashboard HTML includes 5-second polling logic.
- `codex-dashboard-js-smoke.ps1` runs the dashboard frontend script in a minimal DOM to catch undefined variables and render-time errors.
- `codex-dashboard-performance.ps1` checks `/api/ping`, hot `/api/stats`, and dashboard page response time to prevent UI stalls.
- The global scripts in `C:\Users\David\.codex\bin` match current script hashes; run `codex-sync-global-bin.ps1` when they differ.
- Stats fields have no obvious negative values or impossible candidate/scanned counts.
- `codex-context-regression.ps1` creates a temporary project and verifies changed files, README files, and tests still enter context, while low-priority normal files can use cached references.

## Long-Term Optimization Goal

The long-term goal is not to make token numbers artificially low. It is to remove repeated noise while preserving the agent's ability to reason about the project. Every future optimization should pass four checks:

1. No performance regression: changed files, entry points, configs, tests, and recently active files must be covered first. If coverage risk is not `low`, the dashboard must show it.
2. Trustworthy metrics: real request tokens, helper-written tokens, and context-avoided tokens must be separated. If there is no matching log, the tool must not pretend the savings are exact.
3. Stable auto attach: recently active but unattached conversations should be detected and attached when possible. Attach failures should appear in health checks.
4. Explainable UI: the dashboard home should only keep decision-relevant metrics. Charts must explain their scope, time window, and abnormal states.

Roadmap:

- Phase 1: stabilize metrics and keep improving `codex-helper-health` and dashboard smoke tests to prevent blank pages, jumping numbers, and field misreads.
- Phase 2: add low-risk compression such as JSON compaction, whitespace cleanup, duplicate metadata merging, and command-output summaries without rewriting important source content.
- Phase 3: add project-level cache and indexes: reuse summaries for unchanged files, prioritize changed/entry/test files, and avoid rereading full context every time.
- Phase 4: add quality regression fixtures: use fixed project tasks to verify that token savings still allow the same changes to be completed, and surface failures in dashboard health.
- Phase 5: improve cross-conversation takeover: automatically discover active Codex conversations and explain which are attached, which are only log-visible, and which cannot yet save tokens.

## Design Principle

This tool does not magically make complex tasks use zero tokens. It reduces noise: less low-value content, more project structure, constraints, entry points, config, tests, and current changes.
