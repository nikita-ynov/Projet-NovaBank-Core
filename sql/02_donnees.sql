SET ROLE bank_owner;
\timing on

SELECT setseed(0.42);

INSERT INTO core.customers (first_name, last_name, email, phone, birth_date, kyc_status, risk_level, created_at)
SELECT s.prenom, s.nom,
       lower(s.prenom || '.' || s.nom || '.' || s.g || '@' || s.domaine),
       '06' || lpad(floor(random() * 100000000)::int::text, 8, '0'),
       date '1955-01-01' + (random() * 18000)::int,
       CASE WHEN s.r1 < 0.85 THEN 'VERIFIED' WHEN s.r1 < 0.95 THEN 'PENDING' ELSE 'REJECTED' END::core.kyc_status,
       CASE WHEN s.r2 < 0.70 THEN 'LOW' WHEN s.r2 < 0.93 THEN 'MEDIUM' ELSE 'HIGH' END::core.risk_level,
       timestamptz '2022-01-01' + random() * interval '365 days'
FROM (
    SELECT g,
           (ARRAY['Lucas','Emma','Hugo','Lea','Louis','Chloe','Jules','Manon','Adam','Camille',
                  'Nathan','Sarah','Arthur','Ines','Tom','Clara','Noah','Lola','Paul','Zoe'])[1 + floor(random() * 20)::int] AS prenom,
           (ARRAY['Martin','Bernard','Dubois','Thomas','Robert','Richard','Petit','Durand','Leroy','Moreau',
                  'Simon','Laurent','Lefebvre','Michel','Garcia','David','Bertrand','Roux','Vincent','Fournier'])[1 + floor(random() * 20)::int] AS nom,
           (ARRAY['example.com','mail.test','novamail.fr','exemple.org'])[1 + floor(random() * 4)::int] AS domaine,
           random() AS r1,
           random() AS r2
    FROM generate_series(1, 20000) AS g
) AS s;

INSERT INTO core.accounts (customer_id, iban, account_type, status, opened_at)
SELECT c.customer_id,
       'FR76' || lpad(s.g::text, 23, '0'),
       (ARRAY['CHECKING','CHECKING','SAVINGS','BUSINESS'])[1 + floor(s.r1 * 4)::int]::core.account_type,
       CASE WHEN s.r2 < 0.02 THEN 'FROZEN' WHEN s.r2 < 0.04 THEN 'CLOSED' ELSE 'ACTIVE' END::core.account_status,
       c.created_at + random() * interval '300 days'
FROM (SELECT g, random() AS r1, random() AS r2 FROM generate_series(1, 30000) AS g) AS s
JOIN core.customers c ON c.customer_id = 1 + (s.g - 1) % 20000;

INSERT INTO core.transfers (from_account_id, to_account_id, amount, label, created_at)
SELECT s.a,
       1 + (s.a + s.decal) % 30000,
       round((5 + random() * 1495)::numeric, 2),
       (ARRAY['Loyer','Courses','Remboursement','Cadeau','Facture','Epargne'])[1 + floor(random() * 6)::int],
       timestamptz '2024-01-01' + random() * interval '1000 days'
FROM (
    SELECT 1 + floor(random() * 30000)::int AS a,
           floor(random() * 29999)::int     AS decal
    FROM generate_series(1, 300000)
) AS s;

CREATE TEMP TABLE tmp_ecr (
    seq         bigint GENERATED ALWAYS AS IDENTITY,
    account_id  bigint,
    tx_type     core.tx_type,
    amount      numeric(14,2),
    transfer_id bigint,
    created_at  timestamptz,
    ouverture   boolean NOT NULL DEFAULT false
);

INSERT INTO tmp_ecr (account_id, tx_type, amount, created_at, ouverture)
SELECT account_id, 'DEPOSIT', round((200 + random() * 2000)::numeric, 2), opened_at + interval '1 day', true
FROM core.accounts;

INSERT INTO tmp_ecr (account_id, tx_type, amount, transfer_id, created_at)
SELECT from_account_id, 'TRANSFER_OUT', amount, transfer_id, created_at FROM core.transfers;
INSERT INTO tmp_ecr (account_id, tx_type, amount, transfer_id, created_at)
SELECT to_account_id, 'TRANSFER_IN', amount, transfer_id, created_at FROM core.transfers;

INSERT INTO tmp_ecr (account_id, tx_type, amount, created_at)
SELECT 1 + floor(random() * 30000)::int, 'DEPOSIT', round((50 + random() * 1950)::numeric, 2),
       timestamptz '2024-01-01' + random() * interval '1000 days'
FROM generate_series(1, 220000);

INSERT INTO tmp_ecr (account_id, tx_type, amount, created_at)
SELECT s.a, 'WITHDRAWAL',
       round((CASE WHEN s.r < 0.005 THEN 5000 + random() * 2000 ELSE 10 + random() * 490 END)::numeric, 2),
       timestamptz '2024-01-01' + random() * interval '1000 days'
FROM (SELECT 1 + floor(random() * 30000)::int AS a, random() AS r FROM generate_series(1, 150000)) AS s;

WITH cumul AS (
    SELECT account_id,
           sum(delta) OVER (PARTITION BY account_id ORDER BY created_at, seq) AS cumul
    FROM (
        SELECT account_id, created_at, seq,
               CASE WHEN tx_type IN ('DEPOSIT', 'TRANSFER_IN') THEN amount ELSE -amount END AS delta
        FROM tmp_ecr
        WHERE NOT ouverture
    ) AS d
), manque AS (
    SELECT account_id, -min(cumul) AS deficit
    FROM cumul
    GROUP BY account_id
    HAVING min(cumul) < 0
)
UPDATE tmp_ecr e
SET amount = e.amount + m.deficit
FROM manque m
WHERE e.account_id = m.account_id AND e.ouverture;

INSERT INTO core.transactions (account_id, tx_type, amount, balance_after, transfer_id, created_at)
SELECT account_id, tx_type, amount,
       sum(CASE WHEN tx_type IN ('DEPOSIT', 'TRANSFER_IN') THEN amount ELSE -amount END)
           OVER (PARTITION BY account_id ORDER BY created_at, seq),
       transfer_id, created_at
FROM tmp_ecr
ORDER BY created_at, seq;

UPDATE core.accounts a
SET balance = d.balance_after
FROM (
    SELECT DISTINCT ON (account_id) account_id, balance_after
    FROM core.transactions
    ORDER BY account_id, created_at DESC, tx_id DESC
) AS d
WHERE d.account_id = a.account_id;

ANALYZE core.customers, core.accounts, core.transfers, core.transactions;

\echo '--- controle (0 ligne attendue) ---'
SELECT a.account_id, a.balance, s.somme
FROM core.accounts a
JOIN (SELECT account_id,
             sum(CASE WHEN tx_type IN ('DEPOSIT', 'TRANSFER_IN') THEN amount ELSE -amount END) AS somme
      FROM core.transactions GROUP BY account_id) s USING (account_id)
WHERE a.balance <> s.somme OR a.balance < 0;

\echo '--- nombre de lignes ---'
SELECT (SELECT count(*) FROM core.customers)    AS clients,
       (SELECT count(*) FROM core.accounts)     AS comptes,
       (SELECT count(*) FROM core.transfers)    AS virements,
       (SELECT count(*) FROM core.transactions) AS ecritures;
