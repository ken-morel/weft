# Changelog

## v0.2.0-dev

- **Native Linux Task Supervisor & Isolation**:
  - Replaced `systemd-run` task execution with native Linux namespaces (`CLONE_NEWNS`, `NEWUTS`, `NEWIPC`, `NEWPID`, `NEWNET`, `NEWCGROUP`) and cgroups v2 (`CGroup2.zig`).
  - Added dedicated supervisor process (`weft supervisor supervise`, `weft supervisor spawn`) to manage task sandboxes, `pivot_root`, tmpfs mounts, read-only overlays, sibling policies, and signal propagation.
- **Local Environment Shell (`weft env`)**:
  - Added `weft env [mode:]name[,name...] [-- cmds...]` to resolve packages and variables across one or more comma-separated pipelines or environments (checking `pipelines` first, then `environments`), install missing Nix packages through the local daemon, and run commands or `$SHELL` in the current working directory.
  - Added `--` end-of-options passthrough in CLI argument parsing (`argz.zig`).
- **Nix & Package Provisioning (`src/nix/`)**:
  - Added `weft nix search <query>` to search packages via the Devbox API.
  - Added `weft nix query <name>` to inspect available versions, platforms, and output store paths.
  - Added `weft nix info <pkg>` to fetch `.narinfo` metadata from `cache.nixos.org` and display it as YAML.
  - Custom streaming NAR unpacker (`NarUnpacker.zig`) supporting zstd/xz decompression directly into `/var/lib/weft/store/` with atomic locking.
- **ZOTON & `weft zoto` CLI**:
  - Replaced `weft decode` with `weft zoto` (`decode`, `encode`, `edit`, including `weft zoto edit -` for stdin-to-stdout interactive editing via a temporary `.zon` file and `/dev/tty`).
  - Introduced standalone `src/util/zoton.zig` (re-exported as `zoto.n`) built on `std.zig.Ast`/`Zoir`, adding support for closed `error_set`, `error_union`, `zoton.Map(V)`, `zoton.NamedMap(key, V)`, `__`-prefixed hidden fields, custom `zoton_serialize`/`zoton_deserialize_leaky` hooks, and `line:col` error logging.
- **Configuration Schema Migration to ZOTON**:
  - Migrated `weft/weft.zon`, `client.zon`, `/etc/weft/weft.zon`, and `deployment.zon` from `std.zon` to `zoton`.
  - Converted `.pipelines`, `.environments`, and `.remotes` (with named `address`/`groups` fields) to `zoton.NamedMap`, and `.sources`, `.keep`, `.vars`, and client `.remotes` to `zoton.Map`.
  - Changed the default `.sources` entry to `.src = "."` (referenced as `"-src"`).
  - Serialized `Deployment.Id` as an 8-character Crockford Base32 string in ZOTON, narrowed `Deployment.Failed.status` to a closed error union, and renamed `DaemonInstall.Isolate._pad` to `__pad` so it is omitted from config output.
- **ZOTO & Wire Protocol Improvements**:
  - Fixed closed `error_set` serialization in `zoto.zig` to encode/decode by error name rather than build-local error IDs, fixed full-width enum tag hashing, fixed `serializeAlloc` slice ownership, and added scoped `.zoto` deserialization error logging.
  - Replaced global protocol hash check with per-request type-hash verification and upgraded `Task.Status.failed` to carry `TaskError!u16`.
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
  - Added provided remote addresses (`~<script> [args...]`) that spawn an address-provider process (such as a port forwarder), resolve the address printed on its first line of `stdout`, and keep it running for the session.
  - Deduped runner polling and deployment step rendering into a unified step renderer (`DeploymentView.zig`).
  - Improved error propagation on resumed deployments and config loading.
  - Scoped `.debug` and `.info` logging added across client connections, transports, address providers, daemon, supervisor, and runner subsystems; interactive TTY `View` automatically caps runtime logging at `.info`.

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
