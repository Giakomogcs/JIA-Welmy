-- =============================================
-- Welmy — 003: match_documents (RAG global, sem ACL)
--
-- wl_match_documents(query_embedding, match_count, filter):
--   * Sem gating por categoria/equipe. Qualquer membro autenticado, admin
--     ou service_role (n8n) pode recuperar qualquer trecho.
--   * Anexos de conversa (com session_id na metadata) são isolados da busca
--     global; com filtro {session_id} retorna só os daquela conversa (008).
--
-- Rode APÓS 002_rag_schema.sql
-- =============================================

-- =======  UP  ========

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

GRANT EXECUTE ON FUNCTION wl_match_documents(vector, int, jsonb)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS wl_match_documents(vector, int, jsonb);
-- NOTIFY pgrst, 'reload schema';
