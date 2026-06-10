-- =============================================
-- Welmy — 005: Suprimentos & PCP — RPCs / motor de regras
-- (consolidada: antigas 006 + 011 + 013 + 014 — só as versões FINAIS)
--
-- O motor de regras (determinístico) calcula cobertura, dias até ruptura e
-- classifica o risco. O LLM só escreve a justificativa executiva.
--
-- Inclui (versões finais):
--   * CRUD fornecedores / itens / pedidos (+ wl_patch_item: patch parcial manual)
--   * wl_classificar_risco(...)            — regra pura de classificação
--   * wl_create_plano / wl_ingest_necessidades (com necessidade_reportada do ERP
--     e propagação do consumo diário p/ o catálogo)
--   * wl_finalize_plano                    — MRP ÚNICO: apaga os planos anteriores
--   * wl_analisar_plano / wl_reprocessar_plano / wl_delete_plano
--   * wl_dashboard_necessidades / wl_get_necessidade
--   * wl_relatorio_estoque / wl_relatorio_mrp / wl_leadtime_skus / wl_list_itens
--     (estoque mínimo CALCULADO = consumo × lead time, via wl_item_estoque_minimo)
--   * wl_record_decision / wl_learning_signals / wl_list_planos / wl_stats
-- Rode APÓS 004_suprimentos_schema.sql
-- =============================================

-- =======  UP  ========

-- ===================================================================
-- CRUD: FORNECEDORES (admin)
-- ===================================================================
CREATE OR REPLACE FUNCTION wl_list_fornecedores(p_only_active BOOLEAN DEFAULT FALSE)
RETURNS SETOF wl_fornecedor
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM wl_fornecedor f
   WHERE (NOT p_only_active OR f.ativo) ORDER BY f.nome;
END;
$$;

CREATE OR REPLACE FUNCTION wl_admin_upsert_fornecedor(
  p_id UUID, p_nome TEXT, p_tipo TEXT, p_cnpj TEXT DEFAULT NULL,
  p_lead_time_medio_dias NUMERIC DEFAULT NULL, p_atraso_medio_dias NUMERIC DEFAULT 0,
  p_fornecedor_unico BOOLEAN DEFAULT FALSE, p_contato TEXT DEFAULT NULL,
  p_observacoes TEXT DEFAULT NULL, p_ativo BOOLEAN DEFAULT TRUE
)
RETURNS UUID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT (wl_is_admin() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO wl_fornecedor(nome,cnpj,tipo,lead_time_medio_dias,atraso_medio_dias,fornecedor_unico,contato,observacoes,ativo)
    VALUES (p_nome,p_cnpj,COALESCE(p_tipo,'fornecedor'),p_lead_time_medio_dias,COALESCE(p_atraso_medio_dias,0),COALESCE(p_fornecedor_unico,false),p_contato,p_observacoes,COALESCE(p_ativo,true))
    RETURNING id INTO v_id;
  ELSE
    UPDATE wl_fornecedor SET
      nome=p_nome, cnpj=p_cnpj, tipo=COALESCE(p_tipo,tipo),
      lead_time_medio_dias=p_lead_time_medio_dias, atraso_medio_dias=COALESCE(p_atraso_medio_dias,0),
      fornecedor_unico=COALESCE(p_fornecedor_unico,false), contato=p_contato,
      observacoes=p_observacoes, ativo=COALESCE(p_ativo,true)
    WHERE id=p_id RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION wl_admin_delete_fornecedor(p_id UUID)
RETURNS VOID SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT wl_is_admin() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  DELETE FROM wl_fornecedor WHERE id=p_id;
END;
$$;

-- ===================================================================
-- CRUD: ITENS / COMPONENTES (admin) — estoque mínimo/ruptura CALCULADOS
-- ===================================================================
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

CREATE OR REPLACE FUNCTION wl_admin_upsert_item(
  p_id UUID, p_codigo TEXT, p_descricao TEXT, p_grupo TEXT,
  p_unidade TEXT DEFAULT 'un', p_sku_relacionado TEXT DEFAULT NULL, p_curva TEXT DEFAULT NULL,
  p_fornecedor_id UUID DEFAULT NULL,
  p_lt_fornecedor_dias NUMERIC DEFAULT 0, p_lt_terceiro_dias NUMERIC DEFAULT 0, p_lt_montagem_dias NUMERIC DEFAULT 0,
  p_lead_time_padrao_dias NUMERIC DEFAULT NULL, p_lead_time_real_dias NUMERIC DEFAULT NULL,
  p_estoque_atual NUMERIC DEFAULT 0, p_estoque_minimo NUMERIC DEFAULT 0,
  p_ponto_pedido NUMERIC DEFAULT NULL, p_consumo_diario NUMERIC DEFAULT NULL,
  p_ativo BOOLEAN DEFAULT TRUE
)
RETURNS UUID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT (wl_is_admin() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  INSERT INTO wl_item(
    id, codigo, descricao, grupo, unidade, sku_relacionado, curva, fornecedor_id,
    lt_fornecedor_dias, lt_terceiro_dias, lt_montagem_dias, lead_time_padrao_dias, lead_time_real_dias,
    estoque_atual, estoque_minimo, ponto_pedido, consumo_diario, ativo
  ) VALUES (
    COALESCE(p_id, gen_random_uuid()), p_codigo, p_descricao, COALESCE(p_grupo,'comprado'),
    COALESCE(p_unidade,'un'), p_sku_relacionado, p_curva, p_fornecedor_id,
    COALESCE(p_lt_fornecedor_dias,0), COALESCE(p_lt_terceiro_dias,0), COALESCE(p_lt_montagem_dias,0),
    p_lead_time_padrao_dias, p_lead_time_real_dias,
    COALESCE(p_estoque_atual,0), COALESCE(p_estoque_minimo,0), p_ponto_pedido, p_consumo_diario, COALESCE(p_ativo,true)
  )
  ON CONFLICT (codigo) DO UPDATE SET
    descricao=EXCLUDED.descricao, grupo=EXCLUDED.grupo, unidade=EXCLUDED.unidade,
    sku_relacionado=EXCLUDED.sku_relacionado, curva=EXCLUDED.curva, fornecedor_id=EXCLUDED.fornecedor_id,
    lt_fornecedor_dias=EXCLUDED.lt_fornecedor_dias, lt_terceiro_dias=EXCLUDED.lt_terceiro_dias,
    lt_montagem_dias=EXCLUDED.lt_montagem_dias, lead_time_padrao_dias=EXCLUDED.lead_time_padrao_dias,
    lead_time_real_dias=EXCLUDED.lead_time_real_dias, estoque_atual=EXCLUDED.estoque_atual,
    estoque_minimo=EXCLUDED.estoque_minimo, ponto_pedido=EXCLUDED.ponto_pedido,
    consumo_diario=EXCLUDED.consumo_diario, ativo=EXCLUDED.ativo
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION wl_admin_delete_item(p_id UUID)
RETURNS VOID SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT wl_is_admin() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  DELETE FROM wl_item WHERE id=p_id;
END;
$$;

-- ------------------------------------------------------------------
-- Preenchimento manual que PERSISTE (patch parcial por código).
-- Só atualiza os campos enviados (não-nulos); cria o item se não existir.
-- Uma planilha/relatório posterior pode sobrescrever via ingestão
-- (COALESCE novo > existente): manual preenche lacuna; planilha manda.
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

-- ===================================================================
-- PEDIDOS de compra em aberto (backend ou admin)
-- ===================================================================
CREATE OR REPLACE FUNCTION wl_upsert_pedido(
  p_id UUID, p_numero TEXT, p_codigo TEXT, p_quantidade NUMERIC,
  p_data_pedido DATE, p_data_prevista DATE, p_status TEXT DEFAULT 'aberto',
  p_fornecedor_id UUID DEFAULT NULL, p_observacoes TEXT DEFAULT NULL
)
RETURNS UUID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_id UUID; v_item UUID;
BEGIN
  IF NOT (wl_is_admin() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  SELECT id INTO v_item FROM wl_item WHERE codigo = p_codigo LIMIT 1;
  IF p_id IS NULL THEN
    INSERT INTO wl_pedido_compra(numero,item_id,codigo,fornecedor_id,quantidade,data_pedido,data_prevista,status,observacoes)
    VALUES (p_numero,v_item,p_codigo,p_fornecedor_id,COALESCE(p_quantidade,0),p_data_pedido,p_data_prevista,COALESCE(p_status,'aberto'),p_observacoes)
    RETURNING id INTO v_id;
  ELSE
    UPDATE wl_pedido_compra SET
      numero=p_numero,item_id=v_item,codigo=p_codigo,fornecedor_id=p_fornecedor_id,
      quantidade=COALESCE(p_quantidade,0),data_pedido=p_data_pedido,data_prevista=p_data_prevista,
      status=COALESCE(p_status,'aberto'),observacoes=p_observacoes
    WHERE id=p_id RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$;

-- pedidos em aberto agregados por código (qtd total + chegada mais próxima)
CREATE OR REPLACE FUNCTION wl_pedidos_abertos_por_codigo(p_codigo TEXT)
RETURNS TABLE(qtd NUMERIC, data_prevista DATE)
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(quantidade),0), MIN(data_prevista)
    FROM wl_pedido_compra
   WHERE codigo = p_codigo AND status IN ('aberto','parcial','atrasado');
$$;

-- ===================================================================
-- MOTOR DE REGRAS — classificação de risco
-- ===================================================================
CREATE OR REPLACE FUNCTION wl_classificar_risco(
  p_grupo            TEXT,
  p_tem_item         BOOLEAN,   -- existe item cadastrado (vínculo BOM/base)?
  p_necessidade_bruta NUMERIC,
  p_estoque          NUMERIC,
  p_pedido_qtd       NUMERIC,
  p_pedido_data      DATE,
  p_lead_time        NUMERIC,
  p_data_necessidade DATE,
  p_consumo_diario   NUMERIC,
  p_impacto_skus     INT,
  p_fornecedor_unico BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
  risco TEXT, acao TEXT, justificativa TEXT, prioridade INT,
  nec_liquida NUMERIC, cobertura_dias NUMERIC, dias_ate_ruptura NUMERIC, chega_a_tempo BOOLEAN
)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_nec_liq NUMERIC;
  v_cob NUMERIC;
  v_rupt NUMERIC;
  v_tem_pedido BOOLEAN;
  v_chega BOOLEAN;
  v_risco TEXT;
  v_acao TEXT;
  v_just TEXT;
  v_prio INT;
  v_base INT;
  v_estoque NUMERIC := COALESCE(p_estoque, 0);
  v_bruta NUMERIC := COALESCE(p_necessidade_bruta, 0);
  v_ped NUMERIC := COALESCE(p_pedido_qtd, 0);
BEGIN
  v_nec_liq := v_bruta - v_estoque;
  v_tem_pedido := v_ped > 0;
  IF COALESCE(p_consumo_diario,0) > 0 THEN
    v_cob  := ROUND((v_estoque + v_ped) / p_consumo_diario, 1);
    v_rupt := ROUND(v_estoque / p_consumo_diario, 1);
  END IF;
  IF p_pedido_data IS NOT NULL AND p_data_necessidade IS NOT NULL THEN
    v_chega := p_pedido_data <= p_data_necessidade;
  END IF;

  -- ----- DADO INCOMPLETO -----
  IF (NOT COALESCE(p_tem_item, false))
     OR p_lead_time IS NULL
     OR p_data_necessidade IS NULL
     OR (v_estoque = 0 AND COALESCE(p_consumo_diario,0) = 0) THEN
    v_risco := 'dado_incompleto';
    v_acao  := CASE WHEN v_estoque = 0 AND COALESCE(p_consumo_diario,0) = 0
                    THEN 'validar_estoque' ELSE 'revisar_dado' END;
    v_just  := 'Dado insuficiente: ' ||
               concat_ws(', ',
                 CASE WHEN NOT COALESCE(p_tem_item,false) THEN 'item sem cadastro/BOM' END,
                 CASE WHEN p_lead_time IS NULL THEN 'lead time ausente' END,
                 CASE WHEN p_data_necessidade IS NULL THEN 'sem data de necessidade' END,
                 CASE WHEN v_estoque = 0 AND COALESCE(p_consumo_diario,0)=0 THEN 'estoque zerado sem histórico' END
               ) || '.';
    v_base := 50;
  -- ----- RISCO ALTO -----
  ELSIF (v_nec_liq > 0 AND NOT v_tem_pedido AND v_estoque < 0.5 * v_bruta)
        OR (v_nec_liq > 0 AND v_tem_pedido AND v_chega IS FALSE)
        OR (v_nec_liq > 0 AND (v_estoque + v_ped) < v_bruta AND COALESCE(v_chega, false) = false) THEN
    v_risco := 'alto';
    v_just  := CASE
      WHEN NOT v_tem_pedido THEN format('Falta líquida de %s un. e sem pedido de compra em aberto.', round(v_nec_liq))
      WHEN v_chega IS FALSE THEN format('Falta de %s un.: pedido em aberto chega depois da data de necessidade.', round(v_nec_liq))
      ELSE format('Estoque + pedidos não cobrem a necessidade (falta %s un.).', round(v_nec_liq)) END;
    v_base := 300;
  -- ----- RISCO MÉDIO -----
  ELSIF (v_cob IS NOT NULL AND p_lead_time IS NOT NULL AND v_cob < p_lead_time)
        OR (v_tem_pedido AND v_chega IS TRUE AND p_pedido_data IS NOT NULL AND p_data_necessidade IS NOT NULL
            AND (p_data_necessidade - p_pedido_data) <= 3) THEN
    v_risco := 'medio';
    v_just  := CASE
      WHEN v_cob IS NOT NULL AND p_lead_time IS NOT NULL AND v_cob < p_lead_time
        THEN format('Cobertura projetada (%s dias) menor que o lead time do fornecedor (%s dias).', v_cob, round(p_lead_time))
      ELSE 'Pedido em aberto com chegada próxima do limite da necessidade.' END;
    v_base := 200;
  -- ----- RISCO BAIXO -----
  ELSE
    v_risco := 'baixo';
    v_just  := 'Estoque e pedidos cobrem a demanda dentro do prazo.';
    v_base := 100;
  END IF;

  -- ----- AÇÃO SUGERIDA por grupo + risco -----
  IF v_risco = 'dado_incompleto' THEN
    NULL; -- v_acao já definida
  ELSIF v_risco = 'baixo' THEN
    v_acao := 'ok';
  ELSE
    v_acao := CASE p_grupo
      WHEN 'fabricado'          THEN CASE WHEN v_risco='alto' THEN 'fabricar' ELSE 'programar_fabricacao' END
      WHEN 'fabricado_terceiro' THEN 'acionar_fornecedor'
      ELSE CASE WHEN v_tem_pedido THEN 'acompanhar_pedido'
                WHEN v_risco='alto' THEN 'comprar'
                ELSE 'acionar_fornecedor' END
    END;
  END IF;

  -- ----- PRIORIDADE (impacto na montagem + urgência) -----
  v_prio := v_base
            + COALESCE(p_impacto_skus,0) * 5
            + CASE WHEN COALESCE(p_fornecedor_unico,false) THEN 25 ELSE 0 END
            + CASE WHEN v_rupt IS NOT NULL THEN GREATEST(0, 30 - LEAST(30, v_rupt::INT)) ELSE 0 END
            + CASE WHEN p_grupo IN ('materia_prima','fabricado_terceiro') THEN 10 ELSE 0 END;

  risco := v_risco; acao := v_acao; justificativa := v_just; prioridade := v_prio;
  nec_liquida := v_nec_liq; cobertura_dias := v_cob; dias_ate_ruptura := v_rupt; chega_a_tempo := v_chega;
  RETURN NEXT;
END;
$$;

-- ===================================================================
-- PLANO: criar + ingerir linhas do relatório + analisar
-- ===================================================================
CREATE OR REPLACE FUNCTION wl_create_plano(
  p_label TEXT, p_competencia DATE DEFAULT NULL, p_data_limite DATE DEFAULT NULL,
  p_horizonte_dias INT DEFAULT 15, p_qtd_pecas_plano NUMERIC DEFAULT NULL
)
RETURNS UUID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_id UUID; v_comp DATE; v_lim DATE;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  v_comp := COALESCE(p_competencia, date_trunc('month', CURRENT_DATE)::date);
  -- regra Welmy: tudo precisa chegar até o dia 25 do mês de competência
  v_lim  := COALESCE(p_data_limite, (date_trunc('month', v_comp) + INTERVAL '24 days')::date);
  INSERT INTO wl_plano(label, competencia, data_limite, horizonte_dias, qtd_pecas_plano, status, criado_por, started_at)
  VALUES (COALESCE(p_label,'Relatório '||to_char(v_comp,'MM/YYYY')), v_comp, v_lim,
          COALESCE(p_horizonte_dias,15), p_qtd_pecas_plano, 'processando', auth.uid(), NOW())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ------------------------------------------------------------------
-- Ingestão de linhas do Relatório de Necessidades (chamada pelo n8n em lote).
-- p_rows = array JSON com chaves flexíveis (parse defensivo).
-- Versão FINAL: captura a "Necessidade" do ERP (necessidade_reportada, já
-- líquida de estoque+pedidos) e PROPAGA o consumo diário derivado para o
-- catálogo (wl_item), quando o item ainda não tinha consumo.
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

    -- propaga o consumo diário derivado para o catálogo (só se faltava)
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
-- Finalizar plano (versão FINAL — MRP ÚNICO): consolida os contadores de
-- risco E mantém SOMENTE este plano como MRP vigente, apagando os demais
-- (wl_necessidade tem ON DELETE CASCADE).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_finalize_plano(p_plano_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v JSONB; v_removidos INT := 0;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  UPDATE wl_plano p SET
    total_itens     = s.total,
    risco_alto      = s.alto,
    risco_medio     = s.medio,
    risco_baixo     = s.baixo,
    dado_incompleto = s.incompleto,
    status='concluido', finished_at=NOW()
  FROM (
    SELECT COUNT(*) total,
      COUNT(*) FILTER (WHERE risco='alto') alto,
      COUNT(*) FILTER (WHERE risco='medio') medio,
      COUNT(*) FILTER (WHERE risco='baixo') baixo,
      COUNT(*) FILTER (WHERE risco='dado_incompleto') incompleto
    FROM wl_necessidade WHERE plano_id = p_plano_id
  ) s
  WHERE p.id = p_plano_id;

  -- substituição total: o novo relatório é o MRP — descarta os anteriores.
  DELETE FROM wl_plano WHERE id <> p_plano_id;
  GET DIAGNOSTICS v_removidos = ROW_COUNT;

  SELECT to_jsonb(p) INTO v FROM wl_plano p WHERE p.id = p_plano_id;
  RETURN COALESCE(v, '{}'::jsonb) || jsonb_build_object('planos_removidos', v_removidos);
END;
$$;

-- Reanalisa todas as linhas de um plano com as bases atuais (estoque/pedidos/lead time).
CREATE OR REPLACE FUNCTION wl_analisar_plano(p_plano_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  n wl_necessidade; v_item wl_item; v_cls RECORD; v_ped_qtd NUMERIC; v_ped_data DATE; v_unico BOOLEAN; v_lt NUMERIC; v_n INT := 0;
  v_plano wl_plano;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_plano FROM wl_plano WHERE id = p_plano_id;
  FOR n IN SELECT * FROM wl_necessidade WHERE plano_id = p_plano_id AND decisao IS NULL
  LOOP
    SELECT * INTO v_item FROM wl_item WHERE id = n.item_id OR codigo = n.codigo LIMIT 1;
    SELECT qtd, data_prevista INTO v_ped_qtd, v_ped_data FROM wl_pedidos_abertos_por_codigo(n.codigo);
    v_ped_qtd := COALESCE(v_ped_qtd, n.pedido_aberto_qtd, 0);
    v_ped_data := COALESCE(v_ped_data, n.pedido_aberto_data);
    v_lt := COALESCE(wl_item_lead_time(v_item.*), n.lead_time_dias);
    v_unico := COALESCE((SELECT fornecedor_unico FROM wl_fornecedor f WHERE f.id = v_item.fornecedor_id), false);

    SELECT * INTO v_cls FROM wl_classificar_risco(
      COALESCE(v_item.grupo, n.grupo), (v_item.id IS NOT NULL),
      n.necessidade_bruta, COALESCE(v_item.estoque_atual, n.estoque_atual),
      v_ped_qtd, v_ped_data, v_lt, COALESCE(n.data_necessidade, v_plano.data_limite),
      COALESCE(v_item.consumo_diario, n.consumo_diario), n.impacto_skus, v_unico
    );
    UPDATE wl_necessidade SET
      item_id=COALESCE(v_item.id,item_id), estoque_atual=COALESCE(v_item.estoque_atual,estoque_atual),
      pedido_aberto_qtd=v_ped_qtd, pedido_aberto_data=v_ped_data, lead_time_dias=v_lt,
      necessidade_liquida=COALESCE(necessidade_reportada, v_cls.nec_liquida), cobertura_dias=v_cls.cobertura_dias,
      dias_ate_ruptura=v_cls.dias_ate_ruptura, chega_a_tempo=v_cls.chega_a_tempo,
      risco=v_cls.risco, prioridade=v_cls.prioridade, acao_sugerida=v_cls.acao, justificativa=v_cls.justificativa
    WHERE id=n.id;
    v_n := v_n + 1;
  END LOOP;
  RETURN wl_finalize_plano(p_plano_id) || jsonb_build_object('reanalisados', v_n);
END;
$$;

-- Reprocessar = reanalisar o plano com as bases atuais (alias semântico).
CREATE OR REPLACE FUNCTION wl_reprocessar_plano(p_plano_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  RETURN wl_analisar_plano(p_plano_id);
END;
$$;

-- Excluir um plano (e, em cascata, suas necessidades).
CREATE OR REPLACE FUNCTION wl_delete_plano(p_plano_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_removidos INT := 0;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM wl_plano WHERE id = p_plano_id;
  GET DIAGNOSTICS v_removidos = ROW_COUNT;
  RETURN jsonb_build_object('plano_id', p_plano_id, 'removidos', v_removidos);
END;
$$;

-- grava a justificativa executiva do LLM numa linha (backend)
CREATE OR REPLACE FUNCTION wl_set_justificativa_ia(p_necessidade_id UUID, p_texto TEXT)
RETURNS VOID SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  UPDATE wl_necessidade SET justificativa_ia = p_texto WHERE id = p_necessidade_id;
END;
$$;

-- ===================================================================
-- DASHBOARD / RELATÓRIOS
-- ===================================================================
-- Lista priorizada das necessidades de um plano.
CREATE OR REPLACE FUNCTION wl_dashboard_necessidades(
  p_plano_id UUID DEFAULT NULL, p_risco TEXT DEFAULT NULL, p_grupo TEXT DEFAULT NULL,
  p_search TEXT DEFAULT NULL, p_sort TEXT DEFAULT NULL,
  p_limit INT DEFAULT 50, p_offset INT DEFAULT 0
)
RETURNS TABLE(
  id UUID, plano_id UUID, codigo TEXT, descricao TEXT, grupo TEXT, sku_relacionado TEXT,
  fornecedor_nome TEXT, necessidade_bruta NUMERIC, estoque_atual NUMERIC, necessidade_liquida NUMERIC,
  pedido_aberto_qtd NUMERIC, pedido_aberto_data DATE, lead_time_dias NUMERIC, data_necessidade DATE,
  cobertura_dias NUMERIC, dias_ate_ruptura NUMERIC, chega_a_tempo BOOLEAN, impacto_skus INT,
  risco TEXT, prioridade INT, acao_sugerida TEXT, justificativa TEXT, justificativa_ia TEXT,
  decisao TEXT, total_count BIGINT
)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
DECLARE v_plano UUID := p_plano_id;
BEGIN
  IF NOT wl_is_member() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  IF v_plano IS NULL THEN
    SELECT pl.id INTO v_plano FROM wl_plano pl WHERE pl.status='concluido' ORDER BY pl.created_at DESC LIMIT 1;
  END IF;
  RETURN QUERY
    WITH base AS (
      SELECT n.*, COUNT(*) OVER() AS total_count
        FROM wl_necessidade n
       WHERE (v_plano IS NULL OR n.plano_id = v_plano)
         AND (p_risco IS NULL OR n.risco = p_risco)
         AND (p_grupo IS NULL OR n.grupo = p_grupo)
         AND (p_search IS NULL OR n.codigo ILIKE '%'||p_search||'%' OR n.descricao ILIKE '%'||p_search||'%' OR n.sku_relacionado ILIKE '%'||p_search||'%')
    )
    SELECT b.id, b.plano_id, b.codigo, b.descricao, b.grupo, b.sku_relacionado, b.fornecedor_nome,
           b.necessidade_bruta, b.estoque_atual, b.necessidade_liquida, b.pedido_aberto_qtd, b.pedido_aberto_data,
           b.lead_time_dias, b.data_necessidade, b.cobertura_dias, b.dias_ate_ruptura, b.chega_a_tempo, b.impacto_skus,
           b.risco, b.prioridade, b.acao_sugerida, b.justificativa, b.justificativa_ia, b.decisao, b.total_count
      FROM base b
     ORDER BY
       CASE WHEN p_sort='ruptura' THEN b.dias_ate_ruptura END ASC NULLS LAST,
       CASE WHEN p_sort='necessidade' THEN b.necessidade_liquida END DESC NULLS LAST,
       b.prioridade DESC, b.dias_ate_ruptura ASC NULLS LAST
     LIMIT COALESCE(p_limit,50) OFFSET COALESCE(p_offset,0);
END;
$$;

CREATE OR REPLACE FUNCTION wl_get_necessidade(p_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
DECLARE v JSONB;
BEGIN
  IF NOT wl_is_member() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  SELECT to_jsonb(n) INTO v FROM wl_necessidade n WHERE n.id = p_id;
  RETURN v;
END;
$$;

-- Relatório de estoque — estoque mínimo CALCULADO (consumo × lead time),
-- dias de sobrevivência e se o estoque cobre o lead time.
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

-- Relatório MRP: necessidade líquida do plano por grupo, com a ação recomendada
CREATE OR REPLACE FUNCTION wl_relatorio_mrp(p_plano_id UUID DEFAULT NULL)
RETURNS TABLE(
  codigo TEXT, descricao TEXT, grupo TEXT, sku_relacionado TEXT,
  necessidade_bruta NUMERIC, estoque_atual NUMERIC, necessidade_liquida NUMERIC,
  pedido_aberto_qtd NUMERIC, lead_time_dias NUMERIC, data_necessidade DATE,
  dias_ate_ruptura NUMERIC, risco TEXT, acao_sugerida TEXT
)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
DECLARE v_plano UUID := p_plano_id;
BEGIN
  IF NOT wl_is_member() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  IF v_plano IS NULL THEN
    SELECT id INTO v_plano FROM wl_plano WHERE status='concluido' ORDER BY created_at DESC LIMIT 1;
  END IF;
  RETURN QUERY
    SELECT n.codigo, n.descricao, n.grupo, n.sku_relacionado,
           n.necessidade_bruta, n.estoque_atual, n.necessidade_liquida,
           n.pedido_aberto_qtd, n.lead_time_dias, n.data_necessidade,
           n.dias_ate_ruptura, n.risco, n.acao_sugerida
      FROM wl_necessidade n
     WHERE n.plano_id = v_plano AND COALESCE(n.necessidade_liquida,0) > 0
     ORDER BY n.grupo, n.prioridade DESC;
END;
$$;

-- Lead time por SKU/componente decomposto (fornecedor + terceiro + montagem)
CREATE OR REPLACE FUNCTION wl_leadtime_skus(p_search TEXT DEFAULT NULL, p_grupo TEXT DEFAULT NULL)
RETURNS TABLE(
  codigo TEXT, descricao TEXT, grupo TEXT, sku_relacionado TEXT, fornecedor_nome TEXT,
  lt_fornecedor_dias NUMERIC, lt_terceiro_dias NUMERIC, lt_montagem_dias NUMERIC,
  lead_time_padrao_dias NUMERIC, lead_time_real_dias NUMERIC, lead_time_total NUMERIC,
  atraso_medio_dias NUMERIC
)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT wl_is_member() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  RETURN QUERY
    SELECT i.codigo, i.descricao, i.grupo, i.sku_relacionado, f.nome,
           i.lt_fornecedor_dias, i.lt_terceiro_dias, i.lt_montagem_dias,
           i.lead_time_padrao_dias, i.lead_time_real_dias, wl_item_lead_time(i.*),
           f.atraso_medio_dias
      FROM wl_item i
      LEFT JOIN wl_fornecedor f ON f.id = i.fornecedor_id
     WHERE i.ativo
       AND (p_grupo IS NULL OR i.grupo = p_grupo)
       AND (p_search IS NULL OR i.codigo ILIKE '%'||p_search||'%' OR i.descricao ILIKE '%'||p_search||'%')
     ORDER BY wl_item_lead_time(i.*) DESC NULLS LAST, i.codigo;
END;
$$;

-- ===================================================================
-- DECISÕES (base de aprendizado) + sinais + planos + stats
-- ===================================================================
CREATE OR REPLACE FUNCTION wl_record_decision(
  p_necessidade_id UUID, p_acao TEXT, p_concorda BOOLEAN DEFAULT NULL,
  p_motivo TEXT DEFAULT NULL, p_origem TEXT DEFAULT 'humano'
)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE n wl_necessidade;
BEGIN
  IF NOT wl_is_member() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  SELECT * INTO n FROM wl_necessidade WHERE id = p_necessidade_id;
  IF n.id IS NULL THEN RAISE EXCEPTION 'Necessidade não encontrada.'; END IF;

  UPDATE wl_necessidade SET decisao=p_acao, decidido_por=auth.uid(), decidido_em=NOW()
   WHERE id=p_necessidade_id;

  INSERT INTO wl_decision_log(necessidade_id,item_id,codigo,risco,acao_sugerida,acao,concorda,motivo,origem,snapshot,user_id)
  VALUES (n.id,n.item_id,n.codigo,n.risco,n.acao_sugerida,p_acao,
          COALESCE(p_concorda, p_acao = n.acao_sugerida), p_motivo, COALESCE(p_origem,'humano'),
          to_jsonb(n), auth.uid());

  RETURN jsonb_build_object('ok', true, 'necessidade_id', n.id, 'codigo', n.codigo, 'acao', p_acao);
END;
$$;

-- Sinais de aprendizado: taxa de concordância por risco/ação
CREATE OR REPLACE FUNCTION wl_learning_signals()
RETURNS TABLE(risco TEXT, acao_sugerida TEXT, total BIGINT, concordancias BIGINT, taxa NUMERIC)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  RETURN QUERY
    SELECT d.risco, d.acao_sugerida, COUNT(*),
           COUNT(*) FILTER (WHERE d.concorda),
           ROUND(COUNT(*) FILTER (WHERE d.concorda)::NUMERIC / NULLIF(COUNT(*),0), 2)
      FROM wl_decision_log d
     GROUP BY d.risco, d.acao_sugerida
     ORDER BY 1,2;
END;
$$;

CREATE OR REPLACE FUNCTION wl_list_planos(p_limit INT DEFAULT 30)
RETURNS SETOF wl_plano
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT wl_is_member() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT * FROM wl_plano ORDER BY created_at DESC LIMIT COALESCE(p_limit,30);
END;
$$;

-- contadores do painel — "abaixo do mínimo" usa o mínimo calculado
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

-- ---------- grants ----------
GRANT EXECUTE ON FUNCTION wl_list_fornecedores(BOOLEAN)                     TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_admin_upsert_fornecedor(UUID,TEXT,TEXT,TEXT,NUMERIC,NUMERIC,BOOLEAN,TEXT,TEXT,BOOLEAN) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_admin_delete_fornecedor(UUID)                  TO authenticated;
GRANT EXECUTE ON FUNCTION wl_list_itens(BOOLEAN,TEXT,TEXT,TEXT,BOOLEAN)     TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_admin_upsert_item(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,BOOLEAN) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_admin_delete_item(UUID)                        TO authenticated;
GRANT EXECUTE ON FUNCTION wl_patch_item(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_upsert_pedido(UUID,TEXT,TEXT,NUMERIC,DATE,DATE,TEXT,UUID,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_pedidos_abertos_por_codigo(TEXT)              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_classificar_risco(TEXT,BOOLEAN,NUMERIC,NUMERIC,NUMERIC,DATE,NUMERIC,DATE,NUMERIC,INT,BOOLEAN) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_create_plano(TEXT,DATE,DATE,INT,NUMERIC)       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_ingest_necessidades(UUID,JSONB)               TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_finalize_plano(UUID)                          TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_analisar_plano(UUID)                          TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_reprocessar_plano(UUID)                       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_delete_plano(UUID)                            TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_set_justificativa_ia(UUID,TEXT)               TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_dashboard_necessidades(UUID,TEXT,TEXT,TEXT,TEXT,INT,INT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_get_necessidade(UUID)                         TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_relatorio_estoque(TEXT,BOOLEAN,TEXT)          TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_relatorio_mrp(UUID)                           TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_leadtime_skus(TEXT,TEXT)                      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_record_decision(UUID,TEXT,BOOLEAN,TEXT,TEXT)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_learning_signals()                            TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_list_planos(INT)                              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_stats()                                       TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_stats();
-- DROP FUNCTION IF EXISTS wl_list_planos(INT);
-- DROP FUNCTION IF EXISTS wl_learning_signals();
-- DROP FUNCTION IF EXISTS wl_record_decision(UUID,TEXT,BOOLEAN,TEXT,TEXT);
-- DROP FUNCTION IF EXISTS wl_leadtime_skus(TEXT,TEXT);
-- DROP FUNCTION IF EXISTS wl_relatorio_mrp(UUID);
-- DROP FUNCTION IF EXISTS wl_relatorio_estoque(TEXT,BOOLEAN,TEXT);
-- DROP FUNCTION IF EXISTS wl_get_necessidade(UUID);
-- DROP FUNCTION IF EXISTS wl_dashboard_necessidades(UUID,TEXT,TEXT,TEXT,TEXT,INT,INT);
-- DROP FUNCTION IF EXISTS wl_set_justificativa_ia(UUID,TEXT);
-- DROP FUNCTION IF EXISTS wl_delete_plano(UUID);
-- DROP FUNCTION IF EXISTS wl_reprocessar_plano(UUID);
-- DROP FUNCTION IF EXISTS wl_analisar_plano(UUID);
-- DROP FUNCTION IF EXISTS wl_finalize_plano(UUID);
-- DROP FUNCTION IF EXISTS wl_ingest_necessidades(UUID,JSONB);
-- DROP FUNCTION IF EXISTS wl_create_plano(TEXT,DATE,DATE,INT,NUMERIC);
-- DROP FUNCTION IF EXISTS wl_classificar_risco(TEXT,BOOLEAN,NUMERIC,NUMERIC,NUMERIC,DATE,NUMERIC,DATE,NUMERIC,INT,BOOLEAN);
-- DROP FUNCTION IF EXISTS wl_pedidos_abertos_por_codigo(TEXT);
-- DROP FUNCTION IF EXISTS wl_upsert_pedido(UUID,TEXT,TEXT,NUMERIC,DATE,DATE,TEXT,UUID,TEXT);
-- DROP FUNCTION IF EXISTS wl_patch_item(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC);
-- DROP FUNCTION IF EXISTS wl_admin_delete_item(UUID);
-- DROP FUNCTION IF EXISTS wl_admin_upsert_item(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,NUMERIC,BOOLEAN);
-- DROP FUNCTION IF EXISTS wl_list_itens(BOOLEAN,TEXT,TEXT,TEXT,BOOLEAN);
-- DROP FUNCTION IF EXISTS wl_admin_delete_fornecedor(UUID);
-- DROP FUNCTION IF EXISTS wl_admin_upsert_fornecedor(UUID,TEXT,TEXT,TEXT,NUMERIC,NUMERIC,BOOLEAN,TEXT,TEXT,BOOLEAN);
-- DROP FUNCTION IF EXISTS wl_list_fornecedores(BOOLEAN);
-- NOTIFY pgrst, 'reload schema';
