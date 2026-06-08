---
titulo: Como Ler os Relatórios do ERP (Inventário e Necessidades)
area: guia
tags: [erp, inventario, necessidades, relatorio, layout, parsing]
fonte: base de conhecimento (RAG) — global
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
- Grupos: **MATERIA-PRIMA**, **PECAS FABRICADAS**, **EMBALAGEM** (não existe
  grupo "comprado" aqui).
- Mapeamento → `materia_prima`, `fabricado`, `embalagem`.
- O código pode ter **sufixo "R"** (ex.: `01384 R`) — é um item **distinto**.
- Exemplo: `8311.90.00 00232 - SOLDA EM FIO... 3,0000 PC 141,105 423,31`
  → código `00232`, qtd `3`, und `PC`, valor unit `141,105`.

**O que ele atualiza:** `estoque_atual`, `descrição`, `unidade`,
`valor_unitário`, `NCM` dos itens (sem mexer na classificação de risco).
Itens novos são criados.

## 2. Relatório de Necessidades (o que comprar/fabricar = MRP)
Cabeçalho: **"RELATÓRIO DE NECESSIDADES"**. Tem seções:
- **ITENS A COMPRAR** → grupo `comprado` (flag **C**).
- **ITENS A FABRICAR** → grupo `fabricado` (flag **F**).
- **ITENS PAIS OU ORIGINÁRIO DA SELEÇÃO INICIAL** → o **produto final** do plano
  (ex.: `62291 - BAL W 200/50 M`), **não** um componente a comprar.

Após `<código> - <descrição>  <und>  <C/F>` vêm **10 colunas numéricas**, nesta ordem:
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

> **Importante (MRP único):** cada Relatório de Necessidades **É** o MRP e
> **substitui totalmente** o plano anterior — só existe **um** plano ativo por vez.

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

## 5. O que o sistema CALCULA (não vem pronto em nenhum relatório)
- **consumo diário do componente** = `Total Saídas` ÷ horizonte (15 dias);
- **estoque mínimo** = `consumo diário × lead time` (pode ser ajustado à mão);
- **dias até ruptura** = `estoque ÷ consumo diário` e se isso **cobre o lead
  time** até o **dia 25**.

## 6. O que realmente NÃO existe (nem calculado)
- **lead time decomposto** (fornecedor + terceiro + montagem): a planilha só tem
  **um** total por código;
- **histórico de atraso do fornecedor** (atraso médio);
- **data de chegada** dos pedidos (o relatório traz só a quantidade).
