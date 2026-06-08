# Base de Conhecimento — Welmy (RAG do Copiloto de Suprimentos e PCP)

Esta pasta contém os **documentos de contexto e guias** para subir na base de
conhecimento (RAG) do agente de IA da Welmy. Eles fundamentam as respostas do
copiloto: políticas de compras, regras de estoque/lead time, glossário, como
ler os relatórios do ERP e a planilha mestre, e os procedimentos de decisão.

## Como subir no RAG

1. Entre no app como **admin**.
2. Menu lateral → **Documentos (RAG)**.
3. Faça **upload** de cada arquivo `.md` desta pasta (um por vez).
   - O upload usa o endpoint `welmy-rag-admin-upload` → extrai o texto, gera
     embeddings (`text-embedding-3-small`, 1536 dim) e grava em `wl_documents`
     como conhecimento **global** (vale para todas as conversas).
4. Pronto: o agente passa a citar esses documentos via a ferramenta
   `search_knowledge_base(query)`.

> Atualizou um documento? Suba a versão nova — o ideal é remover a antiga em
> **Documentos (RAG)** antes, para não duplicar trechos.

## Índice dos documentos

| Arquivo | Conteúdo | O agente usa para… |
|---|---|---|
| `00_visao_geral_welmy.md` | Quem é a Welmy, produtos, ritmo de produção, objetivo do copiloto | Contextualizar respostas, saudações |
| `01_glossario_suprimentos.md` | Glossário (lead time composto, cobertura, ruptura, curva ABC, MRP…) | Padronizar termos e explicar conceitos |
| `02_politica_compras.md` | Política de compras, prazos, ponto de pedido, fornecedor único | Fundamentar recomendações de compra |
| `03_regras_estoque_minimo_leadtime.md` | Como calcular estoque mínimo, ponto de pedido e lead time | Explicar cobertura/ruptura e o que cadastrar |
| `04_classificacao_risco_e_acoes.md` | Regras de risco (alto/médio/baixo/dado incompleto) e ações por grupo | Explicar o porquê do risco e a ação certa |
| `05_como_ler_relatorios_erp.md` | Layout do Inventário e do Relatório de Necessidades | Interpretar o que o usuário enviou |
| `06_planilha_mestre_skus.md` | Estrutura da planilha mestre (SKUs, lead times, árvore/part numbers) | Guiar `consultar_planilha_skus` |
| `07_playbook_agente.md` | Passo a passo das respostas, tom, formato, erros a evitar | Seguir o fluxo e o formato corretos |
| `08_faq_suprimentos.md` | Perguntas frequentes do time de compras/PCP | Responder dúvidas recorrentes |

> **Importante:** os números de exemplo (prazos, mínimos, contatos) são
> **modelos editáveis**. Ajuste para a realidade da Welmy antes de subir, ou
> suba como estão e refine depois — o agente sempre prioriza os **dados reais**
> do banco (estoque, lead time, pedidos) sobre o texto do RAG.
