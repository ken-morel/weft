# Weft

A lightweight deployment tool and task orchestrator (daemon + CLI client) for small VPSs, written in Zig 0.17.

## Project

- Single Zig executable `weft` — acts as both the client orchestrator and the daemon (`weft daemon run`).
- Entry point: `src/main.zig` (CLI tree defined via `src/util/argz.zig`).
- Config schemas: `weft/weft.zon` (project, see `src/domain/Weft.zig`) and `/etc/weft/config.zon` (daemon).
- Wire: TCP port `9338`, Ed25519 auth, XChaCha20-Poly1305 AEAD, `zoto` binary serialization.
- Requires Zig master (0.17.0); daemon needs Linux + systemd + cgroups.

## Commands

- Build: `zig build -Doptimize=ReleaseSafe` → `zig-out/bin/weft` (plain `zig build` for debug).
- Test: `zig build test` (only `src/main.zig` and `src/util/zoto.zig` have `test` blocks).
- Run: `zig build run -- <args>` or `./zig-out/bin/weft <args>`.
- Format: `zig fmt src/` (CI runs `zig fmt --check src/`).

## Architecture

- `src/client/` — orchestrator: CLI subcommands (`cmd_*.zig`, `do.zig`, `runner.zig`), deployment DAG state (`Deployment.zig`, `Step.zig`, `DeploymentState.zig`), project config loading (`Project.zig`), remote install/registration (`ClientInstall.zig`, `cmd_remote.zig`), Nix fetch (`Fetcher.zig`).
- `src/daemon/` — remote side: `Daemon.zig` (listen/auth), `handler.zig` (request dispatch), `Task.zig` + `Server.zig` (spawn/monitor transient systemd units), `Store.zig` (artifacts), `nix.zig` (binary-cache client), `StatsServer.zig` (metrics), `DaemonInstall.zig`.
- `src/domain/` — shared types: `Weft.zig` (config schema), `proto.zig` (wire messages + hash), `paths.zig` (`/var/lib/weft/` layout), `DotEnv.zig`, `Term.zig`, `spawn.zig`.
- `src/wire/` — transport: `Connection.zig`, `Crypt.zig`, `Identity.zig` (Ed25519 keys), `Nonce.zig`, `Packer.zig`, `Pressor.zig`.
- `src/util/` — `zoto.zig` (serialization + type hashing), `argz.zig` (declarative CLI parser), `Monitor.zig`, `Glob.zig`, `Walker.zig`, `systemd.zig`, `sizes.zig`.

## Conventions

Follow `STYLE_GUIDE.md` exactly — it is unusual and load-bearing:

- **snake_case** for all variables, functions, and struct fields.
- Allocator argument order: `gpa` (general purpose, freed) first, then `ara` (arena, leaky), then `alloc` (function-scoped). Functions taking `ara` get the `_leaky` suffix.
- Always pass `io` and allocators as function arguments; do not store them in structs (store a fixed-buffer or arena allocator instead).
- Use unmanaged containers (`ArrayListUnmanaged`, `StringHashMapUnmanaged`) passing the allocator per operation.
- Use `alloc.print(...)` instead of `std.fmt.allocPrint`.
- Type-annotate the type, not the value: `var arena: std.heap.ArenaAllocator = .init(gpa);`.
- Prefer control flow as an expression over multiple `return`s; avoid mutable variables (use labeled `blk: { break :blk; }` blocks).
- Put `if`/`else`/`for`/`catch` bodies on a new line; omit `{}` for single statements.
- Name loop/block labels after the captured/assigned variable.
- Avoid comments; descriptive names are preferred (doc comments acceptable).
- `return try` when returning from a failing call.

## Notes

- 8-char deployment IDs; tasks run as the `weft-runner` user under transient systemd units with strict sandboxing (`ProtectSystem=strict`, `NoNewPrivileges=yes`, read-only `/nix/store`).
- CI: `.github/jobs.yml` (build+test on `dev`, fmt/lint, Trivy, integration smoke tests) — note lint/security/integration are `continue-on-error`.
