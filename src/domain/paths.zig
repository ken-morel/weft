const std = @import("std");

pub const weft_lib = "/var/lib/weft/";
pub const weft_config = "/etc/weft";
pub const weft_run = "/run/weft/";

pub const weft_workspace = weft_lib ++ "workspace/";
pub const weft_tmp = weft_lib ++ "tmp/";
pub const weft_bin = weft_lib ++ "bin/";
pub const weft_nix = weft_lib ++ "nix/";

/// UID monilithic counter, and lock.
pub const weft_workspace_uid = weft_workspace ++ "uid";

pub const weft_active = weft_lib ++ "active/";

/// fmt: workspace, pipeline, deployment
pub const active_link = weft_active ++ "{s}_{s}_{d}";

pub const weft_socket = weft_run ++ "weft.pipe";

pub const weft_nix_store = weft_nix ++ "store/";
pub const weft_nix_store_lock = weft_nix_store ++ ".lock";
pub const weft_nix_nar = weft_nix ++ "nar/";
pub const weft_nix_narinfo = weft_nix ++ "narinfo/";

/// fmt: workspace
pub const workspace = weft_workspace ++ "{s}/";
/// fmt: workspace (Persistent UID assignment for chown)
pub const workspace_uid = workspace ++ "uid";
/// fmt: workspace (Bound to /home/{workspace})
pub const workspace_home = workspace ++ "home/";
// fmt: workspace
pub const workspace_scratch = workspace ++ "scratch/";

pub const workspace_keep = workspace ++ "keep/";

/// fmt: workspace, artifact, deployment
pub const artifact = workspace ++ "artifact/{s}/{d}/";
//BUG: This will lead to errors if the same artifact is uploaded twice.
/// fmt: workspace, artifact, deployment
pub const artifact_tmp = workspace ++ "artifact/{s}/tmp.{d}/";

/// fmt: workspace, pipeline, deployment (Persistent task record)
pub const task = workspace ++ "task/{s}/{d}/";
/// fmt: workspace, pipeline, deployment (Serialized Task.Spec)
pub const task_spec = task ++ "spec";
/// fmt: workspace, pipeline, deployment (Combined stdout/stderr)
pub const task_log = task ++ "log";
/// fmt: workspace, pipeline, deployment (pending/running/success/failed[ status])
pub const task_status = task ++ "status";

/// fmt: workspace, keep
pub const keep = workspace_keep ++ "{s}/";

/// fmt: workspace
pub const workspace_run = weft_run ++ "{s}/";
/// fmt: workspace, pipeline
pub const tasks_run_parent = workspace_run ++ "{s}/";
/// fmt: workspace, pipeline, deployment (Scratch space for running task)
pub const task_run = workspace_run ++ "{s}/{d}/";
/// fmt: workspace, pipeline, deployment (FIFO for stdin)
///
pub const task_run_in = task_run ++ "in";
/// fmt: workspace, pipeline, deployment (Supervisor's host PID)
pub const task_run_pid = task_run ++ "pid";
/// fmt: workspace, pipeline, deployment (Empty mount point for sandbox tmpfs)
pub const task_run_root = task_run ++ "root/";
/// fmt: workspace, pipeline, deployment (The executable script inside the sandbox)
pub const task_run_root_script = task_run_root ++ "script";

/// fmt: workspace, pipeline, deployment
pub const scratch = workspace_scratch ++ "{s}/{d}/";
/// fmt: workspace, pipeline, deployment
pub const scratch_cwd = scratch ++ "cwd/";
/// fmt: workspace, pipeline, deployment
pub const scratch_outputs = scratch ++ "out/";
/// fmt: workspace, pipeline, deployment, output
pub const scratch_output = scratch ++ "out/{s}/";

pub fn ensure_dirs(io: std.Io) !void {
    const sys_paths = [_][]const u8{
        weft_lib,
        weft_config,
        weft_run,
        weft_workspace,
        weft_active,
        weft_bin,
        weft_nix_nar,
        weft_nix_store,
        weft_nix_narinfo,
    };
    const cwd: std.Io.Dir = .cwd();
    inline for (sys_paths) |p| try cwd.createDirPath(io, p);
}
