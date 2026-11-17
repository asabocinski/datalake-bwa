-- =====================================================================
-- Camada BRONZE do data lake (medallion) - BWE
-- Fonte: upload de CSV via formulário n8n (workflow "ETL Bronze - Notas de Venda")
--
-- Regra da bronze: guardar o dado EXATAMENTE como chegou.
--   * todas as colunas de negócio como TEXT (sem cast, sem trim, sem dedupe)
--   * linha original completa em _payload (jsonb) para não perder colunas extras
--   * metadados de ingestão com prefixo "_" (lote, arquivo, posição, timestamp)
-- Limpeza, tipagem e deduplicação ficam para a camada PRATA.
-- =====================================================================

create schema if not exists bronze;
comment on schema bronze is 'Camada bronze: dados brutos, imutáveis, como vieram da origem';

-- ---------------------------------------------------------------------
-- Controle de lotes (uma linha por arquivo ingerido)
-- ---------------------------------------------------------------------
create table if not exists bronze.lotes_ingestao (
    lote_id        text        primary key,          -- "n8n-exec-<execution id>"
    origem         text        not null,             -- ex.: n8n_form:notas_vendas
    tabela_destino text        not null,             -- ex.: bronze.notas_vendas
    arquivo_nome   text,
    arquivo_mime   text,
    qtd_linhas     integer     not null,
    ingerido_em    timestamptz not null default now()
);
comment on table bronze.lotes_ingestao is 'Um registro por arquivo/lote gravado na bronze';

-- ---------------------------------------------------------------------
-- Notas de venda (CSV notas_vendas_*.csv)
-- ---------------------------------------------------------------------
create table if not exists bronze.notas_vendas (
    _bronze_id     bigint      generated always as identity primary key,

    -- colunas do CSV, sem tratamento
    numero_nf      text,
    data_emissao   text,
    cliente        text,
    cnpj_cliente   text,
    valor_total    text,
    status         text,

    -- linha original inteira (inclui colunas que não existam acima)
    _payload       jsonb       not null,

    -- metadados de ingestão
    _lote_id       text        not null,
    _arquivo_nome  text,
    _registro_num  integer,                          -- posição do registro no arquivo (1 = primeira linha de dados)
    _ingerido_em   timestamptz not null default now()
);
comment on table bronze.notas_vendas is 'Notas de venda brutas, como vieram do CSV (sem limpeza nem dedupe)';

create index if not exists notas_vendas_lote_idx      on bronze.notas_vendas (_lote_id);
create index if not exists notas_vendas_ingerido_idx  on bronze.notas_vendas (_ingerido_em);

-- ---------------------------------------------------------------------
-- Segurança: bronze NÃO é exposta pela API (PostgREST) e fica fechada
-- para anon/authenticated. O n8n grava via conexão Postgres direta.
-- ---------------------------------------------------------------------
alter table bronze.lotes_ingestao enable row level security;
alter table bronze.notas_vendas   enable row level security;

revoke all on schema bronze from public, anon, authenticated;
revoke all on all tables in schema bronze from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- (Opcional, recomendado) usuário dedicado para o n8n, só com INSERT/SELECT
-- na bronze. Rode separadamente definindo a senha fora do repositório:
--
--   create role n8n_etl login password '<defina-no-cofre>';
--   grant usage on schema bronze to n8n_etl;
--   grant select, insert on all tables in schema bronze to n8n_etl;
--   alter default privileges in schema bronze grant select, insert on tables to n8n_etl;
--   -- RLS: como o dono das tabelas é postgres, n8n_etl precisa de policy:
--   create policy n8n_etl_all on bronze.notas_vendas   for all to n8n_etl using (true) with check (true);
--   create policy n8n_etl_all on bronze.lotes_ingestao for all to n8n_etl using (true) with check (true);
-- ---------------------------------------------------------------------
