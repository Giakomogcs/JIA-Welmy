-- ===================================================================
-- 008 — INGESTÃO DO REGISTRO DE INVENTÁRIO (estoque físico)
-- ===================================================================
-- O usuário sobe dois documentos do ERP:
--   1) Relatório de Necessidades  -> wl_ingest_necessidades (006) -> wl_plano
--   2) Registro de Inventário     -> wl_ingest_inventario  (este) -> atualiza wl_item.estoque_atual
--
-- Esta migração adiciona as colunas de valor/auditoria no item, uma tabela
-- de log das importações de inventário e a RPC de ingestão em lote chamada
-- pelo workflow Welmy-Inventario (n8n, via Postgres direto = wl_is_backend()).
-- ===================================================================

-- Colunas extras no item (dados que vêm direto do Registro de Inventário)
--   ncm                  -> "Classificação Fiscal" (1ª coluna de cada linha do inventário)
--   valor_unitario       -> custo unitário do estoque
--   estoque_atualizado_em-> carimbo da última importação de inventário
ALTER TABLE wl_item ADD COLUMN IF NOT EXISTS ncm TEXT;
ALTER TABLE wl_item ADD COLUMN IF NOT EXISTS valor_unitario NUMERIC;
ALTER TABLE wl_item ADD COLUMN IF NOT EXISTS estoque_atualizado_em TIMESTAMPTZ;

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

-- ------------------------------------------------------------------
-- Normaliza o cabeçalho de grupo do inventário para o enum do wl_item.
-- Aceita "MATERIA-PRIMA", "Peças Fabricadas", "EMBALAGEM", etc.
-- Retorna NULL quando não reconhece (assim não sobrescreve a classificação).
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
-- Ingestão em lote do Registro de Inventário.
-- p_rows = array JSON com chaves flexíveis. Cada linha:
--   { codigo, descricao, quantidade, unidade, valor_unitario, grupo }
-- Atualiza estoque_atual dos itens existentes (sem mexer na classificação
-- de risco/lead time) e cria itens novos que ainda não estavam cadastrados.
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

  RETURN jsonb_build_object(
    'import_id', v_import_id,
    'total', v_tot,
    'atualizados', v_atu,
    'criados', v_cri
  );
END;
$$;

-- ------------------------------------------------------------------
-- Histórico das importações de inventário (para a tela "Atualizar dados").
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION wl_list_inventario_imports(p_limit INT DEFAULT 20)
RETURNS SETOF wl_inventario_import
SECURITY DEFINER SET search_path = public LANGUAGE sql STABLE AS $$
  SELECT * FROM wl_inventario_import
   ORDER BY created_at DESC
   LIMIT GREATEST(COALESCE(p_limit, 20), 1);
$$;

-- ------------------------------------------------------------------
-- Grants
-- ------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION wl_map_grupo_inventario(TEXT)        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_ingest_inventario(TEXT, JSONB)    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_list_inventario_imports(INT)      TO authenticated, service_role;

ALTER TABLE wl_inventario_import ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wl_inventario_import_read ON wl_inventario_import;
CREATE POLICY wl_inventario_import_read ON wl_inventario_import
  FOR SELECT USING (wl_is_member());

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_list_inventario_imports(INT);
-- DROP FUNCTION IF EXISTS wl_ingest_inventario(TEXT, JSONB);
-- DROP FUNCTION IF EXISTS wl_map_grupo_inventario(TEXT);
-- DROP TABLE IF EXISTS wl_inventario_import;
-- ALTER TABLE wl_item DROP COLUMN IF EXISTS estoque_atualizado_em;
-- ALTER TABLE wl_item DROP COLUMN IF EXISTS valor_unitario;
-- ALTER TABLE wl_item DROP COLUMN IF EXISTS ncm;
-- NOTIFY pgrst, 'reload schema';
