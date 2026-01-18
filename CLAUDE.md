# Claude Agent Instructions

This is an autonomous agent sandbox. When given a project plan, follow this workflow to execute it independently.

## Workflow Overview

1. **Receive project plan** → Parse and populate planning files
2. **Create feature branch** → All work happens off `main`
3. **Iterate** → Plan → Implement → Simplify → Test → Repeat
4. **Complete** → Create PR to merge to `main`

## Phase 1: Project Initialization

When given a new project or task:

1. Create a feature branch from `main`:
   ```bash
   git checkout -b feature/<descriptive-name>
   ```

2. Invoke `/planning-with-files` to structure the work, or manually update:
   - `task_plan.md` - Break down the project into phases and tasks
   - `findings.md` - Document research, decisions, and rationale
   - `progress.md` - Track session progress and status

3. Commit the initial plan before starting implementation.

## Phase 2: Iterative Development

For each task in the plan:

1. **Update progress.md** - Mark current task as in-progress
2. **Implement** - Write the code/make the changes
3. **Test** - Run relevant tests, fix any failures
4. **Commit** - Small, atomic commits with clear messages
5. **Update planning files** - Mark task complete, note findings

## Phase 3: Completion

When all tasks are complete:

1. **Simplify** - Invoke `/code-simplifier` to refine all modified code
2. **Test** - Ensure all tests still pass after simplification
3. **Commit** - Commit any simplification changes
4. Update `progress.md` with final status
5. Create a pull request to `main`:
   ```bash
   gh pr create --base main --title "Feature: <description>" --body "$(cat task_plan.md)"
   ```

## Subagent Model Selection

When spawning subagents via the Task tool, select models based on task complexity:

| Task Type | Model | Rationale |
|-----------|-------|-----------|
| File search, codebase exploration | `haiku` | Fast, low-cost for simple lookups |
| Code understanding, moderate analysis | `sonnet` | Balanced speed and capability |
| Complex implementation, architecture decisions | `opus` | Maximum capability for difficult work |

Examples:
- Finding files matching a pattern → `haiku`
- Understanding how a module works → `sonnet`
- Designing a new subsystem → `opus`

## Skills Reference

| Skill | When to Use |
|-------|-------------|
| `/planning-with-files` | At project start, or when restructuring approach |
| `/code-simplifier` | Pre-PR quality gate - simplify all modified code before merging |

## Autonomous Operation Guidelines

- **Commit frequently** - Small, working increments
- **Update planning files** - Keep them in sync with reality
- **Document decisions** - Future you (or another agent) needs context
- **Test before marking complete** - A task isn't done until it works
- **Ask if truly stuck** - Don't spin; surface blockers early

## Git Conventions

- Branch naming: `feature/<description>`, `fix/<description>`, `refactor/<description>`
- Commit messages: Imperative mood, concise, explain "why" not just "what"
- Keep `main` stable - all work on feature branches until PR approved
