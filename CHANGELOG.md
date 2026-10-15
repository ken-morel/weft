# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned for 0.2.0
- Decouple task execution from systemd; introduce native `weft shim`.
- Init-agnostic daemon service management (support for OpenRC, runit, sysvinit).

## [0.1.0] - 2026-10-15

### Added
- Weft daemon, running pipelines on remotes using systemd. 
- Weft client, in the same binary and querying the remote.
- Initial weft.zon schema version, firuging remotes, pipelines, environments, sources.
- Wire protocol usinz zoto, Ed2519 for ssh-like authentication and XChaCha20Poly1305.
- Remote installations via `weft remote`.
- Lightweight nix client for provisioning environments. And better isolating the running pipelines from
  the rest of the system with isolated bin and environment.
- AI-Generated tui monitors and monitoring of remotes.
- Github actions integration, also generated.
