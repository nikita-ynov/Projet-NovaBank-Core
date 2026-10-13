#!/bin/bash
set -euo pipefail

BASE="bankdb"
TEMP="bankdb_restore_test"
DOSSIER="/var/backups/novabank"
FICHIER="$DOSSIER/${BASE}_$(date +%Y%m%d_%H%M%S).dump"

if [ "$EUID" -ne 0 ]; then
    echo "A lancer avec sudo" >&2
    exit 1
fi

mkdir -p "$DOSSIER"
chown postgres:postgres "$DOSSIER"
chmod 700 "$DOSSIER"

echo "[1] pg_dump -> $FICHIER"
sudo -u postgres pg_dump -Fc -f "$FICHIER" "$BASE"
ls -lh "$FICHIER"

echo "[2] restauration dans la base temporaire $TEMP"
sudo -u postgres psql -X -q -c "DROP DATABASE IF EXISTS $TEMP;"
sudo -u postgres createdb "$TEMP"
sudo -u postgres pg_restore --no-owner -d "$TEMP" "$FICHIER"

echo "[3] comparaison des nombres de lignes"
REQ="SELECT 'customers', count(*) FROM core.customers
     UNION ALL SELECT 'accounts', count(*) FROM core.accounts
     UNION ALL SELECT 'transfers', count(*) FROM core.transfers
     UNION ALL SELECT 'transactions', count(*) FROM core.transactions
     UNION ALL SELECT 'fraud_alerts', count(*) FROM core.fraud_alerts
     UNION ALL SELECT 'audit_log', count(*) FROM audit.audit_log
     ORDER BY 1"
sudo -u postgres psql -X -At -d "$BASE" -c "$REQ" > /tmp/compte_source.txt
sudo -u postgres psql -X -At -d "$TEMP" -c "$REQ" > /tmp/compte_restaure.txt
paste -d' ' /tmp/compte_source.txt /tmp/compte_restaure.txt | column -t -s' ' || true
if diff -q /tmp/compte_source.txt /tmp/compte_restaure.txt > /dev/null; then
    echo "=> identique : la sauvegarde est bonne"
else
    echo "=> DIFFERENT : probleme de sauvegarde" >&2
    exit 1
fi

echo "[4] nettoyage de la base temporaire"
sudo -u postgres psql -X -q -c "DROP DATABASE $TEMP;"
rm -f /tmp/compte_source.txt /tmp/compte_restaure.txt
