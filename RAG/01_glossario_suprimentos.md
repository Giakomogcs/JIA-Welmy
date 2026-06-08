---
titulo: Glossário de Suprimentos e PCP
area: glossario
tags: [glossario, lead-time, cobertura, ruptura, mrp, curva-abc]
fonte: base de conhecimento (RAG) — global
---

# Glossário — Suprimentos e PCP (Welmy)

Definições padronizadas. O agente deve usar **estes termos** ao explicar.

## Demanda e necessidade
- **Necessidade bruta** — quantidade total exigida pelo plano (no relatório do
  ERP é a coluna **"Total Saídas"**).
- **Necessidade líquida** — o que de fato precisa ser comprado/fabricado depois
  de abater estoque e pedidos em aberto. No Relatório de Necessidades é a
  **coluna "Necessidade"** (o ERP já calcula).
  - Fórmula de referência: `líquida = bruta − estoque_disponível − pedidos_em_aberto`.
  - Exemplo: bateria com 1.200 de saída, 5 em estoque e 600 em pedido →
    necessidade = **595**.

## Estoque
- **Estoque atual** — saldo físico (vem do **Registro de Inventário**).
- **Estoque mínimo** — saldo de segurança abaixo do qual o item entra em alerta.
- **Ponto de pedido** — saldo que dispara a reposição:
  `ponto_de_pedido = consumo_diário × lead_time + estoque_mínimo`.
- **Abaixo do mínimo** — `estoque_atual < estoque_mínimo` (alerta vermelho).

## Tempo e cobertura
- **Consumo diário** — média de unidades consumidas por dia. Se não houver
  cadastro, é estimado por `necessidade_bruta / horizonte (15 dias)`.
- **Cobertura (dias)** — quantos dias o estoque + pedidos aguentam:
  `(estoque + pedidos) / consumo_diário`.
- **Dias até a ruptura** — quantos dias o estoque **sozinho** aguenta:
  `estoque / consumo_diário`. Quando chega a 0, o item **rompe**.
- **Lead time** — prazo entre pedir e ter o item disponível. Na Welmy é
  **composto**: `fornecedor + terceiro + montagem`. Vale `real > padrão > soma das etapas`.
- **Atraso médio** — histórico de dias que o fornecedor costuma atrasar.
- **Chega a tempo** — `data_prevista_do_pedido ≤ data_de_necessidade`.

## Prazos da Welmy
- **Competência** — mês de referência do plano (1º dia do mês).
- **Data limite (dia 25)** — **tudo** precisa chegar até o dia **25** do mês de
  competência.
- **Horizonte de fabricação** — janela padrão de **15 dias** (~2.500 peças).

## Classificação
- **Curva ABC** — prioridade do item: **A** (mais crítico/relevante), B, C.
- **Risco** — `alto | medio | baixo | dado_incompleto` (ver documento 04).
- **MRP** — *Material Requirements Planning*: a necessidade líquida por grupo com
  a ação recomendada (o "o que comprar/fabricar" do plano).

## Fornecimento
- **Fornecedor único** — item com **uma só fonte**; aumenta o risco.
- **Terceiro** — empresa que faz uma etapa (usinagem, zincagem, pintura).
- **Pedido em aberto** — pedido de compra ainda não recebido (`aberto`,
  `parcial` ou `atrasado`).
