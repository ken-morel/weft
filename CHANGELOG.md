# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned for 0.2.0
- Decouple task execution from systemd; introduce native `weft-shim`.
- Init-agnostic daemon service management (support for OpenRC, runit, sysvinit).

## [0.1.0] - 2026-10-15

### Added
- **Unified Single Binary**: `weft` binary serves as both the client orchestrator and remote daemon.
- **Ultra-Low Memory Footprint**: Engineered for minimal VPS instances (128MB–512MB RAM) with < 15MB idle daemon overhead.
- **Declarative Pipelines**: DAG-based pipeline execution with artifact transfer between pipeline steps and remote hosts.
- **Encrypted Wire Protocol**: Authenticated TCP communication using Ed25519 identity keypairs and XChaCha20-Poly1305 AEAD.
- **Wire Schema Versioning**: 64-bit compile-time schema hashing (`proto.hash`) to detect protocol divergence.
- **Lightweight Nix Binary Client**: On-demand fetching of pre-built packages from Nix binary caches without requiring Nix installed on remote hosts.
- **Resource Sandboxing**: Task isolation using transient systemd units, Linux cgroups (CPU, memory, IO weight), and unprivileged user sandboxing.
- **Real-Time TUI Monitor**: Interactive terminal monitor streaming live logs, pipeline status, and bandwidth metrics.
- **Environment Overlays (Modes)**: Multi-target configuration overlays (`dev`, `prod`, etc.) for variables, packages, and remotes.
- **GitHub Actions Integration**: Composite setup action (`action.yml`) for easy zero-build installation in CI pipelines.
