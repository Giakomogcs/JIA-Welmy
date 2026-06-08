-- ===================================================================
-- 009 — SINCRONIZAÇÃO DO CATÁLOGO DE SKUs (planilha mestre do Drive)
-- ===================================================================
-- A planilha mestre (Google Drive) tem:
--   * Aba "ANÁLISE DE SKUS"  -> produtos finais: DESCRIÇÃO, CODIGO, CURVAS,
--                              MÉDIA MENSAL, CONSUMO DIÁRIO ESTIMADO
--   * Aba "LEAD TIMES"        -> lead times por item
--   * Abas por código          -> árvore de produtos / part numbers (BOM, lida pelo agente)
--
-- O workflow Welmy-Migrate-Planilha substitui o arquivo no Drive e chama esta
-- RPC para distribuir a aba de SKUs no catálogo (wl_item, grupo 'fabricado').
--
-- Estratégia: UPSERT por código (não trunca a tabela, para preservar os
-- componentes vindos do Inventário/Necessidades). Itens de catálogo que saírem
-- da planilha podem ser desativados via p_desativar_ausentes = true.
-- ===================================================================

CREATE TABLE IF NOT EXISTS wl_catalogo_import (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  arquivo      TEXT,
  total_linhas INT     NOT NULL DEFAULT 0,
  atualizados  INT     NOT NULL DEFAULT 0,
  criados      INT     NOT NULL DEFAULT 0,
  desativados  INT     NOT NULL DEFAULT 0,
  criado_por   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION wl_sync_skus_catalogo(
  p_arquivo TEXT,
  p_rows JSONB,
  p_desativar_ausentes BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  r JSONB;
  v_codigo TEXT;
  v_desc   TEXT;
  v_curva  TEXT;
  v_cons   NUMERIC;
  v_existe BOOLEAN;
  v_codigos TEXT[] := ARRAY[]::TEXT[];
  v_atu INT := 0;
  v_cri INT := 0;
  v_des INT := 0;
  v_tot INT := 0;
  v_import_id UUID;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb))
  LOOP
    v_codigo := NULLIF(TRIM(COALESCE(r->>'codigo', r->>'código', r->>'cod')), '');
    IF v_codigo IS NULL THEN CONTINUE; END IF;

    v_desc := NULLIF(TRIM(COALESCE(r->>'descricao', r->>'descrição', r->>'descricao_produto', r->>'produto')), '');

    -- curva: aceita "CURVA A" ou "A"
    v_curva := upper(NULLIF(TRIM(COALESCE(r->>'curva', r->>'curvas')), ''));
    v_curva := NULLIF(regexp_replace(COALESCE(v_curva, ''), '[^ABC]', '', 'g'), '');
    IF v_curva IS NOT NULL THEN v_curva := left(v_curva, 1); END IF;

    v_cons := wl_parse_num(COALESCE(r->>'consumo_diario', r->>'consumo_diaria_estimado', r->>'consumo_diario_estimado', r->>'consumo'));

    v_codigos := array_append(v_codigos, v_codigo);

    SELECT TRUE INTO v_existe FROM wl_item WHERE codigo = v_codigo LIMIT 1;

    IF v_existe THEN
      UPDATE wl_item SET
        descricao      = COALESCE(v_desc, descricao),
        curva          = COALESCE(v_curva, curva),
        consumo_diario = COALESCE(v_cons, consumo_diario),
        ativo          = TRUE
      WHERE codigo = v_codigo;
      v_atu := v_atu + 1;
    ELSE
      INSERT INTO wl_item(codigo, descricao, grupo, unidade, curva, consumo_diario, ativo)
      VALUES (v_codigo, COALESCE(v_desc, v_codigo), 'fabricado', 'un', v_curva, v_cons, TRUE);
      v_cri := v_cri + 1;
    END IF;
    v_tot := v_tot + 1;
  END LOOP;

  -- desativa SKUs de catálogo que saíram da planilha (não apaga: preserva histórico/FKs)
  IF p_desativar_ausentes AND array_length(v_codigos, 1) > 0 THEN
    UPDATE wl_item
       SET ativo = FALSE
     WHERE grupo = 'fabricado'
       AND ativo = TRUE
       AND codigo <> ALL (v_codigos);
    GET DIAGNOSTICS v_des = ROW_COUNT;
  END IF;

  INSERT INTO wl_catalogo_import(arquivo, total_linhas, atualizados, criados, desativados, criado_por)
  VALUES (NULLIF(TRIM(p_arquivo), ''), v_tot, v_atu, v_cri, v_des, auth.uid())
  RETURNING id INTO v_import_id;

  RETURN jsonb_build_object(
    'import_id', v_import_id,
    'total', v_tot, 'atualizados', v_atu, 'criados', v_cri, 'desativados', v_des
  );
END;
$$;

CREATE OR REPLACE FUNCTION wl_list_catalogo_imports(p_limit INT DEFAULT 20)
RETURNS SETOF wl_catalogo_import
SECURITY DEFINER SET search_path = public LANGUAGE sql STABLE AS $$
  SELECT * FROM wl_catalogo_import
   ORDER BY created_at DESC
   LIMIT GREATEST(COALESCE(p_limit, 20), 1);
$$;

GRANT EXECUTE ON FUNCTION wl_sync_skus_catalogo(TEXT, JSONB, BOOLEAN) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_list_catalogo_imports(INT)              TO authenticated, service_role;

ALTER TABLE wl_catalogo_import ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wl_catalogo_import_read ON wl_catalogo_import;
CREATE POLICY wl_catalogo_import_read ON wl_catalogo_import
  FOR SELECT USING (wl_is_member());

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_list_catalogo_imports(INT);
-- DROP FUNCTION IF EXISTS wl_sync_skus_catalogo(TEXT, JSONB, BOOLEAN);
-- DROP TABLE IF EXISTS wl_catalogo_import;
-- NOTIFY pgrst, 'reload schema';
