#!/bin/bash
sed -i 's|@import("../../install/client.zig")|@import("../install/client.zig")|g' src/client/do.zig
sed -i 's|@import("../../Connection.zig")|@import("../net/Connection.zig")|g' src/client/do.zig
sed -i 's|@import("../../Client.zig")|@import("../net/Client.zig")|g' src/client/do.zig
sed -i 's|@import("../../Deployment.zig")|@import("../model/Deployment.zig")|g' src/client/do.zig
sed -i 's|@import("../../Project.zig")|@import("../project/Project.zig")|g' src/client/do.zig
sed -i 's|@import("../../Term.zig")|@import("../util/Term.zig")|g' src/client/do.zig

sed -i 's|@import("../Deployment.zig")|@import("../model/Deployment.zig")|g' src/client/runner.zig
sed -i 's|@import("../install.zig").Client|@import("../install/client.zig")|g' src/client/runner.zig
sed -i 's|@import("../Project.zig")|@import("../project/Project.zig")|g' src/client/runner.zig
sed -i 's|@import("../Term.zig")|@import("../util/Term.zig")|g' src/client/runner.zig
sed -i 's|@import("../Client.zig")|@import("../net/Client.zig")|g' src/client/runner.zig

sed -i 's|@import("Connection.zig")|@import("../net/Connection.zig")|g' src/daemon/Daemon.zig
sed -i 's|@import("Server.zig")|@import("../net/Server.zig")|g' src/daemon/Daemon.zig
sed -i 's|@import("Term.zig")|@import("../util/Term.zig")|g' src/daemon/Daemon.zig
sed -i 's|@import("install/daemon.zig")|@import("../install/daemon.zig")|g' src/daemon/Daemon.zig
