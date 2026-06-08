# RAG — Documentos para o Copiloto da Welmy (prontos para o Drive)

Esta pasta tem os **documentos de conhecimento** que fundamentam as respostas do
copiloto de Suprimentos e PCP: visão geral, glossário, política de compras,
regras de estoque/lead time, classificação de risco, como ler os relatórios do
ERP, a planilha mestre, o playbook do agente e o FAQ.

São arquivos **`.md` autocontidos** — basta jogá-los no Google Drive (ou subir
pela tela do app) para o agente passar a citá-los via `search_knowledge_base`.

## Índice

| Arquivo | Conteúdo | O agente usa para… |
|---|---|---|
| `00_visao_geral_welmy.md` | Quem é a Welmy, produtos, ritmo de produção, 3 fontes de dados | Contextualizar respostas |
| `01_glossario_suprimentos.md` | Glossário (necessidade líquida, cobertura, ruptura, lead time, MRP) | Padronizar termos |
| `02_politica_compras.md` | Política de compras, gatilhos, alçadas, fornecedor único | Fundamentar recomendações |
| `03_regras_estoque_minimo_leadtime.md` | Estoque mínimo, ponto de pedido, cobertura, ruptura | Explicar e dizer o que cadastrar |
| `04_classificacao_risco_e_acoes.md` | Regras de risco (alto/médio/baixo/incompleto) e ação por grupo | Justificar o risco e a ação |
| `05_como_ler_relatorios_erp.md` | Layout do Inventário e do Relatório de Necessidades | Interpretar o que foi enviado |
| `06_planilha_mestre_skus.md` | Estrutura da planilha mestre (SKUs, lead times, árvore/part numbers) | Guiar `consultar_planilha_skus` |
| `07_playbook_agente.md` | Fluxos, ferramentas, tom, formato, erros a evitar | Seguir o fluxo correto |
| `08_faq_suprimentos.md` | Perguntas frequentes de Compras/PCP | Responder dúvidas recorrentes |

## Como o agente pega os documentos

Há **dois caminhos** — use o que preferir:

### A) Subir pelo app (recomendado, indexa na hora)
1. Entre no app como **admin**.
2. Menu lateral → **Documentos (RAG)**.
3. **Enviar documento** → escolha cada `.md` desta pasta (um por vez).
   - O upload chama `welmy-rag-admin-upload`, extrai o texto, gera embeddings
     (`text-embedding-3-small`, 1536 dim) e grava em `wl_documents` como
     conhecimento **global** (vale para todas as conversas).
   - O arquivo original também é **arquivado** na pasta do Google Drive
     `139W-HfLxR7y3XzFHv8VULfy8tnTZ2FcO`.

### B) Jogar direto no Drive
1. Copie os `.md` desta pasta para a pasta do Drive do RAG
   (`139W-HfLxR7y3XzFHv8VULfy8tnTZ2FcO`).
2. Indexe-os subindo-os uma vez pela tela **Documentos (RAG)** (passo A) para
   gerar os embeddings — só copiar o arquivo no Drive **não** cria os chunks
   sozinho; o Drive é o arquivo morto, a busca usa `wl_documents`.

> **Atualizou um documento?** Remova a versão antiga em **Documentos (RAG)**
> antes de subir a nova, para não duplicar trechos.

## Observações
- Os números de exemplo (prazos, mínimos, alçadas) em `02` são **modelos
  editáveis** — ajuste para a realidade da Welmy. O agente sempre prioriza os
  **dados reais** do banco (estoque, lead time, pedidos) sobre o texto do RAG.
- Estes arquivos espelham, em formato Drive-ready, a base em
  `welmy-pcp-agent/knowledge/`.
