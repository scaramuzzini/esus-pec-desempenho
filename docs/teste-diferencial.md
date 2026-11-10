# Teste diferencial: provar que a consulta reescrita é equivalente

Uma consulta mais rápida só serve se devolver **exatamente** o mesmo resultado. O teste diferencial roda a consulta original e a reescrita sobre muitas entradas reais e compara as saídas.

## Onde rodar

**Na réplica**, nunca no primário. Ali dá para rodar a consulta original lenta milhares de vezes sem afetar os usuários. Se não houver réplica, use uma cópia restaurada do backup.

## Como montar

1. **Amostra de entradas.** Sorteie entradas reais da própria base, como documentos de responsáveis: `ORDER BY random() LIMIT 2000`. Some a elas os **casos de borda**, escolhidos à mão:
   - responsável só com CPF, só com CNS, com os dois;
   - documento que não existe;
   - dois cidadãos com o mesmo documento;
   - valores nulos e vazios.
2. **Rode as duas versões** para cada entrada e guarde o resultado como conjunto de chaves primárias ordenadas, ou como hash:
   ```sql
   SELECT md5(string_agg(co_seq_familia::text, ',' ORDER BY co_seq_familia))
   FROM ( /* consulta */ ) r;
   ```
3. **Compare.** Qualquer entrada com hash diferente é uma divergência. Investigue antes de seguir.
4. **Registre** só contagens: amostras, divergências, total de linhas comparadas.

## O que reportar

Na base de referência, por exemplo:

| Consulta | Amostras | Divergências | Linhas comparadas |
|---|---|---|---|
| Núcleo familiar | 2.163 | 0 | 4.125 |
| Família | 2.409 | 0 | 6.242 |

## Cuidados com dados pessoais

As entradas de teste são CPFs e CNSs reais. **Não guarde a amostra em arquivo**, não cole saídas com documentos em chamados, e-mails ou issues, e apague as tabelas temporárias no fim.
