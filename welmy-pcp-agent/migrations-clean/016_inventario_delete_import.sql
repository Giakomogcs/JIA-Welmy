-- ===================================================================
-- 016 — EXCLUIR importação de Inventário do histórico
-- ===================================================================
-- A tela "Atualizar dados" lista as importações de Inventário
-- (wl_inventario_import). A equipe pediu para poder EXCLUIR uma importação
-- do histórico. Como a ingestão de inventário atualiza wl_item.estoque_atual
-- DIRETO (não guarda as linhas cruas), excluir aqui significa apenas remover
-- o registro de log — o estoque atual dos itens permanece inalterado.
-- (Reprocessar inventário = reenviar o arquivo pela própria tela.)
--
-- Rode APÓS 008_inventario_ingest.sql
-- ===================================================================

-- =======  UP  ========

-- ------------------------------------------------------------------
-- Exclui um registro do histórico de importações de inventário.
-- Não altera o estoque dos itens (a importação só some do histórico).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_delete_inventario_import(p_import_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_removidos INT := 0;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  DELETE FROM wl_inventario_import WHERE id = p_import_id;
  GET DIAGNOSTICS v_removidos = ROW_COUNT;

  RETURN jsonb_build_object('removidos', v_removidos);
END;
$$;

GRANT EXECUTE ON FUNCTION wl_delete_inventario_import(UUID) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_delete_inventario_import(UUID);
-- NOTIFY pgrst, 'reload schema';
