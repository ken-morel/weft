# Summary

[Introduction](README.md)

# Getting Started

- [Installation & Host Setup](getting-started/installation.md)
- [Authentication & Keys](getting-started/authentication.md)
- [Your First Workspace](getting-started/first-workspace.md)

# Configuration (`weft.zon`)

- [Manifest Overview](config/README.md)
  - [Workspaces, Modes & Remotes](config/workspaces-and-remotes.md)
  - [Sources](config/sources.md)
  - [Environments & Nix Packages](config/environments.md)
  - [Pipelines](config/pipelines.md)
  - [Tuning & Resource Limits (`Tune`)](config/tune.md)
  - [Sibling Concurrency Policy (`Sibling`)](config/sibling.md)
  - [Retention Policies (`Retention`)](config/retention.md)

# Daemon & Task Manager (`weftd`)

- [Daemon Architecture](daemon/README.md)
  - [Init Systems (`systemd`, `OpenRC`, `runit`)](daemon/init-systems.md)
  - [Daemon Configuration (`/etc/weft/config.zon`)](daemon/config.md)
  - [Host Filesystem Layout (`/var/lib/weft`)](daemon/filesystem.md)
  - [Multi-Workspace UID Isolation](daemon/workspace-isolation.md)
  - [The Task Shim (`weft daemon shim`)](daemon/shim.md)
  - [Sandbox & Linux Namespaces](daemon/sandbox.md)
  - [Cgroups v2 & Rlimit Fallbacks](daemon/cgroups.md)

# Orchestration & Execution

- [Deployment Lifecycle](execution/README.md)
  - [Source Fetching & Local Scripts](execution/sources.md)
  - [DAG Resolution & Step Scheduling](execution/dag-and-steps.md)
  - [Artifact Packing, Compression & Transfer](execution/artifacts.md)
  - [Environment Resolution & Nix Realisation](execution/nix-environments.md)
  - [State Persistence & Resuming (`state.zon`)](execution/state-and-resume.md)
  - [Retries, Timeouts & Failure Handling](execution/retries-and-failures.md)

# CLI Reference

- [Command-Line Syntax (`argz`)](cli/README.md)
  - [`weft check` & `weft version`](cli/check-and-version.md)
  - [`weft key`](cli/key.md)
  - [`weft do` & `weft resume`](cli/do-and-resume.md)
  - [`weft logs` & `weft kill`](cli/logs-and-kill.md)
  - [`weft artifact`](cli/artifact.md)
  - [`weft task`](cli/task.md)
  - [`weft remote`](cli/remote.md)
  - [`weft nix`](cli/nix.md)
  - [`weft daemon`](cli/daemon.md)

# Internals & Wire Protocol

- [Wire Protocol Overview](internals/README.md)
  - [Handshake, Identity & Cryptography](internals/cryptography.md)
  - [Binary Serialization (`zoto`)](internals/zoto.md)
  - [RPC Operations (`proto.zig`)](internals/rpc.md)
