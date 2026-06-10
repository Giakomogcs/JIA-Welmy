-- =============================================
-- Welmy — 002: RAG (schema + match_documents)  (consolidada: antigas 002 + 003)
--
-- O RAG é GLOBAL: todo usuário autenticado da empresa acessa todos os
-- documentos (manuais, BOM, tabelas de lead time, políticas de estoque)
-- através do agente de IA. Não há gating por equipe/categoria.
--
-- - Extensões pgvector / pgcrypto
-- - Tabelas: wl_document_metadata (com session_id), wl_document_rows, wl_documents
-- - Índice HNSW (fallback ivfflat) em embedding
-- - wl_match_documents: busca global ignora anexos de chat (session_id);
--   com filtro {session_id} retorna só os daquela conversa.
-- Rode APÓS 001_users_and_admin.sql
-- =============================================

-- =======  UP  ========

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- metadata por arquivo ----------
-- session_id: anexos enviados pelo chat (com sessão); NULL = documento global.
CREATE TABLE IF NOT EXISTS wl_document_metadata (
  file_id      TEXT PRIMARY KEY,
  title        TEXT,
  code         TEXT,
  url          TEXT,
  source       TEXT,
  mime_type    TEXT,
  schema       JSONB,
  session_id   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_wl_meta_code    ON wl_document_metadata(code);
CREATE INDEX IF NOT EXISTS idx_wl_meta_session ON wl_document_metadata(session_id);

DROP TRIGGER IF EXISTS trg_wl_meta_updated_at ON wl_document_metadata;
CREATE TRIGGER trg_wl_meta_updated_at
  BEFORE UPDATE ON wl_document_metadata
  FOR EACH ROW EXECUTE FUNCTION wl_set_updated_at();

-- ---------- linhas tabulares (csv/xlsx) ----------
CREATE TABLE IF NOT EXISTS wl_document_rows (
  id          BIGSERIAL PRIMARY KEY,
  dataset_id  TEXT NOT NULL REFERENCES wl_document_metadata(file_id) ON DELETE CASCADE,
  row_data    JSONB NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_wl_rows_dataset ON wl_document_rows(dataset_id);

-- ---------- chunks vetoriais (LangChain Supabase vector store) ----------
CREATE TABLE IF NOT EXISTS wl_documents (
  id        BIGSERIAL PRIMARY KEY,
  content   TEXT,
  metadata  JSONB,
  embedding vector(1536)
);
CREATE INDEX IF NOT EXISTS idx_wl_docs_file_id
  ON wl_documents ( (metadata->>'file_id') );

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'wl_documents_embedding_hnsw'
  ) THEN
    EXECUTE 'CREATE INDEX wl_documents_embedding_hnsw
             ON wl_documents USING hnsw (embedding vector_cosine_ops)';
  END IF;
EXCEPTION WHEN OTHERS THEN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'wl_documents_embedding_ivfflat'
  ) THEN
    EXECUTE 'CREATE INDEX wl_documents_embedding_ivfflat
             ON wl_documents USING ivfflat (embedding vector_cosine_ops)
             WITH (lists = 100)';
  END IF;
END $$;

-- ---------- upsert atômico de metadata ----------
CREATE OR REPLACE FUNCTION wl_rag_upsert_metadata(
  p_file_id   TEXT,
  p_title     TEXT,
  p_code      TEXT  DEFAULT NULL,
  p_url       TEXT  DEFAULT NULL,
  p_source    TEXT  DEFAULT 'webhook',
  p_mime_type TEXT  DEFAULT NULL,
  p_schema    JSONB DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO wl_document_metadata(
    file_id, title, code, url, source, mime_type, schema, updated_at
  )
  VALUES (p_file_id, p_title, p_code, p_url, p_source, p_mime_type, p_schema, NOW())
  ON CONFLICT (file_id) DO UPDATE
    SET title      = COALESCE(EXCLUDED.title,     wl_document_metadata.title),
        code       = COALESCE(EXCLUDED.code,      wl_document_metadata.code),
        url        = COALESCE(EXCLUDED.url,       wl_document_metadata.url),
        source     = COALESCE(EXCLUDED.source,    wl_document_metadata.source),
        mime_type  = COALESCE(EXCLUDED.mime_type, wl_document_metadata.mime_type),
        schema     = COALESCE(EXCLUDED.schema,    wl_document_metadata.schema),
        updated_at = NOW();
END;
$$;

CREATE OR REPLACE FUNCTION wl_rag_purge_file(p_file_id TEXT)
RETURNS TABLE(deleted_chunks bigint, deleted_rows bigint)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  c1 bigint := 0;
  c2 bigint := 0;
BEGIN
  DELETE FROM wl_documents       WHERE metadata->>'file_id' = p_file_id;
  GET DIAGNOSTICS c1 = ROW_COUNT;
  DELETE FROM wl_document_rows   WHERE dataset_id = p_file_id;
  GET DIAGNOSTICS c2 = ROW_COUNT;
  deleted_chunks := c1;
  deleted_rows   := c2;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION wl_admin_rag_delete_file(p_file_id TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT wl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  PERFORM wl_rag_purge_file(p_file_id);
  DELETE FROM wl_document_metadata WHERE file_id = p_file_id;
END;
$$;

CREATE OR REPLACE FUNCTION wl_admin_list_rag_documents()
RETURNS TABLE(
  file_id     TEXT,
  title       TEXT,
  code        TEXT,
  url         TEXT,
  source      TEXT,
  mime_type   TEXT,
  chunk_count BIGINT,
  created_at  TIMESTAMPTZ,
  updated_at  TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT wl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      m.file_id, m.title, m.code, m.url, m.source, m.mime_type,
      COALESCE((SELECT COUNT(*) FROM wl_documents d WHERE d.metadata->>'file_id' = m.file_id), 0),
      m.created_at, m.updated_at
    FROM wl_document_metadata m
    ORDER BY COALESCE(m.code, m.title, m.file_id);
END;
$$;

-- Lista para membros (sem ACL — todo membro vê todos os documentos)
CREATE OR REPLACE FUNCTION wl_list_rag_documents()
RETURNS TABLE(
  file_id TEXT,
  title   TEXT,
  code    TEXT,
  url     TEXT
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT wl_is_member() THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT m.file_id, m.title, m.code, m.url
      FROM wl_document_metadata m
     ORDER BY COALESCE(m.code, m.title);
END;
$$;

-- ---------- match_documents (RAG global, isola anexos de chat) ----------
DROP FUNCTION IF EXISTS wl_match_documents(vector, int, jsonb);
CREATE OR REPLACE FUNCTION wl_match_documents(
  query_embedding vector(1536),
  match_count     int   DEFAULT 6,
  filter          jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(
  id         bigint,
  content    text,
  metadata   jsonb,
  similarity float
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  is_member_caller BOOLEAN := wl_is_member();
  is_service_role  BOOLEAN := (
    COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role'
    OR COALESCE(auth.role(), '') = 'service_role'
  );
  want_session TEXT := filter->>'session_id';
BEGIN
  IF NOT is_member_caller AND NOT is_service_role THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT
      d.id,
      d.content,
      (
        jsonb_strip_nulls(jsonb_build_object(
          'url',       m.url,
          'title',     m.title,
          'code',      m.code,
          'source',    m.source,
          'mime_type', m.mime_type
        )) || COALESCE(d.metadata, '{}'::jsonb)
      ) AS metadata,
      1 - (d.embedding <=> query_embedding) AS similarity
    FROM wl_documents d
    LEFT JOIN wl_document_metadata m
           ON m.file_id = d.metadata->>'file_id'
    WHERE d.metadata @> COALESCE(filter, '{}'::jsonb)
      -- isola anexos de conversa: busca global ignora chunks com session_id
      AND (
        want_session IS NOT NULL
        OR (d.metadata->>'session_id') IS NULL
      )
    ORDER BY d.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

GRANT SELECT  ON wl_document_metadata TO authenticated;
GRANT SELECT  ON wl_document_rows     TO authenticated;
GRANT SELECT  ON wl_documents         TO authenticated;
GRANT EXECUTE ON FUNCTION wl_rag_upsert_metadata(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_rag_purge_file(TEXT)            TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION wl_admin_rag_delete_file(TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION wl_admin_list_rag_documents()      TO authenticated;
GRANT EXECUTE ON FUNCTION wl_list_rag_documents()            TO authenticated;
GRANT EXECUTE ON FUNCTION wl_match_documents(vector, int, jsonb) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_match_documents(vector, int, jsonb);
-- DROP FUNCTION IF EXISTS wl_list_rag_documents();
-- DROP FUNCTION IF EXISTS wl_admin_list_rag_documents();
-- DROP FUNCTION IF EXISTS wl_admin_rag_delete_file(TEXT);
-- DROP FUNCTION IF EXISTS wl_rag_purge_file(TEXT);
-- DROP FUNCTION IF EXISTS wl_rag_upsert_metadata(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB);
-- DROP INDEX    IF EXISTS wl_documents_embedding_hnsw;
-- DROP INDEX    IF EXISTS wl_documents_embedding_ivfflat;
-- DROP TABLE    IF EXISTS wl_documents;
-- DROP TABLE    IF EXISTS wl_document_rows;
-- DROP TABLE    IF EXISTS wl_document_metadata;
-- NOTIFY pgrst, 'reload schema';
