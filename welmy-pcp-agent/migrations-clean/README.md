# Migrations — Welmy (Copiloto de Suprimentos e PCP)

SQL para o Supabase (Postgres 15 + pgvector). Rode **na ordem** no SQL Editor.
Cada arquivo tem seções `UP` (aplicar) e comentários `DOWN` (reverter).
Prefixo de objetos: `wl_` · papel guardado em `raw_user_meta_data` (`role` ∈ `admin` | `visualizacao`, `company_name='welmy'`).

| Ordem | Arquivo | Objetos principais |
|---|---|---|
| 1 | `001_users_and_admin.sql` | `wl_set_updated_at()`, `wl_is_admin()`, `wl_is_member()`, CRUD de usuários |
| 2 | `002_rag_schema.sql` | `wl_document_metadata`, `wl_document_rows`, `wl_documents` (vector 1536, HNSW) + RPCs do RAG |
| 3 | `003_match_documents.sql` | `wl_match_documents()` — busca vetorial global; isola anexos de conversa por `session_id` |
| 4 | `004_chat_messages.sql` | `wl_chat_message` + trigger que extrai `user_id` do bloco `ID="<uuid>"` |
| 5 | `005_suprimentos_schema.sql` | `wl_fornecedor`, `wl_item` (lead time composto), `wl_pedido_compra`, `wl_plano`, `wl_necessidade`, `wl_decision_log` + RLS |
| 6 | `006_suprimentos_rpc.sql` | **Motor de regras** (`wl_classificar_risco`), ingestão (`wl_ingest_necessidades`), análise, dashboard, relatórios (estoque/MRP/lead time), decisões, stats |
| 7 | `007_seeds.sql` | Apenas **admin inicial** (sem dados de exemplo — catálogo/estoque vêm dos relatórios e da planilha) |
| 8 | `008_inventario_ingest.sql` | Ingestão do **Registro de Inventário** (`wl_ingest_inventario`), mapa de grupos, log de importações (`wl_inventario_import`) e colunas `valor_unitario`/`estoque_atualizado_em` |
| 9 | `009_catalogo_skus.sql` | Sincronização do **catálogo de SKUs** da planilha mestre (`wl_sync_skus_catalogo`, upsert por código) e log (`wl_catalogo_import`) |
| 10 | `010_planilha_mestre_replace.sql` | **Substituição total** do catálogo pela planilha mestre (`wl_replace_planilha_mestre`): recria os SKUs das abas `ANÁLISE DE SKUS` + `LEAD TIMES`, aplica lead time por código a **qualquer** item e remove os SKUs ausentes (estoque preservado) |
| 11 | `011_necessidade_reportada_patch.sql` | Guarda a **Necessidade final do ERP** (`necessidade_reportada`, usada como líquida exibida) e o **patch manual** (`wl_patch_item`): preenche dados que faltam pela interface e **persiste**; uma planilha/relatório novo sobrescreve via ingestão |
| 12 | `012_planilha_componentes.sql` | Evolui `wl_replace_planilha_mestre`: a aba `LEAD TIMES` passa a criar/atualizar o **catálogo de componentes** (descrição, unidade, grupo `F→fabricado`/`C→comprado`, **fornecedor** em `wl_fornecedor`, lead time). O REPLACE remove só `fabricado` ausentes; estoque preservado |
| 13 | `013_cobertura_estoque_minimo.sql` | **Motor de cobertura**: calcula `consumo_diario` do componente (Total Saídas ÷ 15 dias), **estoque mínimo = consumo × lead time** (`wl_item_estoque_minimo`), **dias até ruptura** e "cobre o lead time". Atualiza `wl_relatorio_estoque`, `wl_list_itens`, `wl_stats` para usar o mínimo calculado |
| 14 | `014_plano_unico_mrp.sql` | **MRP único**: cada Relatório de Necessidades **substitui totalmente** o anterior — `wl_finalize_plano` passa a apagar os demais planos (cascade nas necessidades). Adiciona `wl_delete_plano` (exclusão manual) e `wl_reprocessar_plano` (reanalisa com as bases atuais) |
| 15 | `015_mrp_arvore.sql` | **MRP em árvore** (`wl_mrp_arvore`): agrupa as necessidades por SKU final e devolve JSONB com **tempo total** (caminho crítico = maior lead time pendente), **tempo de cada item** e **o que já está OK** (necessidade líquida ≤ 0). Alimenta a tela MRP em árvore por SKU |
| 16 | `016_inventario_delete_import.sql` | **Excluir importação de inventário** (`wl_delete_inventario_import`): remove um registro do histórico de importações de inventário sem alterar o `estoque_atual` dos itens. (Reprocessar inventário = reenviar o arquivo pela tela.) |
| 17 | `017_inventario_unico.sql` | **Inventário único**: cada importação de inventário **substitui a anterior** no histórico — `wl_ingest_inventario` passa a apagar os imports antigos após gravar o novo (igual ao MRP único). O estoque dos itens continua sendo atualizado direto em `wl_item`. |

## Pré-requisitos
- Extensão `vector` habilitada (Database → Extensions → `vector`).
- Supabase Auth ativo.

## Modelo de domínio (escopo Welmy)
O agente lê o **Relatório de Necessidades** (Excel/CSV, ~300–400 itens) e, com um
**motor de regras determinístico**, calcula para cada componente:

- `necessidade_liquida = necessidade_bruta − estoque_atual`
- `cobertura_dias = (estoque + pedidos em aberto) / consumo_diário`
- `dias_ate_ruptura = estoque / consumo_diário` — em quantos dias o estoque "sobrevive"
- `chega_a_tempo = data_prevista_do_pedido ≤ data_de_necessidade` (regra: tudo até o **dia 25**)
- **lead time composto** por SKU: `fornecedor + terceiro + montagem` (real > padrão > soma das etapas)

### Classificação de risco (`wl_classificar_risco`, docx 5.3)
| Classe | Regra |
|---|---|
| **ALTO** | falta líquida + (sem pedido e estoque < 50% da necessidade) **ou** pedido chega depois da data de necessidade |
| **MÉDIO** | cobertura projetada < lead time do fornecedor **ou** pedido com chegada no limite |
| **BAIXO** | estoque + pedidos cobrem dentro do prazo |
| **DADO INCOMPLETO** | sem lead time / fornecedor / data / vínculo BOM, ou estoque 0 sem histórico |

A IA **não calcula** — apenas escreve a justificativa executiva (`justificativa_ia`).
A **lista priorizada** ordena por impacto na montagem + urgência (dias até ruptura).

## Admin inicial
`007` cria `admin@welmy.com.br` / `@Admin123`. **Troque a senha** após o primeiro login.
