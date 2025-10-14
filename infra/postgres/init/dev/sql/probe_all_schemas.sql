\pset pager off
\pset format aligned
\timing off

-- ---------- Parameters ----------
-- roleprefix / group_app / group_ro can be overridden from psql -v
\if :{?roleprefix} \else \set roleprefix 'danipa_%' \endif
\if :{?group_app}  \else \set group_app  'danipa_app' \endif
\if :{?group_ro}   \else \set group_ro   'danipa_readonly' \endif
-- If you pass -v only_schemas='schema1, schema2' we’ll skip auto-detection
\if :{?only_schemas}
\set all_schemas :'only_schemas'
\else
  -- ---------- Collect user schemas (exclude system schemas) ----------
  WITH user_schemas AS (
    SELECT nspname
    FROM pg_namespace
    WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast')
      AND nspname NOT LIKE 'pg_temp_%'
      AND nspname NOT LIKE 'pg_toast_temp_%'
  )
SELECT string_agg(nspname, ', ' ORDER BY nspname) AS all_schemas
FROM user_schemas \gset
         \endif

    \echo
    \echo '=== User schemas ==='
SELECT :'all_schemas'::text;

\echo
\echo '=== Role attributes (' :roleprefix ') ==='
SELECT rolname,
       rolcanlogin   AS canlogin,
       rolinherit    AS inherit,
       rolcreatedb   AS createdb,
       rolcreaterole AS createrole,
       rolsuper      AS superuser
FROM pg_roles
WHERE rolname LIKE :'roleprefix'
ORDER BY rolname;

\echo
\echo '=== Role memberships (' :group_app ', ' :group_ro ') ==='
SELECT r.rolname AS parent_role,
       array_agg(m.rolname ORDER BY m.rolname) AS members
FROM pg_auth_members pam
         JOIN pg_roles r ON r.oid = pam.roleid
         JOIN pg_roles m ON m.oid = pam.member
WHERE r.rolname IN (:'group_app', :'group_ro')
GROUP BY r.rolname
ORDER BY r.rolname;

\echo
\echo '=== Schema ACLs (all user schemas) ==='
SELECT n.nspname AS schema,
       pg_get_userbyid(n.nspowner) AS owner,
       n.nspacl
FROM pg_namespace n
WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
ORDER BY n.nspname;

\echo
\echo '=== Table/View grants (all user schemas) ==='
SELECT n.nspname AS schema,
       c.relname AS table_or_view,
       r.rolname AS grantee,
       c.relacl
FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_roles r ON (c.relacl::text LIKE ('%'||r.rolname||'%'))
WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
  AND c.relkind IN ('r','v','m')
ORDER BY n.nspname, c.relname, r.rolname NULLS LAST;

\echo
\echo '=== Sequence grants (all user schemas) ==='
SELECT n.nspname AS schema,
       c.relname AS sequence,
       c.relacl
FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
  AND c.relkind = 'S'
ORDER BY n.nspname, c.relname;

-- ---------- Functions / Procedures (only if any) ----------
SELECT COUNT(*) AS _fn_cnt
FROM pg_proc p
         JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
  AND p.proacl IS NOT NULL \gset
    \if :_fn_cnt
    \echo
    \echo '=== Function/Procedure grants (all user schemas, proacl IS NOT NULL) ==='
SELECT n.nspname AS schema,
         p.proname AS routine,
         p.prokind AS kind,        -- f=function, p=procedure, a=aggregate, w=window
         p.proacl
FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
  AND p.proacl IS NOT NULL
ORDER BY n.nspname, p.proname;

\echo
\echo '=== Function/Procedure grants expanded (if any) ==='
  WITH routines AS (
    SELECT n.nspname AS schema, p.oid, p.proname, p.prokind, p.proacl
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
      AND p.proacl IS NOT NULL
  ),
  acl AS (
    SELECT schema, proname, prokind, unnest(proacl) AS aclitem
    FROM routines
  )
SELECT schema,
    proname AS routine,
    prokind AS kind,
    split_part(aclitem::text, '=', 1)                   AS grantee,
    split_part(split_part(aclitem::text, '=', 2), '/', 1) AS privileges
FROM acl
ORDER BY schema, routine, grantee;
\endif

-- ---------- RLS Policies (only if enabled/defined) ----------
SELECT COUNT(*) AS _rls_cnt
FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
         LEFT JOIN pg_policy pol ON pol.polrelid = c.oid
WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
  AND c.relkind = 'r'
  AND (c.relrowsecurity OR pol.polname IS NOT NULL) \gset
    \if :_rls_cnt
    \echo
    \echo '=== Row-Level Security policies (only enabled or defined) ==='
SELECT n.nspname AS schema,
         c.relname AS table,
         c.relrowsecurity AS rls_enabled,
         pol.polname AS policy,
         pol.polcmd  AS command,   -- r/w/a
         pg_get_expr(pol.polqual, pol.polrelid)      AS using_expr,
         pg_get_expr(pol.polwithcheck, pol.polrelid) AS check_expr
FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_policy pol ON pol.polrelid = c.oid
WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
  AND c.relkind = 'r'
  AND (c.relrowsecurity OR pol.polname IS NOT NULL)
ORDER BY n.nspname, c.relname, pol.polname NULLS LAST;
\endif

\echo
\echo '=== Default privileges (all user schemas) ==='
SELECT defaclrole::regrole           AS role,
    defaclnamespace::regnamespace AS schema,
       defaclobjtype                 AS objtype,
       defaclacl
FROM pg_default_acl
WHERE defaclnamespace::regnamespace = ANY (
    SELECT nspname::regnamespace
    FROM pg_namespace
    WHERE nspname = ANY (string_to_array(:'all_schemas', ', '))
    )
ORDER BY schema, role, objtype;

\echo
\echo '=== Object ownership summary (all user schemas) ==='
SELECT n.nspname AS schema,
       c.relname  AS object,
       pg_get_userbyid(c.relowner) AS owner,
       c.relkind
FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
ORDER BY n.nspname, owner, relkind, relname;

\echo
\echo '=== Object counts & sizes (all user schemas) ==='
SELECT n.nspname AS schema,
       COUNT(*)  FILTER (WHERE c.relkind IN ('r','m')) AS tables,
       COUNT(*)  FILTER (WHERE c.relkind = 'v')        AS views,
       pg_size_pretty(SUM(pg_total_relation_size(c.oid))) AS total_size
FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY (string_to_array(:'all_schemas', ', '))
GROUP BY n.nspname
ORDER BY n.nspname;
