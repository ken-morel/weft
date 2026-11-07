# Changelog

## v0.2.0-dev

- **Native Linux Task Supervisor & Isolation**:
  - Replaced `systemd-run` task execution with native Linux namespaces (`CLONE_NEWNS`, `NEWUTS`, `NEWIPC`, `NEWPID`, `NEWNET`, `NEWCGROUP`) and cgroups v2 (`CGroup2.zig`).
  - Added dedicated supervisor process (`weft supervisor supervise`, `weft supervisor spawn`) to manage task sandboxes, `pivot_root`, tmpfs mounts, read-only overlays, sibling policies, and signal propagation.
- **Nix & Package Provisioning (`src/nix/`)**:
  - Added `weft nix search <query>` to search packages via the Devbox API.
  - Added `weft nix query <name>` to inspect available versions, platforms, and output store paths.
  - Custom streaming NAR unpacker (`NarUnpacker.zig`) supporting zstd/xz decompression directly into `/var/lib/weft/store/` with atomic locking.
- **ZOTO Binary Inspection**:
  - Added `weft decode` CLI tool to inspect and pretty-print zoto-encoded binary payloads (task specs, status, wire packets) from `stdin` as colored Zig struct definitions, with support for multiline scripts, tuples, error sets, and remaining-byte diagnostics.
- **Artifact & Cache CLI Operations**:
  - Added `weft artifact push` and `weft artifact pull` commands for remote artifact sync.
  - Added `weft artifact register` and `weft artifact path`.
  - Added `weft cache` (`push`, `pull`, `path`) to manage shared workspace caches across remotes.
- **Task Management**:
  - Added `weft task spawn` to trigger single pipeline steps without resolving artifacts.
  - Added `weft task kill` to terminate remote tasks/deployments.
  - `weft run` now accepts task specs matching `weft do`.
- **Wire & Transfer Protocol**:
  - Unified artifact push/pull into wire transfer layer (`src/wire/transfer.zig`) with compression negotiation.
- **Client & TUI Enhancements**:
  - `weft monitor` now supports explicit remote addresses.
  - Deduped runner polling and deployment step rendering into a unified step renderer (`DeploymentView.zig`).
  - Improved error propagation on resumed deployments and config loading.
  - Scoped debug logging added across daemon, supervisor, and runner subsystems.

## v0.1.1-dev

- `weft artifact push/pull`: pull/push artifacts from local project to a remote.
- `weft task spawn`: Manually spawn a task, without artifact resolution.
- `weft artifact register`: Simply register the artifact in the deployment config.
- `weft artifact path`: Prints the expected path for an artifact.
- `weft monitor` moved to `weft remote monitor`.

## v0.1.0

- Weft daemon, running pipelines on remotes using systemd. 
- Weft client, in the same binary and querying the remote.
- Initial weft.zon schema version, firuging remotes, pipelines, environments, sources.
- Wire protocol usinz zoto, Ed2519 for ssh-like authentication and XChaCha20Poly1305.
- Remote installations via `weft remote`.
- Lightweight nix client for provisioning environments. And better isolating the running pipelines from
  the rest of the system with isolated bin and environment.
- AI-Generated tui monitors and monitoring of remotes.
- Github actions integration, also generated.
