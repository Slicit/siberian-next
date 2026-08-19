-- Core databases, created once when the Configuration cluster first starts.
--
-- Per-domain and per-module databases are NOT created here. Those are minted at
-- runtime by the Database service, with credentials scoped to the
-- (module, domain) pair (LOGBOOK.md, Multi-domain).

CREATE DATABASE siberian_configuration;
CREATE DATABASE siberian_orchestrator;
CREATE DATABASE siberian_auth;
CREATE DATABASE siberian_base;
CREATE DATABASE siberian_mailer;
CREATE DATABASE siberian_storage;
CREATE DATABASE siberian_database;

-- The Database service owns provisioning, so it is the only role allowed to
-- create databases and roles. Nothing else in the system gets CREATEDB.
CREATE ROLE siberian_provisioner WITH LOGIN CREATEDB CREATEROLE PASSWORD 'provisioner_dev_only';

COMMENT ON DATABASE siberian_configuration IS 'Core data and configuration store.';
