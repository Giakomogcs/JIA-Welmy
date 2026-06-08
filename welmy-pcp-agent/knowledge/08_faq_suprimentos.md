---
titulo: FAQ — Suprimentos e PCP
area: faq
tags: [faq, duvidas, compras, pcp, estoque]
---

# FAQ — Perguntas Frequentes (Compras e PCP)

Respostas curtas para dúvidas recorrentes do time. O agente pode citar e
adaptar com os **dados reais** do plano.

## Geral

**O que o copiloto faz?**
Lê o último Relatório de Necessidades, mostra os componentes **em risco**
priorizados, explica necessidade líquida / cobertura / ruptura / "chega a tempo"
e recomenda a ação (comprar/fabricar/acionar/acompanhar). A **decisão é sua**.

**De onde vêm os dados?**
- Estoque → **Registro de Inventário** (ERP).
- O que falta comprar/fabricar → **Relatório de Necessidades** (ERP).
- Lead time e árvore de produtos → **planilha mestre** (Google Sheets).
Tudo cruzado por **código**.

**Qual o prazo limite?**
Tudo precisa **chegar até o dia 25** do mês de competência.

## Risco e prioridade

**Por que um item está em risco alto?**
Vai romper antes de o pedido chegar, ou está sem cobertura (sem pedido e estoque
< 50% da necessidade, ou o pedido chega depois da data de necessidade).

**O que significa "dado incompleto"?**
Falta informação para concluir (consumo diário, lead time, estoque ou vínculo).
Complete o cadastro do item — pode ser na tela **Itens** (persiste) ou subindo a
planilha/relatório que traga o dado.

**Como é definida a ordem da fila?**
Risco + impacto em SKUs + fornecedor único + proximidade da ruptura + grupo
crítico (matéria-prima/terceiro).

## Estoque e compras

**Quando devo comprar?**
Quando o item está abaixo do mínimo, atingiu o ponto de pedido, ou foi
classificado como risco alto/médio. Compre com antecedência ≥ lead time + atraso
médio do fornecedor.

**O que é fornecedor único e por que importa?**
Item com uma só fonte. Qualquer atraso não tem plano B → prioridade e margem
extra; busque uma segunda fonte para Curva A.

**Item "fabricado" também se compra?**
Não. `fabricado` vira **ordem de fabricação** (PCP). `fabricado_terceiro` →
acionar o terceiro (usinagem/tratamento/pintura).

## Dados e atualização

**Subi a planilha nova com dados que faltavam — vale a nova?**
Sim. A planilha/relatório **sobrescreve** o que estava em branco ou
desatualizado. Lacunas preenchidas à mão persistem **até** a planilha trazer o
valor oficial.

**Posso jogar os dois relatórios e a planilha de uma vez?**
Sim. Na tela **Atualizar dados** há uma única caixa "Atualizar tudo" — solte os
arquivos juntos que cada um é roteado automaticamente. No chat também dá para
anexar vários de uma vez.

**Excel ou PDF?**
Prefira **Excel/CSV** (parsing mais preciso). PDF funciona, mas depende da
extração de texto.
