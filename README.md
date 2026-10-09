# Weft

A lightweight deployment tool and task orchestrator with a daemon and client, designed to run pipelines and scripts across machines and pass inputs and outputs between steps.

While there are already many tools built for machines with 512MB+ RAM, Weft is specifically built to deploy comfortably on 128MB–512MB single-core VPSs (such as a $1 [TierHive](https://tierhive.com/r/D8A6B5B18DDE) instance). It lets you define pipelines, explicitly choose what they require, produce, and where they run, relying on native Linux cgroups and systemd for isolation with a daemon that runs under 10–15MB RAM (+ ~9MB per concurrent package fetch from Nix) to leave as much memory as possible for your actual applications.

Weft is currently in active development. Breaking changes may occur frequently.

## Concepts

- **Workspace**: A project containing its resources, configuration, and pipelines. Workspaces are isolated from one another on remotes; each receives its own run directory, artifacts, cache, and home directory under `/var/lib/weft/`. A single remote host can run tasks for multiple workspaces concurrently.
- **Remote**: Any machine running the `weftd` daemon. The `local` remote refers to an installation running on the same host as the client. The daemon listens over TCP, manages and spawns tasks, enforces resource constraints, and acts as a lightweight Nix binary cache client to fetch pre-built packages.
- **Client**: The `weft` CLI running on your development machine or CI runner. It acts as the deployment orchestrator, computing dependency graphs, packaging sources, syncing artifacts between hosts, triggering executions, and streaming logs. The client holds the full picture of the deployment, while remotes only manage individual tasks and workspace files.
- **Deployment**: A single execution run of your target pipelines, identified by a unique 8-character identifier (such as `2EWbDg3L`).
- **Pipeline**: A declarative step in your workflow that defines required inputs, output artifacts produced, the execution script or command to run, environment variables and package dependencies, resource limits, sibling concurrency policies, and persistent cache directories.
- **Task**: An active running instance of a pipeline dispatched to a remote. Each task executes as a dedicated transient systemd unit under an unprivileged user with strict filesystem and cgroup protections.
- **Artifact**: A directory tree exchanged between pipeline steps or remote hosts. Source directories are packaged as source artifacts, and pipeline output directories are captured as build artifacts. Artifacts are transferred over the wire and stored uncompressed on disk.
- **Modes**: Named configuration overlays (such as `default`, `prod`, or `dev`) that allow customizing packages, variables, or targets per deployment target without duplicating pipeline or environment definitions.

## Wire Protocol & Security

Communication between the client and daemon takes place exclusively over TCP sockets (port `9338` by default).

### Authentication & Encryption

Authentication uses Ed25519 keypairs. The client generates an identity key (`~/.config/weft/key`), and the daemon maintains authorized client public keys in `/etc/weft/keys`. Traffic is encrypted using `XChaCha20-Poly1305` AEAD with ephemeral session keys established during handshake.

### Handshake & Versioning

Connections begin with an exchange of the protocol magic bytes (`weft`) and a 64-bit schema hash (`proto.hash`) derived from wire types. If the client and daemon schema hashes do not match, a warning is emitted to indicate version divergence between client and server.

### Nonces & Framing

Both ends exchange randomly generated 24-byte nonces during connection establishment. Packets are framed with a 16-bit length prefix, encrypted with an incrementing nonce counter, and verified against a 16-byte Poly1305 authentication tag before processing. Payloads are serialized using the internal `zoto` binary format.

## Setup

The `weft` binary serves as both the client orchestrator and the daemon runner.

### System Requirements

The client runs on Linux, macOS, or Windows, and requires standard `ssh` and `scp` utilities when installing on remote machines.

The daemon runs on Linux hosts with systemd. Because tasks resolve pre-built Nix store packages directly from Hydra and the Nix binary cache, remote hosts should run on Linux architectures supported by nixpkgs (such as `x86_64-linux` or `aarch64-linux`).

### Building from Source

Building Weft requires [Zig](https://ziglang.org/) 0.17+ (master).

```bash
zig build -Doptimize=ReleaseSafe
```

This command produces `zig-out/bin/weft`. You can manually copy it to `/usr/local/bin/weft`, or run `sudo ./zig-out/bin/weft daemon install`, which automatically copies the binary to `/usr/local/bin/weft` during installation.

### Installing the Daemon

Run the daemon installer on any Linux host that will execute tasks:

```bash
sudo weft daemon install
```

The installer provisions the unprivileged `weft-runner` system user via `systemd-sysusers`, creates `/etc/weft/config.zon` with restrictive permissions (`0600`), creates task directory hierarchies under `/var/lib/weft/`, installs the `weftd.service` systemd unit, and immediately starts the daemon.

To run tasks under an existing user instead of creating `weft-runner`, specify the user via `--user <username>` or as a positional argument (e.g. `sudo weft daemon install --user myuser` or `sudo weft daemon install myuser`).

After installing the daemon, register your client public key so it can run tasks:

```bash
sudo weft daemon register $(weft key)
```

### Remote Installation via SSH

From your development machine, you can install Weft and register a remote server in a single step using standard SSH and SCP:

```bash
weft remote install root@192.0.2.1:22
```

Weft uploads the local binary over SCP, runs `weft daemon install` on the remote host, and registers your client public key.

For servers behind NAT or port forwarding (such as NAT VPS instances) where the public Weft port or IP differs from the SSH connection, specify the daemon address using `--weft-addr`:

```bash
weft remote install root@192.0.2.1:2222 --weft-addr 192.0.2.1:19338
```

You can also pass installer options such as `--user <username>` directly through `weft remote install`.

To register your client key on an already installed remote daemon:

```bash
weft remote register root@192.0.2.1:22
```

## Configuration Schemas

Weft relies on two configuration files:

1. `/etc/weft/config.zon`: Configures the daemon service, network port, and worker limits on the remote host (with authorized keys in `/etc/weft/keys`).
2. `weft/weft.zon`: Defines the project pipeline DAG, environments, remotes, and resource constraints in your repository.

### 1. Remote Daemon Configuration (`/etc/weft/config.zon`)

Located at `/etc/weft/config.zon` on the remote host, this file defines daemon server parameters. File permissions must be strictly `0600` (readable only by root).

#### Schema Definition

```zig
pub const Config = struct {
    runner_user: ?[]const u8 = null,
    port: u16 = 9338,
    max_workers: u32 = 8,
    max_nix_workers: u32 = 5,
};
```

#### Example Configuration

```zig
.{
    .port = 9338,
    .max_workers = 8,
    .max_nix_workers = 2,
    .runner_user = "weft-runner",
}
```

- `port`: TCP listening port (defaults to `9338`).
- `max_workers`: Maximum concurrent client connections accepted by the daemon (defaults to `8`).
- `max_nix_workers`: Maximum concurrent background workers for fetching and decompressing Nix packages (defaults to `5`). Each active fetcher uses approximately 9MB of RAM during decompression and releases it immediately upon completion. On constrained VPSs (such as 128MB RAM instances), setting this to `1` or `2` keeps package installation within available system memory.
- `runner_user`: The system user account under which pipeline tasks execute. If `null`, defaults to `weft-runner`.

Authorized client keys are stored in `/etc/weft/keys`, one 64-character hexadecimal public key per line. You can authorize a key using `sudo weft daemon register <key>`.

### 2. Project Configuration (`weft/weft.zon`)

Located at `weft/weft.zon` within your project repository, this file defines the pipelines, dependencies, environments, remotes, and source mappings.

#### Top-Level Struct (`Weft`)

```zig
pub const Weft = struct {
    workspace: []const u8,
    modes: []const []const u8 = &.{"default"},
    sources: ?[]const struct { []const u8, []const u8 } = null,
    environments: []const Env = &.{},
    pipelines: []const Pipeline = &.{},
    remotes: []const Remote = &.{},
};
```

- `workspace`: Unique name for the project. Used to isolate storage, cgroups, unit names, and home directories on target machines.
- `modes`: Supported deployment modes (e.g. `.{ "default", "prod", "staging" }`). Defaults to `&.{"default"}`.
- `sources`: Named mappings from source identifiers to relative paths within the repository: `.{ .{ "backend", "backend/" }, .{ "frontend", "frontend/" } }`. Source directories are packaged as source artifacts prefixed with `-` (e.g. `-backend`). If omitted, defaults to mapping the repository root as `-`.
- `environments`: Reusable environment blocks defining packages and variables.
- `pipelines`: The list of task pipelines.
- `remotes`: List of remote daemon targets: `.{ .{ "name", "host:port", "tags" } }`. The local daemon is always available implicitly as `"local"`.

#### Remotes (`Remote`)

```zig
pub const Remote = struct {
    []const u8, // name
    []const u8, // host:port
    []const u8, // tags separated by spaces
};
```

- `name`: Remote alias used when specifying deployment targets (`<remote>.<pipeline>`).
- `host:port`: Host address and TCP port (e.g. `"192.0.2.10:9338"`).
- `tags`: Space-separated tags/groups used for target filtering in pipeline `.on` declarations (e.g. `"builder prod"`).

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
- `vars`: Key-value pairs of environment variables. Setting a value to `null` instructs Weft to dynamically resolve the variable at execution time.
- `pkgs`: Pre-built Nix store paths (e.g. `vy0xilifxb02fwal0wihsrwc8s69rlyk-rustc-wrapper-1.98.1`). Supports mode scoping (e.g. `prod:pkg-name`).

##### Variable Resolution & Dotenv Hierarchy

When a variable value is set to `null` (such as `.{ "DATABASE_URL", null }`), Weft resolves it at execution time using the following lookup order:
1. `.env.<env-name>` in the project root (e.g. `.env.db` or `.env.rust`).
2. `.env` in the project root.
3. Parent environments declared in `.uses`.
4. If the variable remains unresolved across all sources, Weft aborts execution with `MissingEnviron`.

##### Mode Scoping

Values in `vars`, `pkgs`, and `uses` can be prefixed with `<mode>:` (e.g. `prod:PORT`, `staging:db`). When running under a specific mode, Weft filters out declarations belonging to other modes and applies matching overrides. Unprefixed declarations apply to all modes.

##### Nix Package Integration

Weft acts as a lightweight client for Nix binary caches. It downloads pre-built package closures directly over HTTP from `cache.nixos.org` without requiring the Nix daemon or package manager installed on the target machine:
1. Query Hydra for the latest store path using the CLI:
   ```bash
   weft nix show bun
   # Output: qkydg77xf2s395md9fq0a6djjpq7fzh4-bun-1.4.2
   ```
2. Paste the resulting basename directly into `.pkgs`.
3. When a task is dispatched, the daemon downloads the NAR archives and unpacks them into `/var/lib/weft/store/`.
4. During execution, `/var/lib/weft/store` is mounted read-only into `/nix/store`, and all declared package binary directories (`/nix/store/<pkg>/bin`) are prepended to the task's `$PATH`.

#### Pipelines (`Pipeline`)

```zig
pub const Pipeline = struct {
    name: []const u8,
    in: []const []const u8 = &.{},
    out: ?[]const []const u8 = null,
    run: ?Run = null,
    on: ?[]const []const u8 = null,
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

- `name`: Pipeline identifier. By default, executes `weft/<name>.sh` (or `weft/<name>.*`).
- `in`: Dependencies required before execution. Prepend `-` for source trees (e.g. `"-backend"` or `"-"`), or specify an artifact output emitted by an upstream pipeline.
- `out`: Output artifacts produced by the pipeline. Defaults to `.{ name }` if omitted, but can declare multiple custom artifact names (e.g. `.{ "bin", "assets" }`).
- `on`: Optional priority list of remote names or remote groups/tags where this pipeline is allowed to run (e.g. `.{ "local" }` or `.{ "builder", "prod" }`). When resolving steps, Weft prioritizes the preferred remote if it matches `.on`, or auto-selects the first matching candidate.
- `run`: Execution override:
  - If omitted (`null`), Weft executes the matching script file in `weft/` (e.g. `weft/<name>.sh` or `weft/<name>.*`).
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

## Task Execution & Sandboxing

When Weft runs a pipeline, the daemon prepares an isolated runtime environment and launches the script as a transient systemd service unit.

### Host Directory Layout

All task operations take place under `/var/lib/weft/`:

- **Run Directory (`/var/lib/weft/run/<workspace>/<pipeline>/<deployment_id>/`)**:
  - `bin`: The executable script payload.
  - `cwd/`: The working directory where the script executes.
  - `out/`: Captured output artifact directories (`out/<output>/`).
  - `started`: Marker touched by `ExecStartPost` when the task begins.
- **Artifacts (`/var/lib/weft/artifacts/<workspace>/<deployment_id>/`)**: Stored uncompressed artifacts for the deployment.
- **Archive (`/var/lib/weft/archive/<workspace>/<deployment_id>/<pipeline>/`)**: Task stdout/stderr log file (`logs`) and exit code record (`status`).
- **Cache (`/var/lib/weft/cache/<workspace>/<cache_name>/`)**: Persistent directories maintained across deployments and bound to paths declared in `.keep`.
- **Home (`/var/lib/weft/home/<workspace>/`)**: Isolated persistent home directory scoped to the workspace.
- **Store (`/var/lib/weft/store/`)**: Nix store packages, bind-mounted read-only to `/nix/store`.

### Environment Variables

Weft injects standard variables into every running script:

- `$IN`: Directory containing input artifacts. Each input declared in `.in` is accessible under `$IN/<input>/`. Source inputs reside at `$IN/-<source>/` (or `$IN/-` if using repository root mapping), and upstream pipeline outputs reside at `$IN/<output>/`.
- `$OUT`: Directory where output artifacts must be written. Each output declared in `.out` expects its files under `$OUT/<output>/` (defaulting to `$OUT/<pipeline-name>/` when `.out` is omitted). A pipeline can produce multiple distinct output artifacts.
- `$HOME`: Persistent home directory scoped to the workspace (`/var/lib/weft/home/<workspace>`).
- `$PATH`: Pre-configured search path automatically prepended with `/nix/store/<pkg>/bin` for all packages declared in `.pkgs`.
- `$WEFT_MODE`: Active deployment mode (`default`, `prod`, etc.).
- `$WEFT_PIPELINE`: Name of the pipeline currently running.
- `$WEFT_WORKSPACE`: Name of the active workspace.
- `$WEFT_DEPLOYMENT`: Unique 8-character deployment ID.
- `$WEFT_UNIT`: Full systemd unit name (`weft-runner--<workspace>--<pipeline>--<deployment_id>`).
- Custom variables declared in the pipeline or resolved dynamically from `.env`.

### Sandboxing & Resource Isolation

Tasks execute with strict isolation enforced through systemd and Linux cgroups:

The task runs unprivileged under `weft-runner` (or configured `runner_user`) with `NoNewPrivileges=yes` and an empty capability bounding set (`CapabilityBoundingSet=`), preventing privilege escalation.

Filesystem access is strictly locked down: `ProtectSystem=strict` mounts `/usr`, `/boot`, and `/etc` read-only, `PrivateTmp=yes` grants an isolated private `/tmp`, and `/nix/store` is bind-mounted read-only. Writable access is confined exclusively to the task's working directory (`cwd`), declared output directories (`out`), persistent caches (`keep`), and workspace home (`$HOME`).

System security is further hardened using `ProtectControlGroups=yes`, `ProtectKernelModules=yes`, `ProtectKernelTunables=yes`, and `PrivateDevices=yes`. Network access can be disabled entirely by setting `.tune.disable_network = true` (`PrivateNetwork=yes`).

Hardware resource constraints defined in `.tune` are applied directly to systemd cgroups properties (`MemoryMax`, `MemoryHigh`, `CPUQuota`, `TasksMax`, `IOWeight`, `TimeoutStartSec`). Upon completion, systemd's `ExecStopPost` notifies the daemon over `/run/weft/weft.pipe`, which records the exit code, closes log streams, and unblocks downstream tasks.

## Workflow & Commands

Weft includes a built-in command reference. Run `weft help` or `weft <subcommand> --help` to inspect all available flags and options.

### Validating Configuration

Validate `weft/weft.zon`, checking for syntax errors, missing source directories, cycles in the pipeline graph, missing shebangs, and unresolved environment variables:

```bash
weft check
```

### Viewing Client Public Key

Display the client's Ed25519 public key hex:

```bash
weft key
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

When a deployment begins, Weft computes the execution DAG for the requested targets, packages source directories, syncs artifacts to remotes, executes prerequisite pipelines in topological order, transfers output artifacts between remotes as required by downstream dependencies, and streams logs and resource metrics to the client terminal in real-time.

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

The monitor reports host CPU utilization with variance indicators, RAM usage, network throughput (RX / TX), disk bandwidth, and active task units with per-process CPU time and memory consumption.

## Example Project

Below is a complete example configuration illustrating pipelines, Nix packages, environments, and caching.

`weft/weft.zon`:
```zig
.{
    .workspace = "my-service",
    .modes = .{ "default", "prod" },

    .remotes = .{
        .{ "prod-server", "192.0.2.10:9338", "prod" },
    },

    .sources = .{
        .{ "server", "server/" },
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
            },
        },
    },

    .pipelines = .{
        .{
            .name = "server-build",
            .in = .{"-server"},
            .on = .{"local"},
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
            .name = "server-run",
            .in = .{"server-build"},
            .on = .{"prod"},
            .sibling = .{ .then = .kill },
            .env = .{
                .uses = .{"db"},
                .vars = .{
                    .{ "PORT", "8080" },
                    .{ "prod:PORT", "80" },
                },
            },
        },
    },
}
```

Script file `weft/server-build.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

cp -r "$IN/-server/"* ./
cargo build --release

mkdir -p "$OUT/server-build"
cp target/release/app "$OUT/server-build/app"
```

## License

MIT License. See [LICENSE](LICENSE) for details.
