-- Ensure target DB exists (defensive if you didn't use POSTGRES_DB)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'danipa_fintech_db_dev') THEN
    PERFORM dblink_exec('dbname=' || current_database(),
                        'CREATE DATABASE danipa_fintech_db_dev');
END IF;
END$$;

\connect danipa_fintech_db_dev

-- Make your app user own the schema it will use
CREATE SCHEMA IF NOT EXISTS public AUTHORIZATION danipa_app_dev;

-- Grant sensible privileges
GRANT CONNECT ON DATABASE danipa_fintech_db_dev TO danipa_app_dev, danipa_ro_dev;
GRANT USAGE   ON SCHEMA public TO danipa_app_dev, danipa_ro_dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO danipa_app_dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO danipa_ro_dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO danipa_app_dev, danipa_ro_dev;
