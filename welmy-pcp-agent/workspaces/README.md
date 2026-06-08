# Welmy — Workflows n8n

Coleção de workflows do **Copiloto de Suprimentos e PCP** da Welmy. Cada arquivo
`.json` é importado individualmente no n8n (**Import from File**).

> Todos os webhooks usam o prefixo `welmy-*`. As credenciais são *placeholders*
> (`REPLACE_ME_*`) que devem ser preenchidas no momento da importação.

## Inventário

| Arquivo | Tipo | Endpoint(s) | Função |
|---|---|---|---|
| `Welmy-Front.json` | Webhook GET → HTML | `welmy-app` | Serve a SPA `front-welmy.html` (HTML embutido). |
| `Welmy-Relatorio.json` | Webhook POST (serviço de fundo) | `welmy-relatorio` | **Endpoint unificado**: detecta sozinho se o arquivo é Inventário ou Necessidades (PDF/Excel/CSV) e roteia para a ingestão certa. Usado pela tela "Atualizar dados" e pelo anexo do chat. |
| `Welmy-Ingest.json` | Webhook POST (serviço de fundo) | `welmy-ingest` | Recebe o Relatório de Necessidades (Excel/CSV/PDF), cria o plano, ingere/classifica as necessidades e finaliza o plano. |
| `Welmy-Inventario.json` | Webhook POST (serviço de fundo) | `welmy-inventario` | Recebe o Registro de Inventário (Excel/CSV/PDF) e atualiza o estoque físico dos itens (`wl_ingest_inventario`). |
| `Welmy-Migrate-Planilha.json` | Webhook POST (serviço de fundo) | `welmy-migrate-planilha` | Lê a **planilha mestre conectada** (id fixo) e faz o **replace total** do catálogo a partir das abas `ANALISE DE SKUS` + `LEAD TIMES` (`wl_replace_planilha_mestre`). **Sync sem upload**: se o POST não trouxer arquivo, lê direto do Google Sheets; se trouxer, primeiro substitui o arquivo no Drive. A aba `LEAD TIMES` cadastra os **componentes** (descrição, unidade, F/C, fornecedor, lead time). |
| `Welmy-Agent.json` | AI Agent | `welmy-AgentRag` | Chat do copiloto (Azure OpenAI + memória Postgres + RAG global e de sessão). Chama as ferramentas do Bridge. |
| `Welmy-Bridge.json` | 9 Webhooks POST → Postgres | `welmy-tool-*` | Ferramentas determinísticas do agente (stats, dashboard, necessidade, estoque, mrp, leadtime, planos, learning, decision). |
| `Welmy-RAG.json` | 2 Webhooks POST → Vector Store | `welmy-rag-admin-upload`, `welmy-rag-upload` | Upload de documentos para a base de conhecimento (global e por sessão de chat). Extrai texto (PDF/planilha/texto), faz embeddings e insere em `wl_documents`. **Arquiva o arquivo original** na pasta do Drive `139W-HfLxR7y3XzFHv8VULfy8tnTZ2FcO` (anexos de chat ficam com prefixo `chat-<sessão>-`). |
| `Welmy-RAG-Admin.json` | 4 Webhooks → Postgres | `welmy-rag-docs` (GET), `welmy-rag-doc-delete`, `welmy-rag-purge-all`, `welmy-rag-upsert` | API admin da base RAG usada pela tela **Documentos (RAG)**: listar documentos (+ contagem de chunks), excluir por `file_id`, limpar toda a base, e upsert de metadados. RAG **global** (sem categorias/equipes); queries parametrizadas. |
| `Welmy-Chat-GET-Sessions.json` | Webhook GET → Postgres | `welmy-sessions` | Lista as conversas do usuário. |
| `Welmy-Chat-GET-History.json` | Webhook GET → Postgres | `welmy-history` | Histórico de mensagens de uma conversa. |
| `Welmy-Chat-DELETE-Session.json` | Webhook DELETE → Postgres | `welmy-session` | Apaga uma conversa. |
| `Welmy-AdminUser.json` | Webhook POST → Supabase Auth Admin | `welmy-admin-create-user` | Cria usuários do app via `service_role` (define `company_name='welmy'` e o papel). |
| `Welmy-Sub-Planilha-SKUs.json` | Sub-fluxo (Execute Workflow Trigger) | — (chamado pelo Agent) | Consulta inteligente da planilha de SKUs/Part Numbers no Google Sheets. Sem aba → lista as abas; com aba → devolve/filtra as linhas. Usado como ferramenta `consultar_planilha_skus`. |

## Credenciais (placeholders a substituir)

| Placeholder | Tipo n8n | Nome sugerido | Usado em |
|---|---|---|---|
| `REPLACE_ME_WELMY_DB` | Postgres | `Welmy-DB` | Ingest, Inventario, Bridge, Chat, RAG (purge/metadata) |
| `REPLACE_ME_AZURE_OPENAI_CRED` | Azure OpenAI | `Azure OpenAI` | Agent (chat + embeddings), RAG (embeddings) |
| `REPLACE_ME_SUPABASE_CRED` | Supabase API | `Supabase account` | Agent (vector store), RAG (insert) |
| `REPLACE_ME_SUPABASE_HOST` | (string na URL) | — | AdminUser (`https://<host>/auth/v1/admin/users`) |
| `REPLACE_ME_SERVICE_ROLE_KEY` | (header) | — | AdminUser (`apikey` + `Authorization: Bearer`) |
| `REPLACE_ME_GSHEETS_CRED` | Google Sheets OAuth2 | `Google Sheets account` | Sub-Planilha-SKUs, Migrate-Planilha (ler abas/linhas) |
| `REPLACE_ME_GDRIVE_CRED` | Google Drive OAuth2 | `Google Drive account` | Migrate-Planilha (substituir o arquivo da planilha mestre); RAG (arquivar uploads/anexos na pasta `139W-HfLxR7y3XzFHv8VULfy8tnTZ2FcO`) |
| `REPLACE_ME_SHEET_ID` | (string) | — | Sub-Planilha-SKUs (ID da planilha do Google Sheets) |
| `REPLACE_ME_PLANILHA_WF_ID` | (id de workflow) | — | Agent → ferramenta `consultar_planilha_skus` (ID do `Welmy-Sub-Planilha-SKUs` importado) |

> O Postgres usa o usuário `postgres`, reconhecido por `wl_is_backend()` — assim
> as RPCs `SECURITY DEFINER` aceitam as chamadas do n8n sem JWT de usuário.

## Modelos de IA

- **Chat:** Azure OpenAI `gpt-4o-mini`.
- **Embeddings:** Azure OpenAI `text-embedding-3-small` (1536 dimensões — bate
  com o `vector(1536)` de `wl_documents`).

## Ordem de ativação sugerida

1. Aplicar as migrations (`../migrations-clean/`) no Supabase.
2. Importar e configurar credenciais em **Welmy-Bridge** (as ferramentas).
3. Importar **Welmy-Agent** (depende dos endpoints do Bridge).
4. Importar **Welmy-RAG** e os 3 workflows de **Chat**.
5. Importar **Welmy-Sub-Planilha-SKUs** (configurar credencial Google Sheets e `REPLACE_ME_SHEET_ID`); anotar o **ID do workflow** e preencher `REPLACE_ME_PLANILHA_WF_ID` no **Welmy-Agent**.
6. Importar **Welmy-Ingest** (serviço de fundo).
7. Importar **Welmy-Inventario** (serviço de fundo).
8. Importar **Welmy-AdminUser**.
9. Importar **Welmy-Front** e abrir `…/webhook/welmy-app` no navegador.
10. Em `front-welmy.html` (e no nó HTML do Front), conferir `CONFIG.N8N_BASE`,
   `SUPABASE_URL` e `SUPABASE_ANON_KEY`.

## Serviço de fundo — Welmy-Relatorio (recomendado)

Endpoint **único e automático** para os dois relatórios do ERP. Fluxo:
`welmy-relatorio` (POST multipart, campo `data`) → **Detect Kind** → **É PDF?**
→ **Extract PDF/Spreadsheet** → **Detectar e Normalizar** (identifica Inventário
x Necessidades pelo conteúdo e normaliza as linhas no layout real do ERP) →
**Rota por Tipo** → `wl_ingest_inventario` **ou** `wl_create_plano` +
`wl_ingest_necessidades` + `wl_finalize_plano`. Resposta:
`{ tipo: 'inventario'|'necessidades', ... }` (ou 422 `desconhecido`).

Parsers (PDF real da Welmy):
- **Inventário**: cabeçalhos `Grupo de Estoque: ...`; linhas
  `NCM  código - descrição  qtd  und  valor_unit  valor_total`.
- **Necessidades**: seções `ITENS A COMPRAR`/`ITENS A FABRICAR`; linhas
  `código - descrição  und  C/F  … Total Saídas  Necessidade` (estoque = 1ª
  coluna, necessidade bruta = `Total Saídas`; o grupo vem do C/F).

> Na tela **Atualizar dados** o front usa este endpoint só para os **PDFs dos
> relatórios** (Inventário e Necessidades): antes de processá-los ele faz um
> **sync da planilha conectada** (`welmy-migrate-planilha` sem arquivo) e há um
> botão **Sincronizar planilha** para coletar SKUs/lead times sob demanda. O
> **anexo do chat** também aponta para `welmy-relatorio` (vários arquivos
> juntos). Os workflows `Welmy-Ingest` e `Welmy-Inventario` continuam válidos
> como endpoints diretos.

## Serviço de fundo — Welmy-Ingest

Fluxo: `welmy-ingest` (POST multipart, campo `data`) →
**Parse Spreadsheet** (xlsx/csv) → **Build Payload** →
`wl_create_plano` → `wl_ingest_necessidades` → `wl_finalize_plano` → resposta
`{ plano_id, inseridos }`.

O parser de necessidades aceita variações de cabeçalho (`codigo`/`código`/`cod`,
`necessidade_bruta`/`necessidade`/`qtd`, `estoque_atual`/`saldo`, etc.). A
classificação de risco (`alto`/`medio`/`baixo`/`dado_incompleto`) e o cálculo de
cobertura/ruptura são feitos no banco — o LLM apenas escreve a justificativa.

PDF: o **Build Payload** detecta arquivos PDF e faz um parser best-effort das
linhas `CÓDIGO - DESCRIÇÃO  UND  C/F  …  Necessidade`. Para máxima precisão,
prefira exportar o relatório em Excel/CSV.

## Serviço de fundo — Welmy-Inventario

Fluxo: `welmy-inventario` (POST multipart, campo `data`) →
**Detect Kind** → **É PDF?** → **Extract PDF** / **Extract Spreadsheet** →
**Build Inventory Rows** → `wl_ingest_inventario` → resposta
`{ atualizados, criados, total }`.

Atualiza `wl_item.estoque_atual` (e `descricao`/`unidade`/`valor_unitario`) dos
itens existentes sem alterar a classificação de risco; cria itens novos quando o
código ainda não está cadastrado. O grupo é mapeado a partir do cabeçalho
"Grupo de Estoque" (MATÉRIA-PRIMA → `materia_prima`, PEÇAS FABRICADAS →
`fabricado`, EMBALAGEM → `embalagem`). Cada importação fica registrada em
`wl_inventario_import` (tela **Atualizar dados** do front).

## Serviço de fundo — Welmy-Migrate-Planilha

Fluxo: `welmy-migrate-planilha` (POST multipart) → **Detect File** →
**Tem arquivo?** → (sim) **Update Drive File** (substitui o arquivo
`1zyhzgErwMMy0HPuhxQ_2q7p51MH8PFZuEdcH8wpSA_Q` no Drive) / (não) **sync** direto →
**Ler Aba Lead Times** (`LEAD TIMES`) → **Coletar** (colapsa para 1 item) →
**Ler Aba SKUs** (`ANALISE DE SKUS`) → **Build Rows** →
`wl_replace_planilha_mestre` → resposta
`{ atualizados, criados, componentes, removidos, total }`.

> **Sync sem upload**: o front coleta a planilha conectada chamando este endpoint
> **sem o campo `data`** (só `userId`). Nesse modo o **Update Drive File** é
> pulado e o fluxo lê direto do Google Sheets. Com `data` (arquivo), ele primeiro
> substitui o arquivo no Drive e depois lê as abas.

A planilha mestre contém: aba `ANALISE DE SKUS` (produtos finais: `DESCRIÇÃO DO
PRODUTO`, `CODIGO`, `CURVAS`, `MEDIA MENSAL`, `CONSUMO DIARIA ESTIMADO`), aba
`LEAD TIMES` (componentes: `CODIGO`, `DESCRIÇÃO`, `UNIDADES`, `FABRICA/COMPRADO`,
`FORNECEDOR`, `LEAD TIME DIAS`) e uma aba por código de produto com a árvore de
produtos / part numbers (lida pelo agente via Sub-Planilha-SKUs). O import faz
**replace total** do grupo `fabricado` (produtos finais + componentes fabricados):
recria os itens das abas e **remove** os `fabricado` que saíram da planilha; itens
`comprado`/`materia_prima`/`embalagem` não são removidos aqui (vêm do inventário).
A aba `LEAD TIMES` agora cadastra cada **componente** com descrição, unidade,
grupo (`F→fabricado`, `C→comprado`), **fornecedor** (`wl_fornecedor`) e lead time.
O `estoque_atual` é sempre preservado (vem do Registro de Inventário do ERP).
> Use o **mesmo id** da planilha em `REPLACE_ME_SHEET_ID` (Sub-Planilha-SKUs):
> `1zyhzgErwMMy0HPuhxQ_2q7p51MH8PFZuEdcH8wpSA_Q`.

## Re-geração do Welmy-Front

O HTML é embutido por script (evita edição manual do JSON):

```powershell
powershell -ExecutionPolicy Bypass -File .scripts\build-front-workflow.ps1
```
