import { workflow, node, trigger, sticky, newCredential, expr } from '@n8n/workflow-sdk';

const formUpload = trigger({
  type: 'n8n-nodes-base.formTrigger',
  version: 2.6,
  config: {
    name: 'Formulário de upload CSV',
    position: [0, 300],
    parameters: {
      formTitle: 'Data Lake BWE - Ingestão Bronze',
      formDescription: 'Anexe o CSV de notas de venda. Os dados serão gravados na camada bronze exatamente como estão no arquivo.',
      formFields: {
        values: [
          {
            fieldLabel: 'Arquivo CSV',
            fieldName: 'arquivo_csv',
            fieldType: 'file',
            multipleFiles: false,
            acceptFileTypes: '.csv',
            requiredField: true
          }
        ]
      },
      options: {
        appendAttribution: false,
        buttonLabel: 'Enviar para a bronze',
        path: 'bronze-notas-vendas'
      }
    }
  }
});

const extractCsv = node({
  type: 'n8n-nodes-base.extractFromFile',
  version: 1.2,
  config: {
    name: 'Extrair linhas do CSV',
    position: [240, 300],
    parameters: {
      operation: 'csv',
      binaryPropertyName: expr('{{ Object.keys($binary)[0] }}'),
      options: {
        delimiter: ',',
        encoding: 'utf-8',
        headerRow: true,
        includeEmptyCells: true,
        enableBOM: true
      }
    }
  }
});

const prepareRows = node({
  type: 'n8n-nodes-base.set',
  version: 3.5,
  config: {
    name: 'Montar linha bronze',
    position: [480, 300],
    parameters: {
      mode: 'manual',
      includeOtherFields: false,
      assignments: {
        assignments: [
          { id: 'numero_nf', name: 'numero_nf', value: expr('{{ $json.numero_nf }}'), type: 'string' },
          { id: 'data_emissao', name: 'data_emissao', value: expr('{{ $json.data_emissao }}'), type: 'string' },
          { id: 'cliente', name: 'cliente', value: expr('{{ $json.cliente }}'), type: 'string' },
          { id: 'cnpj_cliente', name: 'cnpj_cliente', value: expr('{{ $json.cnpj_cliente }}'), type: 'string' },
          { id: 'valor_total', name: 'valor_total', value: expr('{{ $json.valor_total }}'), type: 'string' },
          { id: 'status', name: 'status', value: expr('{{ $json.status }}'), type: 'string' },
          { id: 'payload', name: '_payload', value: expr('{{ $json }}'), type: 'object' },
          { id: 'lote', name: '_lote_id', value: expr("{{ 'n8n-exec-' + $execution.id }}"), type: 'string' },
          { id: 'arquivo', name: '_arquivo_nome', value: expr("{{ Object.values($('Formulário de upload CSV').first().binary)[0].fileName }}"), type: 'string' },
          { id: 'registro', name: '_registro_num', value: expr('{{ $itemIndex + 1 }}'), type: 'number' }
        ]
      },
      options: {
        dotNotation: false
      }
    }
  }
});

const insertBronze = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Gravar bronze.notas_vendas',
    position: [720, 300],
    parameters: {
      operation: 'insert',
      schema: { __rl: true, mode: 'name', value: 'bronze' },
      table: { __rl: true, mode: 'name', value: 'notas_vendas' },
      columns: { mappingMode: 'autoMapInputData', value: null },
      options: {
        queryBatching: 'transaction',
        replaceEmptyStrings: false,
        outputColumns: ['_bronze_id']
      }
    },
    credentials: { postgres: newCredential('Supabase BWA - Postgres') }
  }
});

const registerBatch = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.8,
  config: {
    name: 'Registrar lote',
    position: [960, 300],
    executeOnce: true,
    parameters: {
      operation: 'executeQuery',
      query: "insert into bronze.lotes_ingestao (lote_id, origem, tabela_destino, arquivo_nome, arquivo_mime, qtd_linhas) values ($1, 'n8n_form:notas_vendas', 'bronze.notas_vendas', $2, $3, $4) returning lote_id, qtd_linhas;",
      options: {
        queryReplacement: expr("{{ [ $('Montar linha bronze').first().json._lote_id, $('Montar linha bronze').first().json._arquivo_nome, Object.values($('Formulário de upload CSV').first().binary)[0].mimeType, $('Gravar bronze.notas_vendas').all().length ] }}")
      }
    },
    credentials: { postgres: newCredential('Supabase BWA - Postgres') }
  }
});

const formEnd = node({
  type: 'n8n-nodes-base.form',
  version: 2.5,
  config: {
    name: 'Confirmação',
    position: [1200, 300],
    parameters: {
      operation: 'completion',
      respondWith: 'text',
      completionTitle: 'Arquivo gravado na camada bronze',
      completionMessage: expr('{{ $json.qtd_linhas }} linhas gravadas em bronze.notas_vendas (lote {{ $json.lote_id }}).')
    }
  }
});

const note = sticky(
  '## Camada BRONZE\nRecebe o CSV pelo formulário e grava cada linha **como veio** (tudo texto, sem limpeza, sem dedupe) em `bronze.notas_vendas`, com `_payload` (linha original em jsonb), `_lote_id`, `_arquivo_nome`, `_registro_num` e `_ingerido_em`.\n\nInsert em transação: ou entra o arquivo inteiro, ou nada. O lote é registrado em `bronze.lotes_ingestao`.\n\nPrata e ouro ficam em workflows separados.',
  [formUpload, extractCsv, prepareRows, insertBronze, registerBatch, formEnd],
  { color: 4 }
);

export default workflow('etl-bronze-notas-vendas', 'ETL Bronze - Notas de Venda (upload CSV)')
  .add(formUpload)
  .to(extractCsv)
  .to(prepareRows)
  .to(insertBronze)
  .to(registerBatch)
  .to(formEnd)
  .add(note)
  .group('Gravação na bronze', [extractCsv, prepareRows, insertBronze, registerBatch], {
    description: 'Lê o CSV, monta cada linha sem tratamento + metadados e grava em bronze.notas_vendas numa transação'
  });
