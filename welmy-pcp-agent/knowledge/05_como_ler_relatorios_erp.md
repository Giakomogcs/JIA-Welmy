---
titulo: Como Ler os Relatórios do ERP (Inventário e Necessidades)
area: guia
tags: [erp, inventario, necessidades, relatorio, layout, parsing]
---

# Como Ler os Relatórios do ERP

A Welmy usa **dois relatórios** do ERP. O sistema detecta cada um sozinho e
cruza tudo por **código**. Este guia descreve o layout real.

## 1. Registro de Inventário (estoque físico)
Cabeçalho: **"REGISTRO DE INVENTÁRIO"**, com "Estoques Existentes em DD/MM/AAAA".

Estrutura por grupo:
```
Grupo de Estoque: MATERIA-PRIMA
<NCM>  <código> - <descrição>  <quantidade>  <und>  <valor_unit>  <valor_total>
...
Total do Grupo de Estoque: ...
```
- Grupos: **MATERIA-PRIMA**, **PECAS FABRICADAS**, **EMBALAGEM**.
- Mapeamento → `materia_prima`, `fabricado`, `embalagem`.
- O código pode ter **sufixo "R"** (ex.: `01384 R`) — é um item **distinto**.
- Exemplo: `8311.90.00 00232 - SOLDA EM FIO... 3,0000 PC 141,105 423,31`
  → código `00232`, qtd `3`, und `PC`, valor unit `141,105`.

**O que ele atualiza:** `estoque_atual`, `descrição`, `unidade`,
`valor_unitário`, `NCM` dos itens (sem mexer na classificação de risco).
Itens novos são criados.

## 2. Relatório de Necessidades (o que comprar/fabricar)
Cabeçalho: **"RELATÓRIO DE NECESSIDADES"**. Tem seções:
- **ITENS A COMPRAR** → grupo `comprado`.
- **ITENS A FABRICAR** → grupo `fabricado`.
- (a flag **C/F** por linha confirma: C = comprar, F = fabricar.)

Cada linha tem **PREVISÃO DE ENTRADA** e **PREVISÃO DE SAÍDA**. Após
`<código> - <descrição>  <und>  <C/F>` vêm **10 colunas numéricas**, nesta ordem:
```
Est.Disp+Alo | Ped.Compra | Or.Produção | Total Entrada |
Pedido Venda | Prev.Venda | Simulação | Requisitado |
Total Saídas | Necessidade
```
Os campos que o sistema usa:
- **Estoque** = `Est.Disp+Alo` (1ª coluna).
- **Pedido em aberto** = `Ped.Compra` (2ª coluna).
- **Necessidade bruta** = **`Total Saídas`** (penúltima).
- **Necessidade líquida (final)** = coluna **`Necessidade`** (última; o ERP já
  abate estoque e entradas). Ex.: `60933` → 1.200 saídas − 5 estoque − 600
  entrada = **595**.

> A linha **"ITENS PAIS OU ORIGINÁRIO DA SELEÇÃO INICIAL"** é o **produto final**
> do plano (ex.: `62291 - BAL W 200/50 M`), não um componente a comprar.

**O que ele gera:** um **plano** (`wl_plano`) com as necessidades já
classificadas por risco e a ação recomendada.

## 3. Formato recomendado
- **Excel/CSV** → parsing mais preciso (cabeçalhos por coluna).
- **PDF** → funciona (parser best-effort), mas depende da extração de texto.
  Em caso de dúvida no número, exporte em Excel.

## 4. Cruzamento (a "mágica")
Tudo se junta por **código**:
- **Inventário** dá o **estoque** (e valor unitário / NCM).
- **Necessidades** dá o que **falta** (bruta/líquida) e os **pedidos**.
- **Planilha mestre** dá o **lead time**, o **fornecedor**, a **curva**/**consumo**
  (só finais) e a **árvore de produtos** (part numbers).

Com isso o motor classifica o **risco** e sugere a ação, usando a **Necessidade
líquida do ERP** e o **lead time** por código.

## 5. O que o sistema **CALCULA** (não vem pronto em nenhum relatório)
Nenhuma das fontes traz estes números — o motor os deriva (migração 013):
- **consumo diário do componente** = `Total Saídas` ÷ horizonte (15 dias). Os
  produtos finais já têm consumo da aba ANALISE DE SKUS.
- **estoque mínimo** = `consumo diário × lead time` (pode ser ajustado à mão).
  É o estoque que segura a produção durante a reposição — abaixo dele há risco.
- **dias até ruptura** = `estoque ÷ consumo diário` (em quantos dias o estoque
  sobrevive) e se isso **cobre o lead time** até o **dia 25**.

## 6. O que realmente NÃO existe (nem calculado)
- **lead time decomposto** (fornecedor + terceiro + montagem): a planilha só tem
  **um** total por código → ele entra como a **etapa do fornecedor** (comprados);
  terceiro/montagem só se preenchidos à mão na tela Itens.
- **histórico de atraso do fornecedor** (atraso médio);
- **data de chegada** dos pedidos (o relatório traz só a quantidade).
