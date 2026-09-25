# Weft

A lightweight, distributed build and deployment runner written in Zig.

Weft connects local development environments and remote servers into a unified execution graph. It coordinates artifact packaging, incremental build caching, dependency resolution, process lifecycle management, and sandboxed task execution across machines without third-party agents or heavy container runtimes.

---

## Highlights

- **Declarative Pipeline Graphs (`weft.zon`)**: Express build pipelines with explicit input dependencies, output artifacts, persistent caches, and environment bindings.
- **Distributed Remote Execution**: Seamlessly build locally and deploy services to remote servers in a single invocation:
  ```bash
  weft do .build bellacall.run
  ```
- **Zero-Friction Remote Provisioning**: Provision and register remote servers over SSH with a single command:
  ```bash
  weft remote install bellacall s.bellacall
  ```
- **Native Systemd Sandboxing**: Tasks run in isolated, transient systemd units with cgroup resource limits, dynamic tmp directories, read-only system mounts, and clean lifecycle tracking.
- **Automated Process Lifecycle (`.second_instance = .kill`)**: Automatically terminate older running instances when deploying a new release of a service.
- **Incremental Cache Persistence (`.keep`)**: Retain compiler caches (Cargo `target/`, Flutter `.dart_tool/`, Bun/Node modules) across deployments within isolated workspaces.
- **Streaming Wire Protocol**: Binary artifacts are packed, compressed with DEFLATE, streamed over encrypted TCP connections, and unpacked with real-time progress indicators.
- **Live Terminal Monitor & Follow**: Built-in real-time TUI dashboard for system metrics (CPU, memory, disk I/O, network RX/TX, active services) and live deployment log streaming.

---

## Requirements

- **Zig**: `>= 0.16.0`
- **Linux**: Kernel with `systemd` support (for local or remote task runners)
- **OpenSSH**: Client binary (for `weft remote install`)

---

## Quickstart

### 1. Build & Install

```bash
git clone https://github.com/dev-safe/weft.git
cd weft
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/weft /usr/local/bin/weft
```

### 2. Initialize Local Daemon

To run local pipelines or act as a build host:

```bash
sudo weft daemon install
```

This sets up `/var/lib/weft`, creates the default configuration in `/etc/weft.zon`, and enables the `weftd.service` systemd daemon.

To inspect the generated authentication token:

```bash
weft daemon token
```

### 3. Add a Remote Host (Optional)

Install and register a remote server in `~/.config/weft/remotes.zon` over SSH:

```bash
# Using SSH alias or hostname (defaults to root):
weft remote install prod s.prod.example.com

# Specifying custom user, port, and external address:
weft remote install prod deploy@57.129.106.133:2222 57.129.106.133
```

### 4. Define Pipelines (`weft.zon`)

Create a `weft.zon` in your repository root:

```zon
.{
    .name = "my-service",
    .workspace = "my-service",
    .pipelines = .{
        .{
            .name = "build",
            .inputs = .{
                .{ .name = "src" },
            },
            .outputs = .{
                .{ .name = "binary" },
            },
            .keep = .{
                .{ "cargo-target", "target/" },
            },
        },
        .{
            .name = "run",
            .inputs = .{
                .{ .name = "binary" },
            },
            .outputs = .{},
            .second_instance = .kill,
            .env = .{
                .{ "PORT", "8080" },
            },
        },
    },
}
```

### 5. Create Pipeline Scripts (`bin/`)

Pipeline executables live in `./bin/<pipeline-name>` and can be written in any language:

`bin/build`:
```bash
#!/usr/bin/env bash
set -euo pipefail

cp -r "$IN/src"/* ./
cargo build --release
mkdir -p "$OUT/binary"
cp target/release/my-service "$OUT/binary/"
```

`bin/run`:
```bash
#!/usr/bin/env bash
set -euo pipefail

cp "$IN/binary/my-service" ./my-service
chmod +x ./my-service
exec ./my-service
```

Make them executable:
```bash
chmod +x bin/build bin/run
```

### 6. Execute

```bash
# Run build locally:
weft do .build

# Run build locally and execute service on remote 'prod':
weft do .build prod.run
```

---

## Core Concepts

### Pipeline Addressing Syntax

Pipelines are referenced with unambiguous dot-prefixed syntax:

| Target | Description | Example |
|---|---|---|
| `.pipeline` | Pipeline executed on the local daemon | `weft do .build` |
| `remote.pipeline` | Pipeline executed on the specified remote | `weft do prod.run` |

### Pipeline Sandboxing & Environment

When a pipeline task executes inside its transient systemd unit:

- `$IN`: Directory containing input artifacts produced by upstream pipelines (e.g. `$IN/src/`, `$IN/binary/`).
- `$OUT`: Directory where outputs produced by this pipeline must be placed to be collected and streamed to downstream tasks.
- `cwd`: Unique transient sandbox created per deployment run.
- Persistent caches configured via `.keep` are mounted directly into the sandbox directory.

---

## Command Guide

### Executing Deployments (`weft do`)

Run one or more pipeline targets. Upstream dependencies are automatically resolved, built, and streamed across hosts.

```bash
# Run local build:
weft do .build

# Build multiple artifacts locally:
weft do .build-backend .build-frontend

# Build locally and deploy service to remote:
weft do .build prod.run

# Target multiple remotes simultaneously:
weft do .build staging.run prod.run
```

### Resuming & Retrying (`weft retry`)

Retry a previous deployment run or resume from the last failure without rebuilding cached steps:

```bash
# Retry the latest deployment:
weft retry

# Retry a specific deployment by ID or prefix:
weft retry 2947MsUl
```

### Monitoring & Inspections

#### Deployment History (`weft list`)

Inspect recent deployment runs, statuses, run times, and commit identifiers:

```bash
weft list
```

#### Live Task Logs (`weft follow`)

Follow live streaming stdout and stderr logs for a specific pipeline task:

```bash
# Follow task from the latest deployment:
weft follow .run

# Follow remote task from a specific deployment:
weft follow 2947MsUl.prod.run
```

#### Real-time Host Monitor (`weft monitor`)

Open an interactive TUI dashboard displaying host utilization metrics:

```bash
# Monitor default / local host:
weft monitor

# Monitor a specific remote server:
weft monitor prod
```

Metrics tracked in real-time include:
- Total CPU utilization percentage and frequency across cores
- Memory usage (used vs total)
- Disk usage and disk I/O rates
- Network traffic (RX / TX transfer rates)
- Active and failed systemd service units

### Process Control (`weft kill`)

Terminate running tasks by deployment and optional pipeline:

```bash
# Kill all running pipelines in the latest deployment:
weft kill

# Kill a specific pipeline in the latest deployment:
weft kill . run

# Kill all pipelines in a specific deployment:
weft kill 2947MsUl

# Kill a specific pipeline in a specific deployment:
weft kill 2947MsUl run
```

- When the deployment is omitted (or given as `.`), it targets the latest deployment.
- The remote is extracted automatically from the deployment targets without having to crawl remotes.

### Garbage Collection (`weft gc`)

Prune stale deployment artifacts, old logs, and unused sandbox directories locally or remotely:

```bash
# Garbage collect locally (preserves the 5 most recent deployments):
weft gc

# Dry run to preview disk space reclaimed without deleting files:
weft gc --dry-run

# Prune on a remote server, retaining only the 3 most recent deployments:
weft gc prod --keep 3

# Remove artifacts older than a given timeframe:
weft gc --older-than 7d
```

### Remote Server Management (`weft remote`)

Manage registered servers stored in `~/.config/weft/remotes.zon`:

```bash
# Install daemon on remote over SSH and register it locally:
weft remote install prod user@57.129.106.133

# List all registered remotes:
weft remote list

# Deregister a remote:
weft remote remove prod
```

### Daemon Management (`weft daemon`)

Manage the local host runner daemon:

```bash
# Install systemd service and initialize directories:
sudo weft daemon install

# Display the daemon authentication secret:
weft daemon token

# Run daemon in the foreground (useful for development and debugging):
sudo weft daemon run
```

---

## Configuration Reference (`weft.zon`)

Every Weft project defines its graph in `weft.zon` at the project root:

```zon
.{
    .name = "bellacall",
    .workspace = "bellacall",
    .pipelines = .{
        .{
            .name = "build-backend",
            .inputs = .{
                .{ .name = "src" },
            },
            .outputs = .{
                .{ .name = "backend-release" },
            },
            .keep = .{
                .{ "cargo-target", "backend/target/" },
            },
        },
        .{
            .name = "run",
            .inputs = .{
                .{ .name = "backend-release" },
            },
            .outputs = .{},
            .second_instance = .kill,
            .env = .{
                .{ "PORT", "3000" },
                .{ "DATABASE_URL", "postgresql://user:pass@127.0.0.1:5432/db" },
            },
            .script = "run-service",
        },
    },
}
```

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `name` | `[]const u8` | Project identifier. |
| `workspace` | `[]const u8` | Isolation namespace for caches and sandboxes. |
| `pipelines` | `[]Pipeline` | Array of pipeline task definitions. |

### Pipeline Definition Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | `[]const u8` | *required* | Unique pipeline name. |
| `inputs` | `[]Input` | `.{}` | Artifacts required before task can execute (`src` denotes repository snapshot). |
| `outputs` | `[]Output` | `.{}` | Artifacts produced by this task to store and pass downstream. |
| `keep` | `[][2][]const u8` | `.{}` | Cache mappings `.{ "cache-id", "path/relative/to/cwd/" }` retained across runs. |
| `second_instance` | `.kill` \| `.ignore` | `.ignore` | When set to `.kill`, terminates previous running instances upon deployment. |
| `env` | `[][2][]const u8` | `.{}` | Environment variables injected into the task process. |
| `script` | `?[]const u8` | `null` | Script filename inside `bin/` (defaults to pipeline `name`). |

---

## Command Reference

| Command | Syntax | Description |
|---|---|---|
| `do` | `weft do <[remote.]pipeline...>` | Execute build and deployment pipelines across hosts |
| `retry` | `weft retry [deployment]` | Resume or retry an existing deployment run |
| `list` | `weft list` | Display recent deployments and their execution statuses |
| `follow` | `weft follow <[deployment.]pipeline>` | Stream live logs for a running task |
| `monitor` | `weft monitor [remote]` | Open real-time host metrics dashboard (CPU, memory, I/O, network) |
| `kill` | `weft kill [deployment] [pipeline]` | Terminate a deployment or a specific pipeline in a deployment |
| `gc` | `weft gc [remote] [--keep N] [--older-than dur] [--dry-run]` | Garbage collect stale deployment artifacts and sandboxes |
| `remote install` | `weft remote install <name> <ssh> [host]` | Provision and register a remote server via SSH |
| `remote list` | `weft remote list` | List registered remote servers |
| `remote remove` | `weft remote remove <name>` | Remove a registered remote from configuration |
| `daemon install` | `sudo weft daemon install [--user user]` | Install the systemd daemon service locally |
| `daemon run` | `sudo weft daemon run` | Run the daemon process in the foreground |
| `daemon token` | `weft daemon token` | Print the local daemon access secret |

### Global Flags

Global options must precede the command:

| Flag | Description |
|---|---|
| `-q, --quiet` | Silence informational output; log errors only |
| `-v, --verbose` | Enable verbose debug-level logging |
| `--no-color` | Disable ANSI terminal color codes |

---

## License

MIT / Apache-2.0
