CREATE ROLE bank_owner LOGIN;

CREATE ROLE grp_analyste NOLOGIN;
CREATE ROLE grp_support  NOLOGIN;
CREATE ROLE grp_appli    NOLOGIN;
CREATE ROLE grp_auditeur NOLOGIN;

CREATE ROLE analyste1 LOGIN IN ROLE grp_analyste CONNECTION LIMIT 5;
CREATE ROLE support1  LOGIN IN ROLE grp_support  CONNECTION LIMIT 5;
CREATE ROLE appli1    LOGIN IN ROLE grp_appli    CONNECTION LIMIT 20;
CREATE ROLE auditeur1 LOGIN IN ROLE grp_auditeur CONNECTION LIMIT 3;

ALTER ROLE analyste1 SET statement_timeout = '20s';
ALTER ROLE support1  SET statement_timeout = '10s';
ALTER ROLE auditeur1 SET statement_timeout = '30s';
ALTER ROLE appli1    SET statement_timeout = '5s';

CREATE DATABASE bankdb OWNER bank_owner ENCODING 'UTF8';

REVOKE ALL ON DATABASE bankdb FROM PUBLIC;
