# Defeitos de SQL no e-SUS APS PEC 5.6.1

Estes três problemas não se resolvem com índice: a consulta precisa mudar dentro do PEC. Para cada um, este documento descreve o problema, mostra a consulta como ela aparece no banco (`pg_stat_activity`) e propõe a correção em SQL.

Os três foram reportados ao suporte do e-SUS APS. Se o seu município tem os mesmos sintomas, abrir um chamado citando este relato ajuda a priorizar a correção.

Condições do teste: veja o [README](../README.md#condições-do-teste).

---

## 1 e 2. Núcleo familiar e família por CPF/CNS do responsável

### Sintoma

- Erro `FATAL: sorry, too many clients already` no log do PostgreSQL. Na base testada houve 953 ocorrências num dia, com 309 conexões para um limite de 300.
- Mais de cem cópias simultâneas da mesma consulta (consulta 3 de [sql/01-diagnostico.sql](../sql/01-diagnostico.sql)).
- Página inicial do PEC levando cerca de 30 s. Imóveis do e-SUS Território quase não são processados.
- Na base testada, essas duas consultas somavam **cerca de 80% do tempo do banco**.

**Quando aparecem:** na sincronização dos tablets dos ACS e em ações de território no PEC web, como salvar imóvel e processar território.

### Causa

As duas consultas têm o mesmo padrão. Uma tabela de vínculo (núcleo familiar, família) é juntada à `tb_cidadao` por **CPF ou CNS** do responsável, e o filtro também usa OR entre colunas das duas tabelas. Forma simplificada, como aparece no banco:

```sql
SELECT f.*
FROM tb_familia f
LEFT JOIN tb_cidadao c
       ON (f.nu_cpf_cns_responsavel = c.nu_cpf OR f.nu_cpf_cns_responsavel = c.nu_cns)
WHERE f.nu_cpf_cns_responsavel IN (:docs)
   OR c.nu_cpf IN (:docs)
   OR c.nu_cns IN (:docs);
```

O OR no `WHERE` mistura colunas de tabelas diferentes, e por isso nenhum índice pode ser usado. O PostgreSQL junta a tabela de vínculo inteira com a de cidadãos (1,8 milhão e 910 mil linhas, na base testada) e só depois filtra. **Os índices necessários já existem.** O problema é a forma da consulta.

A consulta de núcleo familiar (`tb_cidadao_nucleo_familiar`) segue o mesmo padrão.

### Correção proposta

Separar em dois passos, cada um com filtro que usa índice:

1. Expandir a lista de documentos: para cada cidadão cujo CPF **ou** CNS está na lista, acrescentar os dois documentos dele.
2. Buscar os vínculos cujo documento do responsável está na lista expandida.

```sql
WITH docs AS (
    SELECT unnest(CAST(:docs AS text[])) AS doc
    UNION
    SELECT unnest(ARRAY[c.nu_cpf, c.nu_cns])
    FROM tb_cidadao c
    WHERE c.nu_cpf = ANY (:docs) OR c.nu_cns = ANY (:docs)   -- OR na mesma tabela: BitmapOr com os índices existentes
)
SELECT f.*
FROM tb_familia f
WHERE f.nu_cpf_cns_responsavel IN (SELECT doc FROM docs WHERE doc IS NOT NULL);
```

### Resultado na base testada

| | Antes | Depois |
|---|---|---|
| Núcleo familiar | 9–24 min | 0,5 ms |
| Família | 19–24 min | 0,6 ms |
| Conexões | 309 | 32–64 |
| Página inicial | cerca de 32 s | cerca de 1 s |
| Imóveis processados | 2 em cerca de 3 h | cerca de 4 por minuto |

**Equivalência:** a correção foi validada por [teste diferencial](teste-diferencial.md) na réplica. Houve 0 divergências em 2.163 amostras (núcleo familiar) e 2.409 amostras (família). A amostra incluiu casos de borda: responsável sem CPF, sem CNS, com os dois, documento inexistente e dois cidadãos com o mesmo documento.

### Mitigação enquanto não há correção oficial

Cancelar as cópias dessas consultas que passam de 10 minutos libera conexões e evita o "too many clients". A sincronização tenta de novo depois. Os filtros abaixo usam o início do texto da consulta, porque o `pg_stat_activity` corta o texto em 1.024 caracteres por padrão:

```sql
SELECT pg_cancel_backend(pid)
FROM pg_stat_activity
WHERE datname = current_database()
  AND state = 'active'
  AND now() - query_start > interval '10 minutes'
  AND (query LIKE 'select familia0_.co_seq_familia%from tb_familia familia0_ left outer join tb_cidadao%'
    OR query LIKE 'select cidadaonuc0_.co_seq_cidadao_nucleo_familiar%');
```

**Isso é um paliativo, não uma correção.** Confira antes, com um `SELECT` sem o `pg_cancel_backend`, se o filtro pega só as consultas certas na sua versão.

---

## 3. ETL "Cidadãos vinculados"

### Sintoma

- A fila de fichas recebidas (`tb_dado_transp_recebido`) para de baixar. Na base testada, ficou parada por 5 dias, com cerca de 25,5 mil fichas.
- Na rodada noturna, a etapa "Cidadãos vinculados" (`tb_etl_cidadaos_vinc_prcs`) passou a levar **44–65 horas**. Antes, levava cerca de 5 minutos, e por meses a maioria das rodadas terminou em erro.
- Como a baixa da fila é a última etapa da rodada, nada é baixado enquanto essa etapa não termina.

Para acompanhar, use as consultas 7, 8 e 9 de [sql/01-diagnostico.sql](../sql/01-diagnostico.sql).

### Causa

A rodada separa os cidadãos a processar numa tabela auxiliar (`tb_etl_auxiliar_number`). Mas a consulta que insere os cidadãos vinculados calcula as subconsultas com função de janela sobre **todos os responsáveis do município** (cerca de 372 mil, na base testada) e só depois filtra pela tabela auxiliar. O PostgreSQL estima 7 linhas onde há milhões e escolhe um nested loop que não termina.

### Correção proposta

Aplicar o filtro da tabela auxiliar **dentro** de cada subconsulta, antes da janela, e não só no final:

```sql
-- dentro de cada subconsulta que percorre os responsáveis
WHERE co_cidadao IN (SELECT nu_valor_para_processar FROM tb_etl_auxiliar_number)
```

O resultado não muda, porque o filtro final já restringe aos mesmos cidadãos. A diferença é que a janela passa a ser calculada só sobre o lote da rodada.

### Resultado na base testada

| | Antes | Depois |
|---|---|---|
| Etapa "Cidadãos vinculados" | 44–65 h | 4 min |
| Fila de fichas | parada | 25.583 fichas baixadas na mesma noite |

**Equivalência:** a validação foi mais fraca que a dos itens 1 e 2. O resultado foi idêntico (hash) em 3 lotes reais, de 48 a 76 linhas.

**Atenção:** se o serviço do PEC for reiniciado no meio da rodada, a sessão do ETL pode ficar órfã no PostgreSQL. Ela segura locks até ser encerrada com `pg_terminate_backend`. Veja as consultas 2 e 5 de [sql/01-diagnostico.sql](../sql/01-diagnostico.sql).
