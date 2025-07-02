# Airflow Selective Backup & Restore Guide

This guide provides step-by-step instructions for backing up and restoring Airflow configurations including variables, connections, pools, and DAG metadata.

## Table of Contents
- [Prerequisites](#prerequisites)
- [Backup Process](#backup-process)
- [Restore Process](#restore-process)
- [Troubleshooting](#troubleshooting)

## Prerequisites

Before starting, ensure you have:
- Access to the Kubernetes cluster
- `kubectl` configured with appropriate permissions
- `kubectx` tool installed (optional but recommended)

## Backup Process

### 1. Setup Environment Variables

```bash
# Configure your project settings
project=foo
env=prod
namespace=$env
project_name="${project}_${env}"
project_context="${project}-${env}-aks"
```

### 2. Connect to Kubernetes Cluster

```bash
# Switch to the correct context
kubectx $project_context

# Get the Airflow web pod name
airflow_web_pod=$(kubectl get pods -n $namespace | grep airflow-web | grep Running | awk '{print $1}')

# Exec into the Airflow pod
kubectl exec -it $airflow_web_pod -n $namespace -- /bin/bash
```

### 3. Prepare Airflow Environment

Once inside the pod:

```bash
# Activate the Airflow virtual environment
source /opt/bitnami/airflow/venv/bin/activate

# Change to tmp directory (allows Airflow to write files)
cd /tmp
```

### 4. Backup Airflow Variables

```bash
python3 <<EOF
from airflow.models import Variable
from airflow.utils.db import create_session
import json

variables = {}
with create_session() as session:
    for var in session.query(Variable).all():
        variables[var.key] = var.val

with open("variables_backup.json", "w") as f:
    json.dump(variables, f, indent=2)
print("✅ variables_backup.json written to /tmp")
EOF
```

### 5. Backup Airflow Connections

```bash
python3 <<EOF
from airflow.models import Connection
from airflow.utils.db import create_session
import json

connections = []
with create_session() as session:
    for conn in session.query(Connection).all():
        connections.append({
            "conn_id": conn.conn_id,
            "conn_type": conn.conn_type,
            "host": conn.host,
            "login": conn.login,
            "password": conn.password,
            "schema": conn.schema,
            "port": conn.port,
            "extra": conn.extra
        })

with open("connections_backup.json", "w") as f:
    json.dump(connections, f, indent=2)
print("✅ connections_backup.json written to /tmp")
EOF
```

### 6. Backup Airflow Pools

```bash
python3 <<EOF
from airflow.models import Pool
from airflow.utils.db import create_session
import json

pools = []
with create_session() as session:
    for pool in session.query(Pool).all():
        pools.append({
            "pool": pool.pool,
            "slots": pool.slots,
            "description": pool.description
        })

with open("pools_backup.json", "w") as f:
    json.dump(pools, f, indent=2)
print("✅ pools_backup.json written to /tmp")
EOF
```

### 7. Exit Pod and Copy Backup Files

```bash
# Exit from the Airflow pod
exit

# Create backup directory
mkdir airflow_backup_${project_name}

# Copy backup files from pod to local directory
kubectl cp $airflow_web_pod:/tmp/variables_backup.json ./airflow_backup_${project_name}/variables_backup.json -n $namespace
kubectl cp $airflow_web_pod:/tmp/connections_backup.json ./airflow_backup_${project_name}/connections_backup.json -n $namespace
kubectl cp $airflow_web_pod:/tmp/pools_backup.json ./airflow_backup_${project_name}/pools_backup.json -n $namespace
```

## Restore Process

### 1. Prepare for Restore

After recreating the PostgreSQL and Redis instances (keeping DAG PVC intact):

```bash
# Set project name for restore
project_name="foo_prod"

# Get the new Airflow web pod name
airflow_web_pod=$(kubectl get pods | grep airflow-web | grep Running | awk '{print $1}')
```

### 2. Copy Backup Files to Pod

```bash
# Copy backup files to the Airflow pod
kubectl cp ./airflow_backup_${project_name}/variables_backup.json $airflow_web_pod:/tmp/variables_backup.json
kubectl cp ./airflow_backup_${project_name}/connections_backup.json $airflow_web_pod:/tmp/connections_backup.json
kubectl cp ./airflow_backup_${project_name}/pools_backup.json $airflow_web_pod:/tmp/pools_backup.json
kubectl cp ./airflow_backup_${project_name}/dag_models_backup.json $airflow_web_pod:/tmp/dag_models_backup.json
```

### 3. Initialize Airflow Database

```bash
# Exec into the Airflow pod
kubectl exec -it $airflow_web_pod -- /bin/bash

# Activate virtual environment
source /opt/bitnami/airflow/venv/bin/activate

# Initialize the Airflow database
airflow db init
```

### 4. Restore Variables

```bash
cd /tmp
python3 <<EOF
from airflow.models import Variable
import json

with open("variables_backup.json", "r") as f:
    data = json.load(f)

for key, value in data.items():
    Variable.set(key, value)
print("✅ Restored variables from variables_backup.json")
EOF
```

### 5. Restore Connections

```bash
python3 <<EOF
from airflow.models import Connection
from airflow.utils.db import create_session
import json

with open("connections_backup.json", "r") as f:
    connections = json.load(f)

with create_session() as session:
    for c in connections:
        existing = session.query(Connection).filter_by(conn_id=c["conn_id"]).first()
        if existing:
            print(f"🔁 Updating existing connection: {c['conn_id']}")
            existing.conn_type = c["conn_type"]
            existing.host = c["host"]
            existing.login = c["login"]
            existing.password = c["password"]
            existing.schema = c["schema"]
            existing.port = c["port"]
            existing.extra = c["extra"]
        else:
            print(f"➕ Inserting new connection: {c['conn_id']}")
            new_conn = Connection(
                conn_id=c["conn_id"],
                conn_type=c["conn_type"],
                host=c["host"],
                login=c["login"],
                password=c["password"],
                schema=c["schema"],
                port=c["port"],
                extra=c["extra"]
            )
            session.add(new_conn)

print("✅ All connections restored successfully.")
EOF
```

### 6. Restore DAG Models (Optional)

```bash
python3 <<EOF
from airflow.models.dag import DagModel
from airflow.utils.db import create_session
import json
import os
from datetime import datetime

backup_file = "/tmp/dag_models_backup.json"
if not os.path.exists(backup_file):
    print("⚠️  DAG models backup file not found, skipping...")
else:
    with open(backup_file, "r") as f:
        dag_models = json.load(f)

    with create_session() as session:
        for dag in dag_models:
            existing = session.query(DagModel).filter(DagModel.dag_id == dag['dag_id']).first()

            parsed_time = dag.get('last_parsed_time')
            pickled = dag.get('last_pickled')
            expired = dag.get('last_expired')
            scheduler_lock = dag.get('scheduler_lock')

            if not existing:
                restored = DagModel(
                    dag_id=dag['dag_id'],
                    is_paused=dag['is_paused'],
                    is_active=dag['is_active'],
                    last_parsed_time=datetime.fromisoformat(parsed_time) if parsed_time else None,
                    last_pickled=datetime.fromisoformat(pickled) if pickled else None,
                    last_expired=datetime.fromisoformat(expired) if expired else None,
                    scheduler_lock=scheduler_lock,
                    fileloc=dag['fileloc'],
                    owners=dag['owners']
                )
                session.add(restored)
            else:
                existing.is_paused = dag['is_paused']
                existing.is_active = dag['is_active']
                existing.last_parsed_time = datetime.fromisoformat(parsed_time) if parsed_time else None
                existing.last_pickled = datetime.fromisoformat(pickled) if pickled else None
                existing.last_expired = datetime.fromisoformat(expired) if expired else None
                existing.scheduler_lock = scheduler_lock
                existing.fileloc = dag['fileloc']
                existing.owners = dag['owners']

    print("✅ DAG metadata restored from dag_models_backup.json")
EOF
```

## Troubleshooting

### Common Issues

#### 1. Scheduler Failing with "relation does not exist" Error

**Symptoms:**
```
psycopg2.errors.UndefinedTable: relation "job" does not exist
psycopg2.errors.UndefinedTable: relation "log" does not exist
```

**Solution:**
This typically occurs when the database schema hasn't been properly initialized. Run:

```bash
airflow db init
```

#### 2. Pod Not Found

**Symptoms:**
- `kubectl exec` fails with pod not found

**Solution:**
- Verify the pod is running: `kubectl get pods | grep airflow`
- Update the pod name variable: `airflow_web_pod=$(kubectl get pods | grep airflow-web | grep Running | awk '{print $1}')`

#### 3. Permission Issues

**Symptoms:**
- Cannot write to `/tmp` directory
- Python scripts fail with permission errors

**Solution:**
- Ensure you're in the `/tmp` directory: `cd /tmp`
- Verify the virtual environment is activated: `source /opt/bitnami/airflow/venv/bin/activate`

### Best Practices

1. **Always backup before major changes** - Run the backup process before any significant infrastructure changes
2. **Verify backups** - Check that backup files are created and contain expected data
3. **Test restore process** - Practice the restore process in a non-production environment
4. **Keep DAG PVC intact** - Preserve the DAG persistent volume to maintain DAG files
5. **Monitor logs** - Watch Airflow logs during and after restore to ensure everything is working correctly

### Notes

- The backup process captures the current state of variables, connections, and pools
- DAG files are preserved through the DAG PVC, so they don't need to be backed up separately
- Connection passwords are included in the backup, so handle backup files securely
- The restore process will overwrite existing configurations with backed-up data





