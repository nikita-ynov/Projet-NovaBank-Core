#!/bin/bash
set -euo pipefail

PG_VERSION="${PG_VERSION:-18}"
ADMIN_NET="${ADMIN_NET:-192.168.56.0/24}"

if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit etre lance en root (sudo bash $0)" >&2
    exit 1
fi

echo "[1/6] Mise a jour de la liste des paquets"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

echo "[2/6] Installation de PostgreSQL $PG_VERSION, du client et de ufw"
apt-get install -y -qq postgresql-common ufw curl ca-certificates > /dev/null
if ! apt-cache show "postgresql-$PG_VERSION" > /dev/null 2>&1; then
    echo "      postgresql-$PG_VERSION absent des depots Ubuntu -> ajout du depot PGDG"
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y > /dev/null
fi
apt-get install -y -qq "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION" > /dev/null

read -r VERSION CLUSTER PORT _ < <(pg_lsclusters --no-header | awk -v v="$PG_VERSION" '$1 == v {print; exit}')
CONF_DIR="/etc/postgresql/$VERSION/$CLUSTER"
echo "      cluster trouve : version $VERSION, nom $CLUSTER, port $PORT"

echo "[3/6] Reglages dans conf.d (le fichier principal n'est pas touche)"
mkdir -p "$CONF_DIR/conf.d"
cat > "$CONF_DIR/conf.d/90-novabank.conf" <<EOF
listen_addresses = '*'
password_encryption = 'scram-sha-256'
log_connections = on
log_disconnections = on
log_statement = 'ddl'
log_line_prefix = '%m [%p] %q%u@%d '
EOF

echo "[4/6] Regles de connexion (pg_hba.conf)"
HBA="$CONF_DIR/pg_hba.conf"
[ -f "$HBA.orig" ] || cp "$HBA" "$HBA.orig"
cat > "$HBA" <<EOF

local   all       postgres                                                       peer

host    bankdb    bank_owner,+grp_appli                         127.0.0.1/32     scram-sha-256
host    bankdb    bank_owner,+grp_appli                         ::1/128          scram-sha-256

host    bankdb    +grp_analyste,+grp_support,+grp_auditeur      $ADMIN_NET       scram-sha-256

local   all       all                                                            reject
host    all       all                                           0.0.0.0/0        reject
host    all       all                                           ::/0             reject
EOF
chown postgres:postgres "$HBA"
chmod 640 "$HBA"

echo "[5/6] Pare-feu ufw"
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow OpenSSH > /dev/null
ufw allow from "$ADMIN_NET" to any port "$PORT" proto tcp > /dev/null
ufw --force enable > /dev/null

echo "[6/6] Redemarrage et verifications"
systemctl restart "postgresql@$VERSION-$CLUSTER"
sleep 2
pg_lsclusters
sudo -u postgres psql -Atc "SHOW listen_addresses;"
echo "Erreurs dans pg_hba_file_rules (aucune ligne attendue) :"
sudo -u postgres psql -Atc "SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL;"
ufw status verbose

echo "Termine. Etape suivante : sudo bash scripts/reset_all.sh"
