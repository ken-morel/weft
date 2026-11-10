# Weft

Weft is a deployment and task orchestration tool for Linux written in Zig. A single static binary with zero external dependencies serves as the CLI client, the remote daemon, and the native Linux task supervisor.

Weft is designed to target everything from bare-metal servers to severely resource-constrained environments—such as $0.30 TierHive instances, low-memory VPS hosts, unprivileged LXC/OpenVZ containers, or ephemeral environments like Google Colab—without sacrificing reproducible environments or task isolation.

Instead of relying on container runtimes like Docker or Podman, or requiring a full Nix daemon on the target machine, Weft operates directly on Linux kernel primitives and upstream binary caches:

- **Low-footprint daemon and adaptive isolation**: The remote daemon consumes minimal memory and adapts its sandboxing strategy (`kvm`, `lxc`, `vz`, `colab`) and worker concurrency (`tiny`, `small`, `large`) to the capabilities of the host kernel. When supported by the host, tasks run inside isolated Linux namespaces (`CLONE_NEWNS`, `NEWPID`, `NEWNET`, `NEWCGROUP`, `NEWUTS`, `NEWIPC`) with `pivot_root` and cgroups v2 resource controls.
- **Daemon-less Nix package provisioning**: Environments declare Nix store package identifiers directly in the project configuration. The target daemon downloads and extracts `.nar` archives from upstream binary caches into `/var/lib/weft/store/` using a built-in streaming unpacker, mounting them read-only into the task sandbox without requiring Nix or NixOS on the host.
- **Direct or stdio-tunneled transport**: Remotes can be reached over direct TCP sockets or piped through arbitrary local commands (such as SSH tunnels or custom proxy scripts) for hosts without public IP addresses.

## Authentication and Wire Protocol

Communication between the client and any remote daemon runs over a stateful, authenticated, and encrypted binary protocol:

1. **Identity and Key Registry**: On first use, the client generates an Ed25519 keypair stored in `$XDG_CONFIG_HOME/weft/key` (or `~/.config/weft/key`). Each remote daemon maintains a directory of authorized 32-byte client public keys.
2. **Client Hello**: Upon connecting (via TCP or child process stdio), the client sends a `ClientHello` packet containing the `weft` magic bytes, the 64-bit compile-time protocol hash (`proto.hash`), the client's Ed25519 public key, an ephemeral X25519 public key, and a 24-byte random outbound nonce.
3. **Server Challenge**: The daemon verifies that `proto_hash` matches its own build and checks the client's public key against its authorized key store. If accepted, the daemon replies with a `ServerChallenge` containing a status byte (`ok`, `unauthorized`, or `proto_mismatch`), a 32-byte random challenge, the daemon's ephemeral X25519 public key, and a 24-byte random inbound nonce.
4. **Signature Verification and Key Exchange**: The client signs the concatenation of the 32-byte server challenge and the 32-byte server ephemeral public key using its Ed25519 secret key, sending the 64-byte signature in a `ClientAuth` packet. Both sides compute a shared 32-byte secret via X25519 Diffie-Hellman (`scalarmult`) over their ephemeral keypairs.
5. **Encrypted Framing (`zoto`)**: All subsequent messages are serialized using `zoto` (Weft's binary encoding format), prefixed with a 16-bit little-endian payload length, and encrypted in-place using XChaCha20-Poly1305 AEAD with incrementing directional nonces and a 16-byte authentication tag per frame.

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
    version: nightly # or a specific release tag
```

#### Building from Source

Requires Zig `0.18.0` or newer:

```bash
zig build -Doptimize=ReleaseSafe
```

The resulting binary is placed at `zig-out/bin/weft`.

---

### CLI Commands

#### `weft remote`

Manage and monitor remote daemons.

- **`weft remote install {[user@]{ssh_alias|domain|ip}[:port]} [isolate[-scale]]`**  
  Copies the local `weft` binary to the target machine over `scp`, installs and starts the daemon service via `ssh`, and registers the local client's public key.
  - `ssh`: Accepts an SSH config alias, domain name, or IP address. If `user@` is omitted, it defaults to `root@`. If `:port` is omitted, SSH uses port 22 or the port configured for the alias in `~/.ssh/config`.
  - `extra` (`[isolate[-scale]]`): Optional template passed to `weft daemon install` on the remote. Combining an isolation profile and a scale profile (for example `kvm-small`, `lxc-large`, `vz-tiny`, or `colab`) configures the remote daemon for the target environment's kernel and memory constraints.

- **`weft remote register {[user@]{ssh_alias|domain|ip}[:port]} [pubkey]`**  
  Registers a client Ed25519 public key on a remote daemon over SSH by invoking `/usr/local/bin/weft daemon register <pubkey>` on the target.
  - `ssh`: Target SSH destination (`[user@]{ssh_alias|domain|ip}[:port]`).
  - `pubkey`: Optional 64-character hex public key. If omitted, registers the local client's public key.

- **`weft remote monitor [{remote_name|domain:port|ip:port|local}]`**  
  Connects to a daemon and opens the live terminal UI displaying host CPU usage, RAM, swap, disk usage, disk I/O rates, network RX/TX rates, and active tasks.
  - `remote`: Can be a remote name defined in `weft/weft.zon`, an explicit `host:port` socket address (usable outside of a project directory), or `local` (the default).

#### `weft daemon`

Manage the daemon on the local machine (Linux only).

- **`weft daemon install [isolate[-scale]]`**  
  Installs the currently executing binary to `/usr/local/bin/weft`, writes `/etc/weft/weft.zon`, populates the sandbox utility links, and configures and starts the service under the detected init system (`systemd`, `openrc`, or `runit`). Requires root privileges.
  - `template` (`[isolate[-scale]]`): Dash-separated combination of an isolation template and/or a scale template (defaults to `kvm-small`):
    - **Isolation templates**:
      - `kvm` (default): Enables `cgroups`, `mount`, `pid`, and `net` namespaces.
      - `lxc`: Enables `mount`, `pid`, and `net` namespaces; disables `cgroups` management.
      - `vz`: Disables all namespace and cgroup operations for restricted OpenVZ/Virtuozzo containers.
      - `colab`: Disables all namespace and cgroup operations for unprivileged container environments.
    - **Scale templates**:
      - `tiny`: `max_workers = 1`, disables wire compression and decompression (suited for ultra-low-RAM instances).
      - `small` (default): `max_workers = 4`, disables compression, enables decompression.
      - `large`: `max_workers = 16`, enables both compression and decompression.

- **`weft daemon run`**  
  Runs the daemon process in the foreground using the configuration in `/etc/weft/weft.zon`. Managed automatically by the system's service manager after `weft daemon install`.

- **`weft daemon register <key>`**  
  Adds a 64-character hex-encoded Ed25519 public key to the local daemon's authorized keys directory and signals the running daemon via IPC to reload its key store without restarting.

#### `weft do`

- **`weft do {[mode:][remote.]pipeline ...}`**  
  Resolves the dependency graph for one or more target steps, packages required local sources, transfers missing artifacts between remotes, and executes the pipelines across the target remotes while rendering progress in the terminal UI.
  - Target syntax: `[<mode>:][<remote>.]<pipeline>`.
  - If `<remote>.` is omitted, the target defaults to `local.<pipeline>`.
  - If `<mode>:` is omitted on the first target, it defaults to `default`. When multiple targets are passed, an omitted `<mode>:` inherits the mode specified on the preceding target (for example, `weft do prod:ds.migrate ds.server` runs both targets under mode `prod`).

#### `weft resume`

- **`weft resume [deployment]`**  
  Resumes an interrupted or failed deployment from its recorded state in `.weft/`, skipping steps whose outputs are already satisfied and retrying unfinished steps.
  - `deployment`: Full deployment ID or a unique trailing suffix of the deployment ID. Defaults to the latest deployment in `.weft/`.

#### `weft task`

Inspect or control individual pipeline executions within a deployment.

- **`weft task spawn {[mode:][remote.]pipeline} [deployment]`**  
  Spawns a single pipeline step on the specified remote within an existing deployment without resolving or executing its upstream dependencies. Expects required input artifacts to already be registered in the deployment.
  - `step`: Target specifier (`<pipeline>`, `<remote>.<pipeline>`, or `<mode>:<remote>.<pipeline>`).
  - `deployment`: Deployment ID or unique suffix (defaults to latest).

- **`weft task kill {[mode:][remote.]pipeline} [deployment]`**  
  Sends a kill request to the remote daemon to terminate the running process group for the specified pipeline step.
  - `step`: Target specifier (`<pipeline>`, `<remote>.<pipeline>`, or `<mode>:<remote>.<pipeline>`).
  - `deployment`: Deployment ID or unique suffix (defaults to latest).

- **`weft task logs {[mode:][remote.]pipeline} [deployment]`**  
  Fetches and streams the stdout/stderr log output of a running or completed pipeline step from its remote.
  - `step`: Target specifier (`<pipeline>`, `<remote>.<pipeline>`, or `<mode>:<remote>.<pipeline>`).
  - `deployment`: Deployment ID or unique suffix (defaults to latest).

#### `weft artifact`

Transfer and inspect versioned deployment artifacts stored under `.weft/<deployment>/artifacts/`.

- **`weft artifact pull <name> [remote] [deployment]`**  
  Downloads artifact `<name>` from `<remote>` (defaults to `local`) for `<deployment>` (defaults to latest) into the local deployment directory and records `"local"` as a holder of the artifact.

- **`weft artifact push <name> [remote] [deployment]`**  
  Uploads artifact (or source) `<name>` from the local deployment directory to `<remote>` (defaults to `local`) for `<deployment>` (defaults to latest) and records `<remote>` as a holder in the deployment metadata.

- **`weft artifact register <name> [remote] [deployment]`**  
  Registers `<remote>` (defaults to `local`) as holding artifact `<name>` in `<deployment>` (defaults to latest) without transferring files over the network, and prints the local expected path for that artifact to stdout. Useful when external scripts populate the artifact directory directly.

- **`weft artifact path <name> [deployment]`**  
  Prints the local filesystem path where artifact `<name>` is (or would be) located for `<deployment>` (defaults to latest) without modifying deployment metadata.

#### `weft cache`

Synchronize persistent workspace caches (`keep` directories) between local disk (`.weft/caches/<remote>/<cache>`) and remote daemons. `pull` transfers strictly from remote to local; `push` transfers strictly from local to a remote and errors immediately if the source cache does not exist locally.

- **`weft cache pull {remote[.cache]}`**  
  Pulls workspace cache(s) from `<remote>` into `.weft/caches/<remote>/<cache>`.
  - `remote.cache`: Pulls the single named cache `<cache>` from `<remote>`.
  - `remote`: Pulls all caches declared in `keep` across all pipelines in `weft/weft.zon` from `<remote>`.

- **`weft cache push {src_remote[.src_cache]} [dst_remote[.dst_cache]]`**  
  Pushes local cache(s) from `.weft/caches/<src_remote>/` to a destination remote. Verifies that the local cache directory exists on disk before opening any network connection, returning `error.CacheNotFound` if missing. Supported forms:
  - `weft cache push a.foo`: Pushes local `.weft/caches/a/foo` to remote `a` under cache name `foo`.
  - `weft cache push a`: Pushes all caches currently present in `.weft/caches/a/` to remote `a`.
  - `weft cache push a.foo b.foo` or `weft cache push a.foo b`: Pushes local `.weft/caches/a/foo` to remote `b` under cache name `foo`.
  - `weft cache push a.foo b.bar`: Pushes local `.weft/caches/a/foo` to remote `b` under cache name `bar`.
  - `weft cache push a b`: Pushes all caches currently present in `.weft/caches/a/` to remote `b` under their respective names.

- **`weft cache path {remote[.cache]}`**  
  Prints the local filesystem path `.weft/caches/<remote>[/<cache>]` without creating directories on disk.

#### `weft nix`

Search and inspect Nix packages via the Devbox package index for use in `.pkgs` lists.

- **`weft nix search <query>`**  
  Queries the package index for `<query>` and prints matching package names and summaries.

- **`weft nix query <name>`**  
  Fetches release metadata for package `<name>`, listing available versions, update dates, target platforms (highlighting the current host architecture), and the exact output store paths (`<hash>-<name>-<version>`) to place in `weft/weft.zon`.

#### `weft check`, `weft key`, `weft decode`, `weft version`

- **`weft check`**  
  Parses and validates `weft/weft.zon`. Verifies identifier syntax, checks that all referenced environments and sources exist, detects dependency cycles across pipelines, validates inline script shebangs and referenced script files in `weft/`, and checks task resolution across remotes.

- **`weft key`**  
  Prints the local client's 64-character uppercase hex Ed25519 public key to stdout.

- **`weft decode [file]`**  
  Reads a `zoto`-encoded binary payload from `<file>` (or `stdin` when omitted or `-`) and pretty-prints its structure as syntax-highlighted Zig struct literals. Used to inspect `.weft/<deployment>/status` files, task specs, or raw wire packets.

- **`weft version`**  
  Prints the Weft version, protocol hash, and build optimization mode (`Weft v<version>#<proto_hash>.<mode>`).

---

## 2. Project Configuration (`weft/weft.zon`)

A Weft project is configured by a `weft/weft.zon` file inside the project root, alongside any pipeline or transport scripts in the `weft/` directory. `weft/weft.zon` is parsed directly into the root `Weft` Zig struct (`src/domain/Weft.zig`):

```zig
modes: []const []const u8 = &.{"default"},
environments: []const Env = &.{},
workspace: []const u8,
sources: ?[]const struct { []const u8, []const u8 } = null,

pipelines: []const Pipeline = &.{},
remotes: []const Remote = &.{},

retention: Retention = .{},
```

Below is a reference of every top-level configuration option and its inner structures.

---

### `.pipelines`

`pipelines` defines the build steps, tasks, migrations, and long-running services of the project. Each entry is a `Pipeline` struct:

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

The unique identifier of the pipeline (`[]const u8`). Must begin with an ASCII letter and contain only ASCII alphanumeric characters, `-`, or `_`.

#### `.in` and `.out` (Inputs, Outputs, and Dependency Resolution)

Pipelines depend on one another through named **artifacts**:

- **Sources as inputs**: An input string starting with `-` (such as `"-backend"`) refers to a local source directory named `"backend"` in the top-level `.sources` list (or `"-"` for the root source `"."` when `.sources` is `null`). Before the pipeline runs, Weft packages that source directory and transfers it to the target remote. Inside the task's working directory, the source contents are unpacked directly into `.` (or linked under `<name>`).
- **Pipeline artifacts as inputs**: Any input string not starting with `-` refers to an output artifact produced by another pipeline. When `weft do` targets a pipeline, it walks `.in` recursively to find the producer pipeline for each required artifact, schedules upstream pipelines first, and transfers resulting artifacts to the consumer's remote if they were produced on a different machine. Inside the sandbox, each input artifact `<artifact>` is exposed at `/in/<artifact>` (or linked into the working directory).
- **Outputs (`.out`)**: Declares the artifacts produced by this pipeline.
  - When `.out` is `null` (the default), the pipeline implicitly produces a single artifact named after `.name`, and files written to `/out/<name>` (or the output directory) are harvested when the script exits with code `0`.
  - When `.out` is an explicit slice (e.g. `.{ "bin", "assets" }`), the supervisor mounts output directories for each declared name and harvests each of them upon completion.
  - When `.out = &.{}`, the pipeline produces no artifacts.
- **Mode-conditional inputs/outputs**: Any entry in `.in` or `.out` may be prefixed with `<mode>:` (for example `"prod:migrations"`). That dependency or output is included only when the deployment is invoked under `<mode>` and ignored under other modes.

#### `.run` (`Pipeline.Run`)

Specifies what the pipeline executes:

```zig
pub const Run = union(enum) {
    script: []const u8,
    file: []const u8,
    nothing,
};
```

- **`.{ .script = "..." }`**: An inline script string. Must be non-empty and start with a `#!` shebang line (e.g. `#!/usr/bin/env bash`).
- **`.{ .file = "name" }`**: Executes a script file from the project's `weft/` directory, resolving `weft/<name>` or `weft/<name>.sh`.
- **`null` (omitted)**: Defaults to `.{ .file = pipeline.name }`, looking up `weft/<pipeline.name>` or `weft/<pipeline.name>.sh`.
- **`.nothing`**: Marks the pipeline as a virtual target that runs no remote process. Used to group several pipelines under a single target name (for example, a `build` pipeline with `.in = .{ "backend-build", "frontend-build" }` and `.run = .nothing`).

#### `.on` (Remote Placement Constraints)

An optional list of remote names or remote group tags (`?[]const []const u8`).

- When `.on` is `null`, the pipeline can execute on any remote.
- When `.on` is specified (for example `.on = .{ "local", "builders" }`), the pipeline may only run on a remote whose name or space-separated tag list matches an entry in `.on`. If a downstream pipeline on a restricted production VPS (e.g. `prod`) depends on a heavy build pipeline restricted to `.on = .{"local"}`, running `weft do prod.app` automatically executes the build on `local` and pushes only the compiled artifact to `prod`.

#### `.keep` (Persistent Workspace Caches)

```zig
pub const Keep = struct {
    []const u8,
    []const u8,
};
```

Each entry is a 2-tuple `.{ "<cache_name>", "<relative_workdir_path>" }`.

While artifacts are immutable snapshots scoped to a single deployment ID, `keep` directories persist across deployments on a given remote at `/var/lib/weft/workspaces/<workspace>/caches/<cache_name>`. When the pipeline runs, the supervisor links or mounts that persistent directory into the task's working directory at `<relative_workdir_path>`. This is used both for build caches (such as `.{ "cargo-target", "target/" }` or `.{ "web-modules", "node_modules/" }`) and for stateful service storage (such as `.{ "pg-data", "pg-data" }`). These caches can be pulled from and pushed to remotes using `weft cache`.

#### `.sibling` (`Pipeline.HandleSibling`)

Controls how the supervisor handles an already-running instance of the same pipeline in the same workspace on the remote:

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

When a task is spawned on a remote, the supervisor checks whether another process for `<workspace>/<pipeline>` is currently active:
1. If `wait > 0`, the supervisor polls every `poll` seconds for up to `wait` seconds waiting for the existing sibling to terminate.
2. If the sibling is still running after `wait` seconds (or immediately when `wait == 0`), the supervisor applies `then`:
   - **`.kill`**: Sends `SIGTERM`/`SIGKILL` to the existing sibling's process group and waits for it to exit before starting the new task. Standard for long-running services (`backend-run`, `pg_cluster`) so redeployments cleanly replace the old process.
   - **`.ignore`**: Leaves the existing sibling running and starts the new task concurrently.
   - **`.fail`**: Aborts the new task with an error if the sibling is still running. Useful paired with `wait` (e.g. `.{ .wait = 180, .then = .fail }`) to serialize migrations and fail if a prior migration is stuck.
   - **`.skip`**: Exits the new task immediately without error, leaving the existing sibling untouched.

#### `.env` (Packages, Variables, and Environment Inheritance)

```zig
env: struct {
    uses: []const []const u8 = &.{},
    vars: []const struct { []const u8, ?[]const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
} = .{},
```

- **`uses`**: List of environment names from the top-level `.environments` slice. The pipeline inherits all `pkgs` and `vars` from those environments (expanding transitive `uses` in order).
- **`pkgs`**: List of Nix store package basenames (`"<32-char-hash>-<name>-<version>"`). Before starting the task, the daemon ensures each package is unpacked in `/var/lib/weft/store/<pkg>`, bind-mounts it read-only at `/nix/store/<pkg>` inside the sandbox, and adds `/nix/store/<pkg>/bin` to the task's `PATH`.
- **`vars`**: List of `.{ "<KEY>", <VALUE_OR_NULL> }` pairs:
  - `.{ "PORT", "6210" }`: Sets `PORT=6210` in the task environment.
  - `.{ "DATABASE_URL", null }`: When the value is `null`, the value is resolved from the **client's local environment variables** when the deployment is started (or falls back to a value defined in an inherited `.environments` entry if present). This allows passing secrets from a local `.env` or CI secret store without committing sensitive values to `weft.zon`.

#### `.tune` (`Pipeline.Tune`)

Configures kernel-level resource limits and namespace isolation for the pipeline:

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

- **`cpu`**: Writes to the task's cgroup v2 `cpu.max` controller (`quota` and period `max` in microseconds).
- **`mem`**:
  - `max`: Hard memory limit in bytes (`memory.max`).
  - `high`: Throttle threshold in bytes (`memory.high`).
  - `swap.max`: Swap usage limit in bytes (`memory.swap.max`).
  - `oom_score_adjust`: Adjusts the Linux OOM killer score (`/proc/self/oom_score_adj`, from `-1000` to `1000`).
- **`net`**:
  - `private`: When `true` (and the daemon's isolation template includes `net`), unshares `CLONE_NEWNET` so the task runs in an isolated network namespace with no external network access (useful for enforcing hermetic offline builds after dependencies are fetched).
  - `hosts`: Content written to `/etc/hosts` inside the task sandbox.
- **`io`**:
  - `io_weight`: Block I/O weight in cgroup v2 (`io.weight`, `1`–`10000`).
  - `pids_max`: Maximum number of processes/threads allowed in the task's cgroup (`pids.max`).
  - `mount`: Additional filesystem mounts inside the sandbox, specified as `.{ "<source>", .<mode>, "<target_path>" }`, where mode is `.tmpfs`, `.read` (read-only bind mount), or `.read_write` (read-write bind mount).

#### `.timeout`, `.max_retries`, `.retention`

- **`timeout`**: Optional maximum execution time in seconds (`?u32`).
- **`max_retries`**: Maximum retry count on transient failure (`u16`, defaults to `10`).
- **`retention`**: Optional per-pipeline `Retention` policy overriding the workspace-level `.retention` setting.

---

### `.remotes`

`remotes` defines the machines available to execute pipelines and store caches or artifacts:

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

Each remote is a 3-element tuple `.{ "<name>", "<address>", "<tags>" }`:

1. **Name (`remote.@"0"`)**: Identifier used in CLI targets (e.g. `weft do ds.backend-run`) and `.on` lists. A remote named `"local"` pointing to `127.0.0.1:9338` with tag `"local"` is always implicitly registered unless explicitly overridden in `.remotes`.
2. **Address (`remote.@"1"`, parsed as `Weft.RemoteAddress`)**: Supports two transport mechanisms:
   - **Network address (`{domain|ip}[:port]`)**: Connects over TCP to the specified hostname or IP address. If `:port` is omitted, defaults to `9338`.
   - **Command transport (`!<script> [args...]`)**: When the address string begins with `!` (for example, `.{ "colab", "!remote colab", "colab" }`), Weft locates `<script>` inside the project's `weft/` directory (`weft/remote` or `weft/remote.sh`), spawns it with `[args...]` as a child process, and speaks the encrypted Weft wire protocol over the child process's `stdin` and `stdout`. This allows reaching remotes behind NAT, custom SSH ProxyJump chains, or cloud notebooks without exposing a public TCP port.
3. **Tags (`remote.@"2"`)**: Space-separated group names (e.g. `"prod eu"`). Pipelines can reference any tag in their `.on` field to target a class of remotes rather than a single hardcoded host.

---

### `.environments`

`environments` declares reusable named sets of Nix packages and environment variables that pipelines (or other environments) can inherit via `uses`:

```zig
pub const Env = struct {
    name: []const u8,
    uses: []const []const u8 = &.{},
    vars: []const struct { []const u8, ?[]const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
};
```

- **`name`**: Name of the environment, referenced in `pipeline.env.uses` or another environment's `uses`.
- **`uses`**: Other environment names to inherit from before applying this environment's `pkgs` and `vars`.
- **`pkgs`**: Nix store package basenames (`"<hash>-<name>-<version>"`).
- **`vars`**: Key-value pairs `.{ "<KEY>", "<VALUE>" }` or `.{ "<KEY>", null }`. A `null` value in a shared environment acts as a declaration that the variable must be supplied either by a child environment/pipeline or from the client's host environment at runtime.

---

### `.sources`

```zig
sources: ?[]const struct { []const u8, []const u8 } = null,
```

Maps logical source names to relative directory paths inside the project:

- Each entry is `.{ "<source_name>", "<relative_path>" }` (for example, `.{ "backend", "backend/" }`).
- Pipelines depend on a source by prefixing its name with `-` in `.in` (for example, `.in = .{"-backend"}`).
- When `.sources` is `null`, Weft provides a single default root source `.{ "", "." }`, which pipelines can reference as `"-"`.

---

### `.workspace`

```zig
workspace: []const u8,
```

Required string naming the project workspace. Remote daemons use `workspace` to isolate deployments, logs, artifacts, and persistent `keep` caches on disk under `/var/lib/weft/workspaces/<workspace>/`.

---

### `.modes`

```zig
modes: []const []const u8 = &.{"default"},
```

List of valid deployment mode names for the project (defaults to `&.{ "default" }`). Modes allow a single `weft/weft.zon` to parameterize pipeline dependency graphs via `<mode>:<artifact>` entries in `.in` and `.out` when invoked as `weft do <mode>:<remote>.<pipeline>`.

---

### `.retention`

```zig
pub const Retention = struct {
    artifacts: u32 = 2,
    archive: u32 = 10,
};
```

Configures how many historical deployments the daemon retains on disk before garbage-collecting older entries (can be overridden per pipeline via `pipeline.retention`):

- **`artifacts`**: Number of most recent deployments whose built output artifacts are kept on disk (defaults to `2`).
- **`archive`**: Number of most recent deployments whose task logs and status metadata are kept in the archive (defaults to `10`).

---

## License

MIT — see [LICENSE](LICENSE).
