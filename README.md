# Claude Agent Devcontainer Template

A devcontainer template for running Claude Code in an isolated environment, suitable for autonomous agent work.

## Features

- Runs as root for autonomous/sandboxed operations
- Node.js LTS pre-installed
- Claude Code CLI pre-installed
- Planning files for structured task management (via planning-with-files skill)
- Autonomous workflow defined in `CLAUDE.md`

## Quick Start

1. **Use this template** to create a new repository
2. **Open in VS Code** with the Dev Containers extension
3. **Rebuild Container** when prompted
4. **Authenticate Claude** in the terminal:
   ```
   claude
   ```
   - Select "Claude account with subscription" for Pro/Max users
   - Complete OAuth via the manual code flow (copy URL, paste code back)

5. **Install skills** (one-time per container):
   ```
   /plugin marketplace add OthmanAdi/planning-with-files
   /plugin install planning-with-files@planning-with-files
   /plugin install code-simplifier@claude-plugin-directory
   ```

6. **Start working** - invoke skills with:
   ```
   /planning-with-files    # For complex multi-step tasks
   /code-simplifier        # To simplify and refine code
   ```

## Autonomous Workflow

See `CLAUDE.md` for detailed agent instructions. The workflow:

1. **Initialize** - Receive project plan, create feature branch, populate planning files
2. **Iterate** - Plan → Implement → Simplify → Test → Commit → Repeat
3. **Complete** - Create PR to merge feature branch to `main`

To run fully autonomously:
```bash
claude --dangerously-skip-permissions
```

Then provide a project plan and let the agent execute it.

## Planning Files

This template includes starter planning files from the planning-with-files skill:

- `task_plan.md` - Phase-based task planning
- `findings.md` - Research and decisions log
- `progress.md` - Session progress tracking

## Container Details

- **Base image:** mcr.microsoft.com/devcontainers/base:ubuntu
- **User:** root (for autonomous operations)
- **Memory:** 4GB limit
- **CPUs:** 2
- **PIDs:** 256 limit
- **Security:** `no-new-privileges`, capabilities dropped except:
  - CHOWN, SETUID, SETGID (file ownership)
  - KILL (stop runaway processes)
  - SYS_PTRACE (debugging)
  - NET_BIND_SERVICE (low port binding)
  - DAC_OVERRIDE (file permission bypass)

## Adding Runtimes

The template includes Node.js LTS by default. To add other runtimes, edit `.devcontainer/devcontainer.json` and add features:

```json
"features": {
  "ghcr.io/devcontainers/features/node:1": { "version": "lts" },
  "ghcr.io/devcontainers/features/python:1": { "version": "3.12" },
  "ghcr.io/devcontainers/features/go:1": { "version": "latest" },
  "ghcr.io/devcontainers/features/rust:1": { "version": "latest" }
}
```

See [available features](https://containers.dev/features) for more options.

## Notes

- Auth and plugins don't persist across container rebuilds
- Stop/start (not rebuild) preserves your session
- For fully autonomous work, use `claude --dangerously-skip-permissions`
