-- =====================================================================
-- 050 · Fluxo de caixa e extrato
--  · Conta sem data de saldo de abertura não acumula o histórico antigo (o saldo inicial ficava -10 milhões)
--  · Projeção de pedido de compra aparece como 'prev_pag_pc' (destacada no fluxo)
--  · extrato_compensar(): linhas da mesma operação que somam zero → "compensado" (roda junto da baixa automática do MP)
-- =====================================================================
do $$ declare d text; begin
  d := pg_get_functiondef('public.fluxo_caixa(date,date,integer,bigint)'::regprocedure);
  d := replace(d, '(c.data_saldo_inicial is null or tu.d >= c.data_saldo_inicial)', '(c.data_saldo_inicial is not null and tu.d >= c.data_saldo_inicial)');
  d := replace(d, 'select coalesce(sum(c.saldo_inicial), 0) from cb c)', 'select coalesce(sum(c.saldo_inicial), 0) from cb c where c.data_saldo_inicial is not null)');
  d := replace(d, '''prev_pag'' o, t.id ref', 'case when t.pedido_compra_id is not null and t.projecao then ''prev_pag_pc'' else ''prev_pag'' end o, t.id ref');
  execute d;
end $$;

create or replace function public.extrato_compensar(p_conta bigint default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with op as (
    select conta_bancaria_id c, id_operacao from public.extrato_lancamentos
     where conciliacao = 'pendente' and id_operacao is not null and (p_conta is null or conta_bancaria_id = p_conta)
     group by 1, 2 having count(*) > 1 and abs(sum(valor)) < 0.005 and bool_or(valor > 0) and bool_or(valor < 0)),
  g as (select c, id_operacao, gen_random_uuid() gid from op),
  u as (update public.extrato_lancamentos l set conciliacao = 'compensado', grupo_compensacao = g.gid, conciliado_em = now(), conciliado_por = auth.uid(),
          observacoes = coalesce(l.observacoes || ' · ', '') || 'Compensado: linhas da mesma operação somam zero (disputa/reserva/estorno do ML)'
        from g where l.conta_bancaria_id = g.c and l.id_operacao = g.id_operacao and l.conciliacao = 'pendente' returning 1)
  select count(*) into n from u;
  return n;
end $$;
revoke execute on function public.extrato_compensar(bigint) from public, anon, authenticated;
grant execute on function public.extrato_compensar(bigint) to service_role;

do $$ declare d text; begin
  d := pg_get_functiondef('public.cr_baixar_extrato_mp(bigint)'::regprocedure);
  d := replace(d, 'perform set_config(''nox.baixa_extrato'', ''sim'', true);', 'perform set_config(''nox.baixa_extrato'', ''sim'', true);
  perform public.extrato_compensar(p_conta);');
  execute d;
end $$;
-- (aplicado uma vez manualmente em 23/10: 3.353 linhas / 449 operações compensadas)
