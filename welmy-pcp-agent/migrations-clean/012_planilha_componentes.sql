-- ===================================================================
-- 012 — PLANILHA MESTRE: catálogo COMPLETO (SKUs + componentes da aba LEAD TIMES)
-- ===================================================================
-- Evolui wl_replace_planilha_mestre (010) para aproveitar TODA a planilha mestre
-- conectada (id 1zyhzgErwMMy0HPuhxQ_2q7p51MH8PFZuEdcH8wpSA_Q):
--
--   * aba 'ANALISE DE SKUS'  → produtos finais (grupo 'fabricado'): descrição,
--                              código, curva, consumo diário.
--   * aba 'LEAD TIMES'       → catálogo de COMPONENTES, com colunas reais:
--                              CODIGO | DESCRIÇÃO | UNIDADES | FABRICA/COMPRADO |
--                              FORNECEDOR | LEAD TIME DIAS.
--                              Agora cada componente é cadastrado/atualizado com
--                              descrição, unidade, grupo (F→'fabricado',
--                              C→'comprado'), fornecedor (wl_fornecedor) e lead time.
--
-- O REPLACE total continua valendo só para o grupo 'fabricado' (produtos finais +
-- componentes fabricados): códigos 'fabricado' que sumiram da planilha são
-- REMOVIDOS. Itens 'comprado'/'materia_prima'/'embalagem' nunca são removidos por
-- aqui (eles também vêm do Registro de Inventário do ERP). O estoque (estoque_atual)
-- é sempre preservado — vem do inventário, não da planilha.
--
-- Chamada pelo workflow Welmy-Migrate-Planilha (n8n). Mesma assinatura de 010.
-- Rode APÓS 010_planilha_mestre_replace.sql
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
  r          JSONB;
  v_codigo   TEXT;
  v_desc     TEXT;
  v_curva    TEXT;
  v_cons     NUMERIC;
  v_lt       NUMERIC;
  v_und      TEXT;
  v_fc       TEXT;
  v_grupo    TEXT;
  v_forn     TEXT;
  v_forn_id  UUID;
  v_lt_map   JSONB := '{}'::jsonb;   -- código (UPPER) -> lead time
  v_fab_cods TEXT[] := ARRAY[]::TEXT[];  -- códigos 'fabricado' trazidos pela planilha (SKUs + componentes F)
  v_existe   BOOLEAN;
  v_atu INT := 0;
  v_cri INT := 0;
  v_rem INT := 0;
  v_tot INT := 0;
  v_comp INT := 0;
  v_import_id UUID;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  -- ---------- 1) aba LEAD TIMES: indexa lead time + cadastra componentes ----------
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

    -- demais colunas reais da aba LEAD TIMES
    v_desc := NULLIF(TRIM(COALESCE(r->>'descricao', r->>'descrição', r->>'descricao_produto')), '');
    v_und  := NULLIF(TRIM(COALESCE(r->>'unidade', r->>'unidades', r->>'und', r->>'un')), '');

    -- FABRICA/COMPRADO → grupo
    v_fc := upper(LEFT(NULLIF(TRIM(COALESCE(
      r->>'grupo', r->>'fabrica_comprado', r->>'fabrica/comprado', r->>'fc', r->>'f_c', r->>'f/c'
    )), ''), 1));
    v_grupo := CASE v_fc WHEN 'F' THEN 'fabricado' WHEN 'C' THEN 'comprado' ELSE NULL END;

    -- fornecedor (upsert em wl_fornecedor por nome)
    v_forn := NULLIF(TRIM(COALESCE(r->>'fornecedor', r->>'forn')), '');
    v_forn_id := NULL;
    IF v_forn IS NOT NULL THEN
      SELECT id INTO v_forn_id FROM wl_fornecedor WHERE lower(nome) = lower(v_forn) LIMIT 1;
      IF v_forn_id IS NULL THEN
        INSERT INTO wl_fornecedor(nome) VALUES (v_forn) RETURNING id INTO v_forn_id;
      END IF;
    END IF;

    IF v_grupo = 'fabricado' THEN
      v_fab_cods := array_append(v_fab_cods, v_codigo);
    END IF;

    -- upsert do componente (sem mexer no estoque)
    SELECT TRUE INTO v_existe FROM wl_item WHERE codigo = v_codigo LIMIT 1;
    IF v_existe THEN
      UPDATE wl_item SET
        descricao           = COALESCE(v_desc, descricao),
        unidade             = COALESCE(v_und, unidade),
        grupo               = COALESCE(v_grupo, grupo),
        fornecedor_id       = COALESCE(v_forn_id, fornecedor_id),
        lead_time_real_dias = COALESCE(v_lt, lead_time_real_dias),
        -- o total da planilha é o lead time do fornecedor para itens comprados
        lt_fornecedor_dias  = CASE WHEN COALESCE(v_grupo, grupo) = 'comprado'
                                   THEN COALESCE(v_lt, lt_fornecedor_dias)
                                   ELSE lt_fornecedor_dias END,
        ativo               = TRUE
      WHERE codigo = v_codigo;
    ELSE
      INSERT INTO wl_item(codigo, descricao, grupo, unidade, fornecedor_id, lead_time_real_dias, lt_fornecedor_dias, ativo)
      VALUES (
        v_codigo, COALESCE(v_desc, v_codigo), COALESCE(v_grupo, 'comprado'),
        COALESCE(v_und, 'un'), v_forn_id, v_lt,
        CASE WHEN COALESCE(v_grupo, 'comprado') = 'comprado' THEN COALESCE(v_lt, 0) ELSE 0 END,
        TRUE
      );
      v_cri := v_cri + 1;
    END IF;
    v_comp := v_comp + 1;
  END LOOP;

  -- ---------- 2) aba ANALISE DE SKUS: produtos finais (grupo 'fabricado') ----------
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

    v_fab_cods := array_append(v_fab_cods, v_codigo);

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

  -- ---------- 3) aplica os lead times (aba LEAD TIMES) a QUALQUER item ----------
  FOR v_codigo, v_lt IN
    SELECT key, value::numeric FROM jsonb_each_text(v_lt_map)
  LOOP
    UPDATE wl_item
       SET lead_time_real_dias = v_lt
     WHERE upper(codigo) = v_codigo;
  END LOOP;

  -- ---------- 4) REPLACE: remove 'fabricado' que saíram da planilha ----------
  -- (produtos finais + componentes fabricados que a planilha já não traz). Itens
  -- comprado/materia_prima/embalagem nunca são removidos aqui (vêm do inventário).
  IF array_length(v_fab_cods, 1) > 0 THEN
    DELETE FROM wl_item
     WHERE grupo = 'fabricado'
       AND codigo <> ALL (v_fab_cods);
    GET DIAGNOSTICS v_rem = ROW_COUNT;
  END IF;

  INSERT INTO wl_catalogo_import(arquivo, total_linhas, atualizados, criados, desativados, criado_por)
  VALUES (NULLIF(TRIM(p_arquivo), ''), v_tot + v_comp, v_atu, v_cri, v_rem, auth.uid())
  RETURNING id INTO v_import_id;

  RETURN jsonb_build_object(
    'import_id', v_import_id,
    'total', v_tot,
    'componentes', v_comp,
    'atualizados', v_atu,
    'criados', v_cri,
    'removidos', v_rem
  );
END;
$$;

GRANT EXECUTE ON FUNCTION wl_replace_planilha_mestre(TEXT, JSONB, JSONB) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- (reaplique 010_planilha_mestre_replace.sql para voltar à versão sem componentes)
