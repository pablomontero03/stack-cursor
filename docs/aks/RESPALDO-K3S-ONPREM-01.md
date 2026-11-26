# Respaldo y restauración del estado de k3s — prod-onprem-01 (.31)

> k3s de nodo único usa datastore **SQLite** (no etcd). Todo el estado del cluster
> (deployments, secrets, configmaps, ingress, RBAC, PVCs) vive en un archivo:
> `/var/lib/rancher/k3s/server/db/state.db`

## Respaldo (automático)

- **Script:** `/var/lib/rancher/k3s-backups/k3s-sqlite-backup.sh` (fuente versionada en
  `.local/aks/backup/k3s-sqlite-backup.sh`).
- **Método:** `sqlite3 .backup` (copia online consistente, respeta el WAL — NO un `cp` crudo).
- **Cron:** `/etc/cron.d/k3s-sqlite-backup` → diario a las **02:00** (root), log en
  `/var/log/k3s-sqlite-backup.log`.
- **Retención:** 14 snapshots comprimidos (gzip). Cada uno ~3-4 MB → ~50 MB total.
- **Destino:** `/var/lib/rancher/k3s-backups/k3s-state-<TS>.db.gz` (LOCAL en el .31).
  PENDIENTE: copiar fuera del nodo (si el disco muere, el backup local se pierde con él).

### Ejecutar a mano
```
sudo bash /var/lib/rancher/k3s-backups/k3s-sqlite-backup.sh
```

## Restauración (manual — procedimiento de desastre)

> Solo en caso de corrupción/pérdida del estado. Detiene el cluster brevemente.

```bash
# 1. detener k3s
sudo systemctl stop k3s

# 2. respaldar el state.db actual por si acaso
sudo cp /var/lib/rancher/k3s/server/db/state.db /var/lib/rancher/k3s/server/db/state.db.bad

# 3. descomprimir el snapshot elegido a state.db
sudo sh -c 'zcat /var/lib/rancher/k3s-backups/k3s-state-<TS>.db.gz > /var/lib/rancher/k3s/server/db/state.db'
# limpiar WAL/SHM viejos para que k3s reconstruya desde el .db restaurado
sudo rm -f /var/lib/rancher/k3s/server/db/state.db-wal /var/lib/rancher/k3s/server/db/state.db-shm

# 4. arrancar k3s
sudo systemctl start k3s

# 5. verificar
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
```

## Notas
- sqlite3 v3.45 instalado en el nodo (requerido por `.backup`).
- El backup NO incluye los datos DENTRO de los PVCs (Kafka/ZK/ES local-path) — solo el
  ESTADO del cluster. El dato de DataHub vive en MySQL Azure externo (respaldado aparte).
