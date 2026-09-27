# Contributing to Weft

Thanks for your interest in contributing to Weft. This project is a Zig-based deployment and orchestration tool, and contributions are welcome from beginners and experienced contributors alike.

This guide explains how to set up the project, how to contribute effectively, and what to expect when opening issues or pull requests.

## Project overview

Weft is a CLI + daemon system for deployment workflows. The code is organized around:

- `src/main.zig` — CLI entry point and command parser
- `src/client/` — user-facing commands and client logic
- `src/daemon/` — daemon lifecycle, task handling, store logic, etc.
- `src/domain/` — core deployment/project model
- `src/wire/` — protocol and transport encryption
- `src/util/` — cross-cutting helpers
- `weft/weft.zon` — workspace metadata
- `build.zig` / `build.zig.zon` — Zig build configuration

## Before you begin

### Prerequisites

- Zig 0.16.0 or newer
- A Unix-like environment
- For some workflows, systemd access may be needed because the daemon installs/runs as a system service
- If you’re working on remote deployment or Nix integration, the environment may need additional tooling

### Recommended workflow

1. Fork the repository
2. Clone your fork locally
3. Create a feature branch
4. Make focused changes
5. Run the relevant tests and build checks
6. Open a pull request

## Local setup

```bash
git clone https://github.com/<your-user>/weft.git
cd weft
zig build
```

Run the CLI help:

```bash
zig build run -- --help
```

Run tests:

```bash
zig build test
```

If you want to run a specific command manually:

```bash
zig build run -- daemon install
```

## Development conventions

### Code style

- Follow the existing Zig style in the repo
- Keep functions small and focused
- Prefer explicit error handling
- Use existing project modules rather than introducing unrelated abstractions
- Keep changes scoped to a single concern

### Make small, reviewable patches

Good PRs are:
- narrow in scope
- clearly explained
- easy to review
- backed by validation

Avoid mixing:
- refactors
- formatting-only changes
- unrelated cleanup
- feature work in the same patch

### Add tests when possible

If you fix a bug or add behavior, add a test when practical. The project already uses Zig test blocks and build-based validation.

## Working on the repo

### Good first areas to contribute

Good beginner-friendly areas include:

- CLI UX and argument validation
- Help text improvements
- config parsing and validation
- documentation
- bug fixes in a single command or module
- tests for edge cases

Higher-risk areas:
- daemon lifecycle
- remote install flow
- protocol/networking code
- Nix archive handling
- systemd integration

If you are new to the repo, start in:

- `src/main.zig`
- `src/client/cmd_check.zig`
- `src/client/cmd_list.zig`
- `src/client/cmd_remote.zig`
- `src/daemon/Task.zig`

## Issue reporting

Before opening an issue, please check whether it already exists.

When reporting a bug, include:

- A clear title
- Steps to reproduce
- Expected behavior
- Actual behavior
- Relevant environment details
- Any logs or error output
- The command you ran

Example:

```text
Title: `weft remote install` hangs when SSH target is unavailable

Steps:
1. Run `weft remote install ...`
2. Use an unreachable SSH target
3. Observe no clear failure message

Expected:
The command should fail quickly with a clear SSH error.

Actual:
The process hangs or returns an unclear error.
```

## Pull requests

### PR checklist

Before opening a PR, verify that:

- The code builds
- Tests pass
- The patch is focused
- You explained the purpose of the change
- You included any needed docs or comments
- You did not include unrelated formatting churn

### PR description template

```markdown
## Summary

What changed and why?

## Testing

- `zig build`
- `zig build test`

## Notes

Any caveats, follow-ups, or design decisions.
```

### Merge expectations

We prefer:
- readable, minimal patches
- clear commit messages
- targeted changes over broad rewrites
- maintainers’ feedback being addressed in a follow-up commit or revision

## Security and safety

This repo includes:
- privileged daemon install logic
- systemd integration
- remote SSH installation
- task execution and resource limits

Please treat these areas carefully. If you discover a security issue or unsafe behavior, do not open a public issue with exploit details first. Use a private disclosure path if available in the repository, or contact the maintainer privately.

## Documentation

If you improve behavior, please also update relevant docs if needed:
- `README.md`
- command help text
- inline comments where necessary
- migration or operational notes if behavior changes

## Questions

If you are unsure where to start, ask in the issue tracker or open a small exploratory discussion before implementing a large change. That helps keep the work aligned with the project’s design goals.

Thank you for contributing to Weft.
