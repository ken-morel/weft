# Weft

Weft is a Linux deployment and task orchestration tool written in Zig. A single static binary implements the CLI client, the remote daemon, and the process supervisor.

## Architecture Overview

- **Direct Linux supervision**: Tasks run under a built-in supervisor rather than a container daemon (Docker, Podman). Isolation is configured per host (`kvm`, `lxc`, `vz`) using Linux namespaces (`mount`, `pid`, `net`, `uts`, `ipc`, `cgroup`), `pivot_root`, and cgroups v2, degrading gracefully on restricted kernels such as unprivileged LXC, OpenVZ, or Google Colab.
- **Daemonless Nix provisioning**: Pipeline and developer environments pull binary closures directly from `cache.nixos.org` into `/var/lib/weft/nix/store/` without requiring NixOS or a `nix-daemon` on the target host.
- **Pluggable transports**: Remotes communicate over direct TCP, local stdio proxy scripts (`!<script>`), or dynamic address-provider scripts (`~<script>`).
- **Authenticated wire protocol**: Client-to-daemon connections use an Ed25519 + X25519 handshake with per-request type-hash verification, encrypting all frames with XChaCha20-Poly1305 AEAD.

---

## 1. Installation and CLI Reference

Commands accept arguments positionally or as named flags (`-<field> <value>`), with `--` terminating flag parsing. Commands with terminal UIs automatically emit plain append-only logs when `stdout` is not a TTY.

### Installation

#### Prebuilt Binary

Prebuilt static binaries are published for Linux `x86_64` and `aarch64`:

```bash
curl -fsSL "https://github.com/ken-morel/weft/releases/download/nightly/weft-linux-$(uname -m).tar.gz" | sudo tar -xz -C /usr/local/bin
sudo chmod +x /usr/local/bin/weft
```

#### GitHub Actions

Supports Linux `x86_64` and `aarch64` runners (outputs: `arch`, `public-key`).

```yaml
- uses: ken-morel/weft@nightly
  with:
    version: nightly         # Release tag (default: nightly)
    daemon: kvm-small        # Optional: install & start local daemon (e.g. kvm, kvm-small, lxc, vz, default)
    client-key: ${{ secrets.WEFT_CLIENT_KEY }}     # Optional: 64-char hex or base64 of ~/.config/weft/key
    client-config: |         # Optional: ~/.config/weft/config.zon
      .{ .remotes = .{ .local = "127.0.0.1:9338", .prod = "195.201.10.42:9338" } }
    daemon-config: |         # Optional: /etc/weft/weft.zon
      .{ .port = 9338 }
    authorized-keys: |       # Optional: newline-separated 64-char hex Ed25519 public keys
      ...
    cache-nix: true          # Optional: cache /var/lib/weft/nix/store
    cache-keep: true         # Optional: 'true' (auto-detect from weft/weft.zon) or workspace name(s)
    cache-key-prefix: weft   # Optional: prefix for GitHub Actions cache keys
```

#### Building from Source

Requires Zig `0.18.0-dev` (master):

```bash
zig build -Doptimize=ReleaseSafe
```

The binary is output to `zig-out/bin/weft`.

---

### CLI Commands

#### `weft init` and `weft check`

- `weft init`  
  Initializes a workspace in the current directory by creating `weft/weft.zon`, `weft/.gitignore`, `weft/do/`, and `weft/cache/`.
- `weft check`  
  Validates `weft/weft.zon`: verifies workspace/pipeline/mode/environment identifiers, checks that all pipeline inputs and sources exist, detects dependency cycles and duplicate outputs, checks remote group constraints (`.on`), and ensures referenced script files and required environment variables resolve.

#### `weft do` and `weft resume`

- `weft do {[mode:][remote.]pipeline | - ...}`  
  Packages local sources, resolves the dependency graph for the specified targets, transfers required artifacts across remotes, and runs the tasks.
  - Omitting `<remote>.` defaults to `local`.
  - Omitting `<mode>:` on the first target defaults to `default`. Subsequent targets without an explicit `<mode>:` inherit the preceding target's mode (e.g. `weft do prod:db.migrate db.server` runs both in `prod` mode).
  - A standalone `-` token acts as an execution barrier: all targets before `-` must complete before any target after `-` is scheduled (e.g. `weft do site_fetch - site_build`). Targets within the same stage run concurrently.
  - Each deployment is assigned an 8-character lowercase Crockford Base32 ID (30-bit 250ms timestamp + 10-bit random salt) and recorded under `weft/do/<deployment>/deployment.zon`.
- `weft resume [deployment]`  
  Resumes an interrupted or failed deployment from `weft/do/`, skipping steps already marked done and retrying failed or pending steps.
  - `deployment` accepts a full 8-character ID or a unique suffix (minimum 2 characters), defaulting to the latest deployment.

#### `weft env`

- `weft env [mode:]name[,name...] [-- cmds...]`  
  Resolves Nix packages and environment variables for one or more comma-separated pipelines or environments (matching `pipelines` first, then `environments`), provisions any missing `/nix/store/` packages through the `local` daemon, and spawns `cmds` (or `$SHELL` if omitted) in the current working directory.
  - Multiple environments are merged left-to-right, deduplicating packages and allowing later variables to override earlier ones.
  - Prepends `/nix/store/<pkg>/bin` paths to `PATH` and exports `WEFT_ENV`, `WEFT_MODE`, `WEFT_WORKSPACE`, and `WEFT_VERSION`.

#### `weft task`

- `weft task spawn {[mode:][remote.]pipeline} [deployment]`  
  Executes a single pipeline step inside an existing deployment (defaulting to latest) without scheduling its upstream dependencies. All input artifacts required by the pipeline must already exist in that deployment.
- `weft task kill {[remote.]pipeline} [deployment]`  
  Sends a termination request to the supervisor for the specified task in `deployment` (defaulting to latest).
- `weft task logs {[remote.]pipeline} [deployment] [-from <offset>]`  
  Streams combined stdout/stderr for a running or completed task starting at byte `<offset>` (default `0`) until the task reaches a terminal state.

#### `weft artifact`

- `weft artifact pull <name> [remote] [deployment]`  
  Downloads artifact `<name>` from `<remote>` (default `local`) into `weft/do/<deployment>/<name>/`.
- `weft artifact push <name> [remote] [deployment]`  
  Uploads artifact or source `<name>` from `weft/do/<deployment>/<name>/` to `<remote>` (default `local`).
- `weft artifact register <name> [remote] [deployment]`  
  Records `<remote>` (default `local`) as holding `<name>` in `deployment.zon` without transferring files, and prints the local artifact directory path to `stdout`.
- `weft artifact path <name> [deployment]`  
  Prints the local filesystem path `weft/do/<deployment>/<name>` to `stdout`.

#### `weft cache`

`pull` transfers persistent workspace caches from a remote into `weft/cache/<remote>/<cache>/`. `push` transfers from `weft/cache/` to a remote.

- `weft cache pull {remote[.cache]}`  
  Pulls a specific cache (`remote.cache`), or all caches referenced in `keep` across `weft/weft.zon` (`remote`).
- `weft cache push {src_remote[.src_cache]} [dst_remote[.dst_cache]]`  
  Pushes one or more local caches to a remote:
  - `a.foo` — pushes `weft/cache/a/foo` to remote `a` as `foo`.
  - `a` — pushes all caches under `weft/cache/a/` to remote `a`.
  - `a.foo b` or `a.foo b.foo` — pushes `weft/cache/a/foo` to remote `b` as `foo`.
  - `a.foo b.bar` — pushes `weft/cache/a/foo` to remote `b` renamed as `bar`.
  - `a b` — pushes all caches under `weft/cache/a/` to remote `b`.
- `weft cache path {remote[.cache]}`  
  Prints `weft/cache/<remote>[/<cache>]`.

#### `weft remote` and `weft daemon`

- `weft remote install {[user@]{ssh_alias|domain|ip}[:port]} [template]`  
  Copies the local `weft` binary to `/usr/local/bin/weft` on the target host via `scp`/`ssh`, runs `weft daemon install [template]`, and registers the local client's public key. `user@` defaults to `root@`.
- `weft remote register {[user@]{ssh_alias|domain|ip}[:port]} [pubkey]`  
  Registers a 64-character hex Ed25519 public key (defaulting to the local client's key) on a remote daemon over SSH.
- `weft remote monitor [{remote_name|domain:port|ip:port|local}]`  
  Streams host CPU, memory, swap, disk usage, disk I/O, network throughput, and active task resource metrics from a daemon (default `local`).
- `weft daemon install [template]`  
  Installs the running binary to `/usr/local/bin/weft`, writes `/etc/weft/weft.zon`, hardlinks host utilities into `/var/lib/weft/bin/`, and configures and starts the service under `systemd`, `runit`, `openrc`, or a detached background process (`none`). Requires root.
  - `template` is a hyphen-separated combination of an isolation profile (`kvm`, `lxc`, `vz`), a scale profile (`atomic`, `tiny`, `small`, `large`), and/or a TCP port number (e.g. `kvm-small`, `lxc-large-9338`, `vz-tiny`).
- `weft daemon run`  
  Runs the daemon in the foreground.
- `weft daemon register <key>`  
  Appends a 64-character hex Ed25519 public key to `/etc/weft/keys` and signals the local daemon over `/run/weft/weft.pipe` to reload authorized keys.

#### `weft nix`, `weft zoto`, `weft key`, `weft version`

- `weft nix search <query>` — Searches the Devbox Nix package index.
- `weft nix query <name>` — Lists available versions, platforms, and store path identifiers (`<hash>-<name>-<version>`) for a package.
- `weft nix info <pkg>` — Fetches `.narinfo` metadata for `<pkg>` (full identifier or 32-character store hash) from `cache.nixos.org` and prints it as YAML.
- `weft zoto decode [file] [out]` — Decodes a `zoto` binary file (or `-` for `stdin`) into ZOTON text (written to `out` or `-` for `stdout`), with leading `// zoto:` and `// header:` metadata comments.
- `weft zoto encode [file] [out] [-type <name>] [-header <bool>]` — Encodes ZOTON text (from `file` or `-` for `stdin`) into a `zoto` binary file (or `-` for `stdout`).
- `weft zoto edit [file]` — Decodes a `zoto` binary file to a temporary `.zon` file, opens `$VISUAL`/`$EDITOR` (falling back to `vi`), and atomically re-encodes on exit. Passing `-` reads binary `zoto` from `stdin`, attaches the editor to `/dev/tty`, and writes the edited binary to `stdout`.
- `weft key` — Prints the local client's 64-character hex Ed25519 public key.
- `weft version` — Prints the build version and optimization mode.

---

## 2. Project Configuration (`weft/weft.zon`)

A project is defined by `weft/weft.zon`, pipeline scripts in `weft/`, and optional `.env` files in the project root.

### Project Directory Layout

```text
<project>/
├── .env                    # Default environment variables (optional)
├── .env.<name>             # Scoped variables for pipeline/environment <name> (optional)
└── weft/
    ├── weft.zon            # Project configuration
    ├── .gitignore          # Ignores do/ and cache/
    ├── <pipeline>[.*]      # Pipeline scripts (e.g. .sh, .js, .py)
    ├── do/
    │   └── <deployment>/
    │       ├── deployment.zon
    │       ├── -<source>/  # Packaged source snapshots
    │       └── <artifact>/ # Pulled target output artifacts
    └── cache/
        └── <remote>/
            └── <cache>/    # Pulled workspace caches
```

### Root Schema (`weft/weft.zon`)

Configuration files (`weft/weft.zon`, `client.zon`, `/etc/weft/weft.zon`, and `deployment.zon`) use **ZOTON** (valid ZON syntax parsed via `src/util/zoton.zig`, supporting keyed maps, closed error sets, and error unions). Keys containing special characters such as `:` (e.g. mode-prefixed `.vars` entries like `.@"prod:BASE_PATH"`) use standard ZON identifier quoting.

```zig
.{
    .workspace = "myapp",
    .modes = .{ "default", "prod" },
    .retention = .{ .archive = 10, .artifacts = 2 },
    .sources = .{
        .backend = "backend/",
        .web = "web/",
    },
    .environments = .{
        .bun = .{ .pkgs = .{"qkydg77xf2s395md9fq0a6djjpq7fzh4-bun-1.4.2"} },
    },
    .pipelines = .{
        .web_build = .{
            .on = .{"build"},
            .in = .{"-web"},
            .keep = .{ .web_modules = "node_modules/" },
            .env = .{ .uses = .{"bun"} },
        },
    },
    .remotes = .{
        .local = .{ .groups = "build run" },
        .prod = .{ .address = "195.201.10.42:9338", .groups = "run" },
    },
}
```

- `workspace` (`[]const u8`, required): Project identifier used by remote daemons to namespace state on disk. Must start with an ASCII letter and contain only ASCII alphanumeric characters or `_`.
- `modes` (`[]const []const u8`, default `.{"default"}`): Valid execution modes accepted in `<mode>:<remote>.<pipeline>` targets and `<mode>:<item>` conditional configuration entries.
- `sources` (optional map of `<name> = "<relative_dir>"`): When omitted or `null`, defaults to `.{ .src = "." }`.
- `environments` (map of `<name> = .{ ... }`, default `.{}`): Reusable package/variable bundles referenced from pipeline `.env.uses`.
- `pipelines` (map of `<name> = .{ ... }`, default `.{}`): Task definitions.
- `remotes` (map of `<name> = .{ ... }`, default `.{ .local = .{ .groups = "local" } }`): Target hosts.
- `retention` (default `.{ .archive = 10, .artifacts = 2 }`): Number of recent deployments for which a remote daemon retains harvested output directories (`artifacts`) and task status/log records (`archive`). Enforced automatically whenever a new task is spawned.

---

### `.pipelines`

Each entry under `.pipelines` is declared as `.<name> = .{ ... }`; the key is the pipeline's identifier (do not specify a `.name` field inside the entry). Pipeline names must start with an ASCII letter and contain only ASCII alphanumeric characters or `_`.

```zig
.{
    .in = .{},                            // []const []const u8
    .out = null,                          // ?[]const []const u8
    .run = null,                          // ?Run (.{ .script = ... }, .{ .file = ... }, .nothing)
    .tune = .{},                          // Tune
    .timeout = null,                      // ?u32 (seconds)
    .retries = 10,                        // u16
    .restart = false,                     // bool
    .retention = null,                    // ?Retention
    .sibling = .{ .then = .ignore },      // HandleSibling
    .keep = .{},                          // map of <cache_name> = "<relative_path>"
    .on = null,                           // ?[]const []const u8
    .env = .{
        .uses = .{},                      // []const []const u8
        .vars = .{},                      // map of <KEY> = "<value>" | null
        .pkgs = .{},                      // []const []const u8
    },
}
```

#### `.in` and `.out`

- **Source inputs (`-<source>`)**: An entry in `.in` starting with `-` (e.g. `"-backend"`, or `"-src"` for the default root source) references an entry in `.sources`. During `weft do`, the client snapshots the source directory (respecting `.gitignore`, `.weftignore`, and `.ignore`, and always excluding `.git`, `.jj`, `weft/do`, and `weft/cache`), uploads it to the target remote, and extracts it directly into the task's working directory.
- **Artifact inputs (`<artifact>`)**: An entry in `.in` without a leading `-` references an output produced by another pipeline. Upstream producer pipelines run on the same target remote as the consumer step; their harvested outputs are mounted read-only at `$IN/<artifact>`.
- **Outputs**: When `.out` is `null` (default), the pipeline implicitly declares a single output named `<pipeline.name>`. Providing `.out` overrides the output list (use `.out = &.{}` for tasks that produce no artifacts). Files written to `$OUT/<output>` during execution are harvested when the script exits with code `0`; outputs of top-level deployment targets are automatically pulled back to `weft/do/<deployment>/<output>/`.
- **Mode filtering**: Entries in `.in`, `.out`, `.keep`, `.env.uses`, `.env.pkgs`, and `.env.vars` keys may be prefixed with `<mode>:` (e.g. `"prod:migrate"`), activating that entry only when the step runs under `<mode>`.

#### `.run`

```zig
pub const Run = union(enum) {
    script: []const u8,
    file: []const u8,
    nothing,
};
```

- `.{ .script = "..." }`: Inline entry script (must start with a `#!` shebang; capped at 16 KiB).
- `.{ .file = "name" }`: Loads `weft/<name>` or `weft/<name>.*` (e.g. `.sh`, `.js`, `.py`).
- `null` (default): Resolves `weft/<pipeline.name>` or `weft/<pipeline.name>.*`.
- `.nothing`: Virtual target that spawns no remote process, used to group upstream dependencies in `.in`.

#### `.on`

Optional list of remote group tags (`?[]const []const u8`). When `null`, the pipeline may run on any remote. When set, the pipeline is restricted to remotes whose tag string contains at least one matching tag.

#### `.keep`

Map of `<cache_name>` to `<relative_workdir_path>` (`zoton.Map([]const u8)`):

```zig
.keep = .{
    .@"backend-target" = "target/",
    .node_modules = "node_modules/",
},
```

Each entry mounts (or symlinks under `isolate.mount = false`) a persistent workspace directory `/var/lib/weft/workspace/<workspace>/keep/<cache_name>/` into the task's working directory at `<relative_workdir_path>`. Keep names may be prefixed with `<mode>:`.

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

Determines how the supervisor handles existing active tasks for the same `<workspace>/<pipeline>` (discovered via `/var/lib/weft/active/`):

- If `wait > 0`, the supervisor polls every `poll` seconds for up to `wait` seconds for active siblings to exit.
- If siblings remain active after `wait` expires:
  - `.kill`: Sends `SIGTERM` to each sibling's supervisor and waits for termination before spawning.
  - `.ignore`: Runs concurrently alongside existing siblings.
  - `.fail`: Fails the new task immediately.
  - `.skip`: Marks the new task `.skipped` and exits without running the script.

#### `.env`, `.environments`, and `.env` Files

Top-level `.environments` entries are declared as `.<name> = .{ .uses = ..., .pkgs = ..., .vars = ... }` (without a `.name` field):

```zig
.environments = .{
    .db = .{
        .vars = .{
            .DATABASE_URL = "postgresql://postgres:@localhost:6100/myapp",
        },
    },
    .bun = .{
        .pkgs = .{"qkydg77xf2s395md9fq0a6djjpq7fzh4-bun-1.4.2"},
    },
},
```

Each pipeline's `.env` uses the same fields:

```zig
.env = .{
    .uses = .{ "db", "bun" },
    .pkgs = .{},
    .vars = .{
        .PORT = "8080",
        .DATABASE_URL = null,
    },
},
```

- `uses`: Names of top-level `.environments` entries to inherit (supports up to 100 levels of nesting and `<mode>:` prefixes).
- `pkgs`: Nix store package names (`"<hash>-<name>-<version>"`) to unpack and prepend to `PATH` (supports `<mode>:` prefixes).
- `vars`: Map of variable names to values or `null` (keys support `<mode>:` prefixes). When the value is `null`, Weft resolves `<KEY>` from project `.env` files in the following order:
  1. `.env.<pipeline_or_env_name>` in the project root
  2. `.env` in the project root
  3. Inherited parent environments listed in `uses`

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

- `cpu`: Configures cgroup v2 `cpu.max` (`max` quota and `quota` period in microseconds).
- `mem`: Configures cgroup v2 `memory.max`, `memory.high`, `memory.swap.max` (bytes), and `/proc/self/oom_score_adj`.
- `net`: `private = true` unshares `CLONE_NEWNET` and brings up `lo` (`127.0.0.1` / `::1`) with no external interfaces; `hosts` populates `/etc/hosts` when mount isolation is enabled.
- `io`: Configures cgroup v2 `io.weight`, `pids.max`, and custom mounts `.{ "<target_path>", .<mode>, "<source_path>" }` (`.tmpfs`, `.read`, or `.read_write`).

#### `.timeout`, `.retries`, `.restart`, `.retention`

- `timeout`: Maximum execution duration in seconds (`?u32`). On expiration, the supervisor terminates the task and marks it `.failed`.
- `retries`: Number of automatic retry attempts on failure during `weft do` / `weft resume` (`u16`, default `10`).
- `restart`: When `true`, the daemon automatically respawns the task on daemon startup if its symlink in `/var/lib/weft/active/` was present prior to a host reboot or daemon restart (`bool`, default `false`).
- `retention`: Optional per-pipeline override for the workspace `Retention` policy.

---

### `.remotes` and Client Configuration (`client.zon`)

In `weft/weft.zon`, `.remotes` is a `zoton.NamedMap(.name, Remote)` where each entry specifies `address` (`?[]const u8 = null`) and `groups` (`[]const u8 = ""`):

```zig
.remotes = .{
    .local = .{ .groups = "build run" },
    .prod = .{ .address = "195.201.10.42:9338", .groups = "run" },
},
```

- Key (`<name>`): Identifier used in CLI targets (`<remote>.<pipeline>`).
- `.address` (`?[]const u8`, default `null`):
  - `"{domain|ip}[:port]"` — direct TCP connection (defaults to port `9338`).
  - `"!<script> [args...]"` — spawns `<script>` and runs the encrypted wire protocol over its `stdin`/`stdout`.
  - `"~<script> [args...]"` — spawns `<script>`, reads a resolved address (`host:port` or `!<script>`) from the first line of its `stdout`, and keeps the provider process alive for the session.
  - `null` — looks up the remote's address in the local user's `~/.config/weft/client.zon`.
- `.groups` (`[]const u8`, default `""`): Space-separated group tags matched by pipeline `.on` constraints.

User-level configuration resides in `$XDG_CONFIG_HOME/weft/client.zon` (or `~/.config/weft/client.zon`, with fallback to `config.zon`):

```zig
.{
    .remotes = .{
        .hetzner = "195.201.10.42:9338",
        .colab = "!remote colab",
        .local = "127.0.0.1:9338",
    },
    .compress = true,
    .decompress = true,
}
```

- `compress` / `decompress`: Controls whether the client compresses outbound archive streams and requests compressed inbound streams (`zstd`).
- Connection scripts referenced by `!<script>` or `~<script>` are searched in `~/.config/weft/`, `weft/`, and the project root.

---

## 3. Daemon and Supervisor Internals

### Daemon Configuration (`/etc/weft/weft.zon`)

```zig
pub const Config = struct {
    port: u16 = 9338,
    isolate: Isolate = .default,
    scale: Scale = .default,
};
```

#### Isolation Profiles (`Isolate`)

| Profile | `cgroups` | `mount` | `pid` | `net` | Target Environment |
| :--- | :---: | :---: | :---: | :---: | :--- |
| `kvm` *(default)* | `true` | `true` | `true` | `true` | Bare-metal hosts and KVM/QEMU virtual machines |
| `lxc` | `false` | `true` | `true` | `true` | LXC containers without cgroup v2 delegation |
| `vz` | `false` | `false` | `false` | `false` | OpenVZ / Virtuozzo / Colab containers blocking `unshare` and `mount` |

#### Scale Profiles (`Scale`)

| Profile | `max_workers` | `compress` | `decompress` |
| :--- | :---: | :---: | :---: |
| `atomic` | `1` | `false` | `false` |
| `tiny` | `2` | `false` | `false` |
| `small` *(default)* | `8` | `false` | `true` |
| `large` | `32` | `true` | `true` |

---

### Daemon Filesystem Layout (`src/domain/paths.zig`)

- `/etc/weft/weft.zon` — Daemon configuration (`0600`).
- `/etc/weft/keys` — Newline-separated 64-character hex Ed25519 public keys of authorized clients (`0600`).
- `/var/lib/weft/bin/` — Hardlinks (with copy fallback) to host coreutils (`sh`, `bash`, `cp`, `mv`, `rm`, `tar`, `gzip`, `zstd`, `grep`, `sed`, `awk`, `find`, `weft`, etc.) bind-mounted as `/bin` inside mount-isolated sandboxes.
- `/var/lib/weft/nix/store/` — Shared unpacked Nix store closures guarded by `/var/lib/weft/nix/store/.lock`, with cached NAR info in `/var/lib/weft/nix/narinfo/`.
- `/var/lib/weft/active/` — Symlinks named `<workspace>_<pipeline>_<deployment>` pointing to `/var/lib/weft/workspace/<workspace>/task/<pipeline>/<deployment>/` for active tasks. On startup, the daemon scans this directory to prune stale links and respawn tasks configured with `restart = true`.
- `/var/lib/weft/workspace/<workspace>/`:
  - `uid` — Monotonically allocated unprivileged UID for the workspace user (`weft-<workspace>`).
  - `home/` — Persistent home directory for the workspace user.
  - `keep/<cache>/` — Persistent workspace caches.
  - `artifact/<artifact>/<deployment>/` — Immutable harvested output artifacts and uploaded sources.
  - `task/<pipeline>/<deployment>/` — Task `spec`, combined stdout/stderr `log`, and `status`.
  - `scratch/<pipeline>/<deployment>/` — Execution working directory (`cwd/`) and staged outputs (`out/<output>/`).
- `/run/weft/` — Daemon `pid`, `weft.pipe` UNIX socket, and per-task runtime directories `/run/weft/<workspace>/<pipeline>/<deployment>/` (`pid` of the supervisor, `in` stdin FIFO, and `root/` sandbox mount point).

---

### Supervisor Lifecycle (`src/supervisor/supervisor.zig`)

When a task is spawned, the daemon starts a detached `weft supervisor supervise` process:

1. **Preparation**: Allocates or reads the workspace UID, creates the `/var/lib/weft/active/` symlink, transitions status to `preparing`, downloads and unpacks any missing Nix packages from `cache.nixos.org`, and creates and `chown`s `home/`, `cwd/`, `out/<output>/`, and `keep/<cache>/`.
2. **Sibling resolution**: Scans `/var/lib/weft/active/` for other active tasks of the same `<workspace>/<pipeline>` (skipping itself) and enforces `sibling.wait` and `sibling.then`.
3. **Isolation and spawning**:
   - If `isolate.pid` is enabled, unshares `CLONE_NEWPID` so the child `weft supervisor spawn` process runs as PID 1 inside the namespace; otherwise the child calls `setsid()`.
   - If `isolate.cgroups` is enabled, creates `/sys/fs/cgroup/weft/<workspace>-<pipeline>-<deployment>`, applies `tune` limits, and moves the child into `cgroup.procs`.
   - The supervisor monitors the child via `pidfd_open` and handles `SIGTERM`, `SIGINT`, `SIGTSTP`, and `SIGCONT` via `signalfd` and `poll` (forwarding freeze/unfreeze and enforcing `spec.timeout`).
4. **Sandbox setup (`weft supervisor spawn`)**:
   - When `isolate.mount` is `true`, unshares `CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC` (plus `CLONE_NEWCGROUP` and `CLONE_NEWNET` when configured), mounts a `16m` `tmpfs` at `root/`, writes minimal `/etc/passwd`, `/etc/group`, and `/etc/hosts`, bind-mounts `/nix/store`, `/bin`, `/usr/lib`, `/lib`, `/lib64`, `/proc`, `/tmp`, `/dev/shm`, device nodes, DNS/CA certificates (unless `net.private`), `/in/<artifact>`, `/out/<output>`, and `/work/<keep>`, remounts `/` read-only, and calls `pivot_root`.
   - When `isolate.mount` is `false`, symlinks `/nix/store`, exposes inputs, outputs, and `keep` caches via symlinks inside `root/` and `cwd/`, and changes directory to `cwd/`.
   - Clears supplementary groups, drops UID/GID via `setresgid`/`setresuid` to the workspace UID, sets `PR_SET_NO_NEW_PRIVS`, populates the environment (`PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `IN`, `OUT`, `WEFT_VERSION`, `WEFT_MODE`, `WEFT_WORKSPACE`, `WEFT_PIPELINE`, `WEFT_DEPLOYMENT`, and resolved `vars`), executes the entry script, and reaps descendant processes until the entry script exits.
5. **Harvesting**: If the script exits with code `0`, the supervisor transitions status to `harvesting`, recursively strips write permissions and resets ownership to `root:root` on each staged output directory, atomically moves each output to `artifact/<output>/<deployment>/`, and marks the task `done`. Otherwise, it marks the task `failed` (or `killed`) and tears down the cgroup and runtime directory.

---

## License

MIT — see [LICENSE](LICENSE).
