-- =============================================
-- Welmy — 018: corrige guards para conexões diretas do n8n (tools do agente)
--
-- Problema 1: wl_is_backend() só aceitava current_user IN
-- (postgres/service_role/supabase_admin); o role da credencial do n8n não
-- está nessa lista → "Acesso negado".
-- Problema 2: vários RPCs usados pelo agente (wl_stats,
-- wl_dashboard_necessidades, wl_get_necessidade, wl_relatorio_*,
-- wl_record_decision, ...) checam apenas wl_is_member(), que depende de
-- auth.uid() (JWT) → sempre false em conexão direta do n8n.
--
-- Correção:
--   1. wl_is_backend(): conexão SEM JWT do PostgREST e fora dos roles de
--      API (anon/authenticated) = backend confiável (n8n).
--   2. wl_is_member(): passa a aceitar também wl_is_backend() — conserta
--      TODOS os RPCs de uma vez, sem redefinir função por função.
-- Usuários do app continuam chegando via PostgREST com JWT; nada muda
-- para eles.
-- =============================================

-- =======  UP  ========

CREATE OR REPLACE FUNCTION wl_is_backend()
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    current_setting('request.jwt.claim.role', true) = 'service_role'
    OR auth.role() = 'service_role'
    OR current_user IN ('postgres','service_role','supabase_admin')
    -- conexão direta (n8n): sem JWT do PostgREST e fora dos roles de API
    OR (
      COALESCE(current_setting('request.jwt.claims', true), '') = ''
      AND COALESCE(current_setting('request.jwt.claim.role', true), '') = ''
      AND current_user NOT IN ('anon', 'authenticated')
    ),
    false
  );
$$;

CREATE OR REPLACE FUNCTION wl_is_member()
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT raw_user_meta_data->>'company_name' = 'welmy'
       FROM auth.users
      WHERE id = auth.uid()),
    false
  ) OR public.wl_is_backend();
$$;

-- =======  DOWN  ========
-- (restaurar definições originais de 001/006)
-- CREATE OR REPLACE FUNCTION wl_is_backend()
-- RETURNS BOOLEAN
-- LANGUAGE sql STABLE AS $$
--   SELECT COALESCE(
--     current_setting('request.jwt.claim.role', true) = 'service_role'
--     OR auth.role() = 'service_role'
--     OR current_user IN ('postgres','service_role','supabase_admin'),
--     false
--   );
-- $$;
-- CREATE OR REPLACE FUNCTION wl_is_member()
-- RETURNS BOOLEAN SECURITY DEFINER SET search_path = auth, public
-- LANGUAGE sql STABLE AS $$
--   SELECT COALESCE(
--     (SELECT raw_user_meta_data->>'company_name' = 'welmy'
--        FROM auth.users WHERE id = auth.uid()),
--     false
--   );
-- $$;
