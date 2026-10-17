# Weft

A lightweight task runner and deployment orchestrator with a client and daemon, designed to run pipelines across machines and pass inputs and outputs between them.

There are many deployment tools built for large servers, but Weft is specifically built to run comfortably on budget VPSs—such as a $1 [TierHive](https://tierhive.com) or 128MB–512MB single-core instance—while leaving enough resources for your actual applications. The daemon idles under 10MB RSS (and even lower on `ReleaseSmall` builds), using its own lightweight task runner built directly on Linux namespaces, cgroups v2, and rlimits across `systemd`, `OpenRC`, and `runit` hosts.

> **Status**: Weft is in active development. Breaking changes may occur frequently as we head toward v0.2.0.

---

## Core Concepts

- **Workspace**: A project with its configuration, scripts, and sources. Workspaces are strictly isolated on remotes: each gets its own dedicated UID/GID (`60000..64999`) and `0700`-locked directories (`run`, `artifacts`, `archive`, `cache`, `home`) under `/var/lib/weft/`.
- **Remote**: A machine running the `weft` daemon (`weftd`). Remotes are configured per project. The local host is always available as `"local"`.
- **Client**: The `weft` CLI running on your development machine or CI. It computes dependency DAGs, packages sources, syncs artifacts, and streams logs. Only the client holds the full picture of the deployment; remotes manage individual tasks.
- **Deployment**: A single execution run identified by an 8-character ID (e.g. `2EWbDg3L`), tracking all target pipelines and artifacts.
- **Pipeline**: A declarative step in `weft/weft.zon` associated with a script, required inputs, outputs, environment variables, resource limits, and caching policies.
- **Task**: An active running instance of a pipeline dispatched to a remote and supervised directly by `weftd` inside an isolated cgroup and namespace sandbox.
- **Artifact**: A directory tree produced by a pipeline. Source directories are packaged as source artifacts prefixed with `-` (e.g. `-backend` or `-`).
- **Modes**: Named configuration overlays (e.g. `default`, `prod`, `dev`) that modify environment variables, packages, or targets without duplicating pipelines.

---

## Quickstart

### 1. Build and Install

Building requires [Zig](https://ziglang.org/) 0.16+:

```bash
zig build -Doptimize=ReleaseSmall
sudo ./zig-out/bin/weft daemon install
```

The installer provisions the unprivileged `weft-runner` system user, installs the service for your host's init system (`systemd`, `OpenRC`, or `runit`), and starts the daemon.

Register your client key with the local daemon:
```bash
sudo weft daemon register $(weft key)
```

To provision a remote VPS over SSH in a single step:
```bash
weft remote install root@your-vps.com:22
```

---

## Minimal Example

In your project repository, create `weft/weft.zon`:

```zig
.{
    .workspace = "my-app",
    .modes = .{ "default", "prod" },

    .remotes = .{
        .{ "prod-server", "192.0.2.10:9338", "prod" },
    },

    .sources = .{
        .{ "server", "server/" },
    },

    .environments = .{
        .{
            .name = "toolchain",
            .pkgs = .{
                "qkydg77xf2s395md9fq0a6djjpq7fzh4-bun-1.4.2",
            },
        },
    },

    .pipelines = .{
        .{
            .name = "build",
            .in = .{"-server"},
            .out = .{"build"},
            .on = .{"local"},
            .env = .{ .uses = .{"toolchain"} },
        },
        .{
            .name = "run",
            .in = .{"build"},
            .on = .{"prod-server"},
            .sibling = .{ .then = .kill },
            .env = .{
                .vars = .{
                    .{ "PORT", "3000" },
                    .{ "prod:PORT", "80" },
                },
            },
        },
    },
}
```

Write the pipeline script in `weft/build.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Copy source artifact into working directory
cp -r "$IN/-server/"* ./

bun build index.ts --outdir "$OUT/build"
```

And run:

```bash
# Validate your pipeline graph and variables
weft check

# Run automated deployment
weft do run

# Or deploy specifically in prod mode to the remote
weft do prod:prod-server.run
```

---

## Workflows

### Automated: `weft do`
Weft calculates the dependency graph, packages source directories, transfers outputs between remotes, and streams logs in real-time:
```bash
weft do server-build
weft do prod-server.server-run
```

If a step fails, fix the issue and resume without re-running completed tasks:
```bash
weft resume
```

### Manual: `weft task` & `weft artifact`
For step-by-step or custom scripting workflows:
```bash
# Spawn a single task without triggering prerequisites
weft task spawn server-run prod-server

# Inspect logs
weft logs server-run

# Transfer and manage artifacts
weft artifact push build prod-server
weft artifact pull build prod-server
weft artifact path build

# Live terminal monitor (CPU, RAM, network, tasks)
weft remote monitor prod-server
```

### Command-Line Argument Duality
Weft CLI uses an in-tree parser where positional and keyword arguments are interchangeable:
```bash
weft kill prod-server 2EWbDg3L server-run
# is equivalent to:
weft kill --remote prod-server --deployment 2EWbDg3L --pipeline server-run
```

---

## Documentation

Full documentation, configuration schemas, daemon task runner details, CLI reference, and wire protocol internals are organized in the [`docs/`](docs/src/SUMMARY.md) book:

- **[Getting Started](docs/src/getting-started/installation.md)**
- **[Configuration (`weft.zon`)](docs/src/config/README.md)**
- **[Daemon & Task Manager (`weftd`)](docs/src/daemon/README.md)**
- **[Orchestration & Execution](docs/src/execution/README.md)**
- **[CLI Reference](docs/src/cli/README.md)**
- **[Internals & Wire Protocol](docs/src/internals/README.md)**

To read or preview the documentation locally:
```bash
cd docs
mdbook serve --open
```

---

## License

MIT License. See [LICENSE](LICENSE) for details.
