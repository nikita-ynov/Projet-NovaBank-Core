#!/bin/bash
set -euo pipefail

BASE="${PGDATABASE:-bankdb}"
PSQL_CMD="${PSQL_CMD:-sudo -u postgres psql}"
q() { $PSQL_CMD -d "$BASE" -X -q -At -v ON_ERROR_STOP=1 "$@"; }

echo "== preparation : 1 client, 2 comptes de 100 =="
CLIENT=$(q -c "INSERT INTO core.customers (first_name, last_name, email, birth_date, kyc_status)
               VALUES ('Test', 'Concurrence', 'concurrence.$(date +%s)@example.com', '1990-01-01', 'VERIFIED')
               RETURNING customer_id")
A=$(q -c "CALL core.sp_ouvrir_compte($CLIENT, 'CHECKING', 100, NULL)")
B=$(q -c "CALL core.sp_ouvrir_compte($CLIENT, 'CHECKING', 100, NULL)")
echo "client $CLIENT, comptes A=$A B=$B"

echo
echo "== A) deux virements de 80 depuis A (solde 100) en meme temps =="
( q -c "BEGIN; CALL core.sp_virement($A, $B, 80, 'concurrence 1', NULL); SELECT pg_sleep(4); COMMIT;" >/tmp/conc1.out 2>&1 && echo "session 1 : OK" || echo "session 1 : REFUSE" ) &
sleep 1
( q -c "CALL core.sp_virement($A, $B, 80, 'concurrence 2', NULL)" >/tmp/conc2.out 2>&1 && echo "session 2 : OK" || echo "session 2 : REFUSE ($(grep -o 'Solde insuffisant[^(]*' /tmp/conc2.out | head -1))" ) &
wait
echo "soldes apres :"
q -c "SELECT 'A' AS compte, balance FROM core.accounts WHERE account_id = $A UNION ALL SELECT 'B', balance FROM core.accounts WHERE account_id = $B"
NEG=$(q -c "SELECT count(*) FROM core.accounts WHERE balance < 0")
echo "comptes avec un solde negatif dans toute la base : $NEG"

echo
echo "== B) 2 x 100 virements croises (A->B et B->A) en parallele =="
q -c "INSERT INTO core.transactions (account_id, tx_type, amount) VALUES ($A, 'DEPOSIT', 1000), ($B, 'DEPOSIT', 1000)"
boucle() {
    for i in $(seq 1 100); do
        echo "CALL core.sp_virement($1, $2, 1, 'croise', NULL);"
    done
}
boucle "$A" "$B" | q >/tmp/croise1.out 2>&1 &
boucle "$B" "$A" | q >/tmp/croise2.out 2>&1 &
wait
DEAD=$(cat /tmp/croise1.out /tmp/croise2.out | grep -ci "deadlock" || true)
echo "deadlocks detectes : $DEAD (0 attendu)"
echo "soldes apres :"
q -c "SELECT 'A' AS compte, balance FROM core.accounts WHERE account_id = $A UNION ALL SELECT 'B', balance FROM core.accounts WHERE account_id = $B"
