const std = @import("std");

const DeploymentState = @import("DeploymentState.zig");

state: *DeploymentState,

pub fn init(state: *DeploymentState) @This() {
    return .{
        .state = state,
    };
}

pub fn update(self: *@This()) !void {
    _ = self;
}
