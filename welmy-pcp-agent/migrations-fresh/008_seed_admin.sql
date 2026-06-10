-- =============================================
-- Welmy — 008: Seed (apenas admin bootstrap)  (antiga 007)
--
-- - Cria/atualiza o admin (admin@welmy.com.br / @Admin123)
--     * a senha NÃO é sobrescrita em re-execuções (preserva rotações em prod)
--
-- IMPORTANTE — sem dados de exemplo:
--   Fornecedores e itens NÃO são semeados. TODOS os dados de catálogo,
--   estoque, lead time e necessidades entram exclusivamente pelos relatórios
--   do ERP (Inventário / Necessidades) e pela planilha mestre de SKUs.
-- ALERTA: troque a senha do admin logo após o primeiro login.
-- Rode APÓS 007_mrp_arvore.sql (última)
-- =============================================

-- =======  UP  ========

-- ---------- admin bootstrap ----------
DO $$
DECLARE
  v_email     TEXT := 'admin@welmy.com.br';
  v_password  TEXT := '@Admin123';
  v_user_id   UUID;
  v_meta      JSONB := '{"role":"admin","company_name":"welmy","full_name":"Administrador Welmy"}'::jsonb;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE email = v_email LIMIT 1;

  IF v_user_id IS NULL THEN
    v_user_id := gen_random_uuid();
    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_user_id, 'authenticated', 'authenticated', v_email,
      crypt(v_password, gen_salt('bf')),
      NOW(),
      jsonb_build_object('provider','email','providers',ARRAY['email']),
      v_meta, NOW(), NOW(), '', '', '', ''
    );
    INSERT INTO auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    ) VALUES (
      gen_random_uuid(), v_user_id, v_user_id::text,
      jsonb_build_object('sub', v_user_id::text, 'email', v_email, 'email_verified', true),
      'email', NOW(), NOW(), NOW()
    );
    RAISE NOTICE 'Welmy bootstrap admin criado: %', v_email;
  ELSE
    UPDATE auth.users
       SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || v_meta,
           updated_at = NOW()
     WHERE id = v_user_id;
    RAISE NOTICE 'Welmy bootstrap admin já existe, metadata atualizada: %', v_email;
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DELETE FROM auth.identities WHERE user_id IN (SELECT id FROM auth.users WHERE email='admin@welmy.com.br');
-- DELETE FROM auth.users WHERE email='admin@welmy.com.br';
-- NOTIFY pgrst, 'reload schema';
