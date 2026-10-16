# Changelog

## v0.1.1-dev

- `weft artifact push/pull`: pull/push artifacts from local project to a remote.
- `weft task spawn`: Manually spawn a task, without artifact resolution.
- `weft artifact register`: Simply register the artifact in the deployment config.
- `weft artifact path`: Prints the expected path for an artifact.
- `weft monitor` moved to `weft remote monitor`.

## v0.1.0

- Weft daemon, running pipelines on remotes using systemd. 
- Weft client, in the same binary and querying the remote.
- Initial weft.zon schema version, firuging remotes, pipelines, environments, sources.
- Wire protocol usinz zoto, Ed2519 for ssh-like authentication and XChaCha20Poly1305.
- Remote installations via `weft remote`.
- Lightweight nix client for provisioning environments. And better isolating the running pipelines from
  the rest of the system with isolated bin and environment.
- AI-Generated tui monitors and monitoring of remotes.
- Github actions integration, also generated.
