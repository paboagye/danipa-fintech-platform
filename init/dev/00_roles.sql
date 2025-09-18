-- Create application roles (idempotent-ish on fresh init)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'danipa_app_dev') THEN
CREATE ROLE danipa_app_dev LOGIN PASSWORD 'changeMeAppDev!';
END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'danipa_ro_dev') THEN
CREATE ROLE danipa_ro_dev LOGIN PASSWORD 'changeMeDevRo!';
END IF;
END$$;
