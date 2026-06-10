# Welmy — Migrations para Supabase NOVO (fresh install)

Conjunto consolidado para subir o agente num Supabase do zero.
Substitui as 18 migrations incrementais de `../migrations-clean/`
(que continuam valendo para bancos JÁ migrados — **não rode as duas pastas**).

Cada arquivo já contém apenas a **versão final** de cada tabela/função
(sem o histórico de patches) e o **DOWN comentado** no final.

## Ordem de execução (SQL Editor do Supabase, como owner/postgres)

| #   | Arquivo                                | Conteúdo                                                                                                                | Consolida (antigas)         |
| --- | -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| 1   | `001_users_and_admin.sql`              | Helpers de papel (`wl_is_admin/member/backend` já com fix p/ n8n) + CRUD de usuários                                    | 001 + 018                   |
| 2   | `002_rag.sql`                          | pgvector, `wl_document_*`, `wl_documents`, RPCs RAG + `wl_match_documents`                                              | 002 + 003                   |
| 3   | `003_chat_messages.sql`                | `wl_chat_message` + trigger de user_id                                                                                  | 004                         |
| 4   | `004_suprimentos_schema.sql`           | Tabelas do domínio (item já com ncm/valor/necessidade_reportada) + `wl_item_lead_time` / `wl_item_estoque_minimo` + RLS | 005 + 008* + 011* + 013\*   |
| 5   | `005_suprimentos_rpc.sql`              | Motor de regras + todas as RPCs nas versões finais (MRP único, reportada, estoque mínimo calculado)                     | 006 + 011 + 013 + 014       |
| 6   | `006_ingestao_inventario_planilha.sql` | Ingestão de Inventário (único) + planilha mestre (replace c/ componentes)                                               | 008 + 009 + 012 + 016 + 017 |
| 7   | `007_mrp_arvore.sql`                   | `wl_mrp_arvore` (árvore por SKU/grupo p/ a tela MRP)                                                                    | 015                         |
| 8   | `008_seed_admin.sql`                   | Bootstrap do admin `admin@welmy.com.br` / `@Admin123` (troque a senha!)                                                 | 007                         |

\* apenas as colunas/funções que essas migrations adicionavam ao schema.

## Rollback

O DOWN de cada migration está comentado no fim do próprio arquivo
(seção `=======  DOWN  ========`). Para reverter, descomente e execute
na ordem **inversa** (008 → 001).

## Notas

- Todas são idempotentes (`IF NOT EXISTS` / `CREATE OR REPLACE`) — podem ser
  re-executadas sem erro.
- Sem dados de exemplo: catálogo/estoque/lead times entram só pelos
  relatórios do ERP e pela planilha mestre.
- `NOTIFY pgrst, 'reload schema'` no fim de cada arquivo atualiza o cache do
  PostgREST (evita "Could not find the function ... in the schema cache").
