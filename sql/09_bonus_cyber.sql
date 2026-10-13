SET ROLE bank_owner;

CREATE SCHEMA ext;
CREATE EXTENSION pgcrypto SCHEMA ext;

CREATE TABLE core.customer_phone_secure (
    customer_id bigint PRIMARY KEY REFERENCES core.customers (customer_id),
    phone_enc   bytea NOT NULL
);

\getenv phone_key PHONE_KEY
\if :{?phone_key}
    INSERT INTO core.customer_phone_secure (customer_id, phone_enc)
    SELECT customer_id, ext.pgp_sym_encrypt(phone, :'phone_key')
    FROM core.customers
    WHERE phone IS NOT NULL AND customer_id <= 5;

    \echo '--- ce qu on voit dans la table sans la cle'
    SELECT customer_id, left(encode(phone_enc, 'hex'), 40) || '...' AS phone_enc FROM core.customer_phone_secure ORDER BY 1;

    \echo '--- avec la bonne cle (comparaison avec le telephone d origine)'
    SELECT s.customer_id, ext.pgp_sym_decrypt(s.phone_enc, :'phone_key') AS dechiffre, c.phone AS original
    FROM core.customer_phone_secure s JOIN core.customers c USING (customer_id) ORDER BY 1;

    \echo '--- avec une mauvaise cle : doit echouer'
    \set ON_ERROR_STOP off
    SELECT ext.pgp_sym_decrypt(phone_enc, 'mauvaise-cle') FROM core.customer_phone_secure LIMIT 1;
    \set ON_ERROR_STOP on
\else
    \echo 'PHONE_KEY non definie : demo C3 sautee (export PHONE_KEY=... avant de lancer)'
\endif

CREATE SCHEMA bonus;

CREATE FUNCTION bonus.chercher_client_vulnerable(p_nom text)
RETURNS TABLE (customer_id bigint, last_name text, email text)
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT c.customer_id, c.last_name, c.email FROM core.customers c WHERE c.last_name = ''' || p_nom || '''';
END;
$$;

CREATE FUNCTION bonus.chercher_client_corrigee(p_nom text)
RETURNS TABLE (customer_id bigint, last_name text, email text)
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT c.customer_id, c.last_name, c.email FROM core.customers c WHERE c.last_name = $1'
        USING p_nom;
END;
$$;

\echo '--- usage normal (vulnerable) : un nom'
SELECT count(*) AS nb FROM bonus.chercher_client_vulnerable('Martin');

\echo '--- ATTAQUE : la saisie  '' OR ''1''=''1  renvoie toute la table clients'
SELECT count(*) AS nb FROM bonus.chercher_client_vulnerable(''' OR ''1''=''1');

\echo '--- meme attaque sur la version corrigee : 0 ligne (le texte est cherche tel quel comme un nom)'
SELECT count(*) AS nb FROM bonus.chercher_client_corrigee('Martin');
SELECT count(*) AS nb FROM bonus.chercher_client_corrigee('''' || ' OR ''1''=''1');
