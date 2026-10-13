\set ON_ERROR_STOP off
\pset pager off

SELECT account_id AS a1 FROM core.accounts WHERE status = 'ACTIVE' AND balance >= 1000 ORDER BY account_id LIMIT 1 \gset
SELECT account_id AS a2 FROM core.accounts WHERE status = 'ACTIVE' AND account_id <> :a1 ORDER BY account_id LIMIT 1 \gset
SELECT account_id AS gele FROM core.accounts WHERE status = 'FROZEN' ORDER BY account_id LIMIT 1 \gset
SELECT customer_id AS c_ok FROM core.customers WHERE kyc_status = 'VERIFIED' ORDER BY customer_id LIMIT 1 \gset
SELECT customer_id AS c_ko FROM core.customers WHERE kyc_status = 'PENDING'  ORDER BY customer_id LIMIT 1 \gset
SELECT balance AS solde_a1 FROM core.accounts WHERE account_id = :a1 \gset
\echo 'comptes de test :' :a1 ',' :a2 ' (gele :' :gele ') / clients :' :c_ok ',' :c_ko

\echo
\echo '=========== 1. CONTRAINTES DES TABLES ==========='

\echo '--- [OK] client valide'
BEGIN;
INSERT INTO core.customers (first_name, last_name, email, birth_date)
VALUES ('Test', 'Valide', 'test.valide@example.com', '1990-05-01') RETURNING customer_id, email, kyc_status;
ROLLBACK;

\echo '--- [REFUS] email deja utilise'
INSERT INTO core.customers (first_name, last_name, email, birth_date)
SELECT 'Doublon', 'Test', email, '1990-05-01' FROM core.customers WHERE customer_id = :c_ok;

\echo '--- [REFUS] email invalide'
INSERT INTO core.customers (first_name, last_name, email, birth_date) VALUES ('Test', 'Mail', 'pas-un-email', '1990-05-01');

\echo '--- [REFUS] email avec des majuscules (on force les minuscules)'
INSERT INTO core.customers (first_name, last_name, email, birth_date) VALUES ('Test', 'Maj', 'Test.Maj@Example.com', '1990-05-01');

\echo '--- [REFUS] client mineur'
INSERT INTO core.customers (first_name, last_name, email, birth_date)
VALUES ('Test', 'Mineur', 'test.mineur@example.com', current_date - interval '16 years');

\echo '--- [REFUS] solde negatif a la creation du compte'
INSERT INTO core.accounts (customer_id, iban, account_type, balance)
VALUES (:c_ok, 'FR7699999999999999999999999', 'CHECKING', -5);

\echo '--- [REFUS] IBAN deja utilise'
INSERT INTO core.accounts (customer_id, iban, account_type)
SELECT :c_ok, iban, 'CHECKING' FROM core.accounts WHERE account_id = :a1;

\echo '--- [REFUS] virement avec montant negatif'
INSERT INTO core.transfers (from_account_id, to_account_id, amount) VALUES (:a1, :a2, -10);

\echo '--- [REFUS] virement vers le meme compte'
INSERT INTO core.transfers (from_account_id, to_account_id, amount) VALUES (:a1, :a1, 10);

\echo
\echo '=========== 2. TRIGGERS ==========='

\echo '--- [OK] un depot met le solde a jour tout seul (balance_after calcule par le trigger)'
BEGIN;
SELECT balance AS solde_avant FROM core.accounts WHERE account_id = :a1;
INSERT INTO core.transactions (account_id, tx_type, amount) VALUES (:a1, 'DEPOSIT', 100) RETURNING tx_id, amount, balance_after;
SELECT balance AS solde_apres FROM core.accounts WHERE account_id = :a1;
ROLLBACK;

\echo '--- [REFUS] retrait plus grand que le solde'
INSERT INTO core.transactions (account_id, tx_type, amount) VALUES (:a1, 'WITHDRAWAL', :solde_a1 + 1);

\echo '--- [REFUS] ecriture sur un compte gele'
INSERT INTO core.transactions (account_id, tx_type, amount) VALUES (:gele, 'DEPOSIT', 10);

\echo '--- [REFUS] modifier le solde a la main'
UPDATE core.accounts SET balance = 999999 WHERE account_id = :a1;

\echo '--- [REFUS] grand livre : UPDATE'
UPDATE core.transactions SET amount = 1 WHERE tx_id = 1;
\echo '--- [REFUS] grand livre : DELETE'
DELETE FROM core.transactions WHERE tx_id = 1;
\echo '--- [REFUS] grand livre : TRUNCATE (avec fraud_alerts, sinon c est la cle etrangere qui refuse avant nous)'
TRUNCATE core.transactions, core.fraud_alerts;
\echo '--- [REFUS] virements : UPDATE'
UPDATE core.transfers SET amount = 1 WHERE transfer_id = 1;
\echo '--- [REFUS] journal d audit : DELETE et TRUNCATE (on cree d abord une ligne de journal)'
BEGIN;
UPDATE core.accounts SET status = 'FROZEN' WHERE account_id = :a2;
DELETE FROM audit.audit_log;
ROLLBACK;
TRUNCATE audit.audit_log;

\echo '--- [REFUS] un virement sans ses 2 ecritures (verifie au COMMIT)'
BEGIN;
INSERT INTO core.transfers (from_account_id, to_account_id, amount) VALUES (:a1, :a2, 5);
COMMIT;

\echo '--- [REFUS] un virement avec une seule ecriture'
BEGIN;
INSERT INTO core.transfers (from_account_id, to_account_id, amount) VALUES (:a1, :a2, 5) RETURNING transfer_id AS tid \gset
INSERT INTO core.transactions (account_id, tx_type, amount, transfer_id) VALUES (:a1, 'TRANSFER_OUT', 5, :tid);
COMMIT;

\echo '--- [OK] fraude : retrait de 4999,99 = pas d alerte ; retrait de 5000 = alerte WITHDRAWAL_5000'
BEGIN;
INSERT INTO core.transactions (account_id, tx_type, amount) VALUES (:a1, 'DEPOSIT', 20000);
INSERT INTO core.transactions (account_id, tx_type, amount) VALUES (:a1, 'WITHDRAWAL', 4999.99);
SELECT count(*) AS alertes_apres_4999 FROM core.fraud_alerts WHERE account_id = :a1 AND created_at >= now();
INSERT INTO core.transactions (account_id, tx_type, amount) VALUES (:a1, 'WITHDRAWAL', 5000);
SELECT account_id, rule_code, status FROM core.fraud_alerts WHERE account_id = :a1 AND created_at >= now();
ROLLBACK;

\echo '--- [OK] fraude : 5 virements en moins de 10 minutes = alerte TRANSFERS_5_IN_10MIN (une seule)'
BEGIN;
SELECT format($f$DO $x$ DECLARE v bigint; BEGIN FOR i IN 1..6 LOOP CALL core.sp_virement(%s, %s, 1, 'test fraude', v); END LOOP; END $x$$f$, :a1, :a2) \gexec
SELECT account_id, rule_code, status FROM core.fraud_alerts WHERE account_id = :a1 AND created_at >= now();
ROLLBACK;

\echo '--- [OK] audit : un changement de statut est note (qui, quand, avant, apres)'
BEGIN;
SET LOCAL SESSION AUTHORIZATION support1;
UPDATE core.v_comptes_support SET status = 'FROZEN' WHERE account_id = :a2;
RESET SESSION AUTHORIZATION;
SELECT table_name, operation, db_user, changed_at::timestamp(0),
       old_data ->> 'status' AS avant, new_data ->> 'status' AS apres
FROM audit.audit_log ORDER BY log_id DESC LIMIT 1;
ROLLBACK;

\echo '--- [OK] audit : un depot (le solde bouge) ne remplit pas le journal'
BEGIN;
SELECT count(*) AS lignes_audit_avant FROM audit.audit_log \gset
INSERT INTO core.transactions (account_id, tx_type, amount) VALUES (:a1, 'DEPOSIT', 1);
SELECT count(*) - :lignes_audit_avant AS nouvelles_lignes_audit FROM audit.audit_log;
ROLLBACK;

\echo
\echo '=========== 3. PROCEDURES (en tant que appli1) ==========='

\echo '--- [OK] virement de 10 : les 2 soldes bougent, 2 ecritures creees'
BEGIN;
SELECT account_id, balance FROM core.accounts WHERE account_id IN (:a1, :a2) ORDER BY account_id;
SET LOCAL ROLE appli1;
CALL core.sp_virement(:a1, :a2, 10, 'test', NULL);
RESET ROLE;
SELECT account_id, balance FROM core.accounts WHERE account_id IN (:a1, :a2) ORDER BY account_id;
SELECT tx_id, account_id, tx_type, amount, balance_after, transfer_id FROM core.transactions ORDER BY tx_id DESC LIMIT 2;
ROLLBACK;

\echo '--- [REFUS] montant negatif'
SET ROLE appli1;
CALL core.sp_virement(:a1, :a2, -5, 'test', NULL);
\echo '--- [REFUS] montant a 0'
CALL core.sp_virement(:a1, :a2, 0, 'test', NULL);
\echo '--- [REFUS] meme compte'
CALL core.sp_virement(:a1, :a1, 5, 'test', NULL);
\echo '--- [REFUS] solde insuffisant'
CALL core.sp_virement(:a1, :a2, 99999999, 'test', NULL);
\echo '--- [REFUS] compte gele'
CALL core.sp_virement(:a1, :gele, 5, 'test', NULL);
\echo '--- [REFUS] compte qui n existe pas'
CALL core.sp_virement(:a1, 99999999, 5, 'test', NULL);
RESET ROLE;

\echo '--- [OK] ouverture de compte (client VERIFIED) avec 50 de depot'
BEGIN;
SET LOCAL ROLE appli1;
CALL core.sp_ouvrir_compte(:c_ok, 'savings', 50, NULL);
RESET ROLE;
SELECT account_id, customer_id, iban, account_type, balance, status FROM core.accounts ORDER BY account_id DESC LIMIT 1;
ROLLBACK;

\echo '--- [REFUS] ouverture pour un client dont le KYC n est pas valide'
SET ROLE appli1;
CALL core.sp_ouvrir_compte(:c_ko, 'CHECKING', 0, NULL);
\echo '--- [REFUS] type de compte invalide'
CALL core.sp_ouvrir_compte(:c_ok, 'LIVRET_BIDON', 0, NULL);
RESET ROLE;

\echo '--- [OK] releve (curseur)'
BEGIN;
SET LOCAL ROLE appli1;
CALL core.sp_releve(:a1, '2024-01-01', '2024-12-31', 'releve');
FETCH 5 FROM releve;
ROLLBACK;

\echo
\echo '=========== 4. DROITS ==========='

\echo '--- matrice des droits (t = oui, f = non)'
SELECT r.rol,
       has_table_privilege(r.rol, 'core.customers',     'SELECT') AS lit_customers,
       has_table_privilege(r.rol, 'core.accounts',      'SELECT') AS lit_accounts,
       has_table_privilege(r.rol, 'core.transactions',  'SELECT') AS lit_ecritures,
       has_table_privilege(r.rol, 'core.transactions',  'INSERT') AS ecrit_ecritures,
       has_table_privilege(r.rol, 'audit.audit_log',    'SELECT') AS lit_audit,
       has_table_privilege(r.rol, 'core.v_stats_comptes',  'SELECT') AS vue_stats,
       has_table_privilege(r.rol, 'core.v_clients_support','SELECT') AS vue_clients,
       has_column_privilege(r.rol, 'core.v_comptes_support', 'status',  'UPDATE') AS maj_status,
       has_column_privilege(r.rol, 'core.v_comptes_support', 'balance', 'UPDATE') AS maj_solde,
       has_function_privilege(r.rol, 'core.sp_virement(bigint,bigint,numeric,text,bigint)', 'EXECUTE') AS proc_virement
FROM (VALUES ('analyste1'), ('support1'), ('appli1'), ('auditeur1')) AS r(rol);

\echo '--- analyste1 [REFUS] lire les clients (emails)'
SET ROLE analyste1;
SELECT email FROM core.customers LIMIT 3;
\echo '--- analyste1 [REFUS] lire le journal d audit'
SELECT * FROM audit.audit_log LIMIT 1;
\echo '--- analyste1 [OK] vue anonymisee'
SELECT * FROM core.v_stats_comptes ORDER BY balance DESC LIMIT 3;
\echo '--- analyste1 [OK] vue enregistree'
SELECT * FROM core.mv_volume_mensuel ORDER BY mois DESC, tx_type LIMIT 4;
RESET ROLE;

\echo '--- support1 [REFUS] lire la vraie table clients'
SET ROLE support1;
SELECT email FROM core.customers LIMIT 3;
\echo '--- support1 [OK] vue masquee'
SELECT * FROM core.v_clients_support ORDER BY customer_id LIMIT 3;
\echo '--- support1 [REFUS] fermer un compte a travers la vue (CHECK OPTION)'
UPDATE core.v_comptes_support SET status = 'CLOSED' WHERE account_id = :a2;
\echo '--- support1 [REFUS] modifier le solde par la vue'
UPDATE core.v_comptes_support SET balance = 1000000 WHERE account_id = :a2;
\echo '--- support1 [OK] geler un compte (annule ensuite)'
BEGIN;
UPDATE core.v_comptes_support SET status = 'FROZEN' WHERE account_id = :a2 RETURNING account_id, status;
ROLLBACK;
RESET ROLE;

\echo '--- appli1 [REFUS] lire / modifier les tables directement'
SET ROLE appli1;
SELECT * FROM core.accounts LIMIT 1;
UPDATE core.accounts SET status = 'ACTIVE';
DELETE FROM core.transactions;
RESET ROLE;

\echo '--- auditeur1 [OK] lire le journal, les alertes et les ecritures'
SET ROLE auditeur1;
SELECT count(*) AS lignes_journal FROM audit.audit_log;
SELECT count(*) AS alertes FROM core.fraud_alerts;
\echo '--- auditeur1 [REFUS] lire les clients ; modifier le journal'
SELECT * FROM core.customers LIMIT 1;
UPDATE audit.audit_log SET db_user = 'personne';
RESET ROLE;

\echo
\echo '=========== 5. COHERENCE FINALE ==========='
\echo '--- (0 ligne attendue) comptes dont le solde ne correspond pas aux ecritures'
SELECT a.account_id, a.balance, s.somme
FROM core.accounts a
JOIN (SELECT account_id,
             sum(CASE WHEN tx_type IN ('DEPOSIT', 'TRANSFER_IN') THEN amount ELSE -amount END) AS somme
      FROM core.transactions GROUP BY account_id) s USING (account_id)
WHERE a.balance <> s.somme;
\echo '--- (0 ligne attendue) virements qui n ont pas exactement 2 ecritures'
SELECT t.transfer_id, count(x.tx_id) AS nb
FROM core.transfers t LEFT JOIN core.transactions x USING (transfer_id)
GROUP BY t.transfer_id HAVING count(x.tx_id) <> 2;
\echo '--- (1 000 000 attendu) ecritures'
SELECT count(*) AS ecritures FROM core.transactions;
