SET ROLE bank_owner;

CREATE VIEW core.v_clients_support
WITH (security_barrier = true) AS
SELECT customer_id,
       first_name,
       left(last_name, 1) || '***'                          AS last_name,
       left(email, 2) || '***' || substr(email, strpos(email, '@')) AS email,
       '******' || right(phone, 2)                          AS phone,
       kyc_status,
       risk_level
FROM core.customers;

CREATE VIEW core.v_comptes_support AS
SELECT account_id, customer_id, iban, account_type, balance, status, opened_at
FROM core.accounts
WHERE status IN ('ACTIVE', 'FROZEN')
WITH LOCAL CHECK OPTION;

CREATE VIEW core.v_stats_comptes
WITH (security_barrier = true) AS
SELECT a.account_id,
       a.account_type,
       a.status,
       a.balance,
       c.risk_level,
       CASE WHEN extract(year FROM age(c.birth_date)) < 25 THEN '18-24'
            WHEN extract(year FROM age(c.birth_date)) < 35 THEN '25-34'
            WHEN extract(year FROM age(c.birth_date)) < 50 THEN '35-49'
            WHEN extract(year FROM age(c.birth_date)) < 65 THEN '50-64'
            ELSE '65+' END AS tranche_age
FROM core.accounts a
JOIN core.customers c USING (customer_id);

CREATE MATERIALIZED VIEW core.mv_volume_mensuel AS
SELECT date_trunc('month', created_at)::date AS mois,
       tx_type,
       count(*)    AS nb_ecritures,
       sum(amount) AS total
FROM core.transactions
GROUP BY 1, 2;

CREATE UNIQUE INDEX uq_mv_volume_mensuel ON core.mv_volume_mensuel (mois, tx_type);

GRANT SELECT ON core.v_stats_comptes, core.mv_volume_mensuel TO grp_analyste;
GRANT SELECT ON core.v_clients_support TO grp_support;
GRANT SELECT ON core.v_comptes_support TO grp_support;
GRANT UPDATE (status) ON core.v_comptes_support TO grp_support;
