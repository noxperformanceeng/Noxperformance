-- =====================================================================
-- 110 · Extrato do Mercado Pago: fim das linhas duplicadas que travavam a conciliação
--  · Causa: o relatório diário do MP cobre os últimos 3 dias e o saldo de cada linha recomeça do zero
--    em cada relatório. Como o saldo fazia parte da "identidade" da linha, a mesma movimentação entrava
--    de novo a cada relatório que se sobrepunha (venda já baixada voltava como pendente, operações
--    deixavam de somar zero e não compensavam).
--  · Aqui: apaga as cópias (fica a que já foi conciliada/compensada), devolve para "pendente" as linhas
--    de compensações que tinham cópia no meio, regrava a identidade sem o saldo (mesma regra da
--    importação automática nova) e roda de novo compensação + baixa das vendas nas duas contas MP.
--  · Movimentos repetidos de verdade dentro do mesmo relatório são mantidos (numerados #1, #2…).
-- =====================================================================
begin;

-- identidade da linha sem o saldo (igual à função mp-extrato)
create temp table _mp on commit drop as
select id, conta_bancaria_id c, arquivo, conciliacao, grupo_compensacao g,
       concat_ws('|', coalesce(nullif(linha_original->>'DATE', ''), linha_original->>'TRANSACTION_APPROVAL_DATE', ''),
                 coalesce(linha_original->>'SOURCE_ID', ''), coalesce(linha_original->>'DESCRIPTION', ''),
                 valor::text, coalesce(linha_original->>'GROSS_AMOUNT', '')) chave
  from public.extrato_lancamentos
 where hash like 'mpapi:%' or hash like 'mp2:%';

-- quantas vezes a linha existe de verdade = o máximo que aparece num mesmo arquivo; o resto é cópia
create temp table _copias on commit drop as
with mx as (select c, chave, max(n) manter from (select c, chave, arquivo, count(*) n from _mp group by 1, 2, 3) s group by 1, 2),
     r as (select m.*, mx.manter, row_number() over (partition by m.c, m.chave order by (m.conciliacao = 'pendente'), m.id) rn
             from _mp m join mx using (c, chave))
select id, g from r
 where rn > manter
   and not exists (select 1 from public.transferencias_contas t where t.extrato_saida_id = r.id or t.extrato_entrada_id = r.id)
   and not exists (select 1 from public.extrato_lancamentos l where l.id = r.id and (l.recebimento_id is not null or l.pagamento_id is not null));

-- compensações que tinham cópia no meio deixam de fechar: as linhas que ficam voltam para pendente
update public.extrato_lancamentos l
   set conciliacao = 'pendente', grupo_compensacao = null, conciliado_em = null, conciliado_por = null,
       observacoes = coalesce(l.observacoes || ' · ', '') || 'Compensação refeita (110: linha duplicada removida do grupo)'
 where l.grupo_compensacao in (select g from _copias where g is not null)
   and l.id not in (select id from _copias)
   and l.conciliacao = 'compensado';

delete from public.extrato_lancamentos where id in (select id from _copias);

-- nova identidade (sem saldo), numerando repetições reais (passa por um valor provisório para não esbarrar no índice único)
update public.extrato_lancamentos set hash = 'tmp110:' || id where id in (select id from _mp) and id not in (select id from _copias);
update public.extrato_lancamentos l
   set hash = 'mp2:' || x.chave || '#' || x.n
  from (select id, chave, row_number() over (partition by c, chave order by id) n from _mp where id not in (select id from _copias)) x
 where l.id = x.id;

-- roda de novo: liga às vendas, compensa (operações que somam zero, pares bloqueio/desbloqueio) e baixa as vendas liberadas
select public.extrato_ligar_pagamentos_ml(id) from public.contas_bancarias where tipo = 'pagamentos' and situacao = 'ativo';
select public.cr_baixar_extrato_mp(id) from public.contas_bancarias where tipo = 'pagamentos' and situacao = 'ativo';

commit;

-- resultado esperado: 0 cópias restantes e a contagem de pendentes por conta (bem menor que antes)
select c.descricao conta,
       (select count(*) from (select 1 from public.extrato_lancamentos x where x.conta_bancaria_id = c.id and x.hash like 'mp%'
                               group by x.hash having count(*) > 1) d) hashes_repetidos,
       (select count(*) from public.extrato_lancamentos x where x.conta_bancaria_id = c.id and x.hash like 'mpapi:%') identidade_antiga,
       (select count(*) from public.extrato_lancamentos x where x.conta_bancaria_id = c.id and x.conciliacao = 'pendente') pendentes
  from public.contas_bancarias c where c.tipo = 'pagamentos' and c.situacao = 'ativo' order by c.id;
