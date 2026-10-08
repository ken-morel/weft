#!/usr/bin/env bash

# environ:
# .{
#     .name = "pg_cluster",
#     .pkgs = .{"4nz2y9q8kdn78axpm4jd7c1phmiygg58-postgresql-18.6"},
#     .env = .{
#         .{"PG_USER", "postgres"},
#         .{"PG_PORT", "5432"},
#         .{"PG_DATABASES", "mydb1,mydb2"},
#         .{"PG_LISTEN_ADDRESSES", "*"},
#         .{"PG_DATA", "pg-data/data"},
#     }
# }
# pipeline:
# .{
#     .name = "pg_cluster",
#     .uses = .{"pg_cluster"},
#     .sibling = .{.then = .skip},
#     .keep = .{
#         .{"pg-data", "pg-data"},
#     },
# }

set -e

echo "Initializing PostgreSQL environment"

PG_USER="${PG_USER:-postgres}"
PG_PORT="${PG_PORT:-5432}"
PG_LISTEN_ADDRESSES="${PG_LISTEN_ADDRESSES:-*}"
# Default to creating a database with the same name as the user if not specified
PG_DATABASES="${PG_DATABASES:-$PG_USER}"

if [ -z "$PG_DATA" ]; then
    echo "PG_DATA is not set" >&2
    exit 1
fi

# Dynamically construct configuration arguments
PG_ARGS=()
PG_ARGS+=("-c" "listen_addresses=$PG_LISTEN_ADDRESSES")
if [ -n "$PG_MAX_CONNECTIONS" ]; then PG_ARGS+=("-c" "max_connections=$PG_MAX_CONNECTIONS"); fi
if [ -n "$PG_SHARED_BUFFERS" ]; then PG_ARGS+=("-c" "shared_buffers=$PG_SHARED_BUFFERS"); fi
if [ -n "$PG_WORK_MEM" ]; then PG_ARGS+=("-c" "work_mem=$PG_WORK_MEM"); fi
if [ -n "$PG_MAINTENANCE_WORK_MEM" ]; then PG_ARGS+=("-c" "maintenance_work_mem=$PG_MAINTENANCE_WORK_MEM"); fi

echo "Connection config - User: $PG_USER, Port: $PG_PORT, Databases: $PG_DATABASES"
if [ ${#PG_ARGS[@]} -gt 0 ]; then
    echo "Applying tuning parameters: ${PG_ARGS[*]}"
fi

if [ ! -s "$PG_DATA/PG_VERSION" ]; then
    echo "No existing cluster found at $PG_DATA. Bootstrapping new cluster..."
    initdb -D "$PG_DATA" -U "$PG_USER" --auth-local=trust --auth-host=trust
else
    echo "Existing cluster detected at $PG_DATA."
fi

# Always ensure databases exist by starting a temporary server
echo "Starting temporary server for database provisioning..."
# We append `-c listen_addresses=''` at the end to override the user's configuration during provisioning
# This prevents external apps from flooding the server with connection attempts before databases are ready
pg_ctl -D "$PG_DATA" -o "-p $PG_PORT -k /tmp ${PG_ARGS[*]} -c listen_addresses=''" -w start

IFS=',' read -ra DB_ARRAY <<< "$PG_DATABASES"
for DB_NAME in "${DB_ARRAY[@]}"; do
    # Trim whitespace
    DB_NAME=$(echo "$DB_NAME" | xargs)
    if [ -n "$DB_NAME" ]; then
        if psql -h /tmp -p "$PG_PORT" -U "$PG_USER" -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
            echo "Database '$DB_NAME' already exists. Skipping explicit creation."
        else
            echo "Creating database '$DB_NAME'..."
            createdb -h /tmp -p "$PG_PORT" -U "$PG_USER" "$DB_NAME" || true
        fi
    fi
done

echo "Provisioning complete. Shutting down temporary server..."
pg_ctl -D "$PG_DATA" -m fast -w stop

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
