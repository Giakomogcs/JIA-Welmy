---
titulo: Visão Geral da Welmy e do Copiloto
area: contexto
tags: [welmy, producao, balancas, copiloto, objetivo, pcp, suprimentos]
fonte: base de conhecimento (RAG) — global
---

# Visão Geral — Welmy e o Copiloto de Suprimentos e PCP

## Quem é a Welmy
A **Welmy Indústria e Comércio Ltda** é uma fabricante brasileira de **balanças
e equipamentos de pesagem** com mais de **40 anos** de mercado. Produz linhas
como balanças **pesadoras (P3 a P30)**, **comerciais (W100/W200/W300)**,
**plataformas (WPL)**, **antropométricas/baby**, **estadiômetros/infantômetros**
e indicadores **IDW**.

## Ritmo de produção
- Produção média de **2.500 peças a cada 15 dias** (horizonte padrão de
  fabricação = **15 dias**).
- Cada produto final (SKU) é composto por **dezenas de componentes** de grupos
  diferentes.
- **Prazo limite: dia 25** do mês de competência — todos os componentes precisam
  estar disponíveis até essa data.

## Grupos de componentes
| Grupo | Exemplos | Origem |
|---|---|---|
| **matéria-prima** | chapa de aço, tubo, barra chata, aço tref. | fornecedor |
| **comprado** | parafusos, células de carga, displays, baterias, cabos | fornecedor |
| **fabricado** | bases, colunas, réguas, cursores (produção interna) | interno |
| **fabricado_terceiro** | usinagem, tratamento, zincagem, pintura | terceiro |
| **embalagem** | caixas de papelão, manuais, calços, pallets | fornecedor |

## Lead time composto
O prazo total de um item pode somar até **3 etapas**:
**fornecedor + terceiro + montagem interna**. Itens com **fornecedor único**
(sem segunda fonte) têm risco extra, porque qualquer atraso não tem plano B.

## Objetivo do copiloto
Garantir que **todos os componentes do Relatório de Necessidades cheguem a
tempo** para o plano de produção, **sem ruptura de estoque** e respeitando o
**prazo limite do dia 25** do mês de competência. O copiloto:

1. Mostra a **lista priorizada** de componentes em risco.
2. Explica, por item: **necessidade líquida**, **cobertura (dias)**,
   **dias até a ruptura** e se o pedido **chega a tempo**.
3. Recomenda a **ação** (comprar / fabricar / antecipar / abrir pedido / acompanhar).
4. Destaca itens **abaixo do mínimo** e **fornecedores únicos**.

## As 3 fontes de dados (nada além disso é automático)
1. **Registro de Inventário** (PDF do ERP) → estoque físico atual.
2. **Relatório de Necessidades** (PDF do ERP) → o que falta comprar/fabricar (MRP).
3. **Planilha mestre** (Google Sheets) → lead time, fornecedor, curva/consumo
   dos SKUs finais e a árvore de produtos (part numbers).

Tudo é cruzado por **código** do item.

## Princípio central (humano decide)
O **motor de regras determinístico** calcula cobertura, ruptura e risco. O
**LLM apenas explica e prioriza** em linguagem clara — **não recalcula** o risco
e **não inventa** dados. A recomendação é do agente; a **decisão é da equipe**
de Compras/PCP (human-in-the-loop).
