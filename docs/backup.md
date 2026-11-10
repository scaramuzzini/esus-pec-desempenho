# Backup sem derrubar o ETL do PEC

## O problema

Um `pg_dump` noturno do banco principal pode derrubar a rodada de processamento do PEC.

- O `pg_dump` mantém um `AccessShareLock` em cada tabela durante todo o backup. Numa base de cerca de 1,4 TB, com `-F c`, isso levou **cerca de 8 horas**, com a CPU presa a um núcleo só por causa da compressão.
- Durante a rodada, o ETL do PEC executa `TRUNCATE tb_etl_auxiliar_number`. O `TRUNCATE` precisa de `AccessExclusiveLock` e fica esperando o dump terminar.
- Resultado: o ETL para, a rodada não conclui e a fila de fichas não baixa.

Para confirmar, rode a consulta 6 de [sql/01-diagnostico.sql](../sql/01-diagnostico.sql) enquanto o backup roda. O `TRUNCATE` aparece bloqueado pelo `pg_dump`.

## Opções

| Opção | Como | Situação |
|---|---|---|
| **Dump a partir da réplica** | Rodar o `pg_dump` contra a réplica streaming. O primário fica livre. | Recomendado. Ajuste `max_standby_streaming_delay` ou `hot_standby_feedback` para o dump não ser cancelado por conflito de replicação. |
| **Excluir a tabela auxiliar** | `pg_dump -T tb_etl_auxiliar_number` | **Não testado.** A tabela é temporária por natureza, mas confirme que o restore funciona sem os dados dela. O schema continua no dump; `-T` exclui também a definição, por isso guarde o schema dela com `pg_dump -s -t tb_etl_auxiliar_number`. |
| **Dump paralelo e com pouca compressão** | `pg_dump -F d -j 4 -Z 1` | Testado: gravou 35 GB em 12 minutos, cerca de **9 vezes mais rápido** que `-F c`. Mas **também bloqueou o ETL** enquanto rodava. Reduz a janela, não elimina o conflito. Com 4 jobs, o disco do servidor saturou. |
| **Backup físico** | `pg_basebackup` ou ferramenta como pgBackRest | Não depende de locks de tabela. Exige mais espaço e um processo de restauração diferente. |

## Recomendação

1. Faça o dump na réplica, com `-F d -j N -Z 1`. Escolha o N pela capacidade do disco.
2. Teste a restauração de verdade, numa máquina separada, pelo menos uma vez.
3. Acompanhe a rodada do PEC na noite seguinte (consultas 8 e 9 de [sql/01-diagnostico.sql](../sql/01-diagnostico.sql)).
