#!/bin/bash

# Airflow Backup Script
# Usage: ./run_airflow_backup.sh <project_name> <environment>
# Example: ./run_airflow_backup.sh foo prod

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
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
Airflow Backup Script

USAGE:
    ./run_airflow_backup.sh <project_name> <environment>

ARGUMENTS:
    project_name    The name of the project (e.g., foo, myproject)
    environment     The environment (e.g., prod, dev, staging)

EXAMPLES:
    ./run_airflow_backup.sh foo prod
    ./run_airflow_backup.sh myproject dev

PREREQUISITES:
    - kubectl must be installed and configured
    - Correct Kubernetes context must be active
    - airflow_backup.py must exist in the same directory
    - Sufficient permissions to access the Kubernetes cluster

DESCRIPTION:
    This script backs up Airflow configurations including:
    - Variables
    - Connections
    - Pools
    - DAG Models
    
    The backup files are saved to: ./airflow_backup_<project>_<env>/
EOF
}

# Validate arguments
if [[ $# -ne 2 ]]; then
    error "Invalid number of arguments"
    show_help
    exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# Set variables
project="$1"
env="$2"
project_name="${project}_${env}"
namespace="$env"
backup_dir="airflow_backup_${project_name}"
timestamp=$(date +"%Y%m%d_%H%M%S")
backup_dir_with_timestamp="${backup_dir}_${timestamp}"

log "Starting Airflow backup for project: ${project}, environment: ${env}"

# Validate prerequisites
log "Validating prerequisites..."

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if airflow_backup.py exists
if [[ ! -f "./airflow_backup.py" ]]; then
    error "airflow_backup.py not found in current directory"
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

# Find Airflow web pod
log "Searching for Airflow web pod in namespace: ${namespace}"
airflow_web_pod=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep airflow-web | grep Running | awk '{print $1}' | head -1)

if [[ -z "$airflow_web_pod" ]]; then
    error "No running Airflow web pod found in namespace: ${namespace}"
    log "Available pods in namespace ${namespace}:"
    kubectl get pods -n "$namespace" 2>/dev/null || error "Cannot access namespace ${namespace}"
    exit 1
fi

success "Found Airflow web pod: ${airflow_web_pod}"

# Create backup directory with timestamp
log "Creating backup directory: ${backup_dir_with_timestamp}"
mkdir -p "$backup_dir_with_timestamp"

# Copy backup script to pod
log "Copying airflow_backup.py to pod..."
if ! kubectl cp ./airflow_backup.py "${namespace}/${airflow_web_pod}:/tmp/airflow_backup.py"; then
    error "Failed to copy airflow_backup.py to pod"
    exit 1
fi

# Run backup inside pod
log "Running backup inside pod..."
if ! kubectl exec -n "$namespace" "$airflow_web_pod" -- bash -c "source /opt/bitnami/airflow/venv/bin/activate && python3 /tmp/airflow_backup.py"; then
    error "Backup script failed inside pod"
    exit 1
fi

# Copy backup files to local machine
log "Copying backup files to local machine..."

backup_files=("variables_backup.json" "connections_backup.json" "pools_backup.json" "dag_models_backup.json")
failed_files=()

for file in "${backup_files[@]}"; do
    log "Copying ${file}..."
    if kubectl cp "${namespace}/${airflow_web_pod}:/tmp/${file}" "./${backup_dir_with_timestamp}/${file}"; then
        # Verify file was copied and has content
        if [[ -f "./${backup_dir_with_timestamp}/${file}" && -s "./${backup_dir_with_timestamp}/${file}" ]]; then
            success "✅ ${file} copied successfully"
        else
            warning "⚠️  ${file} copied but appears to be empty"
            failed_files+=("$file")
        fi
    else
        error "❌ Failed to copy ${file}"
        failed_files+=("$file")
    fi
done

# Create backup summary
log "Creating backup summary..."
cat > "./${backup_dir_with_timestamp}/backup_info.txt" << EOF
Airflow Backup Summary
=====================
Project: ${project}
Environment: ${env}
Namespace: ${namespace}
Pod: ${airflow_web_pod}
Backup Date: $(date)
Kubernetes Context: ${current_context}

Files Backed Up:
EOF

for file in "${backup_files[@]}"; do
    if [[ -f "./${backup_dir_with_timestamp}/${file}" ]]; then
        file_size=$(du -h "./${backup_dir_with_timestamp}/${file}" | cut -f1)
        echo "- ${file} (${file_size})" >> "./${backup_dir_with_timestamp}/backup_info.txt"
    else
        echo "- ${file} (FAILED)" >> "./${backup_dir_with_timestamp}/backup_info.txt"
    fi
done

# Cleanup temporary files from pod
log "Cleaning up temporary files from pod..."
for file in "${backup_files[@]}"; do
    kubectl exec -n "$namespace" "$airflow_web_pod" -- rm -f "/tmp/${file}" 2>/dev/null || true
done
kubectl exec -n "$namespace" "$airflow_web_pod" -- rm -f "/tmp/airflow_backup.py" 2>/dev/null || true

# Create symlink to latest backup (without timestamp)
if [[ -L "$backup_dir" ]]; then
    rm "$backup_dir"
fi
ln -s "$backup_dir_with_timestamp" "$backup_dir"

# Final summary
echo
echo "=================================="
success "Backup completed successfully!"
echo "=================================="
log "Backup location: ./${backup_dir_with_timestamp}/"
log "Latest backup symlink: ./${backup_dir}/"

if [[ ${#failed_files[@]} -gt 0 ]]; then
    echo
    warning "Some files failed to backup:"
    for file in "${failed_files[@]}"; do
        echo "  - $file"
    done
    echo
    warning "Please check the pod logs and try again if needed"
    exit 1
fi

# Display backup contents
echo
log "Backup contents:"
ls -la "./${backup_dir_with_timestamp}/"

echo
success "🎉 All backup files created successfully!"
log "You can now use these files for restore operations"


