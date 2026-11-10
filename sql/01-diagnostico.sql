-- Diagnóstico de desempenho do e-SUS APS PEC (PostgreSQL)
-- Todas as consultas são só de leitura. Rode como superusuário ou com pg_read_all_stats.

-- 1. Consultas que mais consomem tempo do banco (requer pg_stat_statements)
SELECT round(total_exec_time / 1000 / 60) AS minutos_total,
       calls                               AS execucoes,
       round(mean_exec_time)               AS ms_media,
       round(max_exec_time)                AS ms_max,
       left(regexp_replace(query, '\s+', ' ', 'g'), 160) AS consulta
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 25;

-- 2. Consultas ativas há mais de 60 segundos
SELECT pid,
       now() - query_start AS duracao,
       wait_event_type,
       wait_event,
       left(regexp_replace(query, '\s+', ' ', 'g'), 160) AS consulta
FROM pg_stat_activity
WHERE datname = current_database()
  AND state = 'active'
  AND pid <> pg_backend_pid()
  AND now() - query_start > interval '60 seconds'
ORDER BY duracao DESC;

-- 3. Mesma consulta rodando em várias cópias. Muitas cópias de uma consulta
--    lenta esgotam as conexões ("FATAL: sorry, too many clients already").
SELECT count(*) AS copias,
       max(now() - query_start) AS mais_antiga,
       left(regexp_replace(query, '\s+', ' ', 'g'), 120) AS inicio_da_consulta
FROM pg_stat_activity
WHERE datname = current_database() AND state = 'active'
GROUP BY 3
HAVING count(*) > 3
ORDER BY copias DESC;

-- 4. Conexões por estado, comparadas com max_connections
SELECT state, count(*),
       current_setting('max_connections') AS max_connections
FROM pg_stat_activity
GROUP BY state
ORDER BY 2 DESC;

-- 5. Sessões "idle in transaction" há mais de 30 minutos (seguram locks e impedem o vacuum)
SELECT pid, usename, application_name,
       now() - state_change AS parada_ha,
       left(regexp_replace(query, '\s+', ' ', 'g'), 120) AS ultima_consulta
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - state_change > interval '30 minutes'
ORDER BY parada_ha DESC;

-- 6. Quem está bloqueando quem
SELECT bloqueada.pid AS pid_bloqueada,
       left(bloqueada.query, 80) AS consulta_bloqueada,
       bloqueadora.pid AS pid_bloqueadora,
       left(bloqueadora.query, 80) AS consulta_bloqueadora,
       now() - bloqueada.query_start AS esperando_ha
FROM pg_stat_activity bloqueada
JOIN LATERAL unnest(pg_blocking_pids(bloqueada.pid)) AS b(pid) ON true
JOIN pg_stat_activity bloqueadora ON bloqueadora.pid = b.pid
ORDER BY esperando_ha DESC;

-- 7. Fila de fichas recebidas (e-SUS Território, CDS, integrações).
--    Pendentes que só crescem indicam que a rodada noturna não está terminando.
SELECT count(*) FILTER (WHERE dt_processamento IS NULL)          AS pendentes,
       count(*) FILTER (WHERE dt_processamento >= current_date)  AS processadas_hoje,
       max(dt_processamento)                                     AS ultima_baixa
FROM tb_dado_transp_recebido
WHERE dt_recebimento >= current_date - 30;

-- 8. Etapas da última rodada de processamento dos relatórios
SELECT dt_processamento_inicio,
       dt_processamento_producao,
       dt_processamento_operacionais,
       dt_processamento_consolidados,
       dt_processamento_conclusao
FROM tb_dado_rel_processamento
ORDER BY dt_processamento_inicio DESC
LIMIT 5;

-- 9. Etapa "Cidadãos vinculados" do ETL (era a mais lenta na base testada)
SELECT no_status_processamento, dt_inicio, dt_fim, dt_fim - dt_inicio AS duracao
FROM tb_etl_cidadaos_vinc_prcs
ORDER BY dt_inicio DESC
LIMIT 10;

-- 10. Maiores tabelas e índices
SELECT c.relname,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_size_pretty(pg_relation_size(c.oid))       AS tabela,
       pg_size_pretty(pg_indexes_size(c.oid))        AS indices
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 20;
