-- =====================================================================
-- 112 · Conciliação do Mercado Pago: classificação automática do que tem destino certo
--  Linhas do extrato que não dependem de venda/título passam a ser classificadas sozinhas
--  (situação "classificado", com a observação "Automático (112)"; dá para desfazer pela tela):
--   · Taxa de antecipação (fee-release_in_advance)        → 7.03.001 Taxas de antecipação ML
--   · Frete do ML sem venda ligada (shipping)              → 4.01.003 Créditos de frete - plataformas
--   · Cashback do ML sem venda ligada (cashback)           → 1.02.001 Reembolsos e ressarcimentos de marketplace
--   · Venda cancelada/devolvida já encerrada: pedido cancelado, sem título a receber em aberto,
--     sem movimento há 15 dias e resultado ≤ 0 (o ML tirou o dinheiro)  → 2.03.001 Estorno de vendas
--  Fica pendente (precisa de alguém): venda cancelada em que o dinheiro ficou na conta (falta receita),
--  disputas recentes, saques sem conta padrão, retenção para dívida e recebimentos sem venda.
--  Roda junto com a compensação a cada importação do extrato e uma vez agora.
-- =====================================================================
create or replace function public.extrato_classificar_auto(p_conta bigint default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; k int;
begin
  if auth.uid() is not null and not (select public.pode('conciliacao', 'alterar')) then raise exception 'Sem permissão'; end if;
  -- tarifas e créditos avulsos do ML
  update public.extrato_lancamentos l
     set conciliacao = 'classificado', conciliado_em = now(), conciliado_por = auth.uid(),
         categoria_financeira_id = (select id from public.categorias_financeiras where codigo =
           case l.tipo when 'fee-release_in_advance' then '7.03.001' when 'shipping' then '4.01.003' else '1.02.001' end),
         observacoes = coalesce(l.observacoes || ' · ', '') || 'Automático (112): ' ||
           case l.tipo when 'fee-release_in_advance' then 'taxa de antecipação do ML' when 'shipping' then 'frete do ML sem venda ligada' else 'cashback do ML' end
   where l.conciliacao = 'pendente' and (p_conta is null or l.conta_bancaria_id = p_conta)
     and (l.tipo = 'fee-release_in_advance' or (l.tipo in ('shipping', 'cashback') and l.pedido_venda_id is null));
  get diagnostics k = row_count; n := n + k;
  -- venda cancelada/devolvida encerrada com perda: o que sobrou na operação vira estorno de venda
  with g as (
    select e.pedido_venda_id pv, e.conta_bancaria_id c, sum(e.valor) liq
      from public.extrato_lancamentos e join public.pedidos_venda p on p.id = e.pedido_venda_id
     where e.conciliacao = 'pendente' and p.situacao = 'cancelado' and (p_conta is null or e.conta_bancaria_id = p_conta)
       and not exists (select 1 from public.titulos_receber t where t.pedido_venda_id = e.pedido_venda_id and t.situacao in ('aberto', 'parcial'))
       and not exists (select 1 from public.extrato_lancamentos x where x.pedido_venda_id = e.pedido_venda_id and x.data > current_date - 15)
     group by 1, 2 having sum(e.valor) <= 0.004)
  update public.extrato_lancamentos l
     set conciliacao = 'classificado', conciliado_em = now(), conciliado_por = auth.uid(),
         categoria_financeira_id = (select id from public.categorias_financeiras where codigo = '2.03.001'),
         observacoes = coalesce(l.observacoes || ' · ', '') || 'Automático (112): venda cancelada/devolvida, resultado da venda R$ ' || to_char(g.liq, 'FM999G999G990D00')
    from g where l.pedido_venda_id = g.pv and l.conta_bancaria_id = g.c and l.conciliacao = 'pendente';
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;
revoke execute on function public.extrato_classificar_auto(bigint) from public, anon;
grant execute on function public.extrato_classificar_auto(bigint) to authenticated, service_role;

-- liga na rotina que roda a cada importação (depois de compensar, antes dos saques automáticos)
create or replace function public.extrato_compensar(p_conta bigint default null)
returns integer language plpgsql security definer set search_path = public as $$
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
  n := n + public.extrato_compensar_pares(p_conta);      -- débito e crédito do mesmo valor na mesma operação (111)
  n := n + public.extrato_classificar_auto(p_conta);     -- tarifas, frete, cashback e vendas canceladas encerradas (112)
  perform public.transferencias_automaticas();           -- saques com conta de destino padrão + confronto das entradas
  return n;
end $$;
revoke execute on function public.extrato_compensar(bigint) from public, anon, authenticated;
grant execute on function public.extrato_compensar(bigint) to service_role;

-- aplica agora nas contas do Mercado Pago
do $$ declare c record; begin
  for c in select id from public.contas_bancarias where tipo = 'pagamentos' and situacao = 'ativo' loop
    perform public.extrato_compensar(c.id);
  end loop;
end $$;

-- resultado: pendentes por conta e quanto foi classificado agora
select c.descricao conta,
       (select count(*) from public.extrato_lancamentos x where x.conta_bancaria_id = c.id and x.conciliacao = 'pendente') pendentes_agora,
       (select count(*) from public.extrato_lancamentos x where x.conta_bancaria_id = c.id and x.conciliacao = 'classificado' and x.observacoes like '%Automático (112)%') classificadas_auto
  from public.contas_bancarias c where c.tipo = 'pagamentos' and c.situacao = 'ativo' order by c.id;
