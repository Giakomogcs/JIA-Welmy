-- ===================================================================
-- 017 — INVENTÁRIO ÚNICO: cada importação substitui a anterior
-- ===================================================================
-- Regra de negócio (decisão do usuário): assim como o Relatório de
-- Necessidades é um MRP único (014), o Registro de Inventário também deve
-- ser ÚNICO no histórico — cada nova importação SUBSTITUI a anterior.
-- O estoque atual dos itens já é atualizado direto em wl_item; aqui apenas
-- garantimos que o histórico (wl_inventario_import) guarde só o mais recente.
--
-- Mantém a mesma lógica de 008, só acrescentando o DELETE dos imports antigos
-- depois de gravar o novo (dentro da mesma função/transação).
--
-- Rode APÓS 008_inventario_ingest.sql (e 016_inventario_delete_import.sql)
-- ===================================================================

-- =======  UP  ========

CREATE OR REPLACE FUNCTION wl_ingest_inventario(p_arquivo TEXT, p_rows JSONB)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  r JSONB;
  v_codigo TEXT;
  v_desc   TEXT;
  v_qtd    NUMERIC;
  v_unid   TEXT;
  v_valor  NUMERIC;
  v_ncm    TEXT;
  v_grupo  TEXT;
  v_existe BOOLEAN;
  v_atu INT := 0;
  v_cri INT := 0;
  v_tot INT := 0;
  v_import_id UUID;
  v_removidos INT := 0;
BEGIN
  IF NOT (wl_is_member() OR wl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb))
  LOOP
    v_codigo := NULLIF(TRIM(COALESCE(r->>'codigo', r->>'código', r->>'cod', r->>'item')), '');
    IF v_codigo IS NULL THEN CONTINUE; END IF;

    v_desc  := NULLIF(TRIM(COALESCE(r->>'descricao', r->>'descrição', r->>'desc', r->>'produto')), '');
    v_qtd   := wl_parse_num(COALESCE(r->>'quantidade', r->>'qtd', r->>'estoque', r->>'saldo', r->>'estoque_atual'));
    v_unid  := NULLIF(TRIM(COALESCE(r->>'unidade', r->>'und', r->>'un')), '');
    v_valor := wl_parse_num(COALESCE(r->>'valor_unitario', r->>'valor_unit', r->>'valor'));
    v_ncm   := NULLIF(TRIM(COALESCE(r->>'ncm', r->>'classificacao_fiscal', r->>'classificação_fiscal', r->>'class_fiscal')), '');
    v_grupo := wl_map_grupo_inventario(COALESCE(r->>'grupo', r->>'grupo_estoque'));

    SELECT TRUE INTO v_existe FROM wl_item WHERE codigo = v_codigo LIMIT 1;

    IF v_existe THEN
      UPDATE wl_item SET
        estoque_atual = COALESCE(v_qtd, estoque_atual),
        descricao     = COALESCE(v_desc, descricao),
        unidade       = COALESCE(v_unid, unidade),
        valor_unitario = COALESCE(v_valor, valor_unitario),
        ncm           = COALESCE(v_ncm, ncm),
        estoque_atualizado_em = NOW()
      WHERE codigo = v_codigo;
      v_atu := v_atu + 1;
    ELSE
      INSERT INTO wl_item(codigo, descricao, grupo, unidade, estoque_atual, valor_unitario, ncm, estoque_atualizado_em)
      VALUES (v_codigo, COALESCE(v_desc, v_codigo), COALESCE(v_grupo, 'comprado'), COALESCE(v_unid, 'un'),
              COALESCE(v_qtd, 0), v_valor, v_ncm, NOW());
      v_cri := v_cri + 1;
    END IF;
    v_tot := v_tot + 1;
  END LOOP;

  INSERT INTO wl_inventario_import(arquivo, total_linhas, atualizados, criados, criado_por)
  VALUES (NULLIF(TRIM(p_arquivo), ''), v_tot, v_atu, v_cri, auth.uid())
  RETURNING id INTO v_import_id;

  -- inventário único: o novo import substitui os anteriores no histórico.
  DELETE FROM wl_inventario_import WHERE id <> v_import_id;
  GET DIAGNOSTICS v_removidos = ROW_COUNT;

  RETURN jsonb_build_object(
    'import_id', v_import_id,
    'total', v_tot,
    'atualizados', v_atu,
    'criados', v_cri,
    'imports_removidos', v_removidos
  );
END;
$$;

GRANT EXECUTE ON FUNCTION wl_ingest_inventario(TEXT, JSONB) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- Restaurar a versão de 008 (sem o DELETE dos imports antigos), se necessário.
-- NOTIFY pgrst, 'reload schema';
