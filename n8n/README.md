# ETL no n8n (medallion)

| Camada | Workflow n8n | Destino |
|---|---|---|
| Bronze | `ETL Bronze - Notas de Venda (upload CSV)` ([fonte SDK](workflows/etl_bronze_notas_vendas.sdk.ts)) | `bronze.notas_vendas`, `bronze.lotes_ingestao` |
| Prata  | a fazer | `silver.*` |
| Ouro   | a fazer | `gold.*` |

## Bronze: fluxo

1. **Formulário de upload CSV** (Form Trigger, path `bronze-notas-vendas`): campo de arquivo `.csv` obrigatório.
2. **Extrair linhas do CSV**: Extract from File (CSV, header, UTF-8, mantém células vazias).
3. **Montar linha bronze**: copia as 6 colunas do CSV como texto, sem tratamento, e adiciona
   `_payload` (linha original em jsonb), `_lote_id` (`n8n-exec-<execution id>`), `_arquivo_nome`, `_registro_num`.
4. **Gravar bronze.notas_vendas**: Postgres insert em transação (ou entra o arquivo inteiro, ou nada).
5. **Registrar lote**: uma linha em `bronze.lotes_ingestao` com a contagem.
6. **Confirmação**: página final do formulário com linhas gravadas e id do lote.

`_ingerido_em` vem do `default now()` do banco.

## Pré-requisitos

1. Aplicar `supabase/migrations/20261117200000_bronze_notas_vendas.sql` no Postgres do Supabase.
2. Criar no n8n a credencial Postgres `Supabase BWA - Postgres` apontando para o banco do Supabase
   (de preferência o usuário dedicado `n8n_etl`, ver bloco opcional na migração) e associá-la aos
   nós "Gravar bronze.notas_vendas" e "Registrar lote".
3. Testar pela URL de teste do formulário com `samples/notas_vendas_baguncadas.csv` (41 linhas de dados, sujas de propósito).
4. Publicar o workflow para usar a URL de produção.

## Conferência após a carga

```sql
select * from bronze.lotes_ingestao order by ingerido_em desc;
select count(*), count(distinct numero_nf) from bronze.notas_vendas where _lote_id = '<lote>';
```
Duplicatas, datas em vários formatos, CNPJ com/sem máscara e valores "R$ 1.326,08" ficam como vieram: quem trata é a prata.
