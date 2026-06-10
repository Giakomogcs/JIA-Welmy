-- =============================================
-- Welmy — 006: Ingestão de Inventário + Planilha Mestre
-- (consolidada: antigas 008 + 009 + 012 + 016 + 017 — só as versões FINAIS)
--
-- Duas fontes de dados do usuário:
--   1) Registro de Inventário (PDF ERP) → wl_ingest_inventario
--      * atualiza wl_item.estoque_atual/descricao/unidade/valor/ncm
--      * INVENTÁRIO ÚNICO: cada importação SUBSTITUI a anterior no histórico
--   2) Planilha mestre (Google Sheets) → wl_replace_planilha_mestre
--      * aba ANALISE DE SKUS → produtos finais (grupo 'fabricado')
--      * aba LEAD TIMES → componentes (descrição, unidade, F/C→grupo,
--        fornecedor, lead time); REPLACE total só do grupo 'fabricado'
--      * wl_sync_skus_catalogo: upsert simples (alternativa sem replace)
-- =============================================

-- =======  UP  ========

-- ------------------------------------------------------------------
-- Log das importações de inventário (histórico de "atualizar dados")
-- ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wl_inventario_import (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  arquivo      TEXT,
  total_linhas INT     NOT NULL DEFAULT 0,
  atualizados  INT     NOT NULL DEFAULT 0,
  criados      INT     NOT NULL DEFAULT 0,
  criado_por   UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Log das importações de catálogo (planilha mestre)
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

-- ------------------------------------------------------------------
-- Normaliza o cabeçalho de grupo do inventário para o enum do wl_item.
-- Aceita "MATERIA-PRIMA", "Peças Fabricadas", "EMBALAGEM", etc.
-- Retorna NULL quando não reconhece (não sobrescreve a classificação).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_map_grupo_inventario(p_raw TEXT)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE g TEXT;
BEGIN
  IF p_raw IS NULL THEN RETURN NULL; END IF;
  -- remove acentos comuns e caixa
  g := upper(translate(p_raw,
        'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
        'AAAAAEEEEIIIIOOOOOUUUUCAAAAAEEEEIIIIOOOOOUUUUC'));
  IF g LIKE '%TERCEIR%' THEN RETURN 'fabricado_terceiro';
  ELSIF g LIKE '%FABRICAD%' OR g LIKE '%PECAS FABR%' THEN RETURN 'fabricado';
  ELSIF g LIKE '%EMBALAGEM%' THEN RETURN 'embalagem';
  ELSIF g LIKE '%MATERIA%' OR g LIKE '%MAT PRIMA%' OR g = 'MP' THEN RETURN 'materia_prima';
  ELSIF g LIKE '%COMPRAD%' THEN RETURN 'comprado';
  END IF;
  RETURN NULL;
END;
$$;

-- ------------------------------------------------------------------
-- Ingestão em lote do Registro de Inventário (versão FINAL — inventário único).
-- p_rows = array JSON com chaves flexíveis:
--   { codigo, descricao, quantidade, unidade, valor_unitario, ncm, grupo }
-- Atualiza estoque_atual dos itens existentes e cria itens novos.
-- O novo import SUBSTITUI os anteriores no histórico (1 só registro).
-- ------------------------------------------------------------------
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

-- Histórico das importações de inventário (tela "Atualizar dados")
CREATE OR REPLACE FUNCTION wl_list_inventario_imports(p_limit INT DEFAULT 20)
RETURNS SETOF wl_inventario_import
SECURITY DEFINER SET search_path = public LANGUAGE sql STABLE AS $$
  SELECT * FROM wl_inventario_import
   ORDER BY created_at DESC
   LIMIT GREATEST(COALESCE(p_limit, 20), 1);
$$;

-- Excluir um registro do histórico (não altera o estoque dos itens)
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

-- ------------------------------------------------------------------
-- Sincronização simples do catálogo de SKUs (upsert, sem replace).
-- Itens de catálogo ausentes podem ser desativados via p_desativar_ausentes.
-- ------------------------------------------------------------------
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

-- ------------------------------------------------------------------
-- REPLACE total pela planilha mestre (versão FINAL — SKUs + componentes).
--   * aba LEAD TIMES: cadastra/atualiza COMPONENTES (descrição, unidade,
--     F→'fabricado'/C→'comprado', fornecedor por nome, lead time; p/ comprados
--     o lead time da planilha vira também lt_fornecedor_dias).
--   * aba ANALISE DE SKUS: produtos finais (grupo 'fabricado').
--   * REPLACE só do grupo 'fabricado': códigos que sumiram da planilha são
--     REMOVIDOS. comprado/materia_prima/embalagem nunca são removidos aqui.
--   * estoque_atual sempre preservado (vem do inventário, não da planilha).
-- ------------------------------------------------------------------
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
  v_lt_map   JSONB := '{}'::jsonb;       -- código (UPPER) -> lead time
  v_fab_cods TEXT[] := ARRAY[]::TEXT[];  -- códigos 'fabricado' trazidos pela planilha
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
  -- Só remove quando a planilha trouxe linhas (evita zerar o catálogo se a
  -- leitura da aba falhar e vier vazia).
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

-- ------------------------------------------------------------------
-- RLS + Grants
-- ------------------------------------------------------------------
ALTER TABLE wl_inventario_import ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wl_inventario_import_read ON wl_inventario_import;
CREATE POLICY wl_inventario_import_read ON wl_inventario_import
  FOR SELECT USING (wl_is_member());

ALTER TABLE wl_catalogo_import ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wl_catalogo_import_read ON wl_catalogo_import;
CREATE POLICY wl_catalogo_import_read ON wl_catalogo_import
  FOR SELECT USING (wl_is_member());

GRANT EXECUTE ON FUNCTION wl_map_grupo_inventario(TEXT)                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_ingest_inventario(TEXT, JSONB)             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_list_inventario_imports(INT)               TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_delete_inventario_import(UUID)             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_sync_skus_catalogo(TEXT, JSONB, BOOLEAN)   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_list_catalogo_imports(INT)                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_replace_planilha_mestre(TEXT, JSONB, JSONB) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_replace_planilha_mestre(TEXT, JSONB, JSONB);
-- DROP FUNCTION IF EXISTS wl_list_catalogo_imports(INT);
-- DROP FUNCTION IF EXISTS wl_sync_skus_catalogo(TEXT, JSONB, BOOLEAN);
-- DROP FUNCTION IF EXISTS wl_delete_inventario_import(UUID);
-- DROP FUNCTION IF EXISTS wl_list_inventario_imports(INT);
-- DROP FUNCTION IF EXISTS wl_ingest_inventario(TEXT, JSONB);
-- DROP FUNCTION IF EXISTS wl_map_grupo_inventario(TEXT);
-- DROP TABLE IF EXISTS wl_catalogo_import;
-- DROP TABLE IF EXISTS wl_inventario_import;
-- NOTIFY pgrst, 'reload schema';
