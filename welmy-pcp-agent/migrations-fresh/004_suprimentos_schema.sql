-- =============================================
-- Welmy — 004: Suprimentos & PCP (schema)  (consolidada: antigas 005 + colunas de 008 e 011)
--
-- Modela o domínio do "Copiloto de Suprimentos e PCP":
--   * wl_fornecedor    — fornecedores / terceiros / montagem (lead time e atraso médio)
--   * wl_item          — componentes/SKUs com lead time COMPOSTO, estoque,
--                        curva A/B/C, NCM e valor unitário (do inventário)
--   * wl_pedido_compra — pedidos de compra em aberto
--   * wl_plano         — execução de um Relatório de Necessidades (MRP)
--   * wl_necessidade   — linhas analisadas (inclui necessidade_reportada do ERP)
--   * wl_decision_log  — decisões da equipe (base de aprendizado)
--
-- Princípio: motor de regras determinístico calcula; o LLM só explica.
-- Human-in-the-loop: o agente recomenda, a equipe decide.
-- Rode APÓS 003_chat_messages.sql
-- =============================================

-- =======  UP  ========

-- helper: parse de data BR ('DD/MM/YYYY [HH24:MI:SS]' ou ISO) -> timestamptz
CREATE OR REPLACE FUNCTION wl_parse_ts(p_txt TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v TIMESTAMPTZ;
BEGIN
  IF p_txt IS NULL OR TRIM(p_txt) = '' THEN
    RETURN NULL;
  END IF;
  BEGIN v := p_txt::timestamptz; RETURN v; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN RETURN to_timestamp(p_txt, 'DD/MM/YYYY HH24:MI:SS'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN RETURN to_timestamp(p_txt, 'DD/MM/YYYY'); EXCEPTION WHEN OTHERS THEN RETURN NULL; END;
END;
$$;

-- helper: parse numérico tolerante a formato BR ("1.234,56" / "1234.56" / "1,5")
CREATE OR REPLACE FUNCTION wl_parse_num(p_txt TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  s TEXT;
BEGIN
  IF p_txt IS NULL THEN RETURN NULL; END IF;
  s := regexp_replace(p_txt, '[^0-9,.-]', '', 'g');
  IF s = '' THEN RETURN NULL; END IF;
  -- formato BR: vírgula decimal e ponto de milhar
  IF position(',' in s) > 0 AND position('.' in s) > 0 THEN
    s := replace(s, '.', '');
    s := replace(s, ',', '.');
  ELSIF position(',' in s) > 0 THEN
    s := replace(s, ',', '.');
  END IF;
  BEGIN RETURN s::NUMERIC; EXCEPTION WHEN OTHERS THEN RETURN NULL; END;
END;
$$;

-- ---------- fornecedores / terceiros / montagem ----------
CREATE TABLE IF NOT EXISTS wl_fornecedor (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome               TEXT NOT NULL,
  cnpj               TEXT,
  tipo               TEXT NOT NULL DEFAULT 'fornecedor'
                     CHECK (tipo IN ('fornecedor','terceiro','montagem')),
  lead_time_medio_dias NUMERIC,                       -- prazo médio nominal
  atraso_medio_dias    NUMERIC NOT NULL DEFAULT 0,    -- histórico de atraso
  fornecedor_unico   BOOLEAN NOT NULL DEFAULT FALSE,  -- único p/ item crítico (risco extra)
  contato            TEXT,
  observacoes        TEXT,
  ativo              BOOLEAN NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_wl_fornecedor_ativo ON wl_fornecedor(ativo);

DROP TRIGGER IF EXISTS trg_wl_fornecedor_updated_at ON wl_fornecedor;
CREATE TRIGGER trg_wl_fornecedor_updated_at
  BEFORE UPDATE ON wl_fornecedor
  FOR EACH ROW EXECUTE FUNCTION wl_set_updated_at();

-- ---------- itens / componentes / SKUs ----------
-- grupo: define a ação recomendada conforme a origem do componente.
-- ncm / valor_unitario / estoque_atualizado_em: vêm do Registro de Inventário.
CREATE TABLE IF NOT EXISTS wl_item (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo             TEXT UNIQUE NOT NULL,           -- chave de cruzamento (relatório/estoque/pedido)
  descricao          TEXT NOT NULL,
  grupo              TEXT NOT NULL DEFAULT 'comprado'
                     CHECK (grupo IN ('materia_prima','comprado','fabricado','fabricado_terceiro','embalagem')),
  unidade            TEXT DEFAULT 'un',
  sku_relacionado    TEXT,                            -- produto final que usa este componente (BOM)
  curva              TEXT CHECK (curva IN ('A','B','C')),
  fornecedor_id      UUID REFERENCES wl_fornecedor(id) ON DELETE SET NULL,
  -- lead time COMPOSTO por etapa (fornecedor + terceiro + montagem)
  lt_fornecedor_dias NUMERIC NOT NULL DEFAULT 0,
  lt_terceiro_dias   NUMERIC NOT NULL DEFAULT 0,
  lt_montagem_dias   NUMERIC NOT NULL DEFAULT 0,
  lead_time_padrao_dias NUMERIC,                      -- prazo nominal do sistema
  lead_time_real_dias   NUMERIC,                      -- prazo médio real (planilha mestre) — CRÍTICO
  -- estoque
  estoque_atual      NUMERIC NOT NULL DEFAULT 0,
  estoque_minimo     NUMERIC NOT NULL DEFAULT 0,      -- 0 = calcular (consumo × lead time)
  ponto_pedido       NUMERIC,
  consumo_diario     NUMERIC,                          -- média de consumo (un/dia)
  -- dados do Registro de Inventário
  ncm                TEXT,
  valor_unitario     NUMERIC,
  estoque_atualizado_em TIMESTAMPTZ,
  ativo              BOOLEAN NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_wl_item_grupo  ON wl_item(grupo);
CREATE INDEX IF NOT EXISTS idx_wl_item_curva  ON wl_item(curva);
CREATE INDEX IF NOT EXISTS idx_wl_item_ativo  ON wl_item(ativo);
CREATE INDEX IF NOT EXISTS idx_wl_item_forn   ON wl_item(fornecedor_id);

DROP TRIGGER IF EXISTS trg_wl_item_updated_at ON wl_item;
CREATE TRIGGER trg_wl_item_updated_at
  BEFORE UPDATE ON wl_item
  FOR EACH ROW EXECUTE FUNCTION wl_set_updated_at();

-- lead time total efetivo (real > padrão > soma das etapas)
CREATE OR REPLACE FUNCTION wl_item_lead_time(p wl_item)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    p.lead_time_real_dias,
    p.lead_time_padrao_dias,
    NULLIF(p.lt_fornecedor_dias + p.lt_terceiro_dias + p.lt_montagem_dias, 0)
  );
$$;

-- estoque mínimo EFETIVO = manual (se > 0), senão consumo × lead time.
-- NULL quando não há como calcular (sem consumo ou sem lead time).
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

-- ---------- pedidos de compra em aberto ----------
CREATE TABLE IF NOT EXISTS wl_pedido_compra (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  numero          TEXT,
  item_id         UUID REFERENCES wl_item(id) ON DELETE CASCADE,
  codigo          TEXT,                                -- redundante p/ itens não cadastrados
  fornecedor_id   UUID REFERENCES wl_fornecedor(id) ON DELETE SET NULL,
  quantidade      NUMERIC NOT NULL DEFAULT 0,
  data_pedido     DATE,
  data_prevista   DATE,                                -- chegada prevista (cruza com data de necessidade)
  status          TEXT NOT NULL DEFAULT 'aberto'
                  CHECK (status IN ('aberto','parcial','recebido','atrasado','cancelado')),
  recebido_em     DATE,
  observacoes     TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_wl_pedido_item   ON wl_pedido_compra(item_id);
CREATE INDEX IF NOT EXISTS idx_wl_pedido_codigo ON wl_pedido_compra(codigo);
CREATE INDEX IF NOT EXISTS idx_wl_pedido_status ON wl_pedido_compra(status);

DROP TRIGGER IF EXISTS trg_wl_pedido_updated_at ON wl_pedido_compra;
CREATE TRIGGER trg_wl_pedido_updated_at
  BEFORE UPDATE ON wl_pedido_compra
  FOR EACH ROW EXECUTE FUNCTION wl_set_updated_at();

-- ---------- plano / execução de um Relatório de Necessidades ----------
-- Cada upload de relatório gera um wl_plano (e SUBSTITUI o anterior — MRP único,
-- ver wl_finalize_plano na 005). Tudo precisa chegar até o dia 25 (data_limite).
CREATE TABLE IF NOT EXISTS wl_plano (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  label           TEXT,
  competencia     DATE,                                -- mês de referência (1º dia)
  data_limite     DATE,                                -- todas as peças devem chegar até aqui (dia 25)
  horizonte_dias  INT NOT NULL DEFAULT 15,             -- janela de fabricação
  qtd_pecas_plano NUMERIC,
  status          TEXT NOT NULL DEFAULT 'pendente'
                  CHECK (status IN ('pendente','processando','concluido','erro')),
  total_itens     INT NOT NULL DEFAULT 0,
  risco_alto      INT NOT NULL DEFAULT 0,
  risco_medio     INT NOT NULL DEFAULT 0,
  risco_baixo     INT NOT NULL DEFAULT 0,
  dado_incompleto INT NOT NULL DEFAULT 0,
  params          JSONB,
  criado_por      UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at      TIMESTAMPTZ,
  finished_at     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_wl_plano_status ON wl_plano(status);

-- ---------- linhas analisadas do relatório (saída do motor de regras) ----------
-- necessidade_reportada: coluna "Necessidade" do ERP (já líquida de
-- estoque + pedidos). Quando presente, é a necessidade_liquida exibida.
CREATE TABLE IF NOT EXISTS wl_necessidade (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plano_id           UUID NOT NULL REFERENCES wl_plano(id) ON DELETE CASCADE,
  item_id            UUID REFERENCES wl_item(id) ON DELETE SET NULL,
  codigo             TEXT,
  descricao          TEXT,
  grupo              TEXT,
  sku_relacionado    TEXT,
  fornecedor_nome    TEXT,
  -- entradas (do relatório / bases)
  necessidade_bruta  NUMERIC,                           -- "Total Saídas" do ERP
  estoque_atual      NUMERIC,                           -- "Est.Disp+Alo"
  pedido_aberto_qtd  NUMERIC NOT NULL DEFAULT 0,        -- "Ped.Compra"
  pedido_aberto_data DATE,
  lead_time_dias     NUMERIC,
  data_necessidade   DATE,
  -- saídas calculadas (motor de regras determinístico)
  necessidade_liquida   NUMERIC,                        -- reportada do ERP, senão bruta - estoque
  necessidade_reportada NUMERIC,                        -- "Necessidade" final do ERP
  consumo_diario      NUMERIC,
  cobertura_dias      NUMERIC,                           -- (estoque+pedidos)/consumo
  dias_ate_ruptura    NUMERIC,                           -- estoque/consumo
  chega_a_tempo       BOOLEAN,                           -- data_prevista <= data_necessidade
  impacto_skus        INT NOT NULL DEFAULT 0,
  risco              TEXT NOT NULL DEFAULT 'dado_incompleto'
                     CHECK (risco IN ('alto','medio','baixo','dado_incompleto')),
  prioridade         INT NOT NULL DEFAULT 0,
  acao_sugerida      TEXT,
  justificativa      TEXT,                               -- regra (texto determinístico)
  justificativa_ia   TEXT,                               -- explicação executiva do LLM (opcional)
  decisao            TEXT,                               -- ação confirmada pela equipe
  decidido_por       UUID,
  decidido_em        TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_wl_nec_plano  ON wl_necessidade(plano_id);
CREATE INDEX IF NOT EXISTS idx_wl_nec_risco  ON wl_necessidade(risco);
CREATE INDEX IF NOT EXISTS idx_wl_nec_codigo ON wl_necessidade(codigo);
CREATE INDEX IF NOT EXISTS idx_wl_nec_prio   ON wl_necessidade(prioridade DESC);

-- ---------- log de decisões (base de aprendizado) ----------
CREATE TABLE IF NOT EXISTS wl_decision_log (
  id              BIGSERIAL PRIMARY KEY,
  necessidade_id  UUID REFERENCES wl_necessidade(id) ON DELETE SET NULL,
  item_id         UUID REFERENCES wl_item(id) ON DELETE SET NULL,
  codigo          TEXT,
  risco           TEXT,
  acao_sugerida   TEXT,
  acao            TEXT NOT NULL,
  concorda        BOOLEAN,
  motivo          TEXT,
  origem          TEXT NOT NULL DEFAULT 'humano' CHECK (origem IN ('humano','ia')),
  snapshot        JSONB,
  user_id         UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_wl_declog_nec  ON wl_decision_log(necessidade_id);
CREATE INDEX IF NOT EXISTS idx_wl_declog_acao ON wl_decision_log(acao);

-- ---------- RLS: leitura para membros, escrita via RPC/service_role ----------
ALTER TABLE wl_fornecedor    ENABLE ROW LEVEL SECURITY;
ALTER TABLE wl_item          ENABLE ROW LEVEL SECURITY;
ALTER TABLE wl_pedido_compra ENABLE ROW LEVEL SECURITY;
ALTER TABLE wl_plano         ENABLE ROW LEVEL SECURITY;
ALTER TABLE wl_necessidade   ENABLE ROW LEVEL SECURITY;
ALTER TABLE wl_decision_log  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS wl_fornecedor_sel ON wl_fornecedor;
DROP POLICY IF EXISTS wl_item_sel       ON wl_item;
DROP POLICY IF EXISTS wl_pedido_sel     ON wl_pedido_compra;
DROP POLICY IF EXISTS wl_plano_sel      ON wl_plano;
DROP POLICY IF EXISTS wl_nec_sel        ON wl_necessidade;
DROP POLICY IF EXISTS wl_declog_sel     ON wl_decision_log;

CREATE POLICY wl_fornecedor_sel ON wl_fornecedor    FOR SELECT TO authenticated USING (wl_is_member());
CREATE POLICY wl_item_sel       ON wl_item          FOR SELECT TO authenticated USING (wl_is_member());
CREATE POLICY wl_pedido_sel     ON wl_pedido_compra FOR SELECT TO authenticated USING (wl_is_member());
CREATE POLICY wl_plano_sel      ON wl_plano         FOR SELECT TO authenticated USING (wl_is_member());
CREATE POLICY wl_nec_sel        ON wl_necessidade   FOR SELECT TO authenticated USING (wl_is_member());
CREATE POLICY wl_declog_sel     ON wl_decision_log  FOR SELECT TO authenticated USING (wl_is_member());

GRANT SELECT ON wl_fornecedor, wl_item, wl_pedido_compra, wl_plano, wl_necessidade, wl_decision_log TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP TABLE IF EXISTS wl_decision_log;
-- DROP TABLE IF EXISTS wl_necessidade;
-- DROP TABLE IF EXISTS wl_plano;
-- DROP TABLE IF EXISTS wl_pedido_compra;
-- DROP FUNCTION IF EXISTS wl_item_estoque_minimo(wl_item);
-- DROP FUNCTION IF EXISTS wl_item_lead_time(wl_item);
-- DROP TABLE IF EXISTS wl_item;
-- DROP TABLE IF EXISTS wl_fornecedor;
-- DROP FUNCTION IF EXISTS wl_parse_num(TEXT);
-- DROP FUNCTION IF EXISTS wl_parse_ts(TEXT);
-- NOTIFY pgrst, 'reload schema';
