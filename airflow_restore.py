from airflow.models import Variable, Connection, Pool, DagModel
from airflow.utils.db import create_session
from datetime import datetime
import json, os

# === Restore Variables ===
if os.path.exists('variables_backup.json'):
    with open('variables_backup.json', 'r') as f:
        variables = json.load(f)
    for key, value in variables.items():
        Variable.set(key, value)
    print('✅ Restored variables from variables_backup.json')
else:
    print('⚠️ variables_backup.json not found')

# === Restore Connections ===
if os.path.exists('connections_backup.json'):
    with open('connections_backup.json', 'r') as f:
        connections = json.load(f)
    with create_session() as session:
        for c in connections:
            existing = session.query(Connection).filter_by(conn_id=c['conn_id']).first()
            if existing:
                print(f'🔁 Updating existing connection: {c["conn_id"]}')
                existing.conn_type = c["conn_type"]
                existing.host = c["host"]
                existing.login = c["login"]
                existing.password = c["password"]
                existing.schema = c["schema"]
                existing.port = c["port"]
                existing.extra = c["extra"]
            else:
                print(f'➕ Inserting new connection: {c["conn_id"]}')
                new_conn = Connection(**c)
                session.add(new_conn)
    print('✅ All connections restored successfully.')
else:
    print('⚠️ connections_backup.json not found')

# === Restore Pools ===
if os.path.exists('pools_backup.json'):
    with open('pools_backup.json', 'r') as f:
        pools = json.load(f)
    with create_session() as session:
        for p in pools:
            existing = session.query(Pool).filter_by(pool=p['pool']).first()
            if existing:
                print(f'🔁 Updating existing pool: {p["pool"]}')
                existing.slots = p['slots']
                existing.description = p['description']
            else:
                print(f'➕ Inserting new pool: {p["pool"]}')
                session.add(Pool(**p))
    print('✅ All pools restored successfully.')
else:
    print('⚠️ pools_backup.json not found')

# === Restore DAG Metadata ===
if os.path.exists('dag_models_backup.json'):
    with open('dag_models_backup.json', 'r') as f:
        dags = json.load(f)
    with create_session() as session:
        for dag in dags:
            existing = session.query(DagModel).filter_by(dag_id=dag['dag_id']).first()
            for time_field in ['last_parsed_time', 'last_pickled', 'last_expired']:
                if dag[time_field]:
                    dag[time_field] = datetime.fromisoformat(dag[time_field])
                else:
                    dag[time_field] = None
            if existing:
                print(f'🔁 Updating existing DAG: {dag["dag_id"]}')
                for k, v in dag.items():
                    setattr(existing, k, v)
            else:
                print(f'➕ Inserting new DAG: {dag["dag_id"]}')
                session.add(DagModel(**dag))
    print('✅ DAG metadata restored from dag_models_backup.json')
else:
    print('⚠️ dag_models_backup.json not found')

print('🎉 Restore complete!')