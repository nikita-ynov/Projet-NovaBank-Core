SET ROLE bank_owner;

CREATE SEQUENCE core.seq_iban START 1000000;

CREATE PROCEDURE core.sp_virement(
    p_from bigint, p_to bigint, p_montant numeric, p_label text DEFAULT NULL,
    INOUT p_transfer_id bigint DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    r        record;
    v_solde  numeric;
    v_trouve int := 0;
BEGIN

    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'Compte source et compte destination obligatoires';
    END IF;
    IF p_montant IS NULL OR p_montant <= 0 THEN
        RAISE EXCEPTION 'Montant invalide : il doit etre strictement positif';
    END IF;
    IF p_montant <> round(p_montant, 2) THEN
        RAISE EXCEPTION 'Montant invalide : 2 decimales maximum';
    END IF;
    IF p_from = p_to THEN
        RAISE EXCEPTION 'Les deux comptes doivent etre differents';
    END IF;

    FOR r IN
        SELECT account_id, balance, status
        FROM core.accounts
        WHERE account_id IN (p_from, p_to)
        ORDER BY account_id
        FOR UPDATE
    LOOP
        v_trouve := v_trouve + 1;
        IF r.status <> 'ACTIVE' THEN
            RAISE EXCEPTION 'Le compte % n''est pas actif (statut %)', r.account_id, r.status;
        END IF;
        IF r.account_id = p_from THEN
            v_solde := r.balance;
        END IF;
    END LOOP;

    IF v_trouve < 2 THEN
        RAISE EXCEPTION 'Compte source ou destination introuvable';
    END IF;

    IF v_solde < p_montant THEN
        RAISE EXCEPTION 'Solde insuffisant sur le compte % (solde %, virement %)', p_from, v_solde, p_montant;
    END IF;

    INSERT INTO core.transfers (from_account_id, to_account_id, amount, label)
    VALUES (p_from, p_to, p_montant, p_label)
    RETURNING transfer_id INTO p_transfer_id;

    INSERT INTO core.transactions (account_id, tx_type, amount, transfer_id)
    VALUES (p_from, 'TRANSFER_OUT', p_montant, p_transfer_id),
           (p_to,   'TRANSFER_IN',  p_montant, p_transfer_id);
END;
$$;

CREATE PROCEDURE core.sp_ouvrir_compte(
    p_customer_id bigint, p_type text, p_depot numeric DEFAULT 0,
    INOUT p_account_id bigint DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_kyc  core.kyc_status;
    v_type core.account_type;
BEGIN
    IF p_depot IS NULL OR p_depot < 0 THEN
        RAISE EXCEPTION 'Depot initial invalide (0 ou plus)';
    END IF;

    BEGIN
        v_type := upper(p_type)::core.account_type;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Type de compte invalide : % (CHECKING, SAVINGS ou BUSINESS)', p_type;
    END;

    SELECT kyc_status INTO v_kyc FROM core.customers WHERE customer_id = p_customer_id FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client % introuvable', p_customer_id;
    END IF;
    IF v_kyc <> 'VERIFIED' THEN
        RAISE EXCEPTION 'Client % : KYC non valide (%), ouverture refusee', p_customer_id, v_kyc;
    END IF;

    INSERT INTO core.accounts (customer_id, iban, account_type)
    VALUES (p_customer_id, 'FR76' || lpad(nextval('core.seq_iban')::text, 23, '0'), v_type)
    RETURNING account_id INTO p_account_id;

    IF p_depot > 0 THEN
        INSERT INTO core.transactions (account_id, tx_type, amount)
        VALUES (p_account_id, 'DEPOSIT', p_depot);
    END IF;
END;
$$;

CREATE PROCEDURE core.sp_releve(
    p_account_id bigint, p_debut date, p_fin date,
    INOUT p_curseur refcursor DEFAULT 'releve')
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF p_debut IS NULL OR p_fin IS NULL OR p_fin < p_debut THEN
        RAISE EXCEPTION 'Periode invalide';
    END IF;
    PERFORM 1 FROM core.accounts WHERE account_id = p_account_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compte % introuvable', p_account_id;
    END IF;

    OPEN p_curseur FOR
        SELECT tx_id, created_at, tx_type, amount, balance_after, transfer_id
        FROM core.transactions
        WHERE account_id = p_account_id
          AND created_at >= p_debut
          AND created_at <  p_fin + 1
        ORDER BY created_at, tx_id;
END;
$$;

GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA core TO grp_appli;
