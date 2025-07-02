#!/bin/bash

# Airflow PostgreSQL Direct Backup Script
# Usage: ./airflow_pg_selective_backup.sh <project_name>
# Example: ./airflow_pg_selective_backup.sh foo_prod

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Help function
show_help() {
    cat << EOF
Airflow PostgreSQL Direct Backup Script

USAGE:
    ./airflow_pg_selective_backup.sh <project_name>

ARGUMENTS:
    project_name    The name of the project (e.g., foo_prod, myproject_dev)

EXAMPLES:
    ./airflow_pg_selective_backup.sh foo_prod
    ./airflow_pg_selective_backup.sh myproject_dev

PREREQUISITES:
    - kubectl must be installed and configured
    - PostgreSQL client tools (psql, pg_dump) must be installed
    - Correct Kubernetes context must be active
    - PostgreSQL pod must be running and accessible
    - Network connectivity to PostgreSQL pod

DESCRIPTION:
    This script directly connects to the PostgreSQL database to backup:
    - Variables (CSV format)
    - Connections (CSV format) 
    - Pools (CSV format)
    - DAG metadata and execution history (SQL dump)
    
    Use this when Airflow web pods are crashed but PostgreSQL is accessible.
EOF
}

# Validate arguments
if [[ $# -ne 1 ]]; then
    error "Invalid number of arguments"
    show_help
    exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# Set variables
project_name="$1"
timestamp=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="postgres_backup_${project_name}_${timestamp}"

log "Starting PostgreSQL direct backup for project: ${project_name}"

# Validate prerequisites
log "Validating prerequisites..."

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if PostgreSQL client tools are installed
if ! command -v psql &> /dev/null; then
    error "psql is not installed. Please install PostgreSQL client tools"
    exit 1
fi

if ! command -v pg_dump &> /dev/null; then
    error "pg_dump is not installed. Please install PostgreSQL client tools"
    exit 1
fi

# Check kubectl connectivity
if ! kubectl cluster-info &> /dev/null; then
    error "Cannot connect to Kubernetes cluster. Please check your context and credentials."
    exit 1
fi

# Get current context
current_context=$(kubectl config current-context)
log "Current Kubernetes context: ${current_context}"

# Find PostgreSQL pod and get its IP
log "Searching for PostgreSQL pod..."
PG_HOST=$(kubectl get pods -o wide --no-headers 2>/dev/null | grep Running | grep "airflow-postgresql-0" | awk '{print $6}')

if [[ -z "$PG_HOST" ]]; then
    error "No running PostgreSQL pod found"
    log "Available pods:"
    kubectl get pods 2>/dev/null || error "Cannot list pods"
    exit 1
fi

success "Found PostgreSQL host: ${PG_HOST}"

# PostgreSQL connection parameters
PG_PORT="5432"
PG_DB="bitnami_airflow"
PG_USER="bn_airflow"
PG_PASSWORD="data-sync"

# Test PostgreSQL connectivity
log "Testing PostgreSQL connectivity..."
export PGPASSWORD="$PG_PASSWORD"

if ! psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1;" &> /dev/null; then
    error "Cannot connect to PostgreSQL database"
    error "Host: $PG_HOST, Port: $PG_PORT, Database: $PG_DB, User: $PG_USER"
    exit 1
fi

success "PostgreSQL connectivity verified"

# Create backup directory
log "Creating backup directory: ${BACKUP_DIR}"
mkdir -p "$BACKUP_DIR"

# Backup metadata tables to CSV
log "Backing up metadata tables to CSV..."

declare -A table_queries=(
    ["variables.csv"]="SELECT key, val FROM variable"
    ["connections.csv"]="SELECT conn_id, conn_type, host, login, password, schema, port, extra FROM connection"
    ["pools.csv"]="SELECT pool, slots, description FROM pool"
)

failed_tables=()

for file in "${!table_queries[@]}"; do
    query="${table_queries[$file]}"
    output_path="${BACKUP_DIR}/${file}"
    
    log "Saving ${file}..."
    
    if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c "\copy (${query}) TO '${output_path}' WITH CSV HEADER" 2>/dev/null; then
        
        # Verify file was created and has content
        if [[ -f "$output_path" && -s "$output_path" ]]; then
            row_count=$(tail -n +2 "$output_path" | wc -l)
            success "✅ ${file} saved successfully (${row_count} records)"
        else
            warning "⚠️  ${file} created but appears to be empty"
        fi
    else
        error "❌ Failed to backup ${file}"
        failed_tables+=("$file")
    fi
done

# Backup DAG-related tables using pg_dump
log "Backing up DAG metadata and execution history..."
DAG_BACKUP_FILE="$BACKUP_DIR/airflow_dag_backup.sql"

if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
    -t dag -t dag_run -t task_instance -t log -t job -t serialized_dag \
    -f "$DAG_BACKUP_FILE" 2>/dev/null; then
    
    if [[ -f "$DAG_BACKUP_FILE" && -s "$DAG_BACKUP_FILE" ]]; then
        file_size=$(du -h "$DAG_BACKUP_FILE" | cut -f1)
        success "✅ DAG metadata backup saved (${file_size})"
    else
        warning "⚠️  DAG backup file created but appears to be empty"
    fi
else
    error "❌ Failed to backup DAG metadata"
    failed_tables+=("DAG metadata")
fi

# Create backup summary
log "Creating backup summary..."
cat > "$BACKUP_DIR/backup_info.txt" << EOF
PostgreSQL Direct Backup Summary
================================
Project: ${project_name}
Backup Date: $(date)
PostgreSQL Host: ${PG_HOST}:${PG_PORT}
Database: ${PG_DB}
User: ${PG_USER}
Kubernetes Context: ${current_context}

Files Backed Up:
EOF

# Add file information to summary
for file in variables.csv connections.csv pools.csv airflow_dag_backup.sql; do
    if [[ -f "$BACKUP_DIR/$file" ]]; then
        file_size=$(du -h "$BACKUP_DIR/$file" | cut -f1)
        if [[ "$file" == *.csv ]]; then
            row_count=$(tail -n +2 "$BACKUP_DIR/$file" | wc -l 2>/dev/null || echo "0")
            echo "- ${file} (${file_size}, ${row_count} records)" >> "$BACKUP_DIR/backup_info.txt"
        else
            echo "- ${file} (${file_size})" >> "$BACKUP_DIR/backup_info.txt"
        fi
    else
        echo "- ${file} (FAILED)" >> "$BACKUP_DIR/backup_info.txt"
    fi
done

# Create symlink to latest backup
LATEST_BACKUP_LINK="postgres_backup_${project_name}"
if [[ -L "$LATEST_BACKUP_LINK" ]]; then
    rm "$LATEST_BACKUP_LINK"
fi
ln -s "$BACKUP_DIR" "$LATEST_BACKUP_LINK"

# Final summary
echo
echo "=================================="
success "PostgreSQL backup completed!"
echo "=================================="
log "Backup location: ./${BACKUP_DIR}/"
log "Latest backup symlink: ./${LATEST_BACKUP_LINK}/"

if [[ ${#failed_tables[@]} -gt 0 ]]; then
    echo
    warning "Some tables failed to backup:"
    for table in "${failed_tables[@]}"; do
        echo "  - $table"
    done
    echo
    warning "Please check PostgreSQL connectivity and permissions"
    exit 1
fi

# Display backup contents
echo
log "Backup contents:"
ls -la "$BACKUP_DIR/"

echo
success "🎉 All backup files created successfully!"
log "Total backup size: $(du -sh "$BACKUP_DIR" | cut -f1)"
log "You can now use these files for restore operations"

# Cleanup
unset PGPASSWORD