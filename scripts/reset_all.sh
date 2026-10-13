#!/bin/bash
set -euo pipefail

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
SQL_DIR="$RACINE/sql"
LOG_DIR="$RACINE/logs"
BASE="bankdb"
ROLES="bank_owner analyste1 support1 appli1 auditeur1 grp_analyste grp_support grp_appli grp_auditeur"

if [ "$EUID" -ne 0 ]; then
    echo "A lancer avec sudo (on se connecte en postgres via le socket)" >&2
    exit 1
fi

pg() { sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 "$@"; }

if [ "${1:-}" != "--oui" ]; then
    echo "ATTENTION : la base '$BASE' et les roles du projet vont etre SUPPRIMES, puis recrees."
    read -r -p "Taper OUI pour continuer : " reponse
    if [ "$reponse" != "OUI" ]; then
        echo "Annule."
        exit 1
    fi
fi

mkdir -p "$LOG_DIR"

echo "[1] Suppression de la base et des roles"
pg -d postgres -c "DROP DATABASE IF EXISTS $BASE WITH (FORCE);"
for r in $ROLES; do
    pg -d postgres -c "DROP ROLE IF EXISTS $r;"
done

export PHONE_KEY="${PHONE_KEY:-$(openssl rand -hex 16)}"

echo "[2] Execution des fichiers SQL"
for f in "$SQL_DIR"/[0-9][0-9]_*.sql; do
    nom="$(basename "$f")"
    case "$nom" in
        08_tests.sql) continue ;;
    esac
    if [ "$nom" = "00_roles_et_base.sql" ]; then db="postgres"; else db="$BASE"; fi
    echo "    -> $nom (base $db)"
    pg -d "$db" < "$f" > "$LOG_DIR/${nom%.sql}.log" 2>&1 || {
        echo "ERREUR dans $nom, voir $LOG_DIR/${nom%.sql}.log" >&2
        tail -n 15 "$LOG_DIR/${nom%.sql}.log" >&2
        exit 1
    }
done

echo "[3] Mots de passe des comptes"
for r in bank_owner analyste1 support1 appli1 auditeur1; do
    var="NB_PW_${r}"
    mdp="${!var:-}"
    if [ -z "$mdp" ]; then
        if [ -t 0 ]; then
            read -r -s -p "    mot de passe pour $r : " mdp
            echo
        else
            echo "    $r : pas de mot de passe (terminal non interactif) -> connexion impossible tant qu'il n'est pas defini"
            continue
        fi
    fi
    NB_TMP_PW="$mdp" sudo --preserve-env=NB_TMP_PW -u postgres psql -X -q -d postgres <<SQL
\getenv pw NB_TMP_PW
ALTER ROLE $r PASSWORD :'pw';
SQL
done

echo "Termine. Base '$BASE' prete. Tests : sudo bash scripts/lancer_tests.sh"
