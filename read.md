A lightweight task runner with daemon, client. Designed to run pipelines accross machines, passing inputs/outputs between them.

There sure are tools which do similar, but I especially built weft to work nice on budget vps's, like a $1 [TierHive](https://tierhive.com) instance and still permit you to deploy your web project. Weft was built to run under 10MB rss(downloading packages from nix takes extra resources though), though releasesmall builds idle even lower than that, aiming to leave more resources for your actual app.

Weft is currently in active development, and may frequently break.

## A few concepts

- **A Workspace**: A project with it's configuration, scripts and sources. You usually have a workspace configuraiton in your project, and different pipelines in it. Workspace are also used for isolation, such that workspaces can only access resources/files in their own workspace.
- **A Remote**: A machine running the weft daemon. Remotes are configured per-project.
- **A Client**: The `weft` binary acts as both client/server, the remote runs the server and you can query it to spawn tasks, upload/download artifacts and so on. Only the client holds the full picture about the deployment and workspace, the remote handles individual pipelines.
- **Deployment**: Identified by a unique identifier, holds a complete workflow run with several target pipelines.
- **Pipeline**: A declararative step in your weft config associated with a script, inputs/outputs, and more determining how and where it can run.
- **Task**: A running pipeline.
- **Artifact**: A folder containing the outputs of a pipeline run. There are special 'source artifacts' which are configured and derived from your project source code when creating a new deployment.
- **Modes**: Modes acts like modifiers in a deployment, you can have a pipeline running in a specific mode. Pipelines can be configured differently in different modes.

## Daemon-Client communication

The weft daemon listens on port `9338` by default, the clients