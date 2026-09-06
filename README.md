# weft

First Zig project: a small build/workflow tool written in Zig.

## Overview

Weft is a lightweight project/workflow runner written in Zig. It supports running a local daemon, performing workspace "pipelines" (defined in weft.zon), and managing remote installations.

This repository contains the core implementation and a CLI (see `src/main.zig`).

## Features

- CLI with subcommands: `daemon`, `do`, and `remote`.
- Simple pipeline description in `weft.zon`.
- Client and daemon implementations, plus utilities for project discovery and execution.
- Uses Zig's build system (see `build.zig`).

## Requirements

- Zig compiler >= 0.16.0 (declared in build.zig.zon)

## Quick start

Build the project:

```bash
zig build
```

Run the compiled binary directly:

```bash
./zig-out/bin/weft --help
```

Or run via the build system (passes arguments through to the program):

```bash
zig build run -- <args>
# examples:
zig build run -- daemon install
zig build run -- daemon run
zig build run -- do build
```

Run tests:

```bash
zig build test
# or
zig test
```

## Common commands

- Start and install the daemon:
  - zig build run -- daemon install
  - zig build run -- daemon run

- Run pipelines in the current project:
  - zig build run -- do <pipeline>
  - Example: zig build run -- do build

- Manage remotes (interactive):
  - zig build run -- remote add <name>

## Project layout

- build.zig — Zig build script that defines `weft` executable and test steps.
- weft.zon — Simple workspace/pipeline description used by the tool.
- src/ — Zig source files, including:
  - main.zig — CLI entrypoint and command parsing.
  - Weft.zig — Core functionality.
  - Client.zig, Server.zig, DaemonInstall.zig, ClientInstall.zig — client/daemon helpers and installers.
  - Many small utilities (UUIDv7.zig, Term.zig, Walker.zig, etc.)

## Contributing

Contributions are welcome. Please open issues or pull requests with proposed changes.

If you fork this repository, note that `build.zig.zon` contains a package fingerprint comment — when forking an actively maintained Zig project you may want to regenerate the package identifier (delete the fingerprint field and run `zig build`).

## License

See the LICENSE file in the repository (if present). If there is no license, add one to clarify usage permissions.

## Contact

Created by ken-morel.
