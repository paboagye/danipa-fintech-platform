\pset pager off
\pset format aligned
\timing off

-- ---------- Parameters (override with: -v schema=fintech -v roleprefix='danipa_%') ----------
\set schema 'fintech'
\set roleprefix 'danipa_%'
\set group_app 'danipa_app'
\set group_ro  'danipa_readonly'

\echo '=== Using parameters ==='
\echo 'schema       : ' :'schema'
\echo 'roleprefix   : ' :'roleprefix'
\echo 'group_app    : ' :'group_app'
\echo 'group_readonly: ' :'group_ro'
\echo

-- ---------- Role attributes ----------
\echo '=== Role attributes (' :'roleprefix' ') ==='
SELECT rolname,
       rolcanlogin AS canlogin,
       rolinherit  AS inherit,
       rolcreatedb AS createdb,
       rolcreaterole AS createrole,
       rolsuper    AS superuser
FROM pg_roles
WHERE rolname LIKE :'roleprefix'
ORDER BY rolname;
\echo

-- ---------- Role memberships (for the two group roles) ----------
\echo '=== Role memberships (' :'group_app' ', ' :'group_ro' ') ==='
SELECT r.rolname AS parent_role,
       array_agg(m.rolname ORDER BY m.rolname) AS members
FROM pg_auth_members pam
         JOIN pg_roles r ON r.oid = pam.roleid
         JOIN pg_roles m ON m.oid = pam.member
WHERE r.rolname IN (:'group_app', :'group_ro')
GROUP BY r.rolname
ORDER BY r.rolname;
\echo

-- ---------- Schema ACL ----------
\echo '=== Schema ACL (' :'schema' ') ==='
\dn+ :"schema"
\echo

-- ---------- Schema grants via catalog (explicit view) ----------
\echo '=== Schema grants (catalog view) ==='
SELECT n.nspname AS schema,
       r.rolname AS grantee,
       n.nspacl
FROM pg_namespace n
    JOIN pg_roles r ON (n.nspacl::text LIKE ('%' || r.rolname || '%'))
WHERE n.nspname = :'schema'
ORDER BY r.rolname;
\echo

-- ---------- Table & View grants ----------
\echo '=== Table/View grants (' :'schema' '.*) ==='
SELECT n.nspname AS schema,
       c.relname AS "table_or_view",
       r.rolname AS grantee,
       c.relacl
FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_roles r ON (c.relacl::text LIKE ('%' || r.rolname || '%'))
WHERE n.nspname = :'schema'
  AND c.relkind IN ('r','v','m')  -- table / view / matview
ORDER BY c.relname, r.rolname NULLS LAST;
\echo

-- ---------- Sequence grants ----------
\echo '=== Sequence grants (' :'schema' '.*) ==='
SELECT n.nspname AS schema,
       c.relname AS sequence,
       c.relacl
FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = :'schema'
  AND c.relkind = 'S'
ORDER BY c.relname;
\echo

-- ---------- Default privileges (who will own new objects & what gets granted) ----------
\echo '=== Default privileges for new objects in ' :'schema' ' ==='
SELECT defaclrole::regrole AS role,
    defaclnamespace::regnamespace AS schema,
       defaclobjtype AS objtype,
       defaclacl
FROM pg_default_acl
WHERE defaclnamespace::regnamespace = :'schema'::regnamespace
ORDER BY role, objtype;
\echo

-- ---------- Object ownership summary ----------
\echo '=== Object ownership summary (' :'schema' '.*) ==='
SELECT n.nspname AS schema,
       c.relname  AS object,
       pg_get_userbyid(c.relowner) AS owner,
       c.relkind
FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = :'schema'
ORDER BY owner, relkind, relname;
\echo
