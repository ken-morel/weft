# weft

`weft` is an experimental, ultra-lightweight deployment orchestrator written in Zig (targeting 0.16). It is built specifically for resource-constrained Linux VPS nodes (128MB–1GB RAM) where standard container runtimes (Docker, containerd, k3s, Nomad) consume unacceptable amounts of idle CPU, memory, and disk I/O.

Instead of running heavy container virtualization daemons, `weft` uses a lean native daemon, an AEAD-encrypted streaming wire protocol, atomic `.zon` state files, and native Linux process execution (`systemd-run` / cgroups).

---

## 🎯 Project Goals & Design Philosophy

`weft` is designed around a strict set of architectural principles tailored for ultra-cheap, resource-constrained infrastructure:

### 1. Sub-10MB Idle & Operational Memory Footprint
Traditional container engines and orchestrators idle at 100MB–300MB+ of RSS, consuming most of a 128MB–512MB VPS before user applications even boot. `weft` is implemented entirely in native Zig using static buffer limits, arena allocators, and zero runtime VMs, maintaining a `<10MB` baseline footprint so your applications get virtually all of the host's memory.

### 2. Zero External Runtime Dependencies
`weft` compiles down to a single standalone static binary with zero external package or library dependencies:
* **Built-in Cryptography:** Native `XChaCha20-Poly1305` AEAD encryption (no OpenSSL/TLS runtime bloat).
* **Built-in Compression:** Streaming chunked `zlib` compression via `std.compress.flate`.
* **Built-in Serialization:** Compile-time type-hashed binary framing (`zoto`) without reflection engines.
* The only host requirement on the target node is a standard Linux kernel with `systemd` / cgroups.

### 3. Zero Remote Configuration ("Self-Provisioning" Deployments)
Host administration is eliminated on target servers:
* **Dumb Remotes, Smart Services:** The remote VPS only needs `weftd` installed once with its generated shared secret token.
* **Declarative Service Bundles:** All environment variables, pipeline steps, script runtimes, cgroup resource limits, ports, volumes, and databases are declared inside the service repository (`weft.zon` and `weft/bin/`).
* Pointing a deployment pipeline to any bare remote node automatically stages artifacts and provisions execution environments without manual SSH setup, custom Ansible playbooks, or host pollution.

### 4. Aggressive Resource Preservation & Caching
Low-end VPSs suffer from slow CPU cores and minimal RAM that choke on heavy compilation steps:
* **Build Offloading:** Compute-intensive build steps (e.g. compiling native binaries, building frontend assets) are resolved locally or on dedicated build runners; the remote server only receives the minimal stripped runtime artifact.
* **Incremental Artifact Deduplication:** The client verifies remote presence (`has_artifact`) before transmission. If an artifact already exists for the deployment DAG, network transfer is skipped entirely.
* **Clean State Separation:** Staging occurs in `/var/lib/weft/tmp/<uuid>`, promoting atomically to `/var/lib/weft/artifacts/...` with read-only inputs (`$IN`) and clean output directories (`$OUT`) to eliminate filesystem debris.
* **Path Preservation (`keep`):** Specific stateful directories are preserved across revisions without requiring heavyweight persistent volume plugins.

### 5. Outbound Traffic & Resource Guardrails
* **Network Gating:** Pipelines support disabling outbound network access (`disable_network = true` by default) to restrict unexpected egress traffic, conserve VPS bandwidth quotas, and mitigate supply-chain network leaks.
* **Cgroup Resource Ceilings:** Fine-grained enforcement of hard memory limits (`max_ram`), memory locking (`mem_lock`), CPU quotas (`cpu_quota`), CPU weights (`cpu_weight`), timeouts (`timeout`), and OOM prioritization (`oom_score_adjust`).
* **Concurrency Strategies:** Automatic collision policies (`second_instance` modes: `wait`, `safe`, `kill`, `ignore`) prevent concurrent pipeline runs from crashing memory-starved machines.

---

## Technical Architecture

```
[ Local Client ]
  │
  ├── 1. Read project definition (`weft.zon`)
  ├── 2. Resolve pipeline DAG (`src/Deployment.zig`)
  ├── 3. Snapshot source tree with `.gitignore` filtering (`src/Walker.zig`)
  ├── 4. Compress & stream chunks via zlib (`src/packer.zig`)
  │
  ▼  Encrypted Wire Protocol (TCP / Unix Socket)
     - Framing: 2-byte length + XChaCha20-Poly1305 ciphertext + 16-byte tag
     - Nonce: 192-bit rolling CSPRNG nonce (u128 base + u64 counter)
     - Serializer: Zoto binary protocol with compile-time type hashes
  │
[ Remote Daemon (`weftd`) ]
  │
  ├── 5. Receive chunks into staging (`/var/lib/weft/tmp/<uuid>/`)
  ├── 6. Atomically promote artifact (`/var/lib/weft/artifacts/...`)
  └── 7. Prepare task environment & execute (`systemd-run` / cgroup limits)
```

---

## Core Components in the Codebase

### 1. Encrypted Transport & Custom Serialization
* **`src/Connection.zig`**: Custom encrypted framing protocol. Packets are capped at 64KB (`u16`), encrypted using `std.crypto.aead.chacha_poly.XChaCha20Poly1305`, and authenticated with a 16-byte Poly1305 tag.
* **`src/Nonce.zig`**: 192-bit nonce (`u128 base` + `u64 counter`) initialized with CSPRNG entropy and incremented per frame to prevent replay attacks.
* **`src/zoto.zig`**: Custom zero-overhead binary serialization engine. Uses compile-time type introspection (`hashType(T)`) to embed 64-bit schema signatures in headers and validate struct/union layouts without runtime reflection.

### 2. File Streaming & Artifact Pipeline
* **`src/Walker.zig` & `src/Glob.zig`**: File walker supporting nested `.gitignore`, `.weftignore`, and `.ignore` files. Supports glob wildcards, directory-only matches, anchored paths, and `!` negations.
* **`src/packer.zig`**: Streaming compressor (`Packer`) and decompressor (`Unpacker`) using `std.compress.flate` (zlib level 5) to stream directories and files in bounded chunk sizes directly over the network.
* **`src/client/src.zig`**: Creates a reproducible local `src` artifact for the deployment deployment workspace.
* **`src/daemon/artifact_push.zig`**: Remote handler that verifies if an artifact already exists on the remote node (`has_artifact` check) to eliminate redundant transfers, unpacks into a temporary directory, and atomically moves it to `/var/lib/weft/artifacts/<workspace>/<service>/<env>/<deployment_id>/<pipeline>`.

### 3. Pipeline DAG & State Engine
* **`src/Deployment.zig`**: Resolves pipeline execution order by matching pipeline `inputs` to other pipelines' `outputs`. Identifies step readiness states (`runnable`, `waits`, `needs`, `running`, `done`).
* **`src/UUIDv7.zig`**: Custom time-ordered UUIDv7 generation for deployments and temporary staging areas.
* **`src/Project.zig`**: Manages project-level storage, loading `weft.zon`, and persisting deployment state into `.weft/<uuid>/<uuid>.zon`.
* **`src/script.zig`**: Automatic runtime resolution for pipeline scripts in `weft/bin/` supporting `.sh`, `.bash`, `.fish`, `.nu`, `.py`, `.zig`, and compiled binaries (`.bin`).
* **`src/version.zig` & `src/NumPattern.zig`**: Semver constraint resolver (`^`, `~`, `=`, `>`, `>=`, `<`, `<=`) and numeric pattern matcher (`>x`, `<x`, `=x`, `!x`, `start:step:stop`).

### 4. Daemon & Server
* **`src/Server.zig` & `src/daemon/Daemon.zig`**: Dual listener accepting connections concurrently over TCP (default port `9338`) and local Unix Domain Socket (`/run/weft/weft.sock`) governed by a semaphore permit pool.
* **`src/DaemonInstall.zig`**: Automated installation routine that copies the binary to `/usr/local/bin/weft`, generates a 32-byte secret key in `/etc/weft.zon` (mode `0600`), and writes + enables the `weftd.service` systemd unit.

---

## Configuration Specification (`weft.zon`)

A project is defined by a `weft.zon` file at the repository root using Zig Object Notation:

```zig
.{
    .name = "my-app",
    .workspace = "production",
    .pipelines = .{
        .{
            .name = "build",
            .inputs = .{
                .{ .name = "src" },
            },
            .outputs = .{
                .{ .name = "bin" },
            },
            .script = "build",
        },
        .{
            .name = "run",
            .inputs = .{
                .{ .name = "bin" },
            },
            .outputs = .{},
            .script = "start",
            // Cgroup resource allocations & guardrails
            .max_ram = 64 * 1024 * 1024, // 64 MB RAM limit
            .cpu_quota = 50,             // 50% CPU quota
            .oom_score_adjust = 500,     // OOM priority
            .disable_network = false,    // Enable outbound network if needed
            .second_instance = .kill,    // Terminate old instance on new deployment
        },
    },
}
```

Pipeline executable scripts are placed in `weft/bin/` (e.g., `weft/bin/build.sh`, `weft/bin/start.py`, `weft/bin/start.zig`).

---

## CLI Usage

### 1. Remote Daemon Setup (On the Target Server)

Install and start the daemon as a systemd service:
```bash
sudo weft daemon install
```
This generates a 32-byte shared token at `/etc/weft.zon` and starts the `weftd` service.

To run the daemon directly in the foreground for debugging:
```bash
weft daemon run
```

### 2. Client Setup (On Your Local Machine)

Register a remote target:
```bash
weft remote add prod
# Prompts for:
#   remote address: 198.51.100.10
#   remote port(9338): 9338
#   remote token: <64-character hex key output from daemon install>
```
Remote node configurations are saved in `$XDG_CONFIG_HOME/weft/remotes.zon` or `~/.config/weft/remotes.zon`.

### 3. Running Deployments

Trigger a deployment pipeline:
```bash
# Execute local steps and remote targets
weft do prod.build prod.run
```

---

## Current Implementation Status

| Feature Area | Component | Status | Notes |
| :--- | :--- | :--- | :--- |
| **Crypto Transport** | `Connection.zig`, `Nonce.zig` | **Complete** | XChaCha20-Poly1305 framing with rolling nonces operational. |
| **Serialization** | `zoto.zig` | **Complete** | Binary serialization with compile-time type hashing. |
| **Artifact Packaging** | `packer.zig`, `Walker.zig`, `Glob.zig` | **Complete** | Chunked streaming zlib compression with ignore-file filtering. |
| **Artifact Transfer** | `uploader.zig`, `artifact_push.zig` | **Complete** | Incremental push with remote cache check and atomic promotion. |
| **Remote Node Config** | `ClientInstall.zig`, `DaemonInstall.zig` | **Complete** | Remote management and systemd service generation. |
| **DAG Resolution** | `Deployment.zig` | **Complete** | Input/output dependency graph resolution and UUIDv7 state. |
| **Task Execution** | `daemon/task_spawn.zig` | **In Progress** | Wire request parsed; `systemd-run` process spawning being implemented. |
| **Task Supervision & Logs** | `Connection.zig` (`logs_stream`) | **Planned** | Protocol messages defined; live streaming stream loop pending. |

---

## Building from Source

### Requirements
* **Zig 0.16.0-dev** (matching current master / `std.Io` async API)
* Linux host (for systemd service unit execution)

### Build Command
```bash
zig build -Doptimize=ReleaseSafe
```
The compiled binary is placed at `./zig-out/bin/weft`.
