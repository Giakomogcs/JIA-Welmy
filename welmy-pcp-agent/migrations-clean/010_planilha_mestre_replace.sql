-- ===================================================================
-- 010 — SUBSTITUIÇÃO TOTAL PELA PLANILHA MESTRE (catálogo de SKUs + lead times)
-- ===================================================================
-- A planilha mestre do Google Drive
--   (id 1zyhzgErwMMy0HPuhxQ_2q7p51MH8PFZuEdcH8wpSA_Q)
-- é a fonte da verdade do catálogo de produtos finais (SKUs, grupo 'fabricado').
-- Cada SKU tem um lead time (a aba LEAD TIMES, ou uma coluna na própria aba de
-- SKUs). O fornecedor de origem não é modelado aqui (não faz diferença para o
-- cálculo): o que importa é o lead time por SKU.
--
-- Diferente de 009 (wl_sync_skus_catalogo, que faz só upsert), esta RPC faz um
-- REPLACE COMPLETO: ao subir a planilha, o catálogo passa a refletir EXATAMENTE
-- as linhas da planilha — os SKUs que sumiram da planilha são REMOVIDOS.
-- O estoque (estoque_atual) dos SKUs que continuam é preservado, porque ele vem
-- do Registro de Inventário do ERP, não da planilha mestre.
--
-- Chamada pelo workflow Welmy-Migrate-Planilha (n8n, via Postgres = wl_is_backend()).
-- Rode APÓS 009_catalogo_skus.sql
-- ===================================================================

-- =======  UP  ========

CREATE OR REPLACE FUNCTION wl_replace_planilha_mestre(
  p_arquivo   TEXT,
  p_skus      JSONB,
  p_leadtimes JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  r         JSONB;
  v_codigo  TEXT;
  v_desc    TEXT;
  v_curva   TEXT;
  v_cons    NUMERIC;
  v_lt      NUMERIC;
  v_lt_map  JSONB := '{}'::jsonb;   -- código (UPPER) -> lead time
  v_codigos TEXT[] := ARRAY[]::TEXT[];
  v_existe  BOOLEAN;
  v_atu INT := 0;
  v_cri INT := 0;
  v_rem INT := 0;
  v_tot INT := 0;
  v_import_id UUID;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  -- ---------- 1) indexa a aba LEAD TIMES por código ----------
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_leadtimes, '[]'::jsonb))
  LOOP
    v_codigo := NULLIF(TRIM(COALESCE(r->>'codigo', r->>'código', r->>'cod')), '');
    IF v_codigo IS NULL THEN CONTINUE; END IF;
    v_lt := wl_parse_num(COALESCE(
      r->>'lead_time_real', r->>'lead_time_dias', r->>'lead_time',
      r->>'leadtime', r->>'lead', r->>'prazo', r->>'dias', r->>'tempo'
    ));
    IF v_lt IS NOT NULL THEN
      v_lt_map := v_lt_map || jsonb_build_object(upper(v_codigo), v_lt);
    END IF;
  END LOOP;

  -- ---------- 2) upsert da aba de SKUs (com o lead time correspondente) ----------
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_skus, '[]'::jsonb))
  LOOP
    v_codigo := NULLIF(TRIM(COALESCE(r->>'codigo', r->>'código', r->>'cod')), '');
    IF v_codigo IS NULL THEN CONTINUE; END IF;

    v_desc := NULLIF(TRIM(COALESCE(
      r->>'descricao', r->>'descrição', r->>'descricao_produto', r->>'produto'
    )), '');

    -- curva: aceita "CURVA A" ou "A"
    v_curva := upper(NULLIF(TRIM(COALESCE(r->>'curva', r->>'curvas')), ''));
    v_curva := NULLIF(regexp_replace(COALESCE(v_curva, ''), '[^ABC]', '', 'g'), '');
    IF v_curva IS NOT NULL THEN v_curva := left(v_curva, 1); END IF;

    v_cons := wl_parse_num(COALESCE(
      r->>'consumo_diario', r->>'consumo_diaria_estimado',
      r->>'consumo_diario_estimado', r->>'consumo'
    ));

    -- lead time: da própria linha de SKU, senão da aba LEAD TIMES
    v_lt := wl_parse_num(COALESCE(
      r->>'lead_time_real', r->>'lead_time_dias', r->>'lead_time',
      r->>'leadtime', r->>'lead', r->>'prazo'
    ));
    IF v_lt IS NULL THEN
      v_lt := wl_parse_num(v_lt_map->>upper(v_codigo));
    END IF;

    v_codigos := array_append(v_codigos, v_codigo);

    SELECT TRUE INTO v_existe FROM wl_item WHERE codigo = v_codigo LIMIT 1;

    IF v_existe THEN
      UPDATE wl_item SET
        descricao           = COALESCE(v_desc, descricao),
        grupo               = 'fabricado',
        curva               = COALESCE(v_curva, curva),
        consumo_diario      = COALESCE(v_cons, consumo_diario),
        lead_time_real_dias = COALESCE(v_lt, lead_time_real_dias),
        ativo               = TRUE
      WHERE codigo = v_codigo;
      v_atu := v_atu + 1;
    ELSE
      INSERT INTO wl_item(codigo, descricao, grupo, unidade, curva, consumo_diario, lead_time_real_dias, ativo)
      VALUES (v_codigo, COALESCE(v_desc, v_codigo), 'fabricado', 'un', v_curva, v_cons, v_lt, TRUE);
      v_cri := v_cri + 1;
    END IF;
    v_tot := v_tot + 1;
  END LOOP;

  -- ---------- 3) aplica os lead times da aba LEAD TIMES a QUALQUER item ----------
  -- (não só os SKUs fabricados: componentes comprados/MP também têm prazo na
  -- aba LEAD TIMES). A planilha é autoritativa: sobrescreve lead_time_real_dias
  -- de quem ela traz; quem ela não traz mantém o valor atual (inclusive o que
  -- foi preenchido manualmente na interface).
  FOR v_codigo, v_lt IN
    SELECT key, value::numeric FROM jsonb_each_text(v_lt_map)
  LOOP
    UPDATE wl_item
       SET lead_time_real_dias = v_lt
     WHERE upper(codigo) = v_codigo;
  END LOOP;

  -- ---------- 4) REPLACE: remove SKUs de catálogo que saíram da planilha ----------
  -- Só remove quando a planilha trouxe linhas (evita zerar o catálogo se a
  -- leitura da aba falhar e vier vazia).
  IF array_length(v_codigos, 1) > 0 THEN
    DELETE FROM wl_item
     WHERE grupo = 'fabricado'
       AND codigo <> ALL (v_codigos);
    GET DIAGNOSTICS v_rem = ROW_COUNT;
  END IF;

  INSERT INTO wl_catalogo_import(arquivo, total_linhas, atualizados, criados, desativados, criado_por)
  VALUES (NULLIF(TRIM(p_arquivo), ''), v_tot, v_atu, v_cri, v_rem, auth.uid())
  RETURNING id INTO v_import_id;

  RETURN jsonb_build_object(
    'import_id', v_import_id,
    'total', v_tot,
    'atualizados', v_atu,
    'criados', v_cri,
    'removidos', v_rem
  );
END;
$$;

GRANT EXECUTE ON FUNCTION wl_replace_planilha_mestre(TEXT, JSONB, JSONB) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_replace_planilha_mestre(TEXT, JSONB, JSONB);
-- NOTIFY pgrst, 'reload schema';
