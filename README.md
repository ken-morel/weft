# Weft

A lightweight deployment tool and task orchestrator with a daemon and client, designed to run pipelines and scripts across machines and pass inputs and outputs between steps.

While there are already many tools built for machines with 512MB+ RAM, Weft is specifically built to deploy comfortably on 128MB–512MB single-core VPSs (such as a $1 [TierHive](https://tierhive.com) instance). It lets you define pipelines, explicitly choose what they require, produce, and where they run, relying on native Linux cgroups and systemd for isolation with a daemon that runs under 10–15MB RAM (+ ~9MB per concurrent package fetch from Nix, freed immediately after extraction) to leave as much memory as possible for your actual applications.

Weft is currently in active development. Breaking changes may occur frequently.

## Concepts

- **Workspace**: A project containing its resources, configuration, and pipelines. Workspaces are isolated from one another on remotes; each receives its own run directory, artifacts, cache, and home directory under `/var/lib/weft/`. A single remote host can run tasks for multiple workspaces concurrently.
- **Remote**: Any machine running the `weftd` daemon. The `local` remote refers to an installation running on the same host as the client. The daemon listens over TCP, manages and spawns tasks, enforces resource constraints, and acts as a lightweight Nix binary cache client to fetch pre-built packages.
- **Client**: The `weft` CLI running on your development machine or CI runner. It acts as the orchestrator: parsing configuration, computing dependency graphs, packaging sources, syncing artifacts between hosts, triggering executions, and streaming logs.
- **Deployment**: A single execution run of your target pipelines, identified by a unique 8-character identifier (e.g. `2EWbDg3L`).
- **Pipeline**: A declarative step in your workflow defining:
  - **Inputs (`in`)**: What the step needs before running—either a source directory from your repository (prefixed with `-`, like `-backend`) or an output artifact emitted by an upstream pipeline (like `backend-build`).
  - **Outputs (`out`)**: Artifacts produced by the pipeline. Files placed in the output directory are captured as artifacts for downstream pipelines.
  - **Environment (`env`)**: Environment variables and pre-built Nix store packages made available to the task.
  - **Execution (`run`)**: An executable script file in `weft/`, an inline script, or a meta-pipeline that runs no script but coordinates dependencies.
  - **Constraints (`tune`)**: Linux cgroup and systemd limits (memory, CPU, processes, timeouts, network isolation).
  - **Sibling Policies (`sibling`)**: Rules for managing concurrent or previous instances of the same pipeline.
  - **Persistent Cache (`keep`)**: Directories preserved across runs (e.g. compiler build caches).
- **Task**: An active running instance of a pipeline spawned on a remote. Each task executes as a dedicated transient systemd unit (`weft-runner--<workspace>--<pipeline>--<deployment_id>`) under an unprivileged user with strict filesystem and cgroup protections.
- **Artifact**: A directory tree exchanged between pipeline steps or hosts. Source directories are packaged as source artifacts, and pipeline output directories are captured as build artifacts. Artifacts are transferred over the wire and stored uncompressed on disk.
- **Modes**: Named configuration overlays (such as `default`, `prod`, `dev`) that allow customizing packages, variables, or targets per deployment target without duplicating pipeline or environment definitions.

## Wire Protocol & Security

Communication between the client and daemon takes place exclusively over TCP sockets (port `9338` by default).

- **Authentication & Encryption**: All traffic is authenticated and encrypted using `XChaCha20-Poly1305` AEAD with a 32-byte pre-shared key (PSK) represented as a 64-character hexadecimal string. The key is stored in `/etc/weft.zon` on the remote and in `~/.config/weft/remotes.zon` on the client.
- **Handshake**: Connections begin with an exchange of the protocol magic bytes (`weft`) and a 64-bit schema hash (`proto.hash`) derived from wire types. If the client and daemon schema hashes do not match, a warning is emitted to indicate version divergence.
- **Nonces & Framing**: Both ends exchange randomly generated 24-byte nonces during connection establishment. Packets are framed with a 16-bit length prefix, encrypted with an incrementing nonce counter, and verified against a 16-byte Poly1305 authentication tag before processing. Payloads are serialized using the internal `zoto` binary format.

## Setup

The `weft` binary serves as both the client and the daemon.

### Prerequisites

- **Client**: Linux, macOS, or Windows.
- **Daemon / Remote Host**: Linux with systemd.
- **Building from Source**: [Zig](https://ziglang.org/) 0.17+ (master).

### Compiling from Source

```bash
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/weft /usr/local/bin/weft
```

### Installing the Daemon

Run this on any Linux server that will execute tasks:

```bash
sudo weft daemon install
```

To run tasks under an existing user instead of creating `weft-runner`, pass the `--user` flag:

```bash
sudo weft daemon install --user myuser
```

This command:
- Creates the unprivileged `weft-runner` system user via `systemd-sysusers`.
- Generates a secure random 32-byte secret in `/etc/weft.zon` with restrictive permissions (`0600`).
- Installs the `weftd.service` systemd unit in `/etc/systemd/system/`.
- Initializes directory trees under `/var/lib/weft/`.
- Enables and starts `weftd.service` immediately.

To inspect the generated authentication token on the daemon machine:

```bash
sudo weft daemon token
```

### Registering Remotes

#### Automated Provisioning via SSH

From your development machine, you can install and register a remote server in a single step:

```bash
weft remote install my-server root@192.0.2.1:22
```

Weft uploads the binary over SCP, runs the daemon installer, retrieves the generated authentication token, and writes the host entry into `~/.config/weft/remotes.zon`. If SSH host aliases are used in `~/.ssh/config`, Weft resolves the underlying hostname automatically.

#### Manual Registration

You can also register hosts directly by editing `~/.config/weft/remotes.zon` (or `$XDG_CONFIG_HOME/weft/remotes.zon`):

```zig
.{
    .{
        .name = "my-server",
        .address = .{ "192.0.2.1", 9338 },
        .token = "4a8f9c...64_hex_chars...",
    },
    .{ // local
        .token = "e3b0c4...local_daemon_token...",
    },
}
```

## Configuration Schemas

Weft relies on three distinct configuration files:
1. `weft/weft.zon`: Defines the project pipeline DAG, environments, and resource constraints.
2. `remotes.zon`: Stores registered daemon connections and pre-shared authentication keys on the client.
3. `weft.zon` (`/etc/weft.zon`): Configures the local daemon daemon service, networking, and worker limits.

---

### 1. Project Configuration (`weft/weft.zon`)

Located at `weft/weft.zon` within your project repository, this file defines the pipelines, dependencies, environments, and source mappings.

#### Top-Level Struct (`Weft`)

```zig
pub const Weft = struct {
    workspace: []const u8,
    modes: []const []const u8 = &.{"default"},
    sources: ?[]const struct { []const u8, []const u8 } = null,
    environments: []const Env = &.{},
    pipelines: []const Pipeline = &.{},
};
```

- `workspace`: Unique name for the project. Used to isolate storage, cgroups, unit names, and home directories on target machines.
- `modes`: Supported deployment modes (e.g. `.{ "default", "prod", "staging" }`). Defaults to `&.{"default"}`.
- `sources`: Named mappings from source identifiers to relative paths within the repository: `.{ .{ "backend", "backend/" }, .{ "frontend", "frontend/" } }`. Source directories are packaged as source artifacts prefixed with `-` (e.g. `-backend`). If omitted, defaults to mapping the entire repository root as `-`.
- `environments`: Reusable environment blocks defining packages and variables.
- `pipelines`: The list of task pipelines.

#### Environments (`Env`)

```zig
pub const Env = struct {
    name: []const u8,
    uses: []const []const u8 = &.{},
    vars: []const struct { []const u8, ?[]const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
};
```

- `name`: Identifier for the environment.
- `uses`: List of parent environment names to inherit from. Supports mode scoping (e.g. `prod:db`).
- `vars`: Key-value pairs of environment variables. Setting a value to `null` instructs Weft to dynamically resolve the variable at runtime.
- `pkgs`: Pre-built Nix store paths (e.g. `vy0xilifxb02fwal0wihsrwc8s69rlyk-rustc-wrapper-1.98.1`). Supports mode scoping (e.g. `prod:pkg-name`).

##### Variable Resolution & Dotenv Hierarchy

When a variable value is set to `null` (such as `.{ "DATABASE_URL", null }`), Weft resolves it at execution time using the following lookup order:
1. `.env.<env-name>` in the project root (e.g. `.env.db` or `.env.rust`).
2. `.env` in the project root.
3. Parent environments declared in `.uses`.
4. If the variable remains unresolved across all sources, Weft aborts execution with `MissingEnviron`.

##### Mode Scoping

Values in `vars`, `pkgs`, and `uses` can be prefixed with `<mode>:` (e.g. `prod:PORT`, `staging:db`). When running under a specific mode, Weft filters out declarations belonging to other modes and applies the matching overrides. Unprefixed declarations apply to all modes.

##### Nix Package Integration

Weft acts as a lightweight client for Nix binary caches. It downloads pre-built package closures directly over HTTP from `cache.nixos.org` without requiring the Nix daemon or package manager installed on the target machine:
- Query Hydra for the latest store path using the CLI:
  ```bash
  weft nix show bun
  # Output: qkydg77xf2s395md9fq0a6djjpq7fzh4-bun-1.4.2
  ```
- Paste the resulting basename directly into `.pkgs`.
- When a task is dispatched, the daemon downloads the NAR archives and unpacks them into `/var/lib/weft/store/`.
- During execution, `/var/lib/weft/store` is mounted read-only into `/nix/store`, and all declared package binary directories (`/nix/store/<pkg>/bin`) are prepended to the task's `$PATH`.

#### Pipelines (`Pipeline`)

```zig
pub const Pipeline = struct {
    name: []const u8,
    in: []const []const u8 = &.{},
    out: ?[]const []const u8 = null,
    run: ?Run = null,
    tune: Tune = .{},
    sibling: HandleSibling = .{ .then = .ignore },
    keep: []const struct { []const u8, []const u8 } = &.{},
    env: struct {
        uses: []const []const u8 = &.{},
        vars: []const struct { []const u8, ?[]const u8 } = &.{},
        pkgs: []const []const u8 = &.{},
    } = .{},
};
```

- `name`: Pipeline identifier. By default, executes `weft/<name>.sh` (or `weft/<name>`).
- `in`: Dependencies required before execution. Prepend `-` for source trees (e.g. `"-backend"`), or specify the name of an upstream pipeline to consume its output artifact.
- `out`: Output artifacts to capture upon successful exit. Defaults to `.{ name }`.
- `run`: Optional execution override:
  - `.run = .{ .script = .{ "#!/bin/sh", "echo 'inline task'" } }`: Inline script lines. The first line must be a valid shebang (`#!`).
  - `.run = .{ .file = "custom.sh" }`: Relative path to a script inside the `weft/` directory.
  - `.run = .nothing`: Meta-pipeline that executes no script but triggers all prerequisite dependencies listed in `.in`.
- `keep`: Cache directories preserved across deployments: `.{ .{ "cache_name", "relative/path/" } }`. The host storage at `/var/lib/weft/cache/<workspace>/<cache_name>/` is bind-mounted directly into the task's working directory at the specified relative path.
- `sibling`: Policy for handling existing running instances of this pipeline:
  ```zig
  pub const HandleSibling = struct {
      then: union(enum) {
          kill,   // Terminate the existing running instance
          ignore, // Run concurrently alongside the existing instance
          fail,   // Abort immediately with an error
          skip,   // Cleanly skip execution if an instance is already active
      },
      wait: u32 = 0, // Seconds to wait before applying the `then` action
      poll: u32 = 5, // Polling interval in seconds
  };
  ```
- `tune`: Linux cgroups and systemd resource constraints:
  ```zig
  pub const Tune = struct {
      memory_max: ?u64 = null,        // Hard memory limit in bytes (MemoryMax)
      memory_high: ?u64 = null,       // Memory throttling threshold (MemoryHigh)
      cpu_quota: ?u16 = null,         // CPU quota percentage (100 = 1 full core)
      tasks_max: ?u32 = null,         // Maximum process/thread count (TasksMax)
      io_weight: ?u32 = null,         // Block I/O scheduling weight (1..10000)
      timeout: ?u32 = null,           // Maximum runtime in seconds (TimeoutStartSec)
      disable_network: bool = false,  // Disables network access (PrivateNetwork=yes)
      oom_score_adjust: ?i32 = null,  // Kernel OOM score adjustment (-1000..1000)
  };
  ```
- `env`: Environment definitions specific to this pipeline, structured identically to `Env`.

#### Project Example

`weft/weft.zon`:
```zig
.{
    .workspace = "my-service",
    .modes = .{ "default", "prod" },

    .sources = .{
        .{ "server", "server/" },
        .{ "web", "web/" },
    },

    .environments = .{
        .{
            .name = "db",
            .vars = .{
                .{ "DATABASE_URL", "postgresql://postgres:@localhost:5432/dev" },
                .{ "prod:DATABASE_URL", null }, // Resolved from .env.db or .env in prod
            },
        },
        .{
            .name = "toolchain",
            .pkgs = .{
                "vy0xilifxb02fwal0wihsrwc8s69rlyk-rustc-wrapper-1.98.1",
                "qkydg77xf2s395md9fq0a6djjpq7fzh4-bun-1.4.2",
            },
        },
    },

    .pipelines = .{
        .{
            .name = "server-build",
            .in = .{"-server"},
            .keep = .{
                .{ "cargo-target", "target/" },
            },
            .env = .{ .uses = .{"toolchain"} },
            .tune = .{
                .memory_max = 512 * 1024 * 1024,
                .cpu_quota = 100,
            },
        },

        .{
            .name = "server-migrate",
            .in = .{"server-build"},
            .sibling = .{ .wait = 30, .then = .fail },
            .env = .{
                .uses = .{"db"},
                .vars = .{
                    .{ "DATABASE_URL", null },
                },
            },
        },

        .{
            .name = "server-run",
            .in = .{ "server-build", "server-migrate" },
            .sibling = .{ .then = .kill },
            .env = .{
                .uses = .{"db"},
                .vars = .{
                    .{ "PORT", "8080" },
                    .{ "prod:PORT", "80" },
                },
            },
        },

        .{
            .name = "web-run",
            .in = .{"-web"},
            .sibling = .{ .then = .kill },
            .keep = .{
                .{ "bun-cache", "node_modules/" },
            },
            .env = .{
                .uses = .{"toolchain"},
                .vars = .{
                    .{ "PORT", "3000" },
                },
            },
        },

        // Meta-pipelines to orchestrate multi-step deployments
        .{
            .name = "build",
            .in = .{"server-build"},
            .run = .nothing,
        },
        .{
            .name = "run",
            .in = .{ "server-run", "web-run" },
            .run = .nothing,
        },
    },
}
```

Pipeline script examples in `weft/`:

`weft/server-build.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

cp -r "$IN/-server/"* ./
cargo build --release

mkdir -p "$OUT/server-build"
cp target/release/app "$OUT/server-build/app"
```

`weft/server-run.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

cp "$IN/server-build/app" ./app
chmod +x ./app
exec ./app
```

---

### 2. Client Remotes Registry (`remotes.zon`)

Located at `~/.config/weft/remotes.zon` (or `$XDG_CONFIG_HOME/weft/remotes.zon`), this file contains the registry of known remote daemons. File permissions are restricted to `0600`.

#### Schema Definition

```zig
pub const Remote = struct {
    name: ?[]const u8 = null,
    address: struct { []const u8, u16 } = .{ "127.0.0.1", 9338 },
    token: []const u8,
    groups: []const []const u8 = &.{},
};
```

The configuration is parsed as an array of `Remote` records:

```zig
.{
    .{
        .name = "prod-node-1",
        .address = .{ "192.0.2.10", 9338 },
        .token = "3a7b...64_hex_chars...9f1e",
        .groups = .{ "prod", "us-east" },
    },
    .{
        .name = "local",
        .address = .{ "127.0.0.1", 9338 },
        .token = "8d1c...local_daemon_token...4a2b",
    },
}
```

- `name`: Remote alias used when specifying deployment targets (`<remote>.<pipeline>`). If omitted, defaults to `"local"`.
- `address`: Hostname/IP and TCP port tuple. Defaults to `.{ "127.0.0.1", 9338 }`.
- `token`: 32-byte cryptographic secret formatted as a 64-character lowercase hexadecimal string.
- `groups`: Optional string tags for categorization.

---

### 3. Daemon Configuration (`/etc/weft.zon`)

Located at `/etc/weft.zon` on the remote host, this file defines daemon server parameters. File permissions must be strictly `0600` (readable only by root).

#### Schema Definition

```zig
pub const Config = struct {
    runner_user: ?[]const u8 = null,
    secret: []const u8,
    port: u16 = 9338,
    max_workers: u32 = 8,
    max_nix_workers: u32 = 5,
};
```

#### Example Configuration

```zig
.{
    .secret = "3a7b21e8d4c5f6a7...64_hex_chars...9f1e8a2b3c4d5e6f",
    .port = 9338,
    .max_workers = 8,
    .max_nix_workers = 2,
    .runner_user = "weft-runner",
}
```

- `secret`: The pre-shared 32-byte key in 64-character hex format used to encrypt and authenticate incoming TCP connections.
- `port`: TCP listening port (defaults to `9338`).
- `max_workers`: Maximum concurrent client connections accepted by the daemon (defaults to `8`).
- `max_nix_workers`: Maximum concurrent background workers for fetching and decompressing Nix packages (defaults to `5`). Each active Nix fetcher uses approximately 9MB of RAM during decompression and releases it immediately upon completion. On constrained VPSs (e.g. 128MB RAM), setting this to `1` or `2` guarantees that package installation stays well within available system memory.
- `runner_user`: The system user account under which pipeline tasks execute. If `null`, defaults to `weft-runner`.

---

## Task Execution & Sandboxing

When Weft runs a pipeline, the daemon prepares an isolated runtime environment and launches the script as a transient systemd service unit.

### Host Directory Layout

All task operations take place under `/var/lib/weft/`:
- **Run Directory (`/var/lib/weft/run/<workspace>/<pipeline>/<deployment_id>/`)**:
  - `bin`: The executable script payload.
  - `cwd/`: The working directory where the script executes.
  - `out/`: Captured output artifact directories (`out/<pipeline>/`).
  - `started`: Marker touched by `ExecStartPost` when the task begins.
- **Artifacts (`/var/lib/weft/artifacts/<workspace>/<deployment_id>/`)**: Stored uncompressed artifacts for the deployment.
- **Archive (`/var/lib/weft/archive/<workspace>/<deployment_id>/<pipeline>/`)**: Task stdout/stderr log file (`logs`) and exit code record (`status`).
- **Cache (`/var/lib/weft/cache/<workspace>/<cache_name>/`)**: Persistent directories maintained across deployments and bound to paths declared in `.keep`.
- **Home (`/var/lib/weft/home/<workspace>/`)**: Isolated persistent home directory scoped to the workspace.
- **Store (`/var/lib/weft/store/`)**: Nix store packages, bind-mounted read-only to `/nix/store`.

### Environment Variables

Weft injects standard variables into every running script:

- `$IN`: Directory containing input artifacts. Source directories reside at `$IN/-<source-name>/`, and upstream pipeline outputs reside at `$IN/<upstream-pipeline>/`.
- `$OUT`: Directory where output files must be written. Files placed in `$OUT/<pipeline-name>/` are captured as the pipeline's output artifact.
- `$HOME`: Persistent home directory scoped to the workspace (`/var/lib/weft/home/<workspace>`).
- `$PATH`: Pre-configured search path automatically prepended with `/nix/store/<pkg>/bin` for all packages declared in `.pkgs`.
- `$WEFT_MODE`: The active deployment mode (`default`, `prod`, etc.).
- `$WEFT_PIPELINE`: Name of the pipeline currently running.
- `$WEFT_WORKSPACE`: Name of the active workspace.
- `$WEFT_DEPLOYMENT`: Unique 8-character deployment ID.
- `$WEFT_UNIT`: The full systemd unit name (`weft-runner--<workspace>--<pipeline>--<deployment_id>`).
- Custom variables declared in the pipeline or resolved dynamically from `.env`.

### Sandboxing & Resource Isolation

Tasks execute with strict isolation enforced through systemd and Linux cgroups:

- **Unprivileged Execution**: Runs under `weft-runner` (or configured `runner_user`) with `NoNewPrivileges=yes` and an empty capability bounding set (`CapabilityBoundingSet=`), preventing privilege escalation.
- **Filesystem Isolation**:
  - `ProtectSystem=strict`: Mounts `/usr`, `/boot`, and `/etc` read-only.
  - `PrivateTmp=yes`: Grants a private `/tmp` unshared with other processes or host services.
  - Read-only bind-mount of `/nix/store`.
  - Writable access is confined exclusively to the task's working directory (`cwd`), output directory (`out`), cache directories (`keep`), and workspace home (`$HOME`).
- **Kernel Hardening**: `ProtectControlGroups=yes`, `ProtectKernelModules=yes`, `ProtectKernelTunables=yes`, and `PrivateDevices=yes`.
- **Network Control**: Network access can be disabled entirely by setting `.tune.disable_network = true` (`PrivateNetwork=yes`).
- **Cgroup Constraints**: Hardware limits defined in `.tune` are applied directly as systemd properties (`MemoryMax`, `MemoryHigh`, `CPUQuota`, `TasksMax`, `IOWeight`, `TimeoutStartSec`).
- **Lifecycle Tracking**: Upon completion, systemd's `ExecStopPost` notifies the daemon over `/run/weft/weft.pipe`, which records the exit code, closes log streams, and unblocks downstream tasks.

---

## Workflow & Commands

Weft includes a built-in command reference. Run `weft help` or `weft <subcommand> --help` to inspect all available flags and options.

### Validating Configuration

Validate `weft/weft.zon`, checking for syntax errors, missing source directories, cycles in the pipeline graph, missing shebangs, and unresolved environment variables:

```bash
weft check
```

### Finding Nix Package Hashes

Query Hydra for the exact store path of any pre-built package:

```bash
weft nix show bun
weft nix show rustc
```

### Deploying Pipelines

Execute pipelines using `weft do`:

```bash
# Run a pipeline locally in default mode
weft do server-build

# Run in 'prod' mode locally
weft do prod:server-run

# Run on a registered remote named 'prod-server'
weft do prod-server.server-run

# Run in 'prod' mode on 'prod-server'
weft do prod:prod-server.server-run

# Trigger a meta-pipeline or run across multiple remotes concurrently
weft do build
weft do prod-server.server-run local.web-run
```

When a deployment begins:
1. Weft computes the execution DAG for the requested targets.
2. Source directories are packaged and synchronized to the target remotes.
3. Prerequisite pipelines execute in topological order.
4. Output artifacts are transferred between remotes as required by downstream dependencies.
5. Logs and cgroup resource usage stream back to the client terminal in real-time.

### Resuming Failed Deployments

If a step fails (for example, a database migration timeout), resolve the issue and resume the deployment:

```bash
# Resume the latest deployment
weft resume

# Resume a specific deployment by ID or unique ID prefix
weft resume 2EWbDg3L
```

Weft resumes execution from the failed pipeline without repeating completed tasks or re-uploading existing artifacts.

### Viewing Logs

Follow or retrieve logs for active or past pipeline runs:

```bash
weft logs --pipeline server-run
weft logs --pipeline server-run --remote prod-server
weft logs --pipeline server-run --deployment 2EWbDg3L
```

### Stopping Tasks

Terminate a running pipeline instance on a remote:

```bash
weft kill --remote prod-server --deployment 2EWbDg3L --pipeline server-run
```

### Resource Monitoring

Weft includes a real-time terminal monitor that connects to the daemon's metrics endpoint over the encrypted wire:

```bash
weft monitor
weft monitor prod-server
```

The monitor reports:
- Host CPU utilization with variance color indicators (detecting gradual drifts and sudden spikes)
- RAM usage and available physical memory
- Network throughput (RX / TX)
- Disk read and write bandwidth
- Active task units with per-process CPU time and memory consumption

---

## License

MIT License. See [LICENSE](LICENSE) for details.
