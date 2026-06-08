-- ===================================================================
-- 014 — MRP ÚNICO: substituição total + exclusão de Relatório de Necessidades
-- ===================================================================
-- Regra de negócio (decisão do usuário): o Relatório de Necessidades JÁ É o MRP
-- vigente. Não faz sentido acumular vários planos — cada novo relatório
-- SUBSTITUI TOTALMENTE o anterior. A equipe também precisa poder excluir ou
-- reprocessar (reanalisar) o plano direto pela interface.
--
-- Esta migração:
--   * wl_finalize_plano  → ao concluir um plano, REMOVE todos os outros planos
--     (mantém apenas o recém-processado). Como wl_necessidade tem
--     ON DELETE CASCADE, as linhas dos planos antigos somem junto.
--   * wl_delete_plano    → exclusão manual de um plano (e suas necessidades).
--   * wl_reprocessar_plano → alias semântico de wl_analisar_plano (reanalisa o
--     plano com as bases atuais: estoque, pedidos, lead time da planilha).
--
-- Rode APÓS 013_cobertura_estoque_minimo.sql
-- ===================================================================

-- =======  UP  ========

-- ------------------------------------------------------------------
-- Finalizar plano: consolida os contadores de risco E mantém SOMENTE este
-- plano como MRP vigente, apagando os demais (substituição total).
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

-- ------------------------------------------------------------------
-- Excluir um plano (e, em cascata, suas necessidades).
-- ------------------------------------------------------------------
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

-- ------------------------------------------------------------------
-- Reprocessar = reanalisar o plano com as bases atuais (estoque/pedidos/lead
-- time vindos da planilha). Útil após sincronizar a planilha conectada.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_reprocessar_plano(p_plano_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  RETURN wl_analisar_plano(p_plano_id);
END;
$$;

-- Recarrega o cache de schema do PostgREST para a API REST (sb.rpc) enxergar
-- imediatamente as funções novas (wl_delete_plano / wl_reprocessar_plano).
-- Sem isto, o Supabase self-hosted pode responder
-- "Could not find the function ... in the schema cache".
NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_reprocessar_plano(UUID);
-- DROP FUNCTION IF EXISTS wl_delete_plano(UUID);
-- -- e restaurar wl_finalize_plano da migração 006 (sem o DELETE de substituição).
