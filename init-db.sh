#!/bin/sh
set -eu

# Only runs when PostgreSQL initializes an empty data directory.
# The application owns its database but has no cluster administration privileges.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
    --set=app_password="$VAULT_DB_PASSWORD" <<'SQL'
CREATE ROLE vaultwarden LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
    PASSWORD :'app_password';
CREATE DATABASE vaultwarden OWNER vaultwarden;
SQL
