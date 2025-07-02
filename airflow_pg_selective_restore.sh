#!/bin/bash

# Airflow PostgreSQL Direct Restore Script
# Usage: ./airflow_pg_selective_restore.sh <project_name> [backup_dir]
# Example: ./airflow_pg_selective_restore.sh foo_prod postgres_backup_foo_prod_20240124_143022

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
Airflow PostgreSQL Direct Restore Script

USAGE:
    ./airflow_pg_selective_restore.sh <project_name> [backup_dir]

ARGUMENTS:
    project_name    The name of the project (e.g., foo_prod, myproject_dev)
    backup_dir      Path to backup directory (optional, defaults to postgres_backup_<project_name>)

EXAMPLES:
    ./airflow_pg_selective_restore.sh foo_prod
    ./airflow_pg_selective_restore.sh foo_prod postgres_backup_foo_prod_20240124_143022
    ./airflow_pg_selective_restore.sh myproject_dev /path/to/backup/dir

PREREQUISITES:
    - kubectl must be installed and configured
    - PostgreSQL client tools (psql) must be installed
    - Correct Kubernetes context must be active
    - PostgreSQL pod must be running and accessible
    - Backup directory must exist with required files
    - Airflow database must be initialized (airflow db init)

DESCRIPTION:
    This script directly connects to the PostgreSQL database to restore:
    - Variables from variables.csv
    - Connections from connections.csv
    - Pools from pools.csv
    - DAG metadata from airflow_dag_backup.sql
    
    Use this when Airflow web pods are crashed but PostgreSQL is accessible.
    
BACKUP FILES EXPECTED:
    - variables.csv (optional)
    - connections.csv (optional)
    - pools.csv (optional)
    - airflow_dag_backup.sql (optional)
EOF
}

# Validate arguments
if [[ $# -lt 1 || $# -gt 2 ]]; then
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
backup_dir="${2:-postgres_backup_${project_name}}"

log "Starting PostgreSQL direct restore for project: ${project_name}"
log "Using backup directory: ${backup_dir}"

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

# Check kubectl connectivity
if ! kubectl cluster-info &> /dev/null; then
    error "Cannot connect to Kubernetes cluster. Please check your context and credentials."
    exit 1
fi

# Check if backup directory exists
if [[ ! -d "$backup_dir" ]]; then
    error "Backup directory not found: $backup_dir"
    log "Available backup directories:"
    ls -la postgres_backup_* 2>/dev/null || log "No backup directories found"
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
PG_DUMP_FILE="airflow_dag_backup.sql"

# Test PostgreSQL connectivity
log "Testing PostgreSQL connectivity..."
export PGPASSWORD="$PG_PASSWORD"

if ! psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1;" &> /dev/null; then
    error "Cannot connect to PostgreSQL database"
    error "Host: $PG_HOST, Port: $PG_PORT, Database: $PG_DB, User: $PG_USER"
    exit 1
fi

success "PostgreSQL connectivity verified"

# Check available backup files
log "Checking available backup files..."
available_files=()
backup_files=("variables.csv" "connections.csv" "pools.csv" "$PG_DUMP_FILE")

for file in "${backup_files[@]}"; do
    if [[ -f "$backup_dir/$file" ]]; then
        available_files+=("$file")
        log "✅ Found: $file"
    else
        log "⚠️  Missing: $file"
    fi
done

if [[ ${#available_files[@]} -eq 0 ]]; then
    error "No backup files found in directory: $backup_dir"
    exit 1
fi

success "Found ${#available_files[@]} backup files to restore"

# Restore Variables
if [[ -f "$backup_dir/variables.csv" ]]; then
    log "Restoring Variables..."
    
    # Count total records (excluding header)
    total_vars=$(tail -n +2 "$backup_dir/variables.csv" | wc -l)
    log "Processing $total_vars variable records..."
    
    restored_vars=0
    failed_vars=0
    
    while IFS=',' read -r key val; do
        # Skip header row
        [[ "$key" == "key" ]] && continue
        
        # Escape single quotes in values
        key_escaped=$(echo "$key" | sed "s/'/''/g")
        val_escaped=$(echo "$val" | sed "s/'/''/g")
        
        if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
            -c "INSERT INTO variable (key, val) VALUES ('$key_escaped', '$val_escaped') ON CONFLICT (key) DO UPDATE SET val = EXCLUDED.val;" &> /dev/null; then
            ((restored_vars++))
        else
            ((failed_vars++))
            warning "Failed to restore variable: $key"
        fi
    done < "$backup_dir/variables.csv"
    
    success "Variables restored: $restored_vars successful, $failed_vars failed"
else
    warning "variables.csv not found — skipping variables restore"
fi

# Restore Connections
if [[ -f "$backup_dir/connections.csv" ]]; then
    log "Restoring Connections..."
    
    # Count total records (excluding header)
    total_conns=$(tail -n +2 "$backup_dir/connections.csv" | wc -l)
    log "Processing $total_conns connection records..."
    
    restored_conns=0
    failed_conns=0
    
    while IFS=',' read -r conn_id conn_type host login password schema port extra; do
        # Skip header row
        [[ "$conn_id" == "conn_id" ]] && continue
        
        # Escape single quotes in values
        conn_id_escaped=$(echo "$conn_id" | sed "s/'/''/g")
        conn_type_escaped=$(echo "$conn_type" | sed "s/'/''/g")
        host_escaped=$(echo "$host" | sed "s/'/''/g")
        login_escaped=$(echo "$login" | sed "s/'/''/g")
        password_escaped=$(echo "$password" | sed "s/'/''/g")
        schema_escaped=$(echo "$schema" | sed "s/'/''/g")
        extra_escaped=$(echo "$extra" | sed "s/'/''/g")
        
        if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
            -c "INSERT INTO connection (conn_id, conn_type, host, login, password, schema, port, extra)
                VALUES ('$conn_id_escaped', '$conn_type_escaped', '$host_escaped', '$login_escaped', '$password_escaped', '$schema_escaped', '$port', '$extra_escaped')
                ON CONFLICT (conn_id) DO UPDATE SET 
                    conn_type = EXCLUDED.conn_type,
                    host = EXCLUDED.host,
                    login = EXCLUDED.login,
                    password = EXCLUDED.password,
                    schema = EXCLUDED.schema,
                    port = EXCLUDED.port,
                    extra = EXCLUDED.extra;" &> /dev/null; then
            ((restored_conns++))
        else
            ((failed_conns++))
            warning "Failed to restore connection: $conn_id"
        fi
    done < "$backup_dir/connections.csv"
    
    success "Connections restored: $restored_conns successful, $failed_conns failed"
else
    warning "connections.csv not found — skipping connections restore"
fi

# Restore Pools
if [[ -f "$backup_dir/pools.csv" ]]; then
    log "Restoring Pools..."
    
    # Count total records (excluding header)
    total_pools=$(tail -n +2 "$backup_dir/pools.csv" | wc -l)
    log "Processing $total_pools pool records..."
    
    restored_pools=0
    failed_pools=0
    
    while IFS=',' read -r pool slots description; do
        # Skip header row
        [[ "$pool" == "pool" ]] && continue
        
        # Escape single quotes in values
        pool_escaped=$(echo "$pool" | sed "s/'/''/g")
        description_escaped=$(echo "$description" | sed "s/'/''/g")
        
        if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
            -c "INSERT INTO pool (pool, slots, description)
                VALUES ('$pool_escaped', $slots, '$description_escaped')
                ON CONFLICT (pool) DO UPDATE SET 
                    slots = EXCLUDED.slots,
                    description = EXCLUDED.description;" &> /dev/null; then
            ((restored_pools++))
        else
            ((failed_pools++))
            warning "Failed to restore pool: $pool"
        fi
    done < "$backup_dir/pools.csv"
    
    success "Pools restored: $restored_pools successful, $failed_pools failed"
else
    warning "pools.csv not found — skipping pools restore"
fi

# Restore DAG Metadata
if [[ -f "$backup_dir/$PG_DUMP_FILE" ]]; then
    log "Restoring DAG metadata from $PG_DUMP_FILE..."
    
    if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -f "$backup_dir/$PG_DUMP_FILE" &> /dev/null; then
        success "✅ DAG metadata restored successfully"
    else
        error "❌ Failed to restore DAG metadata"
        warning "This might be due to schema conflicts or missing dependencies"
    fi
else
    warning "$PG_DUMP_FILE not found — skipping DAG metadata restore"
fi

# Create restore summary
log "Creating restore summary..."
restore_summary_file="$backup_dir/restore_summary_$(date +"%Y%m%d_%H%M%S").txt"

cat > "$restore_summary_file" << EOF
PostgreSQL Direct Restore Summary
=================================
Project: ${project_name}
Backup Directory: ${backup_dir}
Restore Date: $(date)
PostgreSQL Host: ${PG_HOST}:${PG_PORT}
Database: ${PG_DB}
User: ${PG_USER}
Kubernetes Context: ${current_context}

Restore Results:
EOF

# Add restore results to summary
if [[ -f "$backup_dir/variables.csv" ]]; then
    echo "- Variables: ${restored_vars:-0} restored, ${failed_vars:-0} failed" >> "$restore_summary_file"
fi

if [[ -f "$backup_dir/connections.csv" ]]; then
    echo "- Connections: ${restored_conns:-0} restored, ${failed_conns:-0} failed" >> "$restore_summary_file"
fi

if [[ -f "$backup_dir/pools.csv" ]]; then
    echo "- Pools: ${restored_pools:-0} restored, ${failed_pools:-0} failed" >> "$restore_summary_file"
fi

if [[ -f "$backup_dir/$PG_DUMP_FILE" ]]; then
    echo "- DAG Metadata: Restored from SQL dump" >> "$restore_summary_file"
fi

# Final summary
echo
echo "=================================="
success "PostgreSQL restore completed!"
echo "=================================="
log "Backup directory: ${backup_dir}"
log "Restore summary: ${restore_summary_file}"

# Calculate total success/failure
total_restored=$((${restored_vars:-0} + ${restored_conns:-0} + ${restored_pools:-0}))
total_failed=$((${failed_vars:-0} + ${failed_conns:-0} + ${failed_pools:-0}))

echo
log "Total records restored: $total_restored"
if [[ $total_failed -gt 0 ]]; then
    warning "Total records failed: $total_failed"
    warning "Check the logs above for specific failures"
fi

echo
success "🎉 Airflow metadata restoration completed!"
log "You can now restart Airflow services to pick up the restored configuration"

# Cleanup
unset PGPASSWORD