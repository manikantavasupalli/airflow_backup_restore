# Airflow Backup & Restore Automation

This repository contains automated scripts for backing up and restoring Apache Airflow configurations in Kubernetes environments.

## 📋 Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
  - [Method 1: Pod-based Backup (Recommended)](#method-1-pod-based-backup-recommended)
  - [Method 2: PostgreSQL Direct Backup (Emergency)](#method-2-postgresql-direct-backup-emergency)
- [File Structure](#file-structure)
- [Backup Contents](#backup-contents)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)
- [Contributing](#contributing)

## 🔍 Overview

The Airflow backup automation provides **two methods** for backing up and restoring Airflow configurations:

### Method 1: Pod-based Backup (Recommended)
1. **`run_airflow_backup.sh`** - Main backup script that orchestrates the entire backup process
2. **`airflow_backup.py`** - Python script that runs inside the Airflow pod to extract data
3. **`airflow_selective_backup_restore_raw_steps.md`** - Comprehensive manual backup/restore guide

### Method 2: PostgreSQL Direct Backup (Emergency)
1. **`airflow_pg_selective_backup.sh`** - Direct PostgreSQL backup script
2. **`airflow_pg_selective_restore.sh`** - Direct PostgreSQL restore script

**When to use each method:**
- **Pod-based**: When Airflow web pods are running (even if partially broken)
- **PostgreSQL Direct**: When Airflow web pods are completely crashed but PostgreSQL is accessible

## ✅ Prerequisites

Before using the backup scripts, ensure you have:

### Required Tools
- **kubectl** - Kubernetes command-line tool
- **bash** - Unix shell (version 4.0+)
- **Basic Unix utilities** - `awk`, `grep`, `head`, `du`, `date`
- **PostgreSQL client tools** - `psql`, `pg_dump` (for PostgreSQL direct method)

### Kubernetes Access
- Active Kubernetes context pointing to your cluster
- Sufficient permissions to:
  - List pods in the target namespace
  - Execute commands in pods
  - Copy files to/from pods

### File Dependencies
- For pod-based method: `airflow_backup.py` must be present in the same directory
- For PostgreSQL direct method: PostgreSQL client tools must be installed

### Verification Commands
```bash
# Check kubectl connectivity
kubectl cluster-info

# Verify current context
kubectl config current-context

# Check if you can access the target namespace
kubectl get pods -n <your-namespace>

# For PostgreSQL direct method, check client tools
psql --version
pg_dump --version
```

## 🚀 Installation

1. **Clone or download the repository**
   ```bash
   git clone <repository-url>
   cd airflow_backup_restore
   ```

2. **Make the scripts executable**
   ```bash
   chmod +x *.sh
   ```

3. **Verify prerequisites**
   ```bash
   # Check if kubectl is installed
   kubectl version --client

   # For pod-based method
   ls -la airflow_backup.py

   # For PostgreSQL direct method
   psql --version
   pg_dump --version
   ```

4. **Set up Kubernetes context**
   ```bash
   # List available contexts
   kubectl config get-contexts

   # Switch to your target context
   kubectl config use-context <your-context-name>

   # Or use kubectx if available
   kubectx <your-context-name>
   ```

## 🎯 Usage

### Method 1: Pod-based Backup (Recommended)

Use this method when Airflow web pods are running, even if partially broken.

#### Basic Usage

```bash
./run_airflow_backup.sh <project_name> <environment>
```

#### Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `project_name` | Name of your project | `foo`, `myproject` |
| `environment` | Target environment | `prod`, `dev`, `staging` |

#### Examples

```bash
# Backup production environment
./run_airflow_backup.sh foo prod

# Backup development environment
./run_airflow_backup.sh myproject dev

# Backup staging environment
./run_airflow_backup.sh webapp staging
```

#### Help

```bash
# Show help information
./run_airflow_backup.sh --help
./run_airflow_backup.sh -h
```

# Restore 
Follow restore section mentioned in airflow_selective_backup_restore_raw_steps.md file

### Method 2: PostgreSQL Direct Backup (Emergency)

Use this method when Airflow web pods are completely crashed but PostgreSQL is still accessible.

#### Backup Process

```bash
# 1. Set up Kubernetes context
kubectx <your-context>

# 2. Run PostgreSQL backup
./airflow_pg_selective_backup.sh <project_name>

# Example
./airflow_pg_selective_backup.sh foo_prod
```

#### Restore Process

```bash
# 1. Ensure Airflow database is initialized
# (You may need to restart Airflow pods and run 'airflow db init')

# 2. Run PostgreSQL restore
./airflow_pg_selective_restore.sh <project_name> [backup_directory]

# Examples
./airflow_pg_selective_restore.sh foo_prod
./airflow_pg_selective_restore.sh foo_prod postgres_backup_foo_prod_20240124_143022
```

#### Complete Emergency Recovery Workflow

```bash
# Step 1: Set Kubernetes context
kubectx <your-project-context>

# Step 2: Backup data before fixing Airflow
./airflow_pg_selective_backup.sh <project_env>

# Step 3: Reset/fix Airflow infrastructure
# (Delete and recreate pods, reset database, etc.)

# Step 4: Initialize Airflow database
# kubectl exec -it <airflow-pod> -- airflow db init

# Step 5: Restore backed up data
./airflow_pg_selective_restore.sh <project_env> [backup_directory]
```

## 📁 File Structure

### Pod-based Backup Structure

```
airflow_backup_<project>_<env>_<timestamp>/
├── backup_info.txt              # Backup summary and metadata
├── variables_backup.json        # Airflow Variables
├── connections_backup.json      # Airflow Connections
├── pools_backup.json           # Airflow Pools
└── dag_models_backup.json      # DAG metadata

airflow_backup_<project>_<env>   # Symlink to latest backup
```

### PostgreSQL Direct Backup Structure

```
postgres_backup_<project>_<timestamp>/
├── backup_info.txt              # Backup summary and metadata
├── variables.csv                # Airflow Variables (CSV format)
├── connections.csv              # Airflow Connections (CSV format)
├── pools.csv                   # Airflow Pools (CSV format)
└── airflow_dag_backup.sql      # DAG metadata (SQL dump)

postgres_backup_<project>       # Symlink to latest backup
```

### Example Output Structures
```
# Pod-based backup
airflow_backup_foo_prod_20240124_143022/
├── backup_info.txt
├── variables_backup.json
├── connections_backup.json
├── pools_backup.json
└── dag_models_backup.json

# PostgreSQL direct backup
postgres_backup_foo_prod_20240124_143022/
├── backup_info.txt
├── variables.csv
├── connections.csv
├── pools.csv
└── airflow_dag_backup.sql
```

## 📦 Backup Contents

Both backup methods capture the following Airflow configurations:

### 1. Variables
- All Airflow Variables with their keys and values
- Environment-specific configuration values
- Custom application settings
- **Format**: JSON (pod-based) or CSV (PostgreSQL direct)

### 2. Connections
- Database connections
- API endpoints
- Service credentials
- Connection metadata (host, port, schema, etc.)
- **Format**: JSON (pod-based) or CSV (PostgreSQL direct)

### 3. Pools
- Resource pools configuration
- Slot allocations
- Pool descriptions
- **Format**: JSON (pod-based) or CSV (PostgreSQL direct)

### 4. DAG Models/Metadata
- DAG metadata and state
- Pause/unpause status
- Last execution information
- File locations
- Execution history (PostgreSQL direct method only)
- **Format**: JSON (pod-based) or SQL dump (PostgreSQL direct)

### 5. Backup Metadata
- Backup timestamp
- Source information (pod or PostgreSQL host)
- Kubernetes context
- File sizes and record counts

## 🔧 Troubleshooting

### Common Issues and Solutions

#### 1. Pod Not Found (Pod-based method)
```
[ERROR] No running Airflow web pod found in namespace: prod
```

**Solutions:**
- Switch to PostgreSQL direct method if pods are crashed
- Verify the namespace exists: `kubectl get namespaces`
- Check pod status: `kubectl get pods -n <namespace>`
- Ensure Airflow web pod is running: `kubectl get pods -n <namespace> | grep airflow-web`

#### 2. PostgreSQL Connection Failed (PostgreSQL direct method)
```
[ERROR] Cannot connect to PostgreSQL database
```

**Solutions:**
- Verify PostgreSQL pod is running: `kubectl get pods | grep postgresql`
- Check PostgreSQL client tools: `psql --version`
- Test network connectivity to PostgreSQL pod
- Verify database credentials in the script

#### 3. Permission Denied
```
[ERROR] Cannot connect to Kubernetes cluster
```

**Solutions:**
- Check kubectl configuration: `kubectl config view`
- Verify current context: `kubectl config current-context`
- Test cluster connectivity: `kubectl cluster-info`
- Check RBAC permissions with your cluster administrator

#### 4. Missing PostgreSQL Client Tools
```
[ERROR] psql is not installed
```

**Solutions:**
```bash
# Ubuntu/Debian
sudo apt-get install postgresql-client

# CentOS/RHEL
sudo yum install postgresql

# macOS
brew install postgresql

# Verify installation
psql --version
pg_dump --version
```

#### 5. Empty Backup Files
```
[WARNING] connections_backup.json copied but appears to be empty
```

**Solutions:**
- Check if Airflow database contains data
- Verify database connectivity
- For pod-based: Check if Airflow virtual environment is properly activated
- For PostgreSQL direct: Verify table names and structure

### Method-Specific Troubleshooting

#### Pod-based Method
- Ensure `airflow_backup.py` exists in the same directory
- Check pod logs: `kubectl logs -n <namespace> <pod-name>`
- Verify `/tmp` directory permissions in the pod

#### PostgreSQL Direct Method
- Ensure PostgreSQL client tools are installed
- Check PostgreSQL pod IP: `kubectl get pods -o wide | grep postgresql`
- Verify database connection parameters in the script
- Test manual connection: `psql -h <host> -p 5432 -U bn_airflow -d bitnami_airflow`

### Debug Mode

```bash
# Enable bash debug mode for any script
bash -x ./run_airflow_backup.sh foo prod
bash -x ./airflow_pg_selective_backup.sh foo_prod

# Check kubectl operations
export KUBECTL_VERBOSE=6
./run_airflow_backup.sh foo prod
```

## 📋 Best Practices

### Choosing the Right Method

1. **Pod-based Method** (Preferred)
   - Use when Airflow web pods are accessible
   - Provides more detailed metadata
   - Better error handling and validation

2. **PostgreSQL Direct Method** (Emergency)
   - Use when Airflow pods are completely crashed
   - Requires PostgreSQL client tools
   - Direct database access needed

### Before Running Backup

1. **Assess Airflow Status**
   ```bash
   kubectl get pods | grep airflow
   kubectl get pods | grep postgresql
   ```

2. **Choose Appropriate Method**
   - If web pods are running → Use pod-based method
   - If only PostgreSQL is running → Use PostgreSQL direct method

3. **Verify Prerequisites**
   ```bash
   # For pod-based method
   kubectl cluster-info
   ls -la airflow_backup.py

   # For PostgreSQL direct method
   kubectl cluster-info
   psql --version
   ```

### During Backup

1. **Monitor Progress** - Both scripts provide real-time feedback
2. **Don't Interrupt** - Let the backup complete to avoid corrupted files
3. **Check Network** - Ensure stable network connection

### After Backup

1. **Verify Backup Files**
   ```bash
   # Pod-based backup
   ls -la airflow_backup_*/
   cat airflow_backup_*/backup_info.txt

   # PostgreSQL direct backup
   ls -la postgres_backup_*/
   cat postgres_backup_*/backup_info.txt
   ```

2. **Test Backup Integrity**
   ```bash
   # For JSON files (pod-based)
   jq . airflow_backup_*/variables_backup.json

   # For CSV files (PostgreSQL direct)
   head -5 postgres_backup_*/variables.csv
   wc -l postgres_backup_*/connections.csv
   ```

3. **Secure Backup Files**
   ```bash
   # Backup files contain sensitive information
   chmod 600 airflow_backup_*/*.json
   chmod 600 postgres_backup_*/*.csv
   ```

### Emergency Recovery Best Practices

1. **Always backup before fixing** - Run backup before any infrastructure changes
2. **Document the process** - Keep notes of what went wrong and how you fixed it
3. **Test restore process** - Practice restoration in non-production environments
4. **Multiple backup methods** - Use both methods when possible for redundancy

### Automation

Consider setting up automated backups:

```bash
#!/bin/bash
# Cron job example (run daily at 2 AM)
# Try pod-based method first, fallback to PostgreSQL direct

if kubectl get pods | grep airflow-web | grep Running > /dev/null; then
    /path/to/run_airflow_backup.sh foo prod
else
    /path/to/airflow_pg_selective_backup.sh foo_prod
fi
```

## 🤝 Contributing

To contribute to this project:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test both backup methods thoroughly
5. Submit a pull request

### Development Setup

```bash
# Clone the repository
git clone <repository-url>
cd airflow_backup_restore

# Make scripts executable
chmod +x *.sh

# Test pod-based method
./run_airflow_backup.sh test_project dev

# Test PostgreSQL direct method
./airflow_pg_selective_backup.sh test_project_dev
```

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 📞 Support

For support and questions:

1. Check the [Troubleshooting](#troubleshooting) section
2. Review the [manual backup guide](airflow_selective_backup_restore_raw_steps.md)
3. Try the alternative backup method if one fails
4. Open an issue in the repository
5. Contact your DevOps team

---

**⚠️ Important Security Note**: Backup files contain sensitive information including connection passwords. Always handle backup files securely and follow your organization's data protection policies.

**🚨 Emergency Recovery Note**: When Airflow web pods are completely crashed, use the PostgreSQL direct method as your primary recovery option. This method bypasses the need for functional Airflow pods and connects directly to the database. 