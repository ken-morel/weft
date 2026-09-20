# Weft

A lightweight, distributed build and deployment runner written in Zig.

Weft connects local development environments and remote servers into a unified pipeline graph. It coordinates artifact packaging, cache persistence, dependency resolution, process lifecycle management, and task execution across machines.

---

## Key Features

- **Declarative Pipeline Graph (`weft.zon`)**: Define pipelines with explicit input dependencies, output artifacts, persistent caches, and environment bindings.
- **Distributed Remote Execution**: Run build pipelines locally and deploy or run services on remote servers with one command:
  ```bash
  weft do build bellacall.run
  ```
- **Zero-Friction Remote Provisioning**: Install and register remote servers over SSH with a single command:
  ```bash
  weft remote install bellacall s.bellacall
  ```
- **Sandboxed Systemd Execution**: Tasks run in isolated systemd transient units with cgroup accounting, custom mount points, and clean lifecycle management.
- **Process Lifecycle Management (`.second_instance = .kill`)**: Automatically terminate older running instances of a service when deploying a new release.
- **Incremental Build Caching (`.keep`)**: Persist build caches (such as Cargo `target/`, Flutter `.dart_tool/`, and npm/bun caches) across runs per workspace.
- **Streaming Wire Protocol**: Binary artifacts are packed, compressed, streamed over TCP, and unpacked with progress tracking.
- **Live Interactive Terminal UI**: Real-time deployment visualization showing step progress, logs, and artifacts.

---

## Architecture

```
   Local Machine (Client)                         Remote VPS (Daemon)
┌──────────────────────────────┐              ┌──────────────────────────────┐
│  weft do build bellacall.run │              │  weftd (systemd / port 9338) │
│                              │              │                              │
│  1. Snapshot 'src' artifact  │              │  1. Receive artifacts        │
│  2. Execute [local] build    │  TCP (Wire)  │  2. Kill previous instances  │
│  3. Push artifacts ──────────┼─────────────►│  3. Spawn systemd unit       │
│  4. Stream remote logs ◄─────┼──────────────┼─ 4. Run service & stream logs│
└──────────────────────────────┘              └──────────────────────────────┘
```

---

## Requirements

- **Zig**: `>= 0.16.0`
- **Linux**: Kernel with `systemd` support (for daemon task runner).
- **SSH**: OpenSSH client (for remote provisioning).

---

## Installation & Setup

### Build from Source

```bash
git clone https://github.com/dev-safe/weft.git
cd weft
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/weft /usr/local/bin/weft
```

### Install Local Daemon

To run local pipelines or tasks:

```bash
sudo weft daemon install
```

This creates `/var/lib/weft`, initializes `/etc/weft.zon` with a secure token, installs the systemd unit `weftd.service`, and starts the service.

To view your daemon token:

```bash
weft daemon show-token
```

To run the daemon in foreground for debugging:

```bash
sudo weft daemon run
```

---

## Remote Management

Weft manages remote servers in `~/.config/weft/remotes.zon`.

### Add & Install a Remote

To upload the `weft` binary to a remote server, install the daemon systemd service, configure its secret, and register the remote locally:

```bash
# Using an SSH alias or hostname (defaults to root@):
weft remote install bellacall s.bellacall

# With custom SSH user or port:
weft remote install prod user@57.129.106.133:2222

# Specifying a different public host address for the weft daemon:
weft remote install prod root@10.0.0.5 57.129.106.133
```

- If no user is specified, `remote install` defaults to `root@`.
- If a custom SSH port is given (`host:port`), `scp` and `ssh` connect using that port.
- If the remote is already registered, existing host addresses and custom daemon ports are preserved.

---

## Pipeline Configuration (`weft.zon`)

Place a `weft.zon` in your project root:

```zon
.{
    .name = "bellacall",
    .workspace = "bellacall",
    .pipelines = .{
        .{
            .name = "build-backend-release",
            .inputs = .{
                .{ .name = "src" },
            },
            .outputs = .{
                .{ .name = "backend-release" },
            },
            .keep = .{
                .{ "backend-target", "backend/target/" },
            },
        },
        .{
            .name = "build-frontend-web",
            .inputs = .{
                .{ .name = "src" },
            },
            .outputs = .{
                .{ .name = "frontend-web" },
            },
            .keep = .{
                .{ "flutter-tool", "frontend/.dart_tool/" },
                .{ "flutter-build", "frontend/build/" },
            },
        },
        .{
            .name = "build-release",
            .inputs = .{
                .{ .name = "backend-release" },
                .{ .name = "frontend-web" },
            },
            .outputs = .{},
        },
        .{
            .name = "build",
            .inputs = .{
                .{ .name = "backend-release" },
                .{ .name = "frontend-web" },
            },
            .outputs = .{},
            .script = "build-release",
        },
        .{
            .name = "run",
            .inputs = .{
                .{ .name = "backend-release" },
                .{ .name = "frontend-web" },
            },
            .outputs = .{},
            .second_instance = .kill,
            .env = .{
                .{ "PORT", "3000" },
                .{ "DATABASE_URL", "postgresql://user:pass@127.0.0.1:5432/db" },
            },
        },
    },
}
```

### Pipeline Fields

| Field | Type | Description |
|---|---|---|
| `name` | `[]const u8` | Unique pipeline name. |
| `inputs` | `[]Input` | Artifacts needed before this pipeline can run (`src` represents the repository snapshot). |
| `outputs` | `[]Output` | Artifacts produced by this pipeline to store and pass downstream. |
| `keep` | `[]Keep` | Tuple of `.{ "cache-name", "path/relative/to/cwd/" }` mounted into the sandbox and preserved across runs. |
| `second_instance` | `.kill` \| `.ignore` | When set to `.kill`, kills sibling running tasks from previous deployments of the same pipeline. |
| `env` | `[][2][]const u8` | Environment key-value pairs injected into the running task. |
| `script` | `?[]const u8` | Executable script inside `bin/` (defaults to `bin/<pipeline_name>`). |

---

## Pipeline Scripts (`bin/`)

Pipeline executables live in `./bin/` relative to `weft.zon`. Scripts can be written in any language (`sh`, `bash`, `nu`, `python`, etc.):

When a task executes:
- `$IN`: Path to the input artifacts directory (e.g. `$IN/src/`, `$IN/backend-release/`).
- `$OUT`: Path to the output directory where produced artifacts should be saved (e.g. `$OUT/backend-release/`).
- Working directory (`cwd`): Isolated sandbox per deployment.

### Example Build Script (`bin/build-backend-release`)

```nu
#!/usr/bin/env nu

glob $"($env.IN)/src/*" | each { |f| cp -r $f ./ }

cd backend
cargo build --release

mkdir $"($env.OUT)/backend-release"
cp target/release/backend ($env.OUT + "/backend-release/backend")
```

### Example Service Runner (`bin/run`)

```bash
#!/usr/bin/env bash
set -e

cp "$IN/backend-release/backend" ./backend
chmod +x ./backend

exec ./backend
```

---

## Running Pipelines (`weft do`)

### Local Builds

```bash
# Run a specific pipeline locally:
weft do build-backend-release

# Run a composite build:
weft do build
```

### Remote Deployments

Target a remote by prefixing the pipeline name with `<remote>.`:

```bash
# Build locally and run the service on 'bellacall' remote:
weft do build bellacall.run

# Target multiple remotes or pipelines:
weft do local.build bellacall.run

# Run directly on remote (dependencies automatically resolve and upload):
weft do bellacall.run
```

---

## CLI Reference

```
Usage: weft [options] <command> [args]

Commands:
  daemon install                      Install the weft daemon (systemd service, config)
  daemon run                          Run the daemon in the foreground
  daemon show-token                   Print the daemon secret token
  do <pipeline[.remote]...>           Run pipelines: weft do [remote.]pipeline ...
  remote install <name> <ssh> [host]  Install weft on a remote and register it

Options:
  -q, --quiet                         Only log errors
  -v, --verbose                       Log debug messages
  --no-color                          Disable colored output
```

---

## License

MIT / Apache-2.0
