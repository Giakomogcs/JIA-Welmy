-- =============================================
-- Welmy — 003: Chat message table + user_id trigger  (antiga 004)
--
-- Tabela compatível com LangChain Postgres Chat Memory.
-- Trigger preenche user_id automaticamente:
--   - mensagens "human" → extrai do bloco ID="<uuid>" no conteúdo
--   - demais tipos      → copia do primeiro human da mesma session
-- Rode APÓS 002_rag.sql
-- =============================================

-- =======  UP  ========

CREATE TABLE IF NOT EXISTS wl_chat_message (
  id          BIGSERIAL PRIMARY KEY,
  session_id  TEXT        NOT NULL,
  message     JSONB       NOT NULL,
  user_id     UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wl_chat_session ON wl_chat_message(session_id);
CREATE INDEX IF NOT EXISTS idx_wl_chat_user    ON wl_chat_message(user_id);

CREATE OR REPLACE FUNCTION trg_wl_set_chat_user_id()
RETURNS TRIGGER AS $$
DECLARE
  _content TEXT;
  _id_str  TEXT;
  _uid     UUID;
BEGIN
  IF NEW.user_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.message->>'type' = 'human' THEN
    _content := NEW.message->>'content';
    _id_str  := substring(_content from 'ID="([0-9a-fA-F-]{36})"');
    IF _id_str IS NOT NULL THEN
      NEW.user_id := _id_str::UUID;
    END IF;
  ELSE
    SELECT cm.user_id INTO _uid
      FROM wl_chat_message cm
     WHERE cm.session_id = NEW.session_id
       AND cm.user_id IS NOT NULL
     LIMIT 1;
    IF _uid IS NOT NULL THEN
      NEW.user_id := _uid;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_wl_chat_set_user_id ON wl_chat_message;
CREATE TRIGGER trg_wl_chat_set_user_id
  BEFORE INSERT ON wl_chat_message
  FOR EACH ROW
  EXECUTE FUNCTION trg_wl_set_chat_user_id();

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP TRIGGER  IF EXISTS trg_wl_chat_set_user_id ON wl_chat_message;
-- DROP FUNCTION IF EXISTS trg_wl_set_chat_user_id();
-- DROP TABLE    IF EXISTS wl_chat_message;
-- NOTIFY pgrst, 'reload schema';
