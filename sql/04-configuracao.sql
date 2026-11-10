-- Configuração do PostgreSQL para o e-SUS APS PEC
--
-- ALTER SYSTEM grava em postgresql.auto.conf, que tem prioridade sobre o postgresql.conf.
-- Guarde uma cópia do postgresql.auto.conf antes. Todos estes parâmetros valem com reload,
-- sem reiniciar o banco. Se houver réplica, aplique nela também.

-- Valores atuais
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN ('join_collapse_limit', 'from_collapse_limit', 'geqo_threshold',
               'idle_in_transaction_session_timeout', 'log_min_duration_statement',
               'log_lock_waits', 'log_temp_files');


-- ---------------------------------------------------------------------------
-- 1. Planejador: consultas com muitos joins
--
-- As consultas de histórico do cidadão geradas pelo PEC juntam 9 ou 10 tabelas, e a
-- tabela com o filtro mais seletivo (co_cidadao = ?) vem por último. Com o padrão
-- join_collapse_limit = 8, o PostgreSQL não reordena os joins: lia 4,37 milhões de
-- linhas para devolver 1.
--
-- Base de referência (PEC 5.5.27): custo do plano de 769.200 para 15, CPU do banco
-- de 100% para cerca de 19%, consultas lentas simultâneas de ~45 para 0–1.
--
-- Efeito colateral: o planejamento de consultas com muitos joins fica um pouco mais
-- caro. Acompanhe o tempo médio no pg_stat_statements depois de aplicar.
-- ---------------------------------------------------------------------------
ALTER SYSTEM SET join_collapse_limit = 16;
ALTER SYSTEM SET from_collapse_limit = 16;
ALTER SYSTEM SET geqo_threshold = 20;


-- ---------------------------------------------------------------------------
-- 2. Operação
-- ---------------------------------------------------------------------------

-- Encerra sessões paradas dentro de uma transação. Elas seguram locks e impedem o
-- vacuum. Na base de referência chegaram a 55 sessões; com 30 min, nenhum efeito
-- colateral foi observado no PEC.
ALTER SYSTEM SET idle_in_transaction_session_timeout = '30min';

-- Registra no log do PostgreSQL o que vale investigar
ALTER SYSTEM SET log_min_duration_statement = '10s';
ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM SET log_temp_files = '10MB';

SELECT pg_reload_conf();


-- ---------------------------------------------------------------------------
-- O que NÃO fazer
--
-- Aumentar max_connections não resolve "too many clients" quando a causa são cópias
-- de uma consulta lenta (sql/01-diagnostico.sql, consulta 3): só adia o problema e
-- aumenta o risco de falta de memória. No Windows, muitas conexões também esgotam o
-- desktop heap. Corrija a consulta lenta.
-- ---------------------------------------------------------------------------

-- Para reverter:
-- ALTER SYSTEM RESET join_collapse_limit;   -- e assim para cada parâmetro
-- SELECT pg_reload_conf();
