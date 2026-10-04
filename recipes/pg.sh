#!/usr/bin/env bash

# environ:
# .{
#     .name = "pg",
#     .pkgs = .{"4nz2y9q8kdn78axpm4jd7c1phmiygg58-postgresql-18.6"},
#     .env = .{
#         .{"PG_URL", null},
#         .{"PG_DATA", "pg-data/data"},
#     }
# }
# pipeline:
# .{
#     .name = "pg",
#     .uses = .{"pg"},
#     .sibling = .{.then = .skip},
#     .keep = .{
#         .{"pg-data", "pg-data"},
#     },
# }

set -e

echo "Initializing PostgreSQL environment"

if [[ ! "$PG_URL" =~ ^postgres(ql)?://([^:@/]+)(:([^@/]*))?@([^:/]+):([0-9]+)/([^?]+) ]]; then
    echo "Invalid or missing PG_URL" >&2
    exit 1
fi

PG_USER="${BASH_REMATCH[2]}"
PG_PORT="${BASH_REMATCH[6]}"
PG_NAME="${BASH_REMATCH[7]}"

if [ -z "$PG_DATA" ]; then
    echo "PG_DATA is not set" >&2
    exit 1
fi

# Dynamically construct configuration arguments
PG_ARGS=()
if [ -n "$PG_MAX_CONNECTIONS" ]; then PG_ARGS+=("-c" "max_connections=$PG_MAX_CONNECTIONS"); fi
if [ -n "$PG_SHARED_BUFFERS" ]; then PG_ARGS+=("-c" "shared_buffers=$PG_SHARED_BUFFERS"); fi
if [ -n "$PG_WORK_MEM" ]; then PG_ARGS+=("-c" "work_mem=$PG_WORK_MEM"); fi
if [ -n "$PG_MAINTENANCE_WORK_MEM" ]; then PG_ARGS+=("-c" "maintenance_work_mem=$PG_MAINTENANCE_WORK_MEM"); fi

echo "Connection config - User: $PG_USER, Port: $PG_PORT, Database: $PG_NAME"
if [ ${#PG_ARGS[@]} -gt 0 ]; then
    echo "Applying tuning parameters: ${PG_ARGS[*]}"
fi

if [ ! -s "$PG_DATA/PG_VERSION" ]; then
    echo "No existing cluster found at $PG_DATA. Bootstrapping new cluster..."
    initdb -D "$PG_DATA" -U "$PG_USER" --auth-local=trust --auth-host=trust
    
    echo "Starting temporary server for database provisioning..."
    # We use ${PG_ARGS[*]} here to expand the array into a single string for the -o flag
    pg_ctl -D "$PG_DATA" -o "-p $PG_PORT -k /tmp ${PG_ARGS[*]}" -w start
    
    if [ "$PG_NAME" != "$PG_USER" ]; then
        echo "Creating database '$PG_NAME'..."
        createdb -h /tmp -p "$PG_PORT" -U "$PG_USER" "$PG_NAME" || true
    else
        echo "Target database matches owner name. Skipping explicit creation."
    fi
    
    echo "Provisioning complete. Shutting down temporary server..."
    pg_ctl -D "$PG_DATA" -m fast -w stop
else
    echo "Existing cluster detected at $PG_DATA. Skipping bootstrap phase."
fi

chmod 0700 "$PG_DATA"

echo "Starting PostgreSQL daemon on port $PG_PORT..."
# We use "${PG_ARGS[@]}" here to preserve array arguments correctly for exec
exec postgres -D "$PG_DATA" -p "$PG_PORT" -k /tmp "${PG_ARGS[@]}"


# [Profile 1: Ultra-Minimalist]
# Target: Local dev environments, CI pipelines, light background workers.
# Throughput: ~10 - 30 requests/sec
# Footprint: ~20MB - 35MB RAM
#
# .{"PG_MAX_CONNECTIONS", "10"},
# .{"PG_SHARED_BUFFERS", "16MB"},
# .{"PG_WORK_MEM", "2MB"},
# .{"PG_MAINTENANCE_WORK_MEM", "16MB"},
#
#
# [Profile 2: Standard (Native Defaults)]
# Target: Standard web applications, active development.
# Throughput: ~100 - 200 requests/sec
# Footprint: ~100MB - 150MB RAM
# (Note: If you omit all variables, Postgres falls back to exactly this).
#
# .{"PG_MAX_CONNECTIONS", "100"},
# .{"PG_SHARED_BUFFERS", "128MB"},
# .{"PG_WORK_MEM", "4MB"},
# .{"PG_MAINTENANCE_WORK_MEM", "64MB"},
#
#
# [Profile 3: Heavy Workload]
# Target: Data-intensive apps, high concurrency, analytics.
# Throughput: ~500+ requests/sec
# Footprint: ~500MB - 1GB+ RAM
#
# .{"PG_MAX_CONNECTIONS", "200"},
# .{"PG_SHARED_BUFFERS", "256MB"},
# .{"PG_WORK_MEM", "16MB"},
# .{"PG_MAINTENANCE_WORK_MEM", "128MB"},
