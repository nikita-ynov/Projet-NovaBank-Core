#!/bin/bash
set -euo pipefail

DOSSIER="${1:-$HOME/rapports}"
DATE="$(date +%Y%m%d)"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGDATABASE="bankdb"
export PGUSER="analyste1"

if [ ! -f "$HOME/.pgpass" ]; then
    echo "Pas de ~/.pgpass : cree-le (voir le commentaire en haut du script)" >&2
    exit 1
fi

mkdir -p "$DOSSIER"

echo "Rapport 1 : volume par mois et par type d'ecriture"
psql -X -c "\copy (SELECT mois, tx_type, nb_ecritures, total FROM core.mv_volume_mensuel ORDER BY mois, tx_type) TO '$DOSSIER/volume_mensuel_$DATE.csv' WITH (FORMAT csv, HEADER)"

echo "Rapport 2 : soldes par tranche d'age et type de compte"
psql -X -c "\copy (SELECT tranche_age, account_type, count(*) AS nb_comptes, round(avg(balance), 2) AS solde_moyen FROM core.v_stats_comptes WHERE status = 'ACTIVE' GROUP BY 1, 2 ORDER BY 1, 2) TO '$DOSSIER/soldes_par_age_$DATE.csv' WITH (FORMAT csv, HEADER)"

echo "Fichiers crees dans $DOSSIER :"
ls -l "$DOSSIER"/*_"$DATE".csv
