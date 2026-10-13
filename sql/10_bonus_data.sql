SET ROLE bank_owner;
\pset pager off

\echo '--- D1.1 : le compte le plus riche de chaque tranche d age (rank)'
WITH par_age AS (
    SELECT a.account_id, a.balance,
           CASE WHEN extract(year FROM age(c.birth_date)) < 25 THEN '18-24'
                WHEN extract(year FROM age(c.birth_date)) < 35 THEN '25-34'
                WHEN extract(year FROM age(c.birth_date)) < 50 THEN '35-49'
                WHEN extract(year FROM age(c.birth_date)) < 65 THEN '50-64'
                ELSE '65+' END AS tranche_age
    FROM core.accounts a
    JOIN core.customers c USING (customer_id)
), classe AS (
    SELECT *, rank() OVER (PARTITION BY tranche_age ORDER BY balance DESC) AS rang
    FROM par_age
)
SELECT tranche_age, account_id, balance
FROM classe
WHERE rang = 1
ORDER BY tranche_age;

\echo '--- D1.2 : les depots montent-ils ? total par mois, variation vs mois precedent (lag) et moyenne sur 3 mois'
WITH depots AS (
    SELECT date_trunc('month', created_at)::date AS mois, sum(amount) AS total
    FROM core.transactions
    WHERE tx_type = 'DEPOSIT'
      AND created_at >= '2024-02-01'
      AND created_at <  '2026-09-01'
    GROUP BY 1
)
SELECT mois, total,
       lag(total) OVER (ORDER BY mois) AS mois_precedent,
       round(100 * (total - lag(total) OVER (ORDER BY mois)) / lag(total) OVER (ORDER BY mois), 1) AS variation_pct,
       round(avg(total) OVER (ORDER BY mois ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0) AS moyenne_3_mois
FROM depots
ORDER BY mois;

\echo '--- D1.3 : les comptes coupes en 4 groupes de meme taille selon leur solde (ntile)'
WITH q AS (
    SELECT account_id, balance, ntile(4) OVER (ORDER BY balance) AS quartile
    FROM core.accounts
)
SELECT quartile, count(*) AS nb_comptes, min(balance) AS solde_min, max(balance) AS solde_max, round(avg(balance), 2) AS solde_moyen
FROM q GROUP BY quartile ORDER BY quartile;

\echo '--- D1.4 : les 3 plus gros soldes de chaque type de compte'
SELECT * FROM (
    SELECT account_type, account_id, balance,
           rank() OVER (PARTITION BY account_type ORDER BY balance DESC) AS rang
    FROM core.accounts
) t
WHERE rang <= 3
ORDER BY account_type, rang;

\echo '--- D1.5 : mediane et 90e percentile du solde par type de compte (percentile_cont)'
SELECT account_type,
       count(*) AS nb,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY balance)::numeric, 2) AS mediane,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY balance)::numeric, 2) AS p90,
       round(avg(balance), 2) AS moyenne
FROM core.accounts
GROUP BY account_type
ORDER BY account_type;

CREATE TABLE core.withdrawal_anomalies (
    tx_id       bigint PRIMARY KEY REFERENCES core.transactions (tx_id),
    account_id  bigint        NOT NULL,
    amount      numeric(14,2) NOT NULL,
    zscore      numeric(8,2)  NOT NULL,
    detected_at timestamptz   NOT NULL DEFAULT now()
);

INSERT INTO core.withdrawal_anomalies (tx_id, account_id, amount, zscore)
SELECT tx_id, account_id, amount, z
FROM (
    SELECT tx_id, account_id, amount,
           (amount - avg(amount) OVER ()) / NULLIF(stddev_samp(amount) OVER (), 0) AS z
    FROM core.transactions
    WHERE tx_type = 'WITHDRAWAL'
) s
WHERE abs(z) > 3;

GRANT SELECT ON core.withdrawal_anomalies TO grp_auditeur;

\echo '--- D2 : resume des retraits classes comme anormaux (z > 3)'
SELECT count(*) AS nb_anormaux, min(amount) AS plus_petit, max(amount) AS plus_gros, round(max(zscore), 1) AS z_max
FROM core.withdrawal_anomalies;
SELECT * FROM core.withdrawal_anomalies ORDER BY zscore DESC LIMIT 5;
