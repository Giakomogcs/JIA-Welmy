---
titulo: Classificação de Risco e Ações Recomendadas
area: regras
tags: [risco, acao, alto, medio, baixo, dado-incompleto, prioridade]
---

# Classificação de Risco e Ações Recomendadas

O risco é **calculado no banco** (determinístico). O agente **não recalcula** —
explica e prioriza. Este documento descreve as regras para o agente **justificar**
cada classificação de forma consistente.

## Classes de risco

### 🔴 ALTO
Vai **romper antes** de o pedido chegar, ou está sem cobertura. Dispara quando:
- falta líquida > 0 **e sem pedido** em aberto e estoque < 50% da necessidade; **ou**
- falta líquida > 0 **com pedido** que **não chega a tempo**; **ou**
- estoque + pedidos **não cobrem** a necessidade dentro do prazo.

### 🟠 MÉDIO
**Aperta o prazo**, exige acompanhamento/antecipação. Dispara quando:
- cobertura projetada **< lead time** do fornecedor; **ou**
- pedido em aberto com chegada **no limite** da data de necessidade (≤ 3 dias de folga).

### 🟢 BAIXO
Sob controle: estoque + pedidos cobrem a demanda dentro do prazo.

### ⚪ DADO INCOMPLETO
Não dá para concluir. Dispara quando falta: vínculo/cadastro (BOM), lead time,
data de necessidade, **ou** estoque zerado sem histórico de consumo. **Ação:**
peça para **completar o cadastro** (diga o que falta).

## Ação recomendada por grupo + risco

| Grupo | Risco alto | Risco médio |
|---|---|---|
| **fabricado** | `fabricar` (gerar ordem) | `programar_fabricacao` |
| **fabricado_terceiro** | `acionar_fornecedor` (terceiro) | `acionar_fornecedor` |
| **comprado / matéria-prima / embalagem** | `comprar` (ou `acompanhar_pedido` se já há pedido) | `acionar_fornecedor` / `acompanhar_pedido` |
| qualquer (risco baixo) | `ok` | `ok` |
| qualquer (dado incompleto) | `validar_estoque` ou `revisar_dado` | — |

## Prioridade (ordem da fila)
Quanto maior o score, mais urgente. Pesa:
1. **Risco** (alto > médio > baixo);
2. **Impacto em SKUs** (quantos produtos finais o item afeta) — +5 por SKU;
3. **Fornecedor único** — +25;
4. **Proximidade da ruptura** (quanto menos dias, mais urgente);
5. **Grupo crítico** (matéria-prima / terceiro) — +10.

## Como o agente deve explicar
Para cada item recomendado, dizer em 1 frase:
- a **necessidade líquida**, os **dias até a ruptura**, se **chega a tempo** e o
  **impacto** (nº de SKUs). Ex.: *"CHP-03 rompe hoje; fornecedor único (terceiro
  30 dias); sem pedido; afeta 4 SKUs → antecipar compra para garantir o dia 25."*
