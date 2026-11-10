# Weft

Weft is a deployment and task orchestration tool for Linux written in Zig. A single static binary with zero external dependencies serves as the CLI client, the remote daemon, and the task supervisor.

The primary goal of Weft is to make reproducible, multi-stage deployments practical even on constrained targets such as $0.30 TierHive instances, low-memory VPS hosts, unprivileged LXC or OpenVZ containers, and ephemeral environments like Google Colab, while scaling up cleanly to dedicated bare-metal servers.

- Tasks run directly under a built-in Linux supervisor rather than a container runtime like Docker or Podman, avoiding background daemon bloat and image registry overhead while adapting isolation to what the host kernel permits.
- Pipeline environments can provision packages directly from Nix package repositories without requiring NixOS or a Nix daemon on the target machine.
- Remotes can be reached either over direct TCP connections or through arbitrary local stdio proxy commands (such as SSH tunnels or custom connection scripts) when deploying to machines without public IP addresses.
- Client-to-daemon communication is authenticated using Ed25519 keypairs and encrypted end-to-end with XChaCha20-Poly1305 AEAD. On first use, the client generates a private key in `$XDG_CONFIG_HOME/weft/key` (or `~/.config/weft/key`). Remote daemons maintain a registry of authorized client public keys, verifying the client's signature and protocol version hash during a Diffie-Hellman key exchange before accepting commands or transferring data.

---

## 1. Installation and CLI Reference

All CLI commands accept arguments either positionally (in the order shown below) or as named flags (`--<field> <value>`).

### Installation

#### Prebuilt Binary

```bash
curl -fsSL "https://github.com/ken-morel/weft/releases/download/nightly/weft-linux-x86_64.tar.gz" | sudo tar -xz -C /usr/local/bin
sudo chmod +x /usr/local/bin/weft
```

#### GitHub Actions

```yaml
- uses: ken-morel/weft@nightly
  with:
    version: nightly
```

#### Building from Source

Requires Zig `0.18.0` or newer:

```bash
zig build -Doptimize=ReleaseSafe
```

The compiled binary is output to `zig-out/bin/weft`.

---

### CLI Commands

#### `weft remote`

- `weft remote install {[user@]{ssh_alias|domain|ip}[:port]} [isolate[-scale]]`  
  Uploads the local `weft` binary to the target host via `scp`, runs `weft daemon install` over `ssh`, and registers the local client's public key with the remote daemon.
  - The SSH target accepts an `~/.ssh/config` host alias, a domain name, or an IP address. Omitting `user@` defaults to `root@`, and omitting `:port` uses port 22 or the port configured in `~/.ssh/config`.
  - The optional `[isolate[-scale]]` argument (such as `kvm-small`, `lxc-large`, `vz-tiny`, or `colab`) configures the remote daemon's containerization and worker concurrency profile, detailed in the Daemon section below.

- `weft remote register {[user@]{ssh_alias|domain|ip}[:port]} [pubkey]`  
  Registers an authorized client public key on a remote daemon over SSH by invoking `/usr/local/bin/weft daemon register <pubkey>` on the target host.
  - If `pubkey` (a 64-character hex Ed25519 public key) is omitted, the local client's public key is used.

- `weft remote monitor [{remote_name|domain:port|ip:port|local}]`  
  Connects to a daemon and opens the interactive terminal monitor showing live CPU usage, RAM, swap, disk usage, disk I/O throughput, network RX/TX rates, and active tasks.
  - The target can be a remote name declared in `weft/weft.zon`, an explicit `host:port` address (which works outside of a project directory), or `local` by default.

#### `weft daemon`

- `weft daemon install [isolate[-scale]]`  
  Installs the currently running binary to `/usr/local/bin/weft`, writes the daemon configuration to `/etc/weft/weft.zon`, populates sandbox utility links, and registers and starts the service under the host's init system (`systemd`, `openrc`, or `runit`). Requires superuser privileges.
  - The optional `[isolate[-scale]]` template selects the isolation profile (`kvm`, `lxc`, `vz`, `colab`) and worker scale profile (`tiny`, `small`, `large`), defaulting to `kvm-small`. See the Daemon section below for full details on each profile.

- `weft daemon run`  
  Runs the daemon in the foreground. Normally invoked by the host's service manager after installation.

- `weft daemon register <key>`  
  Adds a 64-character hex Ed25519 public key to `/etc/weft/keys` and notifies the running local daemon over IPC to reload its authorized keys without restarting.

#### `weft do`

- `weft do {[mode:][remote.]pipeline ...}`  
  Resolves the dependency graph for one or more targets, packages required local sources, transfers missing artifacts between remotes, and executes the pipelines across the target remotes while displaying live status in the terminal UI.
  - Omitting `<remote>.` defaults the target remote to `local`.
  - Omitting `<mode>:` on the first target defaults to `default`. When multiple targets are given on the command line, any target without an explicit `<mode>:` prefix inherits the mode of the preceding target (for example, `weft do prod:ds.migrate ds.server` executes both steps under mode `prod`).

#### `weft resume`

- `weft resume [deployment]`  
  Resumes an interrupted or failed deployment using its recorded state in `.weft/`, skipping steps whose outputs are already present and retrying incomplete or failed steps.
  - `deployment` accepts either a full deployment ID or a unique trailing character suffix, and defaults to the latest deployment in `.weft/`.

#### `weft task`

- `weft task spawn {[mode:][remote.]pipeline} [deployment]`  
  Spawns a single pipeline step in a deployment without resolving or running its upstream dependencies. All input artifacts required by the pipeline must already be registered in the specified deployment (defaults to latest).

- `weft task kill {[mode:][remote.]pipeline} [deployment]`  
  Terminates the running task for the specified pipeline step in the given deployment (defaults to latest).

- `weft task logs {[mode:][remote.]pipeline} [deployment]`  
  Streams or prints the combined stdout/stderr logs for a running or completed pipeline step in the given deployment (defaults to latest).

#### `weft artifact`

- `weft artifact pull <name> [remote] [deployment]`  
  Downloads artifact `<name>` from `<remote>` (defaults to `local`) in `<deployment>` (defaults to latest) into the local `.weft/<deployment>/artifacts/<name>` directory and records `local` as holding the artifact.

- `weft artifact push <name> [remote] [deployment]`  
  Uploads artifact or source `<name>` from the local deployment directory to `<remote>` (defaults to `local`) in `<deployment>` (defaults to latest) and records `<remote>` as holding the artifact.

- `weft artifact register <name> [remote] [deployment]`  
  Records `<remote>` (defaults to `local`) as holding artifact `<name>` in `<deployment>` (defaults to latest) without transferring data over the network, and prints the local expected path for that artifact.

- `weft artifact path <name> [deployment]`  
  Prints the local filesystem path where artifact `<name>` is stored for `<deployment>` (defaults to latest).

#### `weft cache`

`pull` transfers workspace caches strictly from a remote to `.weft/caches/<remote>/<cache>` on the local machine. `push` transfers strictly from `.weft/caches/` on the local machine to a remote, verifying that the local cache exists on disk before connecting and failing immediately with `error.CacheNotFound` if it is missing.

- `weft cache pull {remote[.cache]}`  
  Pulls a specific cache when given `remote.cache`, or pulls all caches declared in `keep` across all pipelines in `weft/weft.zon` when given `remote`.

- `weft cache push {src_remote[.src_cache]} [dst_remote[.dst_cache]]`  
  Pushes one or more locally stored caches to a remote.
  - Passing `a.foo` pushes `.weft/caches/a/foo` to remote `a` as `foo`.
  - Passing `a` pushes all caches currently present under `.weft/caches/a/` to remote `a`.
  - Passing `a.foo b.foo` or `a.foo b` pushes `.weft/caches/a/foo` to remote `b` as `foo`.
  - Passing `a.foo b.bar` pushes `.weft/caches/a/foo` to remote `b` under the renamed cache `bar`.
  - Passing `a b` pushes all caches currently present under `.weft/caches/a/` to remote `b` under their respective names.

- `weft cache path {remote[.cache]}`  
  Prints the local filesystem path `.weft/caches/<remote>[/<cache>]` without creating directories on disk.

#### `weft nix`

- `weft nix search <query>`  
  Searches the Devbox Nix package index for `<query>` and lists matching package names and descriptions.

- `weft nix query <name>`  
  Queries available versions, release dates, platforms, and store path identifiers (`<hash>-<name>-<version>`) for package `<name>`.

#### `weft check`, `weft key`, `weft decode`, `weft version`

- `weft check`  
  Validates `weft/weft.zon`, checking identifier syntax, environment and source references, pipeline dependency cycles, script files and shebangs, and remote placement rules.

- `weft key`  
  Prints the local client's 64-character hex Ed25519 public key to stdout.

- `weft decode [file]`  
  Decodes a `zoto`-serialized binary file (or `stdin` when omitted or `-`) and prints it as formatted Zig struct literals.

- `weft version`  
  Prints the build version, wire protocol hash, and optimization mode.

---

## 2. Project Configuration (`weft/weft.zon`)

A project is configured via `weft/weft.zon` in the project root, alongside any pipeline scripts in `weft/`. The configuration file deserializes into the root `Weft` struct (`src/domain/Weft.zig`):

```zig
modes: []const []const u8 = &.{"default"},
environments: []const Env = &.{},
workspace: []const u8,
sources: ?[]const struct { []const u8, []const u8 } = null,

pipelines: []const Pipeline = &.{},
remotes: []const Remote = &.{},

retention: Retention = .{},
```

---

### `.pipelines`

`pipelines` defines the tasks, build stages, migrations, and services of the workspace. Each entry is a `Pipeline` struct:

```zig
pub const Pipeline = struct {
    const Input = []const u8;
    const Output = []const u8;

    name: []const u8,
    in: []const Input = &.{},
    out: ?[]const Output = null,
    run: ?Run = null,
    tune: Tune = .{},
    timeout: ?u32 = null,
    max_retries: u16 = 10,
    retention: ?Retention = null,

    sibling: HandleSibling = .{ .then = .ignore },
    keep: []Keep = &.{},
    on: ?[]const []const u8 = null,

    env: struct {
        uses: []const []const u8 = &.{},
        vars: []const struct { []const u8, ?[]const u8 } = &.{},
        pkgs: []const []const u8 = &.{},
    } = .{},
};
```

#### `.name`

The identifier of the pipeline (`[]const u8`). Must begin with an ASCII letter and contain only ASCII alphanumeric characters, `-`, or `_`.

#### `.in` and `.out`

Pipelines connect to sources and to one another through artifacts declared in `.in` and `.out`:

- An entry in `.in` prefixed with `-` (for example `"-backend"`, or `"-"` for the root source) references a local source directory from `.sources`. Before the pipeline executes, the client packages that directory and uploads it to the target remote, where it is extracted into the task's working directory.
- An entry in `.in` without a leading `-` references an output artifact produced by another pipeline. During `weft do`, Weft resolves the producer pipeline for each input, executes upstream pipelines first, transfers artifacts across remotes when the producer and consumer run on different hosts, and exposes each input artifact inside the sandbox at `$IN/<artifact>`.
- When `.out` is `null` (the default), the pipeline implicitly declares a single output artifact with the same name as `.name`. When `.out` is provided, it specifies the exact list of artifact names produced by the pipeline (or `&.{}` for none). Files written to `$OUT/<artifact>` during execution are harvested as deployment artifacts when the task exits with code `0`.
- Entries in `.in` and `.out` can be prefixed with `<mode>:` (such as `"prod:migrate"`), making that dependency or output active only when running under `<mode>`.

#### `.run`

```zig
pub const Run = union(enum) {
    script: []const u8,
    file: []const u8,
    nothing,
};
```

- Setting `.run = .{ .script = "..." }` executes the inline string as the task entry script; the string must be non-empty and start with a `#!` shebang.
- Setting `.run = .{ .file = "name" }` loads the script from `weft/<name>` or `weft/<name>.sh` in the project directory.
- Leaving `.run` as `null` defaults to `.{ .file = pipeline.name }`, resolving `weft/<pipeline.name>` or `weft/<pipeline.name>.sh`.
- Setting `.run = .nothing` defines a virtual target that spawns no remote process, used to group multiple upstream pipelines in `.in` under a single target name.

#### `.on`

An optional list of remote names or remote group tags (`?[]const []const u8`) restricting where the pipeline is allowed to run.

- When `.on` is `null`, the pipeline can run on any remote.
- When `.on` is set (for example `.on = .{ "local", "build-nodes" }`), the pipeline only executes on remotes matching one of the listed names or tags. If a pipeline on another remote depends on this pipeline's output, Weft automatically schedules this pipeline on a matching remote from `.on` and transfers the resulting artifact to the downstream remote.

#### `.keep`

```zig
pub const Keep = struct {
    []const u8,
    []const u8,
};
```

Each entry is a tuple `.{ "<cache_name>", "<relative_workdir_path>" }` mapping a persistent workspace cache on the remote to a path inside the task's working directory.

- Unlike deployment artifacts, which are immutable and versioned per deployment, `keep` directories persist across deployments on the remote and are mounted or linked into the working directory at `<relative_workdir_path>` before the script starts.
- Used both for incremental build directories (such as `.{ "cargo-target", "target/" }` or `.{ "web-modules", "node_modules/" }`) and for persistent service state (such as `.{ "pg-data", "pg-data" }`).

#### `.sibling`

```zig
pub const HandleSibling = struct {
    then: union(enum) {
        kill,
        ignore,
        fail,
        skip,
    },
    wait: u32 = 0,
    poll: u32 = 5,
};
```

Defines what happens when another instance of the same `<workspace>/<pipeline>` (a sibling) is already running on the remote when the task starts:

- When `wait > 0`, the supervisor polls every `poll` seconds for up to `wait` seconds waiting for the active sibling to exit on its own.
- If the sibling is still running after `wait` seconds (or immediately when `wait == 0`), `then` is applied:
  - `.kill` terminates the existing sibling's process group before starting the new task, used for redeploying long-running services.
  - `.ignore` starts the new task alongside the existing sibling.
  - `.fail` aborts the new task with `error.SiblingRunning`, often combined with `wait` for exclusive tasks like database migrations.
  - `.skip` exits the new task cleanly without running its script if a sibling is active.

#### `.env`

```zig
env: struct {
    uses: []const []const u8 = &.{},
    vars: []const struct { []const u8, ?[]const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
} = .{},
```

- `uses` lists environment names from the top-level `.environments` slice whose `pkgs` and `vars` are inherited by the pipeline.
- `pkgs` lists Nix store package identifiers (`"<hash>-<name>-<version>"`) to provision and add to `PATH` inside the task sandbox.
- `vars` lists environment variable pairs `.{ "<KEY>", <VALUE_OR_NULL> }`. Providing a string literal sets the variable to that value; setting the value to `null` instructs the client to read `<KEY>` from the local host environment when starting the deployment (or fall back to an inherited environment value) and forward it to the remote task.

#### `.tune`

```zig
pub const Tune = struct {
    const Cpu = struct {
        max: ?u64 = null,
        quota: ?u64 = null,
    };
    const Mem = struct {
        max: ?u64 = null,
        high: ?u64 = null,
        oom_score_adjust: ?i32 = null,
        swap: Swap = .{},
        const Swap = struct {
            max: ?u64 = null,
        };
    };
    const Net = struct {
        private: bool = false,
        hosts: []const u8 =
            \\127.0.0.1 localhost localhost.localdomain
            \\::1 localhost localhost.localdomain
            \\
        ,
    };
    const Io = struct {
        io_weight: ?u32 = null,
        pids_max: ?u64 = null,
        mount: []const struct {
            []const u8,
            enum { tmpfs, read, read_write },
            []const u8,
        } = &.{},
    };
    cpu: Cpu = .{},
    mem: Mem = .{},
    net: Net = .{},
    io: Io = .{},
};
```

- `cpu.quota` and `cpu.max` configure the cgroup v2 `cpu.max` bandwidth quota and period in microseconds.
- `mem.max`, `mem.high`, and `mem.swap.max` set cgroup v2 byte limits for hard memory cap, memory throttling threshold, and swap usage; `mem.oom_score_adjust` sets `/proc/self/oom_score_adj`.
- `net.private`, when set to `true`, isolates the task in a private network namespace (`CLONE_NEWNET`) with no external network access; `net.hosts` defines the contents of `/etc/hosts` when mount isolation is active.
- `io.io_weight` and `io.pids_max` configure cgroup v2 block I/O weight and maximum process count (`pids.max`).
- `io.mount` specifies custom mount entries as `.{ "<target_path>", .<mode>, "<source_path>" }` where mode is `.tmpfs`, `.read` (read-only bind), or `.read_write` (read-write bind).

#### `.timeout`, `.max_retries`, `.retention`

- `timeout` sets an optional maximum execution duration in seconds (`?u32`).
- `max_retries` sets the maximum number of retry attempts (`u16`, default `10`).
- `retention` optionally overrides the top-level `Retention` policy for this pipeline.

---

### `.remotes`

```zig
pub const Remote = struct {
    /// The remote name
    []const u8,
    /// The weft host:port
    []const u8,
    /// The remote tags seperated by spaces
    []const u8,
};
pub const remote_local: Remote = .{ "local", "127.0.0.1:9338", "local" };
```

Each entry in `remotes` is a 3-tuple `.{ "<name>", "<address>", "<tags>" }` representing a host running the Weft daemon:

- The first element is the remote name referenced in CLI targets and `.on` constraints. A `"local"` remote (`127.0.0.1:9338`, tag `"local"`) is always implicitly present unless overridden.
- The second element is the remote address (`Weft.RemoteAddress`), which supports two forms:
  - A network address `{domain|ip}[:port]` (defaulting to port `9338`), connected over TCP.
  - A command transport `!<script> [args...]` (such as `"!remote colab"`), which resolves `weft/<script>` or `weft/<script>.sh` in the project directory, spawns it as a child process, and runs the encrypted wire protocol over the child's `stdin` and `stdout` pipes.
- The third element is a space-separated string of group tags that pipelines can target in `.on`.

---

### `.environments`

```zig
pub const Env = struct {
    name: []const u8,
    uses: []const []const u8 = &.{},
    vars: []const struct { []const u8, ?[]const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
};
```

Defines reusable named sets of Nix packages (`pkgs`), environment variables (`vars`), and parent environment references (`uses`) that can be shared across pipelines via `pipeline.env.uses`.

---

### `.sources`

```zig
sources: ?[]const struct { []const u8, []const u8 } = null,
```

Maps source names to relative directories in the project root as `.{ "<name>", "<path>" }`, referenced in pipeline `.in` lists as `"-<name>"`. When `.sources` is `null`, a single root source `.{ "", "." }` is implicitly defined and referenced as `"-"`.

---

### `.workspace`, `.modes`, `.retention`

```zig
workspace: []const u8,
modes: []const []const u8 = &.{"default"},
retention: Retention = .{},

pub const Retention = struct {
    artifacts: u32 = 2,
    archive: u32 = 10,
};
```

- `workspace` is the required project identifier used by remote daemons to namespace all state belonging to this project on disk.
- `modes` lists the valid execution modes (defaulting to `&.{ "default" }`) accepted in `<mode>:<remote>.<pipeline>` target specifiers and `<mode>:<artifact>` conditional inputs/outputs.
- `retention` configures how many recent deployments keep their built output directories (`artifacts`, default `2`) and task log/status records (`archive`, default `10`) before older deployments are garbage-collected.

---

## 3. The Weft Daemon

### Daemon Configuration and Templates (`/etc/weft/weft.zon`)

When `weft daemon install [isolate[-scale]]` runs, it generates `/etc/weft/weft.zon`, serialized from `DaemonInstall.Config` (`src/daemon/DaemonInstall.zig`):

```zig
pub const Config = struct {
    port: u16 = 9338,
    isolate: Isolate = .default,
    scale: Scale = .default,
};

pub const Isolate = packed struct(u8) {
    cgroups: bool,
    mount: bool,
    pid: bool,
    net: bool,
    _pad: u4 = 0,
};

pub const Scale = struct {
    max_workers: u32,
    compress: bool,
    decompress: bool,
};
```

#### Isolation Profiles (`Isolate`)

The `isolate` struct controls which Linux kernel isolation mechanisms the supervisor uses when spawning tasks, allowing the daemon to run on kernels where certain namespaces or cgroup controllers are restricted:

- `kvm` (`cgroups = true, mount = true, pid = true, net = true`, default) enables full isolation for standard Linux VMs and bare-metal servers, running tasks in dedicated mount, UTS, IPC, PID, cgroup, and (when requested) network namespaces with a `pivot_root` rootfs and cgroups v2 resource limits.
- `lxc` (`cgroups = false, mount = true, pid = true, net = true`) targets LXC containers where unsharing mount, PID, and network namespaces is permitted, but creating or delegating child cgroup v2 hierarchies is restricted by the host container manager.
- `vz` (`cgroups = false, mount = false, pid = false, net = false`) targets restricted OpenVZ or Virtuozzo containers where namespace `unshare` and `mount` syscalls are blocked by the kernel.
- `colab` (`cgroups = false, mount = false, pid = false, net = false`) uses the same unprivileged execution mode as `vz` for cloud notebook and restricted container environments.

#### Scale Profiles (`Scale`)

The `scale` struct tunes daemon concurrency and wire transfer CPU/memory usage for the host's hardware capacity:

- `tiny` (`max_workers = 1, compress = false, decompress = false`) serializes worker execution to a single thread and disables on-the-fly archive compression and decompression to minimize RAM and CPU spikes on micro-instances.
- `small` (`max_workers = 4, compress = false, decompress = true`, default) runs up to 4 concurrent worker tasks and decompresses incoming transfers while skipping outbound compression.
- `large` (`max_workers = 16, compress = true, decompress = true`) runs up to 16 concurrent worker tasks with bidirectional stream compression enabled.

---

### Daemon Filesystem Layout

The daemon organizes its configuration, package store, workspace state, and runtime sandboxes across `/etc/weft`, `/var/lib/weft`, and `/run/weft` (`src/domain/paths.zig`):

- `/etc/weft/weft.zon` stores the serialized `DaemonInstall.Config`, and `/etc/weft/keys` stores the newline-separated hex Ed25519 public keys of authorized clients.
- `/var/lib/weft/bin/` contains symlinks to a curated set of host coreutils (`sh`, `bash`, `cp`, `mv`, `rm`, `tar`, `gzip`, `zstd`, `grep`, `sed`, `awk`, `find`, `weft`, etc.) exposed as `/bin` inside mount-isolated sandboxes so tasks do not inherit arbitrary host binaries from `/usr/bin`.
- `/var/lib/weft/nix/store/` holds unpacked Nix store packages shared across all workspaces, guarded by `/var/lib/weft/nix/store/.lock`, with cached NAR metadata in `/var/lib/weft/nix/narinfo/`.
- `/var/lib/weft/active/` holds symlinks named `<workspace>_<pipeline>_<deployment>` pointing to currently running tasks for fast sibling discovery and monitoring.
- `/var/lib/weft/workspace/<workspace>/` stores all persistent state for a given project workspace:
  - `uid` records the dedicated numeric Linux UID assigned to the workspace (allocated monotonically from `/var/lib/weft/workspace/uid`).
  - `home/` provides the persistent home directory for the workspace user (`weft-<workspace>`).
  - `keep/<cache>/` stores persistent workspace cache directories across deployments.
  - `artifact/<artifact>/<deployment>/` stores immutable harvested artifacts and uploaded sources.
  - `task/<pipeline>/<deployment>/` stores the persistent task record (`spec`, combined stdout/stderr `log`, and `status`).
  - `scratch/<pipeline>/<deployment>/` holds the temporary execution working directory (`cwd/`) and staged output directories (`out/<output>/`) while a task is running.
- `/run/weft/` holds ephemeral runtime state including the daemon `pid` file, the `weft.pipe` IPC socket, and per-task runtime directories `/run/weft/<workspace>/<pipeline>/<deployment>/` containing the supervisor `pid`, the `in` stdin FIFO, and the `root/` mount point for the task's sandbox rootfs.

---

### Task Spawning and the Supervisor

When the daemon schedules a pipeline task, it spawns a detached `weft supervisor supervise` process for `<workspace>/<pipeline>/<deployment>` along with the daemon's `Isolate` bitmask (`src/supervisor/supervisor.zig`):

- The supervisor first resolves (or assigns) the workspace's dedicated UID, fetches and unpacks any missing Nix packages listed in `spec.pkgs` into `/var/lib/weft/nix/store/`, and creates and chowns the workspace `home/`, scratch `cwd/`, staged `out/<output>/`, and persistent `keep/<cache>/` directories to the workspace UID.
- Next, it inspects `/var/lib/weft/active/` for any running sibling of the same `<workspace>/<pipeline>`, waits up to `sibling.wait` seconds (polling every `sibling.poll` seconds), and applies `sibling.then` (`kill`, `fail`, `skip`, or `ignore`).
- For process and resource isolation:
  - When `isolate.pid` is enabled, the supervisor calls `unshare(CLONE_NEWPID)` before spawning the child `weft supervisor spawn` process so the spawner becomes PID 1 inside the new PID namespace. When `isolate.pid` is disabled, the spawner instead calls `setsid()` to run in a dedicated process group that is killed via `kill(-child_pid, SIGKILL)` on teardown.
  - When `isolate.cgroups` is enabled, the supervisor creates a cgroup v2 directory for the task, applies the pipeline's `tune.cpu`, `tune.mem`, `tune.io.io_weight`, and `tune.io.pids_max` settings, places the child spawner PID into `cgroup.procs`, and destroys and kills the cgroup when the task exits. When `isolate.cgroups` is disabled, cgroup creation and resource limits are skipped.
- Inside `weft supervisor spawn`, filesystem and network setup depend on `isolate.mount`:
  - When `isolate.mount` is `true` (`kvm`, `lxc`), the spawner unshares `CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC` (plus `CLONE_NEWCGROUP` if `isolate.cgroups` is set, and `CLONE_NEWNET` if `isolate.net` and `tune.net.private` are set). It mounts a `16m` `tmpfs` at `/run/weft/<workspace>/<pipeline>/<deployment>/root/`, generates minimal `/etc/passwd`, `/etc/group`, and `/etc/hosts` files, bind-mounts `/var/lib/weft/nix/store` to `/nix/store`, `/var/lib/weft/bin` to `/bin`, and host `/usr/lib`, `/lib`, and `/lib64` read-only, mounts `/proc`, `/tmp`, `/dev/shm`, and `/dev/{null,zero,full,random,urandom}`, and (unless `tune.net.private` is true) bind-mounts `/etc/resolv.conf` and host CA certificates read-only. It then bind-mounts each input artifact read-only at `/in/<artifact>`, each staged output directory read-write at `/out/<output>`, each `keep` cache at `/work/<path>`, and any custom `tune.io.mount` entries, locks the root mount read-only, calls `pivot_root` into the new rootfs, and changes directory to `/work`.
  - When `isolate.mount` is `false` (`vz`, `colab`), the spawner avoids `mount` and `pivot_root` syscalls altogether so tasks can run inside unprivileged containers. If `isolate.net` and `tune.net.private` are enabled, it unshares `CLONE_NEWNET`. It creates a host symlink from `/nix/store` to `/var/lib/weft/nix/store`, writes the entry script and creates `in/<artifact>` and `out/<output>` as symlinks inside `/run/weft/<workspace>/<pipeline>/<deployment>/root/`, creates symlinks for `keep` caches and `tune.io.mount` entries inside the task's scratch `cwd/` (emulating `.tmpfs` mounts with random directories under `/tmp/weft-tmp/`), and changes directory directly into the scratch `cwd/`.
- Before executing the script, the spawner clears supplementary groups (`setgroups`), drops real, effective, and saved UID/GID (`setresgid`, `setresuid`) to the unprivileged workspace UID, sets `PR_SET_NO_NEW_PRIVS`, constructs the clean environment (`PATH` with `/nix/store/<pkg>/bin` entries followed by `/bin`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `IN`, `OUT`, `WEFT_VERSION`, `WEFT_MODE`, `WEFT_WORKSPACE`, `WEFT_PIPELINE`, `WEFT_DEPLOYMENT`, and pipeline `vars`), and spawns the entry script while reaping child processes until the entry script exits.
- If the entry script exits with status `0`, the outer supervisor transitions the task status to `harvesting`, recursively strips write permissions and resets ownership to `root:root` (`freeze_dir`) on each staged output directory, and atomically renames each output into `/var/lib/weft/workspace/<workspace>/artifact/<output>/<deployment>/` before marking the task `done`.

---

## License

MIT — see [LICENSE](LICENSE).
