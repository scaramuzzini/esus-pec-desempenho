-- Remove os índices criados por sql/02-indices.sql.
-- Rode cada comando separadamente, fora de transação.

DROP INDEX CONCURRENTLY IF EXISTS in_envrnds_stnecenvio_coseq_perf;
DROP INDEX CONCURRENTLY IF EXISTS in_cdscadind_sterroinat_stversatl_perf;
DROP INDEX CONCURRENTLY IF EXISTS in_cidadao_counicoultficha_perf;
DROP INDEX CONCURRENTLY IF EXISTS in_cidadao_nomaefiltrogin_perf;
