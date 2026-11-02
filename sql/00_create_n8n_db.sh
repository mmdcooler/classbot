#!/bin/sh
# Runs once on first start of the postgres container: separate database for n8n's own tables
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "CREATE DATABASE \"${N8N_DB:-n8n}\";"
