SET ROLE bank_owner;

GRANT CONNECT ON DATABASE bankdb TO grp_analyste, grp_support, grp_appli, grp_auditeur;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA core TO grp_analyste, grp_support, grp_appli, grp_auditeur;
GRANT USAGE ON SCHEMA audit TO grp_auditeur;

GRANT SELECT ON audit.audit_log, core.fraud_alerts, core.transactions TO grp_auditeur;

ALTER DEFAULT PRIVILEGES FOR ROLE bank_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
