-- ===================================================================
-- 013 — MOTOR DE COBERTURA: estoque mínimo, consumo e dias de sobrevivência
-- ===================================================================
-- Os relatórios do ERP NÃO trazem estoque mínimo nem o consumo diário dos
-- componentes — mas o serviço precisa deles ("matéria-prima não pode faltar",
-- "em quantos dias o estoque sobrevive até chegar o pedido"). Esta migração
-- CALCULA esses números a partir do que existe:
--
--   * consumo_diario de COMPONENTE  = Total Saídas do plano ÷ horizonte (15 dias).
--     (produtos finais já têm consumo da aba ANALISE DE SKUS.)
--   * estoque_minimo (quando não definido à mão) = consumo_diario × lead time.
--     É o estoque que segura a produção durante o tempo de reposição do
--     fornecedor/terceiro/montagem — abaixo disso, há risco de ruptura.
--   * dias_ate_ruptura = estoque_atual ÷ consumo_diario.
--   * cobre_lead_time  = dias_ate_ruptura ≥ lead time efetivo.
--
-- Regra de prioridade da Welmy: tudo precisa chegar até o dia 25 (data_limite do
-- plano). Comprar/fabricar com antecedência = lead time, priorizando Curva A,
-- maior necessidade e menor cobertura.
--
-- Rode APÓS 012_planilha_componentes.sql
-- ===================================================================

-- =======  UP  ========

-- ------------------------------------------------------------------
-- Estoque mínimo EFETIVO = manual (se > 0), senão consumo × lead time.
-- Devolve NULL quando não há como calcular (sem consumo ou sem lead time).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_item_estoque_minimo(p wl_item)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    NULLIF(p.estoque_minimo, 0),
    CASE
      WHEN COALESCE(p.consumo_diario, 0) > 0 AND wl_item_lead_time(p) IS NOT NULL
      THEN CEIL(p.consumo_diario * wl_item_lead_time(p))
    END
  );
$$;

-- ------------------------------------------------------------------
-- Ingestão de necessidades — agora também PROPAGA o consumo diário do
-- componente para o catálogo (wl_item), para alimentar estoque mínimo e dias
-- de sobrevivência nas telas de Estoque/Itens. Só preenche quando o item ainda
-- não tem consumo (produtos finais mantêm o consumo da planilha).
-- (Supersede a versão de 011, acrescentando a propagação de consumo.)
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

    v_bruta   := wl_parse_num(COALESCE(r->>'necessidade_bruta', r->>'total_saidas', r->>'nec_bruta', r->>'qtd'));
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

    v_liquida := COALESCE(v_reportada, v_cls.nec_liquida);

    -- >>> propaga o consumo diário derivado para o catálogo (só se faltava) <<<
    IF v_item.id IS NOT NULL AND v_consumo IS NOT NULL
       AND COALESCE(v_item.consumo_diario, 0) = 0 THEN
      UPDATE wl_item SET consumo_diario = v_consumo WHERE id = v_item.id;
    END IF;

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
-- Relatório de estoque — estoque mínimo CALCULADO (consumo × lead time),
-- dias de sobrevivência e se o estoque cobre o lead time.
-- (Supersede a versão de 006; mesma assinatura.)
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_relatorio_estoque(
  p_grupo TEXT DEFAULT NULL, p_apenas_abaixo_minimo BOOLEAN DEFAULT FALSE, p_search TEXT DEFAULT NULL
)
RETURNS TABLE(
  codigo TEXT, descricao TEXT, grupo TEXT, unidade TEXT, curva TEXT, fornecedor_nome TEXT,
  estoque_atual NUMERIC, estoque_minimo NUMERIC, ponto_pedido NUMERIC, consumo_diario NUMERIC,
  dias_ate_ruptura NUMERIC, lead_time_total NUMERIC, cobre_lead_time BOOLEAN, abaixo_minimo BOOLEAN
)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT wl_is_member() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  RETURN QUERY
    SELECT i.codigo, i.descricao, i.grupo, i.unidade, i.curva, f.nome,
           i.estoque_atual,
           wl_item_estoque_minimo(i.*) AS emin,
           COALESCE(NULLIF(i.ponto_pedido,0), wl_item_estoque_minimo(i.*)) AS pp,
           i.consumo_diario,
           CASE WHEN COALESCE(i.consumo_diario,0)>0 THEN ROUND(i.estoque_atual/i.consumo_diario,1) END AS dias_rupt,
           wl_item_lead_time(i.*) AS lt,
           CASE WHEN COALESCE(i.consumo_diario,0)>0 AND wl_item_lead_time(i.*) IS NOT NULL
                THEN (i.estoque_atual/i.consumo_diario) >= wl_item_lead_time(i.*) END AS cobre,
           (wl_item_estoque_minimo(i.*) IS NOT NULL AND i.estoque_atual < wl_item_estoque_minimo(i.*)) AS abaixo
      FROM wl_item i
      LEFT JOIN wl_fornecedor f ON f.id = i.fornecedor_id
     WHERE i.ativo
       AND (p_grupo IS NULL OR i.grupo = p_grupo)
       AND (NOT p_apenas_abaixo_minimo
            OR (wl_item_estoque_minimo(i.*) IS NOT NULL AND i.estoque_atual < wl_item_estoque_minimo(i.*)))
       AND (p_search IS NULL OR i.codigo ILIKE '%'||p_search||'%' OR i.descricao ILIKE '%'||p_search||'%')
     ORDER BY (wl_item_estoque_minimo(i.*) IS NOT NULL AND i.estoque_atual < wl_item_estoque_minimo(i.*)) DESC,
              dias_rupt ASC NULLS LAST, i.codigo;
END;
$$;

-- ------------------------------------------------------------------
-- Lista de itens (Cadastros) — estoque mínimo e ruptura calculados.
-- (Supersede a versão de 006; mesma assinatura/colunas.)
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_list_itens(
  p_only_active BOOLEAN DEFAULT FALSE, p_grupo TEXT DEFAULT NULL,
  p_curva TEXT DEFAULT NULL, p_search TEXT DEFAULT NULL,
  p_abaixo_minimo BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
  id UUID, codigo TEXT, descricao TEXT, grupo TEXT, unidade TEXT,
  sku_relacionado TEXT, curva TEXT, fornecedor_id UUID, fornecedor_nome TEXT,
  lt_fornecedor_dias NUMERIC, lt_terceiro_dias NUMERIC, lt_montagem_dias NUMERIC,
  lead_time_padrao_dias NUMERIC, lead_time_real_dias NUMERIC, lead_time_total NUMERIC,
  estoque_atual NUMERIC, estoque_minimo NUMERIC, ponto_pedido NUMERIC,
  consumo_diario NUMERIC, dias_ate_ruptura NUMERIC, abaixo_minimo BOOLEAN, ativo BOOLEAN
)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT i.id, i.codigo, i.descricao, i.grupo, i.unidade, i.sku_relacionado, i.curva,
           i.fornecedor_id, f.nome,
           i.lt_fornecedor_dias, i.lt_terceiro_dias, i.lt_montagem_dias,
           i.lead_time_padrao_dias, i.lead_time_real_dias, wl_item_lead_time(i.*),
           i.estoque_atual, wl_item_estoque_minimo(i.*),
           COALESCE(NULLIF(i.ponto_pedido,0), wl_item_estoque_minimo(i.*)),
           i.consumo_diario,
           CASE WHEN COALESCE(i.consumo_diario,0) > 0 THEN ROUND(i.estoque_atual / i.consumo_diario, 1) END,
           (wl_item_estoque_minimo(i.*) IS NOT NULL AND i.estoque_atual < wl_item_estoque_minimo(i.*)),
           i.ativo
      FROM wl_item i
      LEFT JOIN wl_fornecedor f ON f.id = i.fornecedor_id
     WHERE (NOT p_only_active OR i.ativo)
       AND (p_grupo IS NULL OR i.grupo = p_grupo)
       AND (p_curva IS NULL OR i.curva = p_curva)
       AND (NOT p_abaixo_minimo
            OR (wl_item_estoque_minimo(i.*) IS NOT NULL AND i.estoque_atual < wl_item_estoque_minimo(i.*)))
       AND (p_search IS NULL OR i.codigo ILIKE '%'||p_search||'%' OR i.descricao ILIKE '%'||p_search||'%')
     ORDER BY (wl_item_estoque_minimo(i.*) IS NOT NULL AND i.estoque_atual < wl_item_estoque_minimo(i.*)) DESC,
              i.curva NULLS LAST, i.codigo;
END;
$$;

-- ------------------------------------------------------------------
-- Stats do painel — "abaixo do mínimo" agora usa o mínimo calculado.
-- (Supersede a versão de 006.)
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_stats()
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
DECLARE v_plano UUID; v JSONB;
BEGIN
  IF NOT wl_is_member() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  SELECT id INTO v_plano FROM wl_plano WHERE status='concluido' ORDER BY created_at DESC LIMIT 1;
  SELECT jsonb_build_object(
    'plano_id', v_plano,
    'risco_alto',      COALESCE((SELECT COUNT(*) FROM wl_necessidade WHERE plano_id=v_plano AND risco='alto'),0),
    'risco_medio',     COALESCE((SELECT COUNT(*) FROM wl_necessidade WHERE plano_id=v_plano AND risco='medio'),0),
    'risco_baixo',     COALESCE((SELECT COUNT(*) FROM wl_necessidade WHERE plano_id=v_plano AND risco='baixo'),0),
    'dado_incompleto', COALESCE((SELECT COUNT(*) FROM wl_necessidade WHERE plano_id=v_plano AND risco='dado_incompleto'),0),
    'total_itens',     COALESCE((SELECT COUNT(*) FROM wl_necessidade WHERE plano_id=v_plano),0),
    'pendentes_decisao', COALESCE((SELECT COUNT(*) FROM wl_necessidade WHERE plano_id=v_plano AND decisao IS NULL AND risco IN ('alto','medio')),0),
    'itens_abaixo_minimo', COALESCE((SELECT COUNT(*) FROM wl_item i WHERE i.ativo
        AND wl_item_estoque_minimo(i.*) IS NOT NULL AND i.estoque_atual < wl_item_estoque_minimo(i.*)),0),
    'itens_total',     COALESCE((SELECT COUNT(*) FROM wl_item WHERE ativo),0)
  ) INTO v;
  RETURN v;
END;
$$;

GRANT EXECUTE ON FUNCTION wl_item_estoque_minimo(wl_item)                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_ingest_necessidades(UUID,JSONB)             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_relatorio_estoque(TEXT,BOOLEAN,TEXT)        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_list_itens(BOOLEAN,TEXT,TEXT,TEXT,BOOLEAN)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_stats()                                     TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- (reaplique 006 e 011 para voltar à versão sem o estoque mínimo calculado)
-- DROP FUNCTION IF EXISTS wl_item_estoque_minimo(wl_item);
