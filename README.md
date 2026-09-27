# Weft

Weft is a Zig-based deployment and orchestration tool for running project pipelines on local or remote hosts.

It provides:
- a local daemon service
- a CLI for deployment management
- project validation and pipeline execution
- remote registration and monitoring
- systemd-based task execution

This project is designed for Linux environments and uses systemd for task isolation and lifecycle management.

## Requirements

- Zig 0.16.0 or newer
- Linux with systemd
- root access for installing the daemon
- `ssh` for remote operations

## Quick start

Clone the repo:

```bash
git clone https://github.com/zendrx/weft.git
cd weft
```

Build:

```bash
zig build
```

Show help:

```bash
zig build run -- --help
```

## Common commands

### Install the daemon

```bash
sudo zig build run -- daemon install
```

### Run the daemon

```bash
sudo zig build run -- daemon run
```

### Validate a project

```bash
zig build run -- check
```

### Start a deployment

```bash
zig build run -- do remote.pipeline
```

### List recent deployments

```bash
zig build run -- list
```

### Follow a running pipeline

```bash
zig build run -- follow <pipeline> --deployment <deployment-id>
```

### Manage remotes

```bash
zig build run -- remote list
zig build run -- remote install <name> <ssh-target>
zig build run -- remote remove <name>
```

### Kill a deployment or pipeline

```bash
zig build run -- kill --deployment <deployment-id>
zig build run -- kill --deployment <deployment-id> --pipeline <pipeline>
```

### Garbage collect old artifacts

```bash
zig build run -- gc
```

## Project layout

```text
.
├── build.zig
├── build.zig.zon
├── README.md
├── src/
│   ├── main.zig
│   ├── client/
│   ├── daemon/
│   ├── domain/
│   ├── util/
│   └── wire/
├── weft/
│   └── weft.zon
└── .gitignore
```

### Main areas

- `src/main.zig`  
  CLI entry point and command dispatch

- `src/client/`  
  User-facing commands and client-side deployment logic

- `src/daemon/`  
  Daemon runtime, task lifecycle, state, and service management

- `src/domain/`  
  Core deployment/project concepts

- `src/wire/`  
  Network and encryption logic

- `src/util/`  
  Shared helpers and runtime utilities

## Development

Building:

```bash
zig build
```

Running tests:

```bash
zig build test
```

Formatting:

```bash
zig fmt src
```

## Contributing

Contributions are welcome. Keep PRs small and focused.

Recommended approach:
1. Fork the project
2. Create a feature branch
3. Make a small, scoped change
4. Run build + tests
5. Open a PR with a clear description

If you are new to the repo, start with:
- `src/main.zig`
- `src/client/`
- `src/domain/`

## Notes

- The daemon installs and runs as a system service and expects a Linux/systemd environment.
- This project is not a generic cross-platform app; it is built around a system-managed execution model.
- Some commands require privileged access or preconfigured system directories.

## License

This project does not currently declare a license in the repository root. If a license is added later, update this section accordingly.
