# Weft 🧶

**A lightweight, zero-dependency deployment engine and container-less task orchestrator for Linux and remote servers, written in pure Zig.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.18.0+-orange.svg)](https://ziglang.org/)
[![Zero Dependencies](https://img.shields.io/badge/Dependencies-0-brightgreen.svg)]()
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux%20(x86__64)-lightgrey.svg)]()

---

## Overview

Modern software deployment usually forces a compromise between two extremes:
- **Ad-hoc shell scripts + SSH**: Simple and lightweight, but fragile, difficult to reproduce, lacking isolation, and painful to monitor or retry.
- **Heavyweight container engines (Docker, Podman, K8s, Nomad)**: Feature-rich, but require massive daemons, complex rootless setups, layered images, gigabytes of overhead, and slow build-push-pull feedback loops on smaller VPS hosts.

**Weft** takes a different path:
It provides **reproducible, isolated, multi-stage task orchestration** across any number of remote Linux machines or local environments using a **single static binary with zero runtime dependencies**.

Instead of container engines, Weft uses native Linux kernel primitives (`namespaces`, `cgroups v2`, `pivot_root`) and daemon-less Nix binary store packages to give you airtight isolation and reproducible toolchains with near-zero overhead.

---

## Key Highlights

- ⚡ **Zero External Dependencies**  
  A single self-contained executable that functions as the CLI client, background daemon, and task supervisor. No Docker daemon, no systemd requirement at runtime, no external C libraries.
- 🔒 **Native Linux Sandboxing & Tuning**  
  Direct kernel namespace isolation (`CLONE_NEWNS`, `NEWPID`, `NEWNET`, `NEWCGROUP`, `NEWUTS`, `NEWIPC`) with cgroups v2 resource enforcement. Fine-tune CPU quotas, memory limits, swap behavior, OOM scores, private network namespaces, and tmpfs mounts per pipeline.
- 📦 **Daemon-less Nix Package Provisioning**  
  Declaratively specify packages in `weft.zon` (e.g. PostgreSQL, Rust, Bun, Python). Weft searches, queries, downloads, and unpacks hermetic Nix binary packages directly into an isolated store with atomic locking—without needing NixOS or the Nix daemon installed on host or remotes.
- 🛡️ **Encrypted Zero-Trust Wire Protocol**  
  End-to-end encrypted wire communication using Ed25519 public-key authentication and XChaCha20-Poly1305 AEAD over a custom zero-copy binary serialization format (`zoto`).
- 📁 **Declarative Pipelines in `weft.zon`**  
  Define your deployment graph in native Zig Object Notation. Wire pipeline inputs (`in`), outputs (`out`), source folders (`sources`), environments (`environments`), and persistent storage directories (`keep`).
- 🔄 **Smart Sibling Lifecycle Management**  
  Control concurrency and lifecycle behavior when spawning tasks. Automatically terminate previous service instances (`then = .kill`), wait for migrations (`wait = 180, then = .fail`), or skip redundant runs (`then = .skip`).
- 💾 **Workspace Caching & Artifact Synchronization**  
  Transfer build artifacts (`.weft/artifacts/`) and synchronize build caches (e.g., Cargo `target/`, `node_modules/`) between local machines and remote servers seamlessly via streaming compression (`weft cache push/pull`).
- 📊 **Real-Time Interactive TUI & Remote Telemetry**  
  Live terminal dashboard displaying pipeline dependency execution status, streaming stdout/stderr logs, and real-time remote host metrics (CPU, RAM, Swap, Disk I/O, Network bandwidth, and active processes).
- 🔁 **Resumable Deployments**  
  Interrupted or failed deployments can be retried or resumed instantly from the point of failure with `weft resume`.
- 🐧 **Universal Linux Init Support**  
  One-command remote provisioning auto-detects and configures `systemd`, `openrc` (Alpine), `runit`, or standalone execution.

---

## Architecture

Weft is architected around four cohesive layers designed for minimal overhead, strict isolation, and zero external dependencies:

- **Client & CLI Runner (`weft do`, `weft cache`, `weft remote monitor`)**
  - Parses project configurations (`weft/weft.zon`) and resolves task dependency DAGs across local and remote targets.
  - Manages client cryptographic identity using local Ed25519 keypairs (`~/.config/weft/identity`).
  - Provides a real-time interactive terminal UI for live pipeline execution, streaming logs, and host telemetry.
  - Manages compressed streaming transfers for build caches and versioned artifacts.

- **Wire Protocol & Security Layer**
  - **Zero-Trust Authentication**: SSH-like key trust model where remote daemons authenticate clients against an authorized Ed25519 public key registry.
  - **Authenticated Encryption**: Full end-to-end transport encryption using XChaCha20-Poly1305 AEAD.
  - **Binary Framing (`zoto`)**: Custom zero-copy binary serialization format for fast, type-safe payload framing with minimal CPU overhead.

- **Remote Daemon (`weft daemon`)**
  - **Worker Pool**: Dispatches and manages pipeline tasks concurrently based on host scaling profiles (`tiny`, `small`, `large`).
  - **Package Provisioner**: Queries upstream Nix binary caches via Devbox API and uses a built-in streaming NAR unpacker (`/var/lib/weft/store`) with atomic locking.
  - **Telemetry Engine (`StatsServer`)**: Streams live host statistics (CPU, memory, swap, disk I/O, network bandwidth, running tasks) to connected clients.
  - **Init System Agnostic**: Detects and integrates seamlessly into `systemd`, `openrc` (Alpine), `runit`, or standalone background processes.

- **Native Linux Task Supervisor (`weft supervisor`)**
  - **Kernel Namespace Sandboxing**: Spawns tasks inside dedicated Linux namespaces (`CLONE_NEWNS`, `NEWPID`, `NEWNET`, `NEWCGROUP`, `NEWUTS`, `NEWIPC`) without container engines.
  - **cgroups v2 Enforcement**: Enforces hard and soft memory ceilings, swap limits, CPU bandwidth quotas, OOM score adjustments, and I/O weights per pipeline.
  - **Filesystem Isolation**: Constructs an isolated rootfs with tmpfs mounts, performs `pivot_root`, and mounts requested Nix store paths as read-only layers.
  - **Persistent State (`keep`)**: Mounts persistent workspace folders across runs (e.g. database data, compilation caches) into the sandboxed task.
  - **Process Lifecycle Management**: Enforces sibling policies (`kill`, `wait`, `fail`, `skip`), maintains process groups via `setsid`, and ensures clean signal propagation.

---

## Installation

### Prebuilt Binary

Download the latest static Linux binary:

```bash
# Download and install Weft to /usr/local/bin
curl -fsSL "https://github.com/ken-morel/weft/releases/download/nightly/weft-linux-x86_64.tar.gz" | sudo tar -xz -C /usr/local/bin
sudo chmod +x /usr/local/bin/weft

# Verify installation
weft version
```

### GitHub Actions

Use Weft directly in your CI/CD workflows using the official composite action:

```yaml
- name: Setup Weft
  uses: ken-morel/weft@nightly
  with:
    version: nightly # or a release tag like v0.2.0

- name: Deploy to Staging
  run: weft do staging.backend-run
```

### Building from Source

Requirements: [Zig](https://ziglang.org/) `0.18.0` or master.

```bash
git clone https://github.com/ken-morel/weft.git
cd weft
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/weft /usr/local/bin/
```

---

## 5-Minute Quickstart

### 1. Provision a Remote Server

To set up a remote VPS, run:

```bash
weft remote install user@myserver.com:22
```

Weft will:
1. Connect via SSH.
2. Install the `weft` binary on the remote.
3. Configure the daemon under the host's init system (`systemd`, `openrc`, or `runit`).
4. Generate client keys if needed and register your client public key with the remote daemon.

### 2. Configure `weft/weft.zon`

Inside your project root, create a `weft/` folder with `weft/weft.zon`:

```zig
.{
    .workspace = "my-app",
    
    // Source folders to sync
    .sources = .{
        .{ "src", "src/" },
    },

    // Reusable hermetic environments with Nix packages
    .environments = .{
        .{
            .name = "bun-env",
            .pkgs = .{
                "qkydg77xf2s395md9fq0a6djjpq7fzh4-bun-1.4.2",
            },
        },
    },

    // Pipelines
    .pipelines = .{
        .{
            .name = "build",
            .in = .{"-src"}, // '-' prefix indicates source dependency
            .keep = .{
                .{ "node-modules", "node_modules/" },
            },
            .env = .{ .uses = .{"bun-env"} },
            .run = .{
                .script =
                    \\#!/usr/bin/env bash
                    \\bun install
                    \\bun run build
                ,
            },
        },
        .{
            .name = "server",
            .in = .{"build"},
            .sibling = .{ .then = .kill }, // Terminate previous server process before starting new
            .env = .{
                .uses = .{"bun-env"},
                .vars = .{
                    .{ "PORT", "3000" },
                },
            },
            .tune = .{
                .mem = .{ .max = 512 * 1024 * 1024 }, // Limit to 512MB RAM
                .cpu = .{ .quota = 100_000 },
            },
            .run = .{
                .script =
                    \\#!/usr/bin/env bash
                    \\bun run start
                ,
            },
        },
    },

    // Target remote servers
    .remotes = .{
        .{ "prod", "myserver.com:9338", "production" },
    },
}
```

### 3. Validate Configuration

```bash
weft check
```

Checks syntax, circular dependencies, environment definitions, and binary references.

### 4. Deploy

Deploy locally or to your remote:

```bash
# Run the server pipeline on 'prod' (automatically builds dependencies)
weft do prod.server

# Or run locally
weft do local.server
```

### 5. Monitor in Real-Time

Open the live telemetry monitor to watch CPU, RAM, disk I/O, network traffic, and active tasks on the remote:

```bash
weft remote monitor prod
```

---

## Configuration Reference (`weft.zon`)

Weft configuration files live at `weft/weft.zon` in your project root.

### Root Schema

| Field | Type | Description |
| :--- | :--- | :--- |
| `workspace` | `[]const u8` | Unique identifier for the workspace/project. |
| `sources` | `?[]const .{ name, path }` | Source directory mappings tracked for changes. |
| `environments` | `[]const Env` | Reusable hermetic environments and package sets. |
| `pipelines` | `[]const Pipeline` | Pipeline step definitions and execution rules. |
| `remotes` | `[]const Remote` | Registered remote hosts (`.{ name, addr, tags }`). |
| `modes` | `[]const []const u8` | Execution modes (defaults to `{"default"}`). |
| `retention` | `Retention` | Global retention policy for artifacts and archive logs. |

### Pipeline Schema

```zig
.{
    .name = "api",
    
    // Dependencies: "-source" for sources, "step" for previous pipeline steps
    .in = .{ "-backend-src", "db-migrate" },
    
    // Declared output artifacts
    .out = .{ "api-binary" },
    
    // Host restriction: run only on specific remotes or tags
    .on = .{ "prod", "staging" },
    
    // Persistent folders across runs (e.g. caches, database state)
    .keep = .{
        .{ "cache-name", "relative/target/path/" },
    },
    
    // Sibling lifecycle handling: .kill, .fail, .skip, or .ignore
    .sibling = .{
        .then = .kill,
        .wait = 0,
        .poll = 5,
    },
    
    // Environment variables and package dependencies
    .env = .{
        .uses = .{ "rust-env" },
        .vars = .{
            .{ "PORT", "8080" },
            .{ "SECRET_KEY", null }, // null pulls value from host environment
        },
    },
    
    // Resource isolation & sandboxing
    .tune = .{
        .cpu = .{ .max = 200_000, .quota = 100_000 },
        .mem = .{
            .max = 1024 * 1024 * 1024, // 1 GB hard limit
            .swap = .{ .max = 256 * 1024 * 1024 },
            .oom_score_adjust = 500,
        },
        .net = .{
            .private = false, // Set to true to isolate in private network namespace
        },
        .io = .{
            .pids_max = 500,
            .io_weight = 100,
        },
    },
    
    // Execution: inline script, file reference, or .nothing
    .run = .{ .script = "#!/usr/bin/env bash\n./target/release/server" },
    
    .timeout = 3600,
    .max_retries = 3,
}
```

### Script Resolution

A pipeline's `.run` property can be specified in three ways:
1. **Inline Script**: `.run = .{ .script = "#!/usr/bin/env bash\n..." }`
2. **External File**: `.run = .{ .file = "build-script" }` (looks for `weft/build-script` or `weft/build-script.sh`)
3. **Implicit Script**: If `.run` is omitted, Weft automatically searches for `weft/<pipeline_name>.sh`
4. **Virtual / Aggregator**: `.run = .nothing` (used for grouping targets like `build`, `fetch`, or `deploy`)

### Sibling Policies

Sibling policies manage what happens if another instance of the pipeline is already running or active:
- `.then = .kill`: Terminates the previous instance before launching the new one (standard for daemon services and web servers).
- `.then = .fail`: Fails immediately if a sibling is active (prevents concurrent migrations).
- `.then = .wait`: Waits up to `wait` seconds for the active sibling to finish; fails if it exceeds timeout.
- `.then = .skip`: Skips execution if the sibling is already running.

---

## CLI Reference

### Deployments & Execution

| Command | Description |
| :--- | :--- |
| `weft do [targets...]` | Start a deployment. Target syntax: `[<mode>:][<remote>.]<pipeline>` (e.g. `weft do prod.server`, `weft do build`) |
| `weft resume [deployment-id]` | Resume an existing or failed deployment (defaults to latest) |

### Task Management

| Command | Description |
| :--- | :--- |
| `weft task spawn <step> [--deployment <id>]` | Manually spawn a single pipeline without executing its target graph |
| `weft task kill <step> [--deployment <id>]` | Terminate a running deployment or specific pipeline task |
| `weft task logs <step> [--deployment <id>]` | Stream or display logs for a running/completed pipeline |

### Remote Server Management

| Command | Description |
| :--- | :--- |
| `weft remote install <ssh-addr> [extra...]` | Install Weft daemon on a remote host via SSH and register client key |
| `weft remote register <ssh-addr> [pubkey]` | Register a client public key with the remote daemon over SSH |
| `weft remote monitor [remote]` | Open live interactive TUI monitor for CPU, RAM, disk, network, and tasks |

### Cache Synchronization

Workspace caches (e.g. `keep` folders like `target/` or `node_modules/`) can be synchronized between local disk and remote hosts:

| Command | Description |
| :--- | :--- |
| `weft cache pull <remote>[.<cache>]` | Pull cache(s) from a remote to local `.weft/caches/<remote>/` |
| `weft cache push <source> [dest]` | Push local cache(s) to a remote host (verifies local presence first) |
| `weft cache path <remote>[.<cache>]` | Print expected local storage path for a cache without creating directories |

### Artifact Management

Artifacts produced by pipelines (`out` fields) are versioned per deployment:

| Command | Description |
| :--- | :--- |
| `weft artifact pull <name> [--remote <r>]` | Fetch an artifact from a remote deployment |
| `weft artifact push <name> [--remote <r>]` | Push a local artifact or source to a remote |
| `weft artifact register <name>` | Register an artifact in deployment metadata |
| `weft artifact path <name>` | Print expected path of an artifact in a deployment |

### Nix Package Operations

| Command | Description |
| :--- | :--- |
| `weft nix search <query>` | Search available Nix packages via Devbox index |
| `weft nix query <name>` | Inspect versions, platforms, and NAR store hashes for a package |

### Inspection & Diagnostics

| Command | Description |
| :--- | :--- |
| `weft check` | Validate `weft/weft.zon` syntax, dependency graphs, and environment integrity |
| `weft decode [file]` | Decode and pretty-print `zoto`-encoded binary wire payloads or task specs |
| `weft key` | Display the local client public key (hex) |
| `weft version` | Display Weft version, protocol hash, and build mode |

### Daemon Administration

| Command | Description |
| :--- | :--- |
| `weft daemon install [--template <t>]` | Install local daemon service (supports templates: `kvm`, `lxc`, `vz`, `colab`) |
| `weft daemon run` | Run daemon directly in the foreground (requires superuser privileges) |
| `weft daemon register <pubkey>` | Register an authorized client public key locally |

---

## Contributing

Weft is written in pure Zig.

### Guidelines
- **Zero external dependencies**: Standard library only.
- **Code style**: `snake_case` naming, minimal curly braces for single-expression blocks, explicit `else` branches, unmanaged data structures with explicit allocators.
- **Testing**: Run `zig build test` to run unit test suites.

---

## License

This project is licensed under the [MIT License](LICENSE).
