-- ===================================================================
-- 011 — Necessidade reportada pelo ERP (C) + preenchimento manual (patch)
-- ===================================================================
-- C) O Relatório de Necessidades já traz a coluna final "Necessidade" — que o
--    ERP calcula abatendo estoque disponível e pedidos em aberto
--    (ex.: item 60933 = 1200 saídas − 5 estoque − 600 pedido = 595).
--    Passamos a guardar esse número (necessidade_reportada) e a usá-lo como a
--    necessidade líquida exibida, para a tela bater 100% com o ERP. O motor de
--    regras continua classificando o risco normalmente.
--
-- PERSISTÊNCIA + SOBRESCRITA (requisito do usuário):
--    - wl_patch_item: preenche na interface os dados que faltam (lead time,
--      consumo, fornecedor, etc.) e PERSISTE — só toca nos campos enviados.
--    - Quando uma planilha/relatório novo traz o dado que faltava, a ingestão
--      (COALESCE(novo, existente)) SOBRESCREVE o valor manual pelo da planilha.
--      Ou seja: manual preenche lacuna; planilha manda quando existe.
-- Rode APÓS 010_planilha_mestre_replace.sql
-- ===================================================================

-- =======  UP  ========

ALTER TABLE wl_necessidade ADD COLUMN IF NOT EXISTS necessidade_reportada NUMERIC;

-- ------------------------------------------------------------------
-- C) Ingestão de necessidades — agora capturando a "Necessidade" final do ERP
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_ingest_necessidades(p_plano_id UUID, p_rows JSONB)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  r JSONB;
  v_plano wl_plano;
  v_item wl_item;
  v_codigo TEXT;
  v_bruta NUMERIC; v_estoque NUMERIC; v_consumo NUMERIC; v_lt NUMERIC;
  v_ped_qtd NUMERIC; v_ped_data DATE; v_data_nec DATE;
  v_grupo TEXT; v_forn TEXT; v_sku TEXT; v_impacto INT; v_unico BOOLEAN;
  v_reportada NUMERIC; v_liquida NUMERIC;
  v_cls RECORD;
  v_count INT := 0;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_plano FROM wl_plano WHERE id = p_plano_id;
  IF v_plano.id IS NULL THEN RAISE EXCEPTION 'Plano % não encontrado.', p_plano_id; END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows,'[]'::jsonb))
  LOOP
    v_codigo := NULLIF(TRIM(COALESCE(r->>'codigo', r->>'código', r->>'cod', r->>'item')), '');
    IF v_codigo IS NULL THEN CONTINUE; END IF;

    SELECT * INTO v_item FROM wl_item WHERE codigo = v_codigo LIMIT 1;

    -- necessidade BRUTA = "Total Saídas" do ERP
    v_bruta   := wl_parse_num(COALESCE(r->>'necessidade_bruta', r->>'total_saidas', r->>'nec_bruta', r->>'qtd'));
    -- necessidade FINAL do ERP (coluna "Necessidade", já líquida de estoque+pedidos)
    v_reportada := wl_parse_num(COALESCE(r->>'necessidade', r->>'necessidade_liquida', r->>'necessidade_final'));
    v_estoque := COALESCE(wl_parse_num(COALESCE(r->>'estoque_atual', r->>'estoque', r->>'saldo')), v_item.estoque_atual);
    v_grupo   := COALESCE(NULLIF(TRIM(r->>'grupo'),''), v_item.grupo, 'comprado');
    v_sku     := COALESCE(NULLIF(TRIM(COALESCE(r->>'sku_relacionado', r->>'sku', r->>'produto')),''), v_item.sku_relacionado);
    v_forn    := NULLIF(TRIM(COALESCE(r->>'fornecedor', r->>'fornecedor_nome')),'');
    v_impacto := COALESCE(wl_parse_num(r->>'impacto_skus')::INT, 1);

    -- consumo diário: do item, ou derivado do horizonte de fabricação do plano
    v_consumo := COALESCE(wl_parse_num(r->>'consumo_diario'), v_item.consumo_diario);
    IF v_consumo IS NULL AND v_bruta IS NOT NULL AND COALESCE(v_plano.horizonte_dias,15) > 0 THEN
      v_consumo := ROUND(v_bruta / v_plano.horizonte_dias, 3);
    END IF;

    -- lead time: do relatório, ou do item (real>padrão>etapas)
    v_lt := COALESCE(
      wl_parse_num(COALESCE(r->>'lead_time_real', r->>'lead_time', r->>'leadtime', r->>'lt')),
      wl_item_lead_time(v_item.*)
    );

    -- pedidos em aberto: do relatório, senão da base agregada por código
    v_ped_qtd  := wl_parse_num(COALESCE(r->>'pedido_aberto_qtd', r->>'pedido_aberto', r->>'pedido', r->>'ped_compra'));
    v_ped_data := wl_parse_ts(COALESCE(r->>'pedido_aberto_data', r->>'data_prevista', r->>'previsao'))::date;
    IF v_ped_qtd IS NULL THEN
      SELECT qtd, data_prevista INTO v_ped_qtd, v_ped_data FROM wl_pedidos_abertos_por_codigo(v_codigo);
    END IF;
    v_ped_qtd := COALESCE(v_ped_qtd, 0);

    -- data de necessidade: do relatório, senão a data limite do plano (dia 25)
    v_data_nec := COALESCE(wl_parse_ts(COALESCE(r->>'data_necessidade', r->>'data_limite'))::date, v_plano.data_limite);

    v_unico := COALESCE((SELECT fornecedor_unico FROM wl_fornecedor f WHERE f.id = v_item.fornecedor_id), false);

    SELECT * INTO v_cls FROM wl_classificar_risco(
      v_grupo, (v_item.id IS NOT NULL), v_bruta, v_estoque, v_ped_qtd, v_ped_data,
      v_lt, v_data_nec, v_consumo, v_impacto, v_unico
    );

    -- necessidade líquida exibida = a do ERP quando veio; senão a calculada
    v_liquida := COALESCE(v_reportada, v_cls.nec_liquida);

    INSERT INTO wl_necessidade(
      plano_id, item_id, codigo, descricao, grupo, sku_relacionado, fornecedor_nome,
      necessidade_bruta, estoque_atual, pedido_aberto_qtd, pedido_aberto_data, lead_time_dias, data_necessidade,
      necessidade_liquida, necessidade_reportada, consumo_diario, cobertura_dias, dias_ate_ruptura, chega_a_tempo, impacto_skus,
      risco, prioridade, acao_sugerida, justificativa
    ) VALUES (
      p_plano_id, v_item.id, v_codigo,
      COALESCE(NULLIF(TRIM(r->>'descricao'),''), v_item.descricao),
      v_grupo, v_sku, v_forn,
      v_bruta, v_estoque, v_ped_qtd, v_ped_data, v_lt, v_data_nec,
      v_liquida, v_reportada, v_consumo, v_cls.cobertura_dias, v_cls.dias_ate_ruptura, v_cls.chega_a_tempo, v_impacto,
      v_cls.risco, v_cls.prioridade, v_cls.acao, v_cls.justificativa
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('plano_id', p_plano_id, 'inseridos', v_count);
END;
$$;

-- ------------------------------------------------------------------
-- Preenchimento manual que PERSISTE (patch parcial por código).
-- Só atualiza os campos enviados (não-nulos); cria o item se não existir.
-- Usado pela interface para completar dados que faltam (lead time, consumo,
-- fornecedor, estoque mínimo, etc.). Uma planilha/relatório posterior pode
-- sobrescrever via a ingestão (COALESCE novo > existente).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_patch_item(
  p_codigo TEXT,
  p_descricao TEXT DEFAULT NULL,
  p_grupo TEXT DEFAULT NULL,
  p_unidade TEXT DEFAULT NULL,
  p_sku_relacionado TEXT DEFAULT NULL,
  p_curva TEXT DEFAULT NULL,
  p_fornecedor_id UUID DEFAULT NULL,
  p_lt_fornecedor_dias NUMERIC DEFAULT NULL,
  p_lt_terceiro_dias NUMERIC DEFAULT NULL,
  p_lt_montagem_dias NUMERIC DEFAULT NULL,
  p_lead_time_padrao_dias NUMERIC DEFAULT NULL,
  p_lead_time_real_dias NUMERIC DEFAULT NULL,
  p_estoque_atual NUMERIC DEFAULT NULL,
  p_estoque_minimo NUMERIC DEFAULT NULL,
  p_ponto_pedido NUMERIC DEFAULT NULL,
  p_consumo_diario NUMERIC DEFAULT NULL
)
RETURNS UUID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_id UUID; v_codigo TEXT;
BEGIN
  IF NOT (wl_is_admin() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  v_codigo := NULLIF(TRIM(p_codigo), '');
  IF v_codigo IS NULL THEN RAISE EXCEPTION 'Código é obrigatório.'; END IF;

  SELECT id INTO v_id FROM wl_item WHERE codigo = v_codigo LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO wl_item(
      codigo, descricao, grupo, unidade, sku_relacionado, curva, fornecedor_id,
      lt_fornecedor_dias, lt_terceiro_dias, lt_montagem_dias, lead_time_padrao_dias, lead_time_real_dias,
      estoque_atual, estoque_minimo, ponto_pedido, consumo_diario, ativo
    ) VALUES (
      v_codigo, COALESCE(NULLIF(TRIM(p_descricao),''), v_codigo), COALESCE(p_grupo,'comprado'),
      COALESCE(NULLIF(TRIM(p_unidade),''),'un'), p_sku_relacionado, p_curva, p_fornecedor_id,
      COALESCE(p_lt_fornecedor_dias,0), COALESCE(p_lt_terceiro_dias,0), COALESCE(p_lt_montagem_dias,0),
      p_lead_time_padrao_dias, p_lead_time_real_dias,
      COALESCE(p_estoque_atual,0), COALESCE(p_estoque_minimo,0), p_ponto_pedido, p_consumo_diario, TRUE
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE wl_item SET
      descricao             = COALESCE(NULLIF(TRIM(p_descricao),''), descricao),
      grupo                 = COALESCE(p_grupo, grupo),
      unidade               = COALESCE(NULLIF(TRIM(p_unidade),''), unidade),
      sku_relacionado       = COALESCE(p_sku_relacionado, sku_relacionado),
      curva                 = COALESCE(p_curva, curva),
      fornecedor_id         = COALESCE(p_fornecedor_id, fornecedor_id),
      lt_fornecedor_dias    = COALESCE(p_lt_fornecedor_dias, lt_fornecedor_dias),
      lt_terceiro_dias      = COALESCE(p_lt_terceiro_dias, lt_terceiro_dias),
      lt_montagem_dias      = COALESCE(p_lt_montagem_dias, lt_montagem_dias),
      lead_time_padrao_dias = COALESCE(p_lead_time_padrao_dias, lead_time_padrao_dias),
      lead_time_real_dias   = COALESCE(p_lead_time_real_dias, lead_time_real_dias),
      estoque_atual         = COALESCE(p_estoque_atual, estoque_atual),
      estoque_minimo        = COALESCE(p_estoque_minimo, estoque_minimo),
      ponto_pedido          = COALESCE(p_ponto_pedido, ponto_pedido),
      consumo_diario        = COALESCE(p_consumo_diario, consumo_diario)
    WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION wl_ingest_necessidades(UUID, JSONB) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_patch_item(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_patch_item(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC);
-- ALTER TABLE wl_necessidade DROP COLUMN IF EXISTS necessidade_reportada;
-- (wl_ingest_necessidades: reaplicar a versão de 006)
-- NOTIFY pgrst, 'reload schema';
