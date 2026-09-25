# Weft

A lightweight, distributed build and deployment runner written in Zig.

Weft coordinates artifact packaging, incremental build caching, dependency resolution, process lifecycle management, reproducible package environments, and sandboxed task execution across local machines and remote servers without third-party agents or container runtimes.

---

## Motivation & Design Goals

Deploying small services and applications often forces a choice between resource-heavy container runtimes (which consume hundreds of megabytes of memory before running any workload) or fragile custom shell scripts.

Weft is designed specifically for small virtual private servers (such as 512 MB to 1 GB RAM instances) with a primary goal of maintaining a daemon memory footprint of under 15 MB. It relies directly on Linux-native `systemd` transient services for sandboxing, process isolation, cgroup limits, and lifecycle management rather than introducing an external container engine.

When package dependencies are defined with `pkgs`, Weft streams pre-compiled closures directly from the Nix binary cache (`cache.nixos.org`) without requiring Nix to be installed. While network transfers and archive decompression transiently elevate memory usage during package extraction, the daemon returns to its minimal baseline once tasks are launched.

---

## Highlights

- **Declarative Pipeline Graphs (`weft/weft.zon`)**: Define pipelines with explicit input dependencies, output artifacts, persistent caches, and environment bindings.
- **Reproducible Package Management (`pkgs`)**: Provision dependencies directly from the Nix binary cache (`cache.nixos.org`) without installing Nix on the host. Store paths are bound read-only into `/nix/store` and injected into `$PATH`.
- **Distributed Remote Execution**: Build locally and deploy services to remote servers in a single invocation:
  ```bash
  weft do .build prod.run
  ```
- **Zero-Friction Remote Provisioning**: Install and register remote servers over SSH with a single command:
  ```bash
  weft remote install prod user@example.com
  ```
- **Native Systemd Sandboxing**: Tasks execute in isolated transient systemd units with cgroup limits, dynamic temporary filesystems, read-only system mounts, and lifecycle tracking.
- **Process Lifecycle Management (`.second_instance = .kill`)**: Automatically terminate older running service instances when deploying a new release.
- **Incremental Cache Persistence (`.keep`)**: Retain compiler caches (Cargo `target/`, Zig `.zig-cache/`, Node modules) across deployments within isolated workspaces.
- **Streaming Wire Protocol**: Artifacts are packed, compressed with DEFLATE, streamed over TCP connections, and unpacked with progress tracking.
- **Live Terminal Monitor & Follow**: Terminal interface for system metrics (CPU, memory, disk I/O, network) and real-time task log streaming.

---

## Requirements

- **Zig**: `>= 0.16.0`
- **Linux**: Kernel with `systemd` support
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

This sets up `/var/lib/weft`, creates the default configuration in `/etc/weft.zon`, and starts the `weftd.service` systemd unit.

To inspect the generated authentication token:

```bash
weft daemon token
```

### 3. Add a Remote Host (Optional)

Install and register a remote server in `~/.config/weft/remotes.zon` over SSH:

```bash
# Using SSH alias or hostname:
weft remote install prod s.prod.example.com

# Specifying custom user, port, and external address:
weft remote install prod deploy@57.129.106.133:2222 57.129.106.133
```

### 4. Define Pipelines (`weft/weft.zon`)

Create `weft/weft.zon` in your repository root:

```zon
.{
    .workspace = "my-service",
    .pipelines = .{
        .{
            .name = "docs",
            .in = .{"src"},
            .out = .{"docs"},
            .pkgs = .{
                "il1g4zw7ngwvsnn051z8zj1vr2v9pwg1-lowdown-3.0.1",
            },
        },
        .{
            .name = "build",
            .in = .{"src"},
            .out = .{"bin"},
            .pkgs = .{
                "83qs3ksyjclr149vpxbaz1z18wvi9rms-zig-0.16.0",
            },
            .keep = .{
                .{ "zig-cache", ".zig-cache" },
            },
        },
        .{
            .name = "run",
            .in = .{"bin"},
            .second_instance = .kill,
            .env = .{
                .{ "PORT", "8080" },
            },
        },
    },
}
```

### 5. Create Pipeline Scripts (`weft/`)

Pipeline executables live in `./weft/<pipeline-name>` (or `./weft/<pipeline-name>.sh`):

`weft/docs.sh`:
```bash
#!/usr/bin/env sh
set -eu
lowdown -s "$IN/src/README.md" -o "$OUT/docs/README.html"
```

`weft/build.sh`:
```bash
#!/usr/bin/env sh
set -eu
cp -r "$IN/src"/* .
zig build
cp -r zig-out/bin/* "$OUT/bin/"
```

`weft/run.sh`:
```bash
#!/usr/bin/env sh
set -eu
exec "$IN/bin/my-service"
```

Make scripts executable:
```bash
chmod +x weft/docs.sh weft/build.sh weft/run.sh
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

Pipelines are referenced with dot-prefixed syntax:

| Target | Description | Example |
|---|---|---|
| `.pipeline` | Pipeline executed on the local daemon | `weft do .build` |
| `remote.pipeline` | Pipeline executed on the specified remote | `weft do prod.run` |

### Package Management (`pkgs`)

Pipelines can declare binary dependencies directly in `weft.zon` without installing Nix on the host machine.

Packages are identified by their immutable store basename (`{hash}-{name}-{version}`):

```zon
.pkgs = .{
    "83qs3ksyjclr149vpxbaz1z18wvi9rms-zig-0.16.0",
    "il1g4zw7ngwvsnn051z8zj1vr2v9pwg1-lowdown-3.0.1",
},
```

To resolve the latest store basename for a package:

```bash
weft nix show zig
# Outputs: 83qs3ksyjclr149vpxbaz1z18wvi9rms-zig-0.16.0
```

When a task executes:
- The daemon downloads `.narinfo` and the compressed `.nar.zst` archive directly from `cache.nixos.org`.
- Archives are unpacked into `/var/lib/weft/store/` atomically.
- Systemd bind-mounts `/var/lib/weft/store` read-only to `/nix/store`.
- The package `bin/` directories are prepended to the task's `$PATH`.
- Store paths are shared across tasks and cached permanently by hash.

### Pipeline Sandboxing & Environment

When a pipeline task executes inside its transient systemd unit:

- `$IN`: Directory containing input artifacts produced by upstream pipelines (e.g. `$IN/src/`, `$IN/bin/`).
- `$OUT`: Directory where outputs produced by this pipeline must be placed. Subdirectories declared in `.out` are writable state directories.
- `cwd`: Unique transient working directory created per deployment run.
- Persistent caches configured via `.keep` are mounted directly into `cwd`.

---

## Command Guide

### Pre-Flight Validation (`weft check`)

Validate configuration syntax, source directories, pipeline DAG dependencies, script existence, executable permissions, and environment variables without triggering a deployment:

```bash
# Validate against local environment:
weft check

# Validate against a specific remote environment (.env.prod):
weft check --remote prod
```

### Executing Deployments (`weft do`)

Run one or more pipeline targets. Upstream dependencies are automatically resolved, built, and streamed across hosts.

```bash
# Run local build:
weft do .build

# Build multiple artifacts locally:
weft do .build .docs

# Build locally and deploy service to remote:
weft do .build prod.run

# Target multiple remotes simultaneously:
weft do .build staging.run prod.run
```

### Finding Package IDs (`weft nix show`)

Query Hydra for the latest pre-built Nix store path on the current architecture:

```bash
weft nix show bun
# qkydg77xf2s395md9fq0a6djjpq7fzh4-bun-1.4.2

weft nix show lowdown
# il1g4zw7ngwvsnn051z8zj1vr2v9pwg1-lowdown-3.0.1
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

Open a terminal dashboard displaying host metrics:

```bash
# Monitor local daemon:
weft monitor

# Monitor a specific remote server:
weft monitor prod
```

Metrics tracked:
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

### Garbage Collection (`weft gc`)

Prune stale deployment artifacts, old logs, and unused sandbox directories locally or remotely:

```bash
# Garbage collect locally (preserves 5 most recent deployments):
weft gc

# Dry run to preview disk space reclaimed without deleting files:
weft gc --dry-run

# Prune on a remote server, retaining 3 most recent deployments:
weft gc prod --keep 3

# Remove artifacts older than a given timeframe:
weft gc --older-than 7d
```

### Remote Server Management (`weft remote`)

Manage registered servers stored in `~/.config/weft/remotes.zon`:

```bash
# Install daemon on remote over SSH and register it locally:
weft remote install prod user@57.129.106.133

# List registered remotes:
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

# Run daemon in the foreground (useful for development):
sudo weft daemon run
```

---

## Configuration Reference (`weft/weft.zon`)

Every Weft project defines its graph in `weft/weft.zon`:

```zon
.{
    .workspace = "my-service",
    .pipelines = .{
        .{
            .name = "build",
            .in = .{"src"},
            .out = .{"bin"},
            .pkgs = .{
                "83qs3ksyjclr149vpxbaz1z18wvi9rms-zig-0.16.0",
            },
            .keep = .{
                .{ "zig-cache", ".zig-cache" },
            },
        },
        .{
            .name = "run",
            .in = .{"bin"},
            .second_instance = .kill,
            .env = .{
                .{ "PORT", "3000" },
            },
        },
    },
}
```

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `workspace` | `[]const u8` | Isolation namespace for caches and sandboxes. |
| `pipelines` | `[]Pipeline` | Array of pipeline task definitions. |
| `sources` | `?[][2][]const u8` | Source mappings (defaults to `.{ .{ "", "." } }`). |
| `env` | `[][2][]const u8` | Global environment variables for all pipelines. |

### Pipeline Definition Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | `[]const u8` | *required* | Unique pipeline name. |
| `in` | `[]const []const u8` | `.{}` | Artifacts required before task can execute (`src` denotes repository snapshot). |
| `out` | `?[]const []const u8` | `null` | Output artifact directories created under `$OUT/` and collected after execution. |
| `pkgs` | `[]const []const u8` | `.{}` | Pre-built Nix store paths fetched from binary cache and injected into `$PATH`. |
| `keep` | `[][2][]const u8` | `.{}` | Cache mappings `.{ "cache-id", "path/relative/to/cwd/" }` retained across runs. |
| `second_instance` | `.kill` \| `.ignore` \| `.fail` | `.ignore` | Behavior when a second instance of the pipeline is deployed. |
| `env` | `[][2][]const u8` | `.{}` | Environment variables injected into the task process. |
| `run` | `.default` \| `.{ .script = "name" }` \| `.nothing` | `.default` | Script resolution mode in `weft/`. |

### Scoped Environment Variables (`.env.<remote>`)

Weft supports environment scoping per target remote. Variables in `.env` serve as the base defaults, and `.env.<remote>` overrides or extends them:

* Local deployments (`weft do .run`): loads `.env`, overlaid by `.env.local` if present.
* Remote deployments (`weft do prod.run`): loads `.env`, overlaid by `.env.prod` if present.
* Pre-flight checks (`weft check --remote prod`): validates that all required environment variables for `prod` are satisfied.

---

## Command Reference

| Command | Syntax | Description |
|---|---|---|
| `check` | `weft check [--remote name]` | Pre-flight validation of configuration, DAG, scripts, and environment |
| `do` | `weft do <[remote.]pipeline...>` | Execute build and deployment pipelines across hosts |
| `retry` | `weft retry [deployment]` | Resume or retry an existing deployment run |
| `list` | `weft list` | Display recent deployments and their execution statuses |
| `follow` | `weft follow <[deployment.]pipeline>` | Stream live logs for a running task |
| `monitor` | `weft monitor [remote]` | Open real-time host metrics dashboard (CPU, memory, I/O, network) |
| `kill` | `weft kill [deployment] [pipeline]` | Terminate a deployment or a specific pipeline in a deployment |
| `gc` | `weft gc [remote] [--keep N] [--older-than dur] [--dry-run]` | Garbage collect stale deployment artifacts and sandboxes |
| `nix show` | `weft nix show <pkg>` | Query Hydra for the latest pre-built Nix store basename |
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
