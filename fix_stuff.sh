#!/bin/bash
sed -i 's|\[\]const Deployment.Target|\[\]const Target|g' src/client/do.zig
sed -i '/const Deployment = @import("..\/model\/Deployment.zig");/a const Target = @import("..\/model\/Target.zig");' src/client/do.zig

sed -i 's|targets: \[\]Deployment.Target,|targets: \[\]Target,|g' src/model/Deployment.zig
sed -i 's|owned_targets: \[\]Deployment.Target|owned_targets: \[\]Target|g' src/model/Deployment.zig
sed -i 's|owned_targets: \[\]const Deployment.Target|owned_targets: \[\]const Target|g' src/model/Deployment.zig

# Daemon.zig capture
sed -i 's#.task => |task_id| {},#.task => { _ = msg; },#g' src/daemon/Daemon.zig
