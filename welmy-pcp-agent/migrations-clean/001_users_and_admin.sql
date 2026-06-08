-- =============================================
-- Welmy — Copiloto de Suprimentos e PCP
-- 001: Users, roles e admin guards
--
-- Adaptado do agente NL Diagnóstica (auth/ACL), simplificado:
--   * SEM equipes / SEM categorias-ACL — todo usuário autenticado da empresa
--     enxerga tudo (documentos RAG, plano de produção, necessidades) via agente.
--   * Apenas DOIS perfis: 'admin' (PCP/gestão) e 'visualizacao' (compras/almox.).
--
-- - Helpers: wl_is_admin(), wl_is_member()
-- - CRUD de usuários via raw_user_meta_data (role + company_name='welmy')
-- - Guards admin-only em todas as RPCs de escrita
-- - Admin não pode excluir a si mesmo / não exclui o último admin
-- =============================================

-- =======  UP  ========

-- helper genérico de updated_at (usado por várias tabelas)
CREATE OR REPLACE FUNCTION wl_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

-- ---------- helpers de papel ----------
CREATE OR REPLACE FUNCTION wl_is_admin()
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT raw_user_meta_data->>'role' = 'admin'
            AND raw_user_meta_data->>'company_name' = 'welmy'
       FROM auth.users
      WHERE id = auth.uid()),
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
  );
$$;

-- ---------- list users (admin-only, filtra por company_name) ----------
DROP FUNCTION IF EXISTS wl_admin_list_users();
CREATE OR REPLACE FUNCTION wl_admin_list_users()
RETURNS TABLE(
  user_id      UUID,
  email        TEXT,
  full_name    TEXT,
  role         TEXT,
  company_name TEXT,
  confirmed    BOOLEAN,
  created_at   TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT wl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      u.id,
      u.email::TEXT,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::TEXT,
      COALESCE(u.raw_user_meta_data->>'role', 'visualizacao')::TEXT,
      COALESCE(u.raw_user_meta_data->>'company_name', '')::TEXT,
      (u.email_confirmed_at IS NOT NULL),
      u.created_at
    FROM auth.users u
    WHERE u.raw_user_meta_data->>'company_name' = 'welmy'
    ORDER BY u.created_at DESC;
END;
$$;

-- ---------- list members (qualquer membro: selects de responsável etc.) ----------
DROP FUNCTION IF EXISTS wl_list_members();
CREATE OR REPLACE FUNCTION wl_list_members()
RETURNS TABLE(
  user_id   UUID,
  full_name TEXT,
  email     TEXT
)
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT wl_is_member() THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      u.id,
      COALESCE(NULLIF(u.raw_user_meta_data->>'full_name',''), u.email)::TEXT,
      u.email::TEXT
    FROM auth.users u
    WHERE u.raw_user_meta_data->>'company_name' = 'welmy'
    ORDER BY 2;
END;
$$;

-- ---------- confirm user (admin-only) ----------
CREATE OR REPLACE FUNCTION wl_admin_confirm_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT wl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  UPDATE auth.users
     SET email_confirmed_at = NOW(),
         updated_at         = NOW()
   WHERE id = p_user_id;
END;
$$;

-- ---------- update user (admin-only, sempre carimba company_name) ----------
DROP FUNCTION IF EXISTS wl_admin_update_user(UUID, TEXT, TEXT);
CREATE OR REPLACE FUNCTION wl_admin_update_user(
  p_user_id   UUID,
  p_full_name TEXT,
  p_role      TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
DECLARE
  new_meta JSONB;
BEGIN
  IF NOT wl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  IF p_role IS NOT NULL AND p_role NOT IN ('admin', 'visualizacao') THEN
    RAISE EXCEPTION 'Perfil inválido: % (use admin ou visualizacao).', p_role USING ERRCODE = '22023';
  END IF;
  new_meta := jsonb_build_object('full_name', p_full_name, 'company_name', 'welmy');
  IF p_role IS NOT NULL THEN
    new_meta := new_meta || jsonb_build_object('role', p_role);
  END IF;
  UPDATE auth.users
     SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || new_meta,
         updated_at         = NOW()
   WHERE id = p_user_id;
END;
$$;

-- ---------- delete user (admin-only, sem self-delete, protege último admin) ----------
CREATE OR REPLACE FUNCTION wl_admin_delete_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
DECLARE
  admin_count INT;
  target_role TEXT;
BEGIN
  IF NOT wl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Você não pode excluir sua própria conta.' USING ERRCODE = '42501';
  END IF;

  SELECT raw_user_meta_data->>'role' INTO target_role
    FROM auth.users WHERE id = p_user_id;

  IF target_role = 'admin' THEN
    SELECT COUNT(*) INTO admin_count
      FROM auth.users
     WHERE raw_user_meta_data->>'company_name' = 'welmy'
       AND raw_user_meta_data->>'role' = 'admin';
    IF admin_count <= 1 THEN
      RAISE EXCEPTION 'Não é possível excluir o último administrador.' USING ERRCODE = '42501';
    END IF;
  END IF;

  DELETE FROM auth.users WHERE id = p_user_id;
END;
$$;

-- ---------- grants ----------
GRANT EXECUTE ON FUNCTION wl_is_admin()                            TO authenticated;
GRANT EXECUTE ON FUNCTION wl_is_member()                           TO authenticated;
GRANT EXECUTE ON FUNCTION wl_admin_list_users()                    TO authenticated;
GRANT EXECUTE ON FUNCTION wl_list_members()                        TO authenticated;
GRANT EXECUTE ON FUNCTION wl_admin_confirm_user(UUID)              TO authenticated;
GRANT EXECUTE ON FUNCTION wl_admin_update_user(UUID, TEXT, TEXT)   TO authenticated;
GRANT EXECUTE ON FUNCTION wl_admin_delete_user(UUID)               TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_admin_delete_user(UUID);
-- DROP FUNCTION IF EXISTS wl_admin_update_user(UUID, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS wl_admin_confirm_user(UUID);
-- DROP FUNCTION IF EXISTS wl_admin_list_users();
-- DROP FUNCTION IF EXISTS wl_list_members();
-- DROP FUNCTION IF EXISTS wl_is_member();
-- DROP FUNCTION IF EXISTS wl_is_admin();
-- DROP FUNCTION IF EXISTS wl_set_updated_at();
-- NOTIFY pgrst, 'reload schema';
