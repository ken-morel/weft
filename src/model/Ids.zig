const std = @import("std");
const Service = @import("Service.zig");
const Deployment = @import("Deployment.zig");
const UUIDv7 = @import("UUIDv7.zig");

pub const ServiceId = struct {
    workspace: []const u8,
    service: []const u8,
    pub fn from_service(s: Service) @This() {
        return .{
            .workspace = s.workspace,
            .service = s.name,
        };
    }
};
pub const DeploymentId = struct {
    service: ServiceId,
    deployment: UUIDv7,
    pub fn from_deployment(d: Deployment) @This() {
        return .{
            .deployment = d.uuid,
            .service = .from_service(d.service),
        };
    }
};
pub const TaskId = struct {
    deployment: DeploymentId,
    pipeline: []const u8,
};
pub const ArtifactId = struct {
    task: TaskId,
    idx: u8,
};
