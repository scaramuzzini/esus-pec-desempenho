# esus-pec-desempenho

> **English:** Performance fixes for the PostgreSQL database behind Brazil's e-SUS APS PEC (the Ministry of Health's primary-care EHR). The repo has five indexes, planner settings, diagnostic queries and write-ups of three SQL defects. All of it was measured in production on a large municipality. The documentation is in Portuguese.

Índices, configurações do PostgreSQL e consultas de diagnóstico para o **e-SUS APS PEC** quando ele fica lento em bases grandes. Tudo foi medido em produção, num município de grande porte.

Três defeitos de SQL que só se corrigem dentro do PEC estão descritos em [docs/defeitos-sql.md](docs/defeitos-sql.md). Eles foram reportados ao suporte do e-SUS APS.

## Condições do teste

| | |
|---|---|
| PEC | **5.6.1** (índices e defeitos) e **5.5.27** (configuração do planejador) |
| Banco | PostgreSQL 15, com réplica streaming |
| Servidor do banco | Windows Server, 64 GB de RAM, 36 vCPU, disco único |
| Tamanho da base | cerca de 1,4 TB (cerca de 970 GB de tabelas e 450 GB de índices) |
| Volume | mais de 3 milhões de cidadãos cadastrados, cerca de 1.000 usuários simultâneos, centenas de tablets do e-SUS Território |

Em bases menores, o ganho tende a ser menor. **Meça antes de aplicar** (veja [Como medir](#como-medir)).

## Resultados

| # | O que | Tipo | Antes | Depois |
|---|---|---|---|---|
| 1 | Consultas de histórico do cidadão com 9–10 joins | configuração ([sql/04-configuracao.sql](sql/04-configuracao.sql)) | CPU do banco em 100%, custo do plano 769.200 | CPU em cerca de 19%, custo 15 |
| 2 | Envio pendente para a RNDS (`tb_envio_rnds`) | índice | 2–13 min | 0,2 ms |
| 3 | Cadastro individual com erro de inativação (`tb_cds_cad_individual`) | índice | 23–70 s | 0,09 ms |
| 4 | Cidadão pela última ficha (`tb_cidadao.co_unico_ultima_ficha`), a cada FCI processada | índice parcial | cerca de 1 s, 3,5 GB lidos | menos de 0,1 ms |
| 5 | Busca de cidadão pelo nome da mãe (`LIKE '%…%'`) | índice GIN trigram **e** btree (os dois juntos, veja abaixo) | cerca de 3,1 s | cerca de 40 ms |
| 6 | Núcleo familiar e família por CPF/CNS do responsável | **defeito no SQL do PEC** ([relato](docs/defeitos-sql.md#1-e-2-núcleo-familiar-e-família-por-cpfcns-do-responsável)) | 9–24 min, "too many clients" | 0,5–0,6 ms com a correção |
| 7 | ETL "Cidadãos vinculados" | **defeito no SQL do PEC** ([relato](docs/defeitos-sql.md#3-etl-cidadãos-vinculados)) | 44–65 h, fila de fichas parada | 4 min com a correção |

**O índice da RNDS (item 2) aponta um provável erro do próprio PEC.** O índice `in_envrnds_necenvio_coseq`, apesar do nome, não inclui a coluna `st_necessita_envio`. Confira na sua base:

```sql
SELECT indexdef FROM pg_indexes WHERE indexname = 'in_envrnds_necenvio_coseq';
```

**O índice do nome da mãe (item 5) não pode ir sozinho.** Só com o GIN, a exportação de "possíveis duplicatas" (Unificação de prontuários) passa a usá-lo para comparar nomes exatos, a cerca de 0,4 s por cadastro. Na base testada ela rodou mais de 2 horas sem terminar. Com um btree na mesma coluna, terminou em cerca de 2,5 minutos. Os dois estão em [sql/02-indices.sql](sql/02-indices.sql).

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| [sql/01-diagnostico.sql](sql/01-diagnostico.sql) | Consultas mais caras, sessões longas, bloqueios, `idle in transaction`, fila de fichas e etapas da rodada noturna |
| [sql/02-indices.sql](sql/02-indices.sql) | Os 5 índices, cada um com a consulta que ele atende e uma verificação prévia |
| [sql/03-reverter-indices.sql](sql/03-reverter-indices.sql) | Remove os índices |
| [sql/04-configuracao.sql](sql/04-configuracao.sql) | Parâmetros do planejador e de operação |
| [docs/defeitos-sql.md](docs/defeitos-sql.md) | Os 3 defeitos de SQL do PEC: sintoma, causa, plano e correção proposta |
| [docs/backup.md](docs/backup.md) | Por que o `pg_dump` noturno derruba o ETL do PEC e como evitar |
| [docs/teste-diferencial.md](docs/teste-diferencial.md) | Como provar que uma consulta reescrita devolve o mesmo resultado |

## Como medir

1. Ative o `pg_stat_statements` se ainda não estiver ativo (exige reinício do PostgreSQL).
2. Rode as consultas de [sql/01-diagnostico.sql](sql/01-diagnostico.sql) num horário de uso normal e guarde o resultado.
3. Para cada índice de [sql/02-indices.sql](sql/02-indices.sql), rode antes a verificação que vem com ele. Só crie o índice se a consulta-alvo aparecer entre as mais caras.
4. Depois de criar, faça `pg_stat_statements_reset()` e compare de novo após algumas horas.

## Cuidados

- **Teste antes numa réplica ou base de homologação.** Faça backup.
- Os índices usam `CREATE INDEX CONCURRENTLY`. Isso não bloqueia o PEC, mas não pode rodar dentro de uma transação, e por isso o `psql` precisa estar em autocommit.
- Todo índice novo deixa a escrita um pouco mais lenta e ocupa disco (de 67 MB a 544 MB, na base testada).
- **Atualização do PEC:** os índices têm o sufixo `_perf` e não colidem com nomes do PEC. Mesmo assim, antes de atualizar, confira nas notas da versão se o PEC passou a criar índice equivalente. Se passou, remova o seu com [sql/03-reverter-indices.sql](sql/03-reverter-indices.sql).
- Este projeto **não é oficial** e não tem relação com o Ministério da Saúde nem com o Laboratório Bridge/UFSC. O uso é por sua conta e risco.

## Contribua

Se você aplicou algo daqui no seu município, abra uma issue com a versão do PEC, o tamanho da base e o antes e depois. Relatos de outros ambientes, inclusive os de "não fez diferença", ajudam a calibrar as recomendações.

## Licença

- **Código SQL (`sql/`):** [Apache License 2.0](LICENSE). Quem redistribuir deve manter o arquivo [NOTICE](NOTICE).
- **Documentação (este README e `docs/`):** [Creative Commons Atribuição 4.0](LICENSE-CC-BY-4.0). Você pode copiar e adaptar, desde que cite a autoria e o link deste repositório.

Para citar, use o botão "Cite this repository" do GitHub ou o arquivo [CITATION.cff](CITATION.cff).
