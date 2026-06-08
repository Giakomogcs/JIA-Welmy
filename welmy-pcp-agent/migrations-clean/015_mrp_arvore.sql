-- ===================================================================
-- 015 — MRP em ÁRVORE: tempo total, tempo por item e o que já está OK
-- ===================================================================
-- A tela de MRP precisava ser mais "acionável": em vez de uma lista plana de
-- necessidade líquida, mostrar a ÁRVORE de itens agrupada por SKU final
-- (sku_relacionado), respondendo às 3 perguntas do PCP:
--
--   1) Quanto tempo demora no TOTAL para o pedido ficar pronto?
--      → caminho crítico = MAIOR lead time entre os itens que ainda precisam de
--        ação (comprar/fabricar). Os itens são providenciados em paralelo, então
--        o gargalo é o item pendente mais demorado, não a soma.
--   2) Quanto tempo demora CADA item? → lead_time_dias de cada componente.
--   3) Quais já estão OK? → itens sem necessidade líquida (necessidade_liquida<=0),
--        ou seja, o estoque já cobre — nada a providenciar.
--
-- wl_mrp_arvore devolve um JSONB pronto para a UI:
--   { plano_id, label, data_limite,
--     total_itens, itens_pendentes, itens_ok, itens_em_compra,
--     soma_necessario, soma_estoque, soma_em_compra, soma_a_comprar,
--     lead_time_total_dias, previsao_pronto,
--     skus: [ { sku, grupo, por_sku, sku_descricao, lead_time_total_dias,
--               total_itens, itens_pendentes, itens_ok, itens_em_compra,
--               soma_necessario, soma_estoque, soma_em_compra, soma_a_comprar, pronto,
--               componentes: [ {codigo, descricao, grupo, necessidade_bruta,
--                 estoque_atual, pedido_aberto_qtd, pedido_aberto_data,
--                 necessidade_liquida, lead_time_dias, dias_ate_ruptura,
--                 data_necessidade, risco, acao_sugerida, pendente, coberto_por_pedido} ] } ] }
--
-- O Relatório de Necessidades do ERP já traz, por item: Est.Disp+Alo (estoque_atual),
-- Ped.Compra (pedido_aberto_qtd = "em compra/produção"), Total Saídas
-- (necessidade_bruta = "necessário") e Necessidade (necessidade_liquida = "falta
-- comprar/fabricar"). A árvore consolida tudo isso por SKU/grupo e no topo do plano.
--
-- Rode APÓS 014_plano_unico_mrp.sql
-- ===================================================================

-- =======  UP  ========

CREATE OR REPLACE FUNCTION wl_mrp_arvore(p_plano_id UUID DEFAULT NULL)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_plano wl_plano;
  v JSONB;
BEGIN
  IF NOT wl_is_member() THEN RAISE EXCEPTION 'Acesso negado.' USING ERRCODE='42501'; END IF;

  IF p_plano_id IS NULL THEN
    SELECT * INTO v_plano FROM wl_plano WHERE status='concluido' ORDER BY created_at DESC LIMIT 1;
  ELSE
    SELECT * INTO v_plano FROM wl_plano WHERE id = p_plano_id;
  END IF;

  IF v_plano.id IS NULL THEN
    RETURN jsonb_build_object('plano_id', NULL, 'skus', '[]'::jsonb,
      'total_itens', 0, 'itens_pendentes', 0, 'itens_ok', 0, 'lead_time_total_dias', 0);
  END IF;

  WITH nec AS (
    SELECT
      n.id, n.codigo, n.descricao, n.prioridade,
      n.necessidade_bruta, n.pedido_aberto_qtd, n.pedido_aberto_data,
      n.necessidade_liquida, n.estoque_atual, n.dias_ate_ruptura, n.data_necessidade,
      n.risco, n.acao_sugerida,
      COALESCE(n.grupo, i.grupo, 'outros') AS grupo,
      -- lead time do snapshot OU do catálogo atual (igual às telas de Estoque/Lead Time)
      COALESCE(n.lead_time_dias, wl_item_lead_time(i.*)) AS lead_time_dias,
      -- SKU do snapshot OU do catálogo; quando não há, agrupa pelo grupo do item
      COALESCE(NULLIF(TRIM(n.sku_relacionado), ''), NULLIF(TRIM(i.sku_relacionado), '')) AS sku,
      (COALESCE(n.necessidade_liquida, 0) > 0) AS pendente,
      -- quanto do necessário já está coberto por estoque + pedidos em aberto
      (COALESCE(n.estoque_atual,0) + COALESCE(n.pedido_aberto_qtd,0) >= COALESCE(n.necessidade_bruta,0)
        AND COALESCE(n.pedido_aberto_qtd,0) > 0) AS coberto_por_pedido
    FROM wl_necessidade n
    LEFT JOIN LATERAL (
      SELECT it.* FROM wl_item it
       WHERE it.id = n.item_id OR it.codigo = n.codigo
       ORDER BY (it.id = n.item_id) DESC NULLS LAST
       LIMIT 1
    ) i ON TRUE
    WHERE n.plano_id = v_plano.id
  ),
  nec2 AS (
    SELECT
      nec.*,
      -- chave de agrupamento: SKU se houver, senão o grupo (prefixado p/ não colidir)
      COALESCE(sku, 'grupo:' || grupo) AS chave,
      (sku IS NOT NULL)                AS por_sku
    FROM nec
  ),
  comp AS (
    SELECT
      chave,
      bool_or(por_sku)                                    AS por_sku,
      MAX(sku)                                            AS sku,
      MAX(grupo)                                          AS grupo,
      COUNT(*)                                            AS total_itens,
      COUNT(*) FILTER (WHERE pendente)                    AS itens_pendentes,
      COUNT(*) FILTER (WHERE NOT pendente)                AS itens_ok,
      COUNT(*) FILTER (WHERE coberto_por_pedido)          AS itens_em_compra,
      COALESCE(MAX(lead_time_dias) FILTER (WHERE pendente), 0) AS lead_time_total_dias,
      COALESCE(SUM(necessidade_bruta), 0)                 AS soma_necessario,
      COALESCE(SUM(estoque_atual), 0)                     AS soma_estoque,
      COALESCE(SUM(pedido_aberto_qtd), 0)                 AS soma_em_compra,
      COALESCE(SUM(necessidade_liquida) FILTER (WHERE pendente), 0) AS soma_a_comprar,
      MAX(prioridade)                                     AS max_prio,
      jsonb_agg(
        jsonb_build_object(
          'id', id, 'codigo', codigo, 'descricao', descricao, 'grupo', grupo,
          'necessidade_bruta', necessidade_bruta,
          'estoque_atual', estoque_atual,
          'pedido_aberto_qtd', pedido_aberto_qtd,
          'pedido_aberto_data', pedido_aberto_data,
          'necessidade_liquida', necessidade_liquida,
          'lead_time_dias', lead_time_dias, 'dias_ate_ruptura', dias_ate_ruptura,
          'data_necessidade', data_necessidade, 'risco', risco,
          'acao_sugerida', acao_sugerida, 'pendente', pendente,
          'coberto_por_pedido', coberto_por_pedido
        )
        ORDER BY pendente DESC, lead_time_dias DESC NULLS LAST, prioridade DESC
      ) AS componentes
    FROM nec2
    GROUP BY chave
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*) FROM nec2)                          AS total_itens,
      (SELECT COUNT(*) FROM nec2 WHERE pendente)           AS itens_pendentes,
      (SELECT COUNT(*) FROM nec2 WHERE NOT pendente)       AS itens_ok,
      (SELECT COUNT(*) FROM nec2 WHERE coberto_por_pedido) AS itens_em_compra,
      (SELECT COALESCE(SUM(necessidade_bruta),0) FROM nec2)                  AS soma_necessario,
      (SELECT COALESCE(SUM(estoque_atual),0) FROM nec2)                      AS soma_estoque,
      (SELECT COALESCE(SUM(pedido_aberto_qtd),0) FROM nec2)                  AS soma_em_compra,
      (SELECT COALESCE(SUM(necessidade_liquida),0) FROM nec2 WHERE pendente) AS soma_a_comprar,
      COALESCE((SELECT MAX(lead_time_total_dias) FROM comp), 0) AS lt_total
  )
  SELECT jsonb_build_object(
    'plano_id',             v_plano.id,
    'label',                v_plano.label,
    'data_limite',          v_plano.data_limite,
    'total_itens',          a.total_itens,
    'itens_pendentes',      a.itens_pendentes,
    'itens_ok',             a.itens_ok,
    'itens_em_compra',      a.itens_em_compra,
    'soma_necessario',      a.soma_necessario,
    'soma_estoque',         a.soma_estoque,
    'soma_em_compra',       a.soma_em_compra,
    'soma_a_comprar',       a.soma_a_comprar,
    'lead_time_total_dias', a.lt_total,
    'previsao_pronto',      CASE WHEN a.lt_total > 0
                                 THEN (CURRENT_DATE + CEIL(a.lt_total)::int) END,
    'skus', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'sku',                  c.sku,
          'grupo',                c.grupo,
          'por_sku',              c.por_sku,
          'sku_descricao',        CASE WHEN c.por_sku
                                       THEN (SELECT i.descricao FROM wl_item i WHERE i.codigo = c.sku LIMIT 1) END,
          'lead_time_total_dias', c.lead_time_total_dias,
          'total_itens',          c.total_itens,
          'itens_pendentes',      c.itens_pendentes,
          'itens_ok',             c.itens_ok,
          'itens_em_compra',      c.itens_em_compra,
          'soma_necessario',      c.soma_necessario,
          'soma_estoque',         c.soma_estoque,
          'soma_em_compra',       c.soma_em_compra,
          'soma_a_comprar',       c.soma_a_comprar,
          'pronto',               (c.itens_pendentes = 0),
          'componentes',          c.componentes
        )
        ORDER BY (c.itens_pendentes = 0) ASC, c.lead_time_total_dias DESC, c.max_prio DESC, c.grupo
      )
      FROM comp c
    ), '[]'::jsonb)
  ) INTO v
  FROM agg a;

  RETURN v;
END;
$$;

GRANT EXECUTE ON FUNCTION wl_mrp_arvore(UUID) TO authenticated, service_role;

-- Recarrega o cache do PostgREST para a API REST enxergar a função nova.
NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_mrp_arvore(UUID);
-- NOTIFY pgrst, 'reload schema';
