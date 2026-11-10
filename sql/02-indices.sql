-- Índices de desempenho para o e-SUS APS PEC 5.6.x
--
-- CREATE INDEX CONCURRENTLY não bloqueia o PEC, mas não roda dentro de transação.
-- Rode cada comando separadamente, com o psql em autocommit (o padrão).
-- Antes de criar cada índice, rode a verificação dele e confirme que a consulta-alvo
-- aparece no pg_stat_statements (sql/01-diagnostico.sql, consulta 1).
--
-- Tempos medidos na base de referência (PEC 5.6.1, ~1,4 TB). Veja o README.


-- ---------------------------------------------------------------------------
-- 1. RNDS: busca de registros com envio pendente
--    Consulta-alvo:
--      select min(co_seq_envio_rnds) / max(...) from tb_envio_rnds where st_necessita_envio = $1
--    O índice do PEC "in_envrnds_necenvio_coseq" não contém st_necessita_envio, apesar do nome.
--    Antes: 2–13 min | Depois: 0,2 ms | Tamanho: ~544 MB | Criação: ~40 s
-- ---------------------------------------------------------------------------

-- Verificação
SELECT indexdef FROM pg_indexes WHERE indexname = 'in_envrnds_necenvio_coseq';
SELECT st_necessita_envio, count(*) FROM tb_envio_rnds GROUP BY 1;

CREATE INDEX CONCURRENTLY IF NOT EXISTS in_envrnds_stnecenvio_coseq_perf
    ON tb_envio_rnds (st_necessita_envio, co_seq_envio_rnds);


-- ---------------------------------------------------------------------------
-- 2. Cadastro individual com erro de inativação
--    Consulta-alvo:
--      select 1 from tb_cds_cad_individual
--      where st_erro_inativacao = $1 and st_versao_atual = $2 and co_localidade_origem = $3 limit $4
--    Nenhum índice do PEC inclui st_erro_inativacao.
--    Antes: 23–70 s | Depois: 0,09 ms | Tamanho: ~67 MB | Criação: ~11 s
-- ---------------------------------------------------------------------------

-- Verificação
SELECT st_erro_inativacao, st_versao_atual, count(*) FROM tb_cds_cad_individual GROUP BY 1, 2;

CREATE INDEX CONCURRENTLY IF NOT EXISTS in_cdscadind_sterroinat_stversatl_perf
    ON tb_cds_cad_individual (st_erro_inativacao, st_versao_atual, co_localidade_origem);


-- ---------------------------------------------------------------------------
-- 3. Cidadão pelo UUID da última ficha (executada a cada FCI processada)
--    Consulta-alvo:
--      select ... from tb_cidadao where co_unico_ultima_ficha = $1 limit $2
--    Sem índice, o PostgreSQL lê a tabela inteira (parallel seq scan).
--    Antes: ~1 s e ~3,5 GB lidos | Depois: < 0,1 ms | Tamanho: ~127 MB | Criação: ~16 s
--    Na base testada rodava ~26 vezes por minuto: foi o índice de maior impacto total.
-- ---------------------------------------------------------------------------

-- Verificação
SELECT count(*) AS execucoes, round(mean_exec_time) AS ms_media
FROM pg_stat_statements WHERE query ILIKE '%co_unico_ultima_ficha%';

CREATE INDEX CONCURRENTLY IF NOT EXISTS in_cidadao_counicoultficha_perf
    ON tb_cidadao (co_unico_ultima_ficha)
    WHERE co_unico_ultima_ficha IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 4. Busca de cidadão pelo nome da mãe
--    Consulta-alvo: ... where no_mae_filtro like '%texto%'
--    O PEC já tem índice trigram para o nome do cidadão, mas não para o nome da mãe.
--    Requer a extensão pg_trgm (o PEC já a usa).
--    Antes: ~3,1 s (máx. 39 s) | Depois: ~40 ms | Tamanho: ~214 MB | Criação: ~73 s
--    É o índice mais pesado para escrita. Crie só se essa busca aparecer como lenta.
-- ---------------------------------------------------------------------------

-- Verificação
SELECT extname FROM pg_extension WHERE extname = 'pg_trgm';
SELECT count(*) AS execucoes, round(mean_exec_time) AS ms_media
FROM pg_stat_statements WHERE query ILIKE '%no_mae_filtro%';

CREATE INDEX CONCURRENTLY IF NOT EXISTS in_cidadao_nomaefiltrogin_perf
    ON tb_cidadao USING gin (no_mae_filtro gin_trgm_ops);


-- ---------------------------------------------------------------------------
-- Depois de criar: confirme que os índices estão válidos e sendo usados
-- ---------------------------------------------------------------------------
SELECT c.relname AS indice, i.indisvalid AS valido, s.idx_scan AS usos,
       pg_size_pretty(pg_relation_size(c.oid)) AS tamanho
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = i.indexrelid
WHERE c.relname LIKE '%\_perf';
-- Se um índice ficar com valido = false (criação interrompida), remova e crie de novo.
