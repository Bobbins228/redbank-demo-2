#!/bin/bash

# This script runs every time the server starts (via postgresql-start).
# Substitutes $POSTGRESQL_USER in init.sql and applies the schema + seed data.

echo "Running initialization SQL..."
sed "s/\$POSTGRESQL_USER/$POSTGRESQL_USER/g" /opt/app-root/src/postgresql-start/init.sql | \
    psql -U postgres -d "$POSTGRESQL_DATABASE"
echo "Initialization complete!"
