# Welmy — Copiloto de Suprimentos e PCP

Agente de IA para a **Welmy** (fabricante de balanças e equipamentos de pesagem,
40+ anos). É um **serviço de retaguarda** que, a partir do **Relatório de
Necessidades** da produção (Excel/CSV, ~300–400 itens), apoia o **PCP** e
**Suprimentos**:

- prevê o tempo de chegada dos materiais (lead time por SKU: fornecedor +
  terceiro + montagem);
- analisa atrasos de fornecedores e de serviços terceirizados;
- controla estoque com **estoque mínimo** e calcula **quantos dias o estoque
  sobrevive** até o pedido chegar;
- gera **relatório de estoque**, **relatório de necessidades (MRP)** e
  **lead time por SKU**;
- garante que todas as peças do plano de produção cheguem até o **dia 25** do mês.

> Contexto de produção: ~2.500 peças a cada ~15 dias de fabricação; a
> matéria-prima **não pode faltar**.

## Arquitetura

```
front-welmy.html  ──HTTP──►  n8n (webhooks welmy-*)  ──►  Supabase (Postgres + pgvector + Auth)
                                      │
                                      ├─ AI Agent (Azure OpenAI gpt-4o-mini)
                                      ├─ RAG (text-embedding-3-small → wl_documents)
                                      └─ RPCs SECURITY DEFINER (regras determinísticas)
```

Princípio central: **as regras calculam, o LLM justifica**. Toda priorização,
classificação de risco e cobertura de estoque é feita por RPCs no banco; o modelo
apenas redige a explicação em linguagem natural.

## Estrutura do projeto

| Pasta | Conteúdo |
|---|---|
| `migrations-clean/` | Esquema Supabase (auth/admin, RAG, suprimentos, RPCs, seeds). Ver `migrations-clean/README.md`. |
| `workspaces/` | Workflows n8n (`Welmy-*.json`) + inventário. Ver `workspaces/README.md`. |
| `front-welmy.html` | SPA (login Supabase, dashboards, RAG, chat). Servida pelo `Welmy-Front`. |
| `.scripts/` | Utilitários (ex.: `build-front-workflow.ps1`). |

## Stack

- **n8n** — orquestração e webhooks.
- **Supabase** — Postgres 15 + `pgvector` + Auth (RLS). Papel em
  `raw_user_meta_data.role ∈ {admin, visualizacao}`, `company_name='welmy'`.
- **Azure OpenAI** — `gpt-4o-mini` (chat) e `text-embedding-3-small` (embeddings, 1536 dims).

## Como subir

1. **Banco:** aplicar `migrations-clean/*.sql` no Supabase (ordem numérica).
2. **n8n:** importar os workflows de `workspaces/` e preencher as credenciais
   `REPLACE_ME_*` (ver `workspaces/README.md`).
3. **Front:** abrir `…/webhook/welmy-app`; ajustar `CONFIG` no HTML se necessário.
4. **Ingestão:** enviar o Relatório de Necessidades via `welmy-ingest`
   (a tela de planos do front dispara isso).

## Sobre a pasta de referência

Este projeto foi derivado do agente **NL Diagnóstica** (domínio de editais de
licitação), mantido **apenas como referência** em `../welmy-agent/`. O projeto da
Welmy é independente e vive em `welmy-pcp-agent/`; nenhum arquivo da NL é
necessário em produção.
