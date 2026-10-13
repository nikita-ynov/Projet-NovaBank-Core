SET ROLE bank_owner;
ANALYZE core.customers, core.accounts, core.transactions;

SELECT account_id AS cpt FROM core.transactions GROUP BY account_id ORDER BY count(*) DESC LIMIT 1 \gset
SELECT email AS mail FROM core.customers WHERE customer_id = 777 \gset
\echo 'compte teste :' :cpt ' / email teste :' :mail

\echo ''
\echo '################  AVANT  ################'

\echo '--- Q1 : releve d un compte (filtre par compte, trie par date)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON)
SELECT * FROM core.transactions WHERE account_id = :cpt ORDER BY created_at DESC;

\echo '--- Q2 : recherche d un email sans tenir compte de la casse'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON)
SELECT * FROM core.customers WHERE lower(email) = lower(:'mail');

\echo '--- Q3 : les comptes geles'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON)
SELECT account_id, iban FROM core.accounts WHERE status = 'FROZEN';

\echo '--- Q4 : somme des ecritures d un mois'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON)
SELECT sum(amount) FROM core.transactions
WHERE created_at >= '2025-03-01' AND created_at < '2025-04-01';

CREATE INDEX idx_tx_account_date ON core.transactions (account_id, created_at DESC);

CREATE INDEX idx_customers_email_lower ON core.customers (lower(email));

CREATE INDEX idx_accounts_frozen ON core.accounts (account_id) WHERE status = 'FROZEN';

CREATE INDEX idx_tx_created_brin ON core.transactions USING brin (created_at);

CREATE INDEX idx_tx_transfer ON core.transactions (transfer_id) WHERE transfer_id IS NOT NULL;
CREATE INDEX idx_accounts_customer ON core.accounts (customer_id);

ANALYZE core.customers, core.accounts, core.transactions;

\echo ''
\echo '################  APRES  ################'

\echo '--- Q1 : releve d un compte'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON)
SELECT * FROM core.transactions WHERE account_id = :cpt ORDER BY created_at DESC;

\echo '--- Q2 : recherche email'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON)
SELECT * FROM core.customers WHERE lower(email) = lower(:'mail');

\echo '--- Q3 : comptes geles'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON)
SELECT account_id, iban FROM core.accounts WHERE status = 'FROZEN';

\echo '--- Q4 : somme sur un mois'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON)
SELECT sum(amount) FROM core.transactions
WHERE created_at >= '2025-03-01' AND created_at < '2025-04-01';

\echo ''
\echo '################  TAILLE DES INDEX  ################'
SELECT indexrelid::regclass AS index, pg_size_pretty(pg_relation_size(indexrelid)) AS taille
FROM pg_index
WHERE indrelid IN ('core.transactions'::regclass, 'core.customers'::regclass, 'core.accounts'::regclass)
ORDER BY pg_relation_size(indexrelid) DESC;
SELECT pg_size_pretty(pg_relation_size('core.transactions')) AS taille_table_transactions;

\echo ''
\echo '################  UN INDEX INUTILE  ################'

CREATE INDEX idx_inutile_status ON core.accounts (status);
ANALYZE core.accounts;
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM core.accounts WHERE status = 'ACTIVE';
DROP INDEX core.idx_inutile_status;
