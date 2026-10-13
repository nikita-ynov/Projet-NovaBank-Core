SET ROLE bank_owner;

CREATE SCHEMA core;
CREATE SCHEMA audit;

CREATE TYPE core.kyc_status     AS ENUM ('PENDING', 'VERIFIED', 'REJECTED');
CREATE TYPE core.risk_level     AS ENUM ('LOW', 'MEDIUM', 'HIGH');
CREATE TYPE core.account_type   AS ENUM ('CHECKING', 'SAVINGS', 'BUSINESS');
CREATE TYPE core.account_status AS ENUM ('ACTIVE', 'FROZEN', 'CLOSED');
CREATE TYPE core.tx_type        AS ENUM ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER_OUT', 'TRANSFER_IN');
CREATE TYPE core.alert_status   AS ENUM ('OPEN', 'REVIEWED', 'CLOSED');

CREATE TABLE core.customers (
    customer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name  text        NOT NULL,
    last_name   text        NOT NULL,
    email       text        NOT NULL,
    phone       text,
    birth_date  date        NOT NULL,
    kyc_status  core.kyc_status NOT NULL DEFAULT 'PENDING',
    risk_level  core.risk_level NOT NULL DEFAULT 'LOW',
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_customers_email        UNIQUE (email),

    CONSTRAINT ck_customers_email_min    CHECK (email = lower(email)),
    CONSTRAINT ck_customers_email_valide CHECK (email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'),
    CONSTRAINT ck_customers_phone        CHECK (phone IS NULL OR phone ~ '^\+?[0-9 ]{6,20}$'),
    CONSTRAINT ck_customers_majeur       CHECK (birth_date <= current_date - interval '18 years'),
    CONSTRAINT ck_customers_noms         CHECK (btrim(first_name) <> '' AND btrim(last_name) <> '')
);

CREATE TABLE core.accounts (
    account_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  bigint        NOT NULL REFERENCES core.customers (customer_id),
    iban         text          NOT NULL,
    account_type core.account_type   NOT NULL,
    balance      numeric(14,2) NOT NULL DEFAULT 0,
    status       core.account_status NOT NULL DEFAULT 'ACTIVE',
    opened_at    timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT uq_accounts_iban        UNIQUE (iban),
    CONSTRAINT ck_accounts_iban        CHECK (iban ~ '^[A-Z]{2}[0-9]{2}[0-9A-Z]{11,30}$'),
    CONSTRAINT ck_accounts_solde_pos   CHECK (balance >= 0)
);

CREATE TABLE core.transfers (
    transfer_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_account_id bigint        NOT NULL REFERENCES core.accounts (account_id),
    to_account_id   bigint        NOT NULL REFERENCES core.accounts (account_id),
    amount          numeric(14,2) NOT NULL,
    label           text,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT ck_transfers_montant_pos  CHECK (amount > 0),
    CONSTRAINT ck_transfers_comptes_diff CHECK (from_account_id <> to_account_id)
);

CREATE TABLE core.transactions (
    tx_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id    bigint        NOT NULL REFERENCES core.accounts (account_id),
    tx_type       core.tx_type  NOT NULL,
    amount        numeric(14,2) NOT NULL,
    balance_after numeric(14,2) NOT NULL,
    transfer_id   bigint        REFERENCES core.transfers (transfer_id),
    created_at    timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT ck_tx_montant_pos   CHECK (amount > 0),
    CONSTRAINT ck_tx_solde_pos     CHECK (balance_after >= 0),

    CONSTRAINT ck_tx_virement_lien CHECK ((tx_type IN ('TRANSFER_OUT', 'TRANSFER_IN')) = (transfer_id IS NOT NULL))
);

CREATE TABLE core.fraud_alerts (
    alert_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id bigint      NOT NULL REFERENCES core.accounts (account_id),
    tx_id      bigint      NOT NULL REFERENCES core.transactions (tx_id),
    rule_code  text        NOT NULL,
    status     core.alert_status NOT NULL DEFAULT 'OPEN',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_alerts_rule CHECK (rule_code IN ('WITHDRAWAL_5000', 'TRANSFERS_5_IN_10MIN'))
);

CREATE TABLE audit.audit_log (
    log_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text        NOT NULL,
    operation  text        NOT NULL,
    old_data   jsonb,
    new_data   jsonb,
    db_user    text        NOT NULL DEFAULT session_user,
    changed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_audit_operation CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE'))
);
