# airflow_backup.py

from airflow.models import Variable, Connection, Pool
from airflow.models.dag import DagModel
from airflow.utils.db import create_session
import json
import os

backup_dir = "/tmp"
os.makedirs(backup_dir, exist_ok=True)

# Backup Variables
variables = {}
with create_session() as session:
    for var in session.query(Variable).all():
        variables[var.key] = var.val
with open(f"{backup_dir}/variables_backup.json", "w") as f:
    json.dump(variables, f, indent=2)

# Backup Connections
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
with open(f"{backup_dir}/connections_backup.json", "w") as f:
    json.dump(connections, f, indent=2)

# Backup Pools
pools = []
with create_session() as session:
    for pool in session.query(Pool).all():
        pools.append({
            "pool": pool.pool,
            "slots": pool.slots,
            "description": pool.description
        })
with open(f"{backup_dir}/pools_backup.json", "w") as f:
    json.dump(pools, f, indent=2)

# Backup DAG Models
dags = []
with create_session() as session:
    for dag in session.query(
        DagModel.dag_id,
        DagModel.is_paused,
        DagModel.is_active,
        DagModel.is_subdag,
        DagModel.fileloc,
        DagModel.owners,
        DagModel.schedule_interval
    ).all():
        dags.append({
            "dag_id": dag.dag_id,
            "is_paused": dag.is_paused,
            "is_active": dag.is_active,
            "is_subdag": dag.is_subdag,
            "fileloc": dag.fileloc,
            "owners": dag.owners,
            "schedule_interval": str(dag.schedule_interval),
        })

with open("/tmp/dag_models_backup.json", "w") as f:
    json.dump(dags, f, indent=2)

print("✅ DAG metadata backed up successfully for Airflow 2.1.0")

print(f"✅ All backups written to {backup_dir}/*.json")