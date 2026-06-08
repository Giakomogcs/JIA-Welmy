---
titulo: Regras de Estoque Mínimo, Ponto de Pedido e Lead Time
area: regras
tags: [estoque-minimo, ponto-de-pedido, lead-time, cobertura, ruptura]
fonte: base de conhecimento (RAG) — global
---

# Regras — Estoque Mínimo, Ponto de Pedido e Lead Time

Guia de cálculo que o agente usa para **explicar** cobertura/ruptura e dizer
**o que falta cadastrar** quando um item está como `dado_incompleto`.

## 1. Lead time composto
O lead time efetivo de um item é o **primeiro disponível** nesta ordem:
1. `lead_time_real_dias` (histórico real — preferido);
2. `lead_time_padrao_dias` (prazo nominal do sistema);
3. soma das etapas `lt_fornecedor + lt_terceiro + lt_montagem`.

> Sempre prefira o **real**. O nominal costuma estar defasado. A planilha mestre
> traz **um** total por código → ele entra como a **etapa do fornecedor**
> (comprados); terceiro/montagem só se preenchidos à mão na tela Itens.

## 2. Estoque mínimo (segurança)
Modelo de referência:
```
estoque_mínimo = consumo_diário × lead_time × fator_segurança
```
- `fator_segurança` sugerido: **1,2** (itens normais) a **1,5** (Curva A /
  fornecedor único / lead time longo).
- O motor calcula `estoque_mínimo = consumo_diário × lead_time`; um valor
  preenchido à mão (override) tem prioridade enquanto não for sobrescrito.

## 3. Ponto de pedido (gatilho)
```
ponto_de_pedido = (consumo_diário × lead_time) + estoque_mínimo
```
Quando `estoque_atual ≤ ponto_de_pedido`, **dispare a compra**.

## 4. Cobertura e ruptura
```
cobertura_dias     = (estoque_atual + pedidos_em_aberto) / consumo_diário
dias_até_ruptura   = estoque_atual / consumo_diário
```
- **Cobre o lead time?** `dias_até_ruptura ≥ lead_time` → sim (sob controle).
- `cobertura_dias < lead_time` → **risco médio** (aperta o prazo).

## 5. Chega a tempo?
```
chega_a_tempo = data_prevista_do_pedido ≤ data_de_necessidade
```
Se o pedido em aberto chega **depois** da data de necessidade, ele **não
resolve** — tratar como se não houvesse pedido (risco alto).

## 6. Consumo diário do componente (calculado)
Nenhum relatório traz isso pronto. O motor deriva:
```
consumo_diário (componente) = Total Saídas ÷ horizonte (15 dias)
```
Os produtos finais já têm consumo da aba **ANALISE DE SKUS** da planilha.

## 7. O que cadastrar quando falta dado
Um item fica `dado_incompleto` quando falta um destes. Peça ao usuário para
completar **exatamente** o que estiver faltando:
- **consumo diário** (un/dia) — sem ele não há cobertura nem ruptura;
- **lead time** — sem ele não dá para saber se chega a tempo;
- **estoque atual** — vem do Inventário; se zerado sem histórico, validar;
- **data de necessidade** — vem do plano (default: dia 25);
- **vínculo do item** (cadastro/BOM) — para relacionar ao SKU final.

> Esses campos podem ser preenchidos manualmente na tela **Itens** (persistem).
> Quando uma planilha/relatório novo trouxer o dado, ele **sobrescreve** o
> valor manual.
