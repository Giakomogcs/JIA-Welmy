---
titulo: Planilha Mestre de SKUs (estrutura e uso)
area: guia
tags: [planilha, skus, part-number, arvore, lead-time, google-sheets]
fonte: base de conhecimento (RAG) — global
---

# Planilha Mestre de SKUs — Estrutura e Uso

A planilha mestre (Google Drive/Sheets) é a **fonte da verdade do catálogo** de
produtos finais, dos **lead times** e da **árvore de produtos (part numbers)**.
O agente a consulta com a ferramenta `consultar_planilha_skus`.

ID da planilha: `1zyhzgErwMMy0HPuhxQ_2q7p51MH8PFZuEdcH8wpSA_Q`

## Estrutura das abas
| Aba | Conteúdo | Colunas-chave |
|---|---|---|
| **ANALISE DE SKUS** | produtos finais (SKUs, ~59 finais) | DESCRIÇÃO DO PRODUTO, CODIGO, CURVAS, MEDIA MENSAL, **CONSUMO DIARIA ESTIMADO** |
| **LEAD TIMES** | catálogo de **componentes** | CODIGO, DESCRIÇÃO, UNIDADES, **FABRICA/COMPRADO** (F/C), **FORNECEDOR**, **LEAD TIME DIAS** |
| **(uma aba por código)** | **árvore de produtos / part numbers** do SKU | composição detalhada (BOM) |

> A aba **LEAD TIMES** é catálogo completo: além do prazo, cada componente entra
> no sistema com descrição, unidade, grupo (`F→fabricado`, `C→comprado`) e
> **fornecedor**.

## Como o agente deve consultar (2 passos)
1. **Não sabe o nome exato da aba?** Chame `consultar_planilha_skus` com
   `nome_do_separador` **vazio** → recebe a lista de abas.
2. Com a aba certa, passe `nome_do_separador` e, se quiser filtrar, um
   `termo_de_pesquisa` (código SKU, part number ou descrição).

Use para descobrir:
- **consumo diário** de um SKU (aba ANALISE DE SKUS);
- **lead time** de um item (aba LEAD TIMES);
- **composição/part numbers** de um SKU (aba do código).

## Substituição total (replace) e sync
A tela **Atualizar dados** coleta a planilha **direto do Google Sheets conectado**
(mesmo ID) — não é preciso subir arquivo. Acontece pelo botão **Sincronizar
planilha** e automaticamente antes de processar os PDFs. Ao sincronizar, o sistema:
1. **recria o catálogo** a partir de ANALISE DE SKUS + LEAD TIMES;
2. cadastra os **componentes** da aba LEAD TIMES (descrição, unidade, grupo F/C,
   **fornecedor**, lead time);
3. aplica o **lead time por código** a **qualquer** item;
4. **remove** os itens `fabricado` (finais + componentes fabricados) que saíram
   da planilha; comprados/MP/embalagem não são removidos aqui;
5. **preserva o estoque** (que vem do Inventário, não da planilha).

> Lacunas preenchidas manualmente na tela **Itens** persistem; quando a planilha
> trouxer o dado, ela **sobrescreve** o valor manual.

## Boas práticas de preenchimento
- **CÓDIGO** é a chave de cruzamento — mantenha igual ao do ERP.
- **CURVAS**: use A/B/C (aceita "CURVA A" ou "A").
- **CONSUMO DIÁRIO**: número (un/dia). Decimal com vírgula é aceito.
- **LEAD TIMES**: prazo em **dias**; pode incluir códigos de **componentes**,
  não só de SKUs finais.
