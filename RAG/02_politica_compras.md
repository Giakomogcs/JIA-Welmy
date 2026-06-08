---
titulo: Política de Compras
area: politica
tags: [compras, politica, prazo, fornecedor-unico, aprovacao]
nota: MODELO EDITÁVEL — ajuste os números à realidade da Welmy.
fonte: base de conhecimento (RAG) — global
---

# Política de Compras — Welmy (modelo)

> Este é um **modelo editável**. Os prazos, faixas e alçadas abaixo são
> sugestões de referência; ajuste para as regras reais da Welmy antes de tratar
> como oficial. O agente sempre usa os **dados reais do banco** sobre o texto.

## 1. Princípio
Comprar **na hora certa, na quantidade certa**, para que **todo componente do
Relatório de Necessidades chegue até o dia 25** do mês de competência, sem
ruptura e sem excesso de estoque.

## 2. Quando comprar (gatilhos)
Dispare a reposição quando **qualquer** condição for verdadeira:
- `estoque_atual < estoque_mínimo` (abaixo do mínimo), ou
- `estoque_atual ≤ ponto_de_pedido`, ou
- a análise do plano classificar o item como **risco alto** ou **médio**.

## 3. Quanto comprar
- Cobrir a **necessidade líquida** do plano + repor o **estoque mínimo**.
- Para **Curva A**, considerar uma folga de segurança maior (fornecedor único
  ou lead time longo).

## 4. Antecedência (lead time)
- Emitir o pedido com antecedência ≥ **lead time composto** do item
  (`fornecedor + terceiro + montagem`) somado ao **atraso médio** do fornecedor.
- Para **fornecedor único**, adicionar margem extra (sugestão: +20% do lead time).

## 5. Fornecedor único
- Itens de fornecedor único são **prioridade**: qualquer atraso não tem segunda
  fonte. Sinalize sempre e prefira antecipar.
- Ação recomendada: buscar **segunda fonte** para itens Curva A de fonte única.

## 6. Faixas de alçada (modelo)
| Valor do pedido | Aprovação |
|---|---|
| até R$ 5.000 | Comprador |
| R$ 5.000 – R$ 50.000 | Coordenador de Suprimentos |
| acima de R$ 50.000 | Gerência |

## 7. Itens fabricados e por terceiro
- **fabricado** internamente → vira **ordem de fabricação** (PCP), não compra.
- **fabricado_terceiro** → acionar o terceiro (usinagem/tratamento/pintura) com
  antecedência do lead time da etapa.

## 8. Registro de decisão
Toda decisão tomada na fila de necessidades deve ser **registrada** (comprar /
antecipar / abrir pedido / acompanhar / ignorar) com o **motivo**. Isso alimenta
a base de aprendizado e melhora as recomendações futuras.
