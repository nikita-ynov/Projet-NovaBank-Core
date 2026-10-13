SET ROLE bank_owner;

CREATE FUNCTION core.fn_ecriture_solde() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_solde   numeric(14,2);
    v_statut  core.account_status;
    v_nouveau numeric(14,2);
BEGIN

    SELECT balance, status INTO v_solde, v_statut
    FROM core.accounts
    WHERE account_id = NEW.account_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compte % introuvable', NEW.account_id;
    END IF;
    IF v_statut <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Compte % non actif (statut %) : ecriture refusee', NEW.account_id, v_statut;
    END IF;

    IF NEW.tx_type IN ('DEPOSIT', 'TRANSFER_IN') THEN
        v_nouveau := v_solde + NEW.amount;
    ELSE
        v_nouveau := v_solde - NEW.amount;
    END IF;

    IF v_nouveau < 0 THEN
        RAISE EXCEPTION 'Solde insuffisant sur le compte % (solde %, montant demande %)',
            NEW.account_id, v_solde, NEW.amount;
    END IF;

    NEW.balance_after := v_nouveau;
    UPDATE core.accounts SET balance = v_nouveau WHERE account_id = NEW.account_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_transactions_before_solde
    BEFORE INSERT ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_ecriture_solde();

CREATE FUNCTION core.fn_solde_protege() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION 'Le solde ne se modifie pas directement : il faut passer par une ecriture (core.transactions)';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_accounts_before_solde_protege
    BEFORE UPDATE ON core.accounts
    FOR EACH ROW WHEN (OLD.balance IS DISTINCT FROM NEW.balance)
    EXECUTE FUNCTION core.fn_solde_protege();

CREATE FUNCTION core.fn_immuable() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'Table %.% : les lignes ne peuvent jamais etre modifiees ni supprimees (% refuse)',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP;
END;
$$;

CREATE TRIGGER trg_transactions_before_immuable
    BEFORE UPDATE OR DELETE ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_immuable();
CREATE TRIGGER trg_transactions_before_immuable_truncate
    BEFORE TRUNCATE ON core.transactions
    FOR EACH STATEMENT EXECUTE FUNCTION core.fn_immuable();

CREATE TRIGGER trg_transfers_before_immuable
    BEFORE UPDATE OR DELETE ON core.transfers
    FOR EACH ROW EXECUTE FUNCTION core.fn_immuable();
CREATE TRIGGER trg_transfers_before_immuable_truncate
    BEFORE TRUNCATE ON core.transfers
    FOR EACH STATEMENT EXECUTE FUNCTION core.fn_immuable();

CREATE TRIGGER trg_audit_log_before_immuable
    BEFORE UPDATE OR DELETE ON audit.audit_log
    FOR EACH ROW EXECUTE FUNCTION core.fn_immuable();
CREATE TRIGGER trg_audit_log_before_immuable_truncate
    BEFORE TRUNCATE ON audit.audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION core.fn_immuable();

CREATE FUNCTION core.fn_virement_complet() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_vir   core.transfers%ROWTYPE;
    v_out   int;
    v_in    int;
    v_total int;
BEGIN

    SELECT * INTO v_vir FROM core.transfers WHERE transfer_id = NEW.transfer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ecriture rattachee a un virement inexistant (%)', NEW.transfer_id;
    END IF;

    SELECT count(*) FILTER (WHERE tx_type = 'TRANSFER_OUT' AND account_id = v_vir.from_account_id AND amount = v_vir.amount),
           count(*) FILTER (WHERE tx_type = 'TRANSFER_IN'  AND account_id = v_vir.to_account_id   AND amount = v_vir.amount),
           count(*)
    INTO v_out, v_in, v_total
    FROM core.transactions
    WHERE transfer_id = NEW.transfer_id;

    IF v_out <> 1 OR v_in <> 1 OR v_total <> 2 THEN
        RAISE EXCEPTION 'Virement % incomplet : il faut exactement 1 debit et 1 credit (trouve : % debit, % credit, % ecritures)',
            NEW.transfer_id, v_out, v_in, v_total;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_transfers_after_complet
    AFTER INSERT ON core.transfers
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION core.fn_virement_complet();

CREATE CONSTRAINT TRIGGER trg_transactions_after_complet
    AFTER INSERT ON core.transactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW WHEN (NEW.transfer_id IS NOT NULL)
    EXECUTE FUNCTION core.fn_virement_complet();

CREATE FUNCTION core.fn_fraude() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_nb int;
BEGIN
    IF NEW.tx_type = 'WITHDRAWAL' AND NEW.amount >= 5000 THEN
        INSERT INTO core.fraud_alerts (account_id, tx_id, rule_code)
        VALUES (NEW.account_id, NEW.tx_id, 'WITHDRAWAL_5000');

    ELSIF NEW.tx_type = 'TRANSFER_OUT' THEN

        SELECT count(*) INTO v_nb
        FROM core.transactions
        WHERE account_id = NEW.account_id
          AND tx_type = 'TRANSFER_OUT'
          AND created_at >  NEW.created_at - interval '10 minutes'
          AND created_at <= NEW.created_at;

        IF v_nb >= 5 AND NOT EXISTS (
            SELECT 1 FROM core.fraud_alerts
            WHERE account_id = NEW.account_id
              AND rule_code = 'TRANSFERS_5_IN_10MIN'
              AND created_at > now() - interval '10 minutes'
        ) THEN
            INSERT INTO core.fraud_alerts (account_id, tx_id, rule_code)
            VALUES (NEW.account_id, NEW.tx_id, 'TRANSFERS_5_IN_10MIN');
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_transactions_after_fraude
    AFTER INSERT ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_fraude();

CREATE FUNCTION core.fn_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_old jsonb;
    v_new jsonb;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN v_new := to_jsonb(NEW); END IF;

    IF TG_TABLE_NAME = 'customers' THEN
        IF v_old IS NOT NULL THEN
            v_old := v_old || jsonb_build_object('email', md5(v_old ->> 'email'), 'phone', md5(v_old ->> 'phone'));
        END IF;
        IF v_new IS NOT NULL THEN
            v_new := v_new || jsonb_build_object('email', md5(v_new ->> 'email'), 'phone', md5(v_new ->> 'phone'));
        END IF;
    END IF;

    INSERT INTO audit.audit_log (table_name, operation, old_data, new_data, db_user)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, TG_OP, v_old, v_new, session_user);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_customers_after_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.customers
    FOR EACH ROW EXECUTE FUNCTION core.fn_audit();

CREATE TRIGGER trg_accounts_after_audit_id
    AFTER INSERT OR DELETE ON core.accounts
    FOR EACH ROW EXECUTE FUNCTION core.fn_audit();

CREATE TRIGGER trg_accounts_after_audit_maj
    AFTER UPDATE ON core.accounts
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
       OR OLD.account_type IS DISTINCT FROM NEW.account_type
       OR OLD.iban IS DISTINCT FROM NEW.iban
       OR OLD.customer_id IS DISTINCT FROM NEW.customer_id)
    EXECUTE FUNCTION core.fn_audit();

CREATE TRIGGER trg_fraud_alerts_after_audit
    AFTER UPDATE OR DELETE ON core.fraud_alerts
    FOR EACH ROW EXECUTE FUNCTION core.fn_audit();
