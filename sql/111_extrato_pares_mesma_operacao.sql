-- =====================================================================
-- 111 · Conciliação do Mercado Pago: débito e crédito do mesmo valor na mesma venda se anulam
--  · Até aqui só se anulavam bloqueio/desbloqueio (reserva) e mediação aberta/cancelada.
--    Agora qualquer saída −X e entrada +X da MESMA operação do MP é marcada como "compensada":
--    mediação −X com reembolso +X, bloqueio −X com mediação/liberação +X, pagamento +X devolvido −X…
--  · O que sobra na operação é o efeito real no saldo (ex.: o custo da devolução) e continua pendente.
--  · Fora da regra: saques (payout) e o recebimento de venda que ainda tem título a receber em aberto
--    (esse continua indo para a baixa do título).
--  · Roda sozinha a cada importação do extrato (junto da compensação que já existia) e uma vez agora.
-- =====================================================================
create or replace function public.extrato_compensar_pares(p_conta bigint default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is not null and not (select public.pode('conciliacao', 'alterar')) then raise exception 'Sem permissão'; end if;
  with base as (
    select l.id, l.conta_bancaria_id c, l.id_operacao op, abs(l.valor) v, sign(l.valor) s, l.data
      from public.extrato_lancamentos l
     where l.conciliacao = 'pendente' and l.id_operacao is not null and l.valor <> 0 and l.tipo is distinct from 'payout'
       and (p_conta is null or l.conta_bancaria_id = p_conta)
       and not (l.tipo = 'payment' and l.valor > 0 and l.pedido_venda_id is not null
                and exists (select 1 from public.titulos_receber t where t.pedido_venda_id = l.pedido_venda_id and t.situacao in ('aberto', 'parcial')))),
  num as (select *, row_number() over (partition by c, op, v, s order by data, id) rn from base),
  par as (select a.id ida, b.id idb, gen_random_uuid() gid from num a join num b
            on b.c = a.c and b.op = a.op and b.v = a.v and b.rn = a.rn and a.s > 0 and b.s < 0),
  u as (update public.extrato_lancamentos l set conciliacao = 'compensado', grupo_compensacao = par.gid, conciliado_em = now(), conciliado_por = auth.uid(),
          observacoes = coalesce(l.observacoes || ' · ', '') || 'Compensado: saída e entrada do mesmo valor na mesma operação do Mercado Pago (sem efeito no saldo)'
        from par where l.id in (par.ida, par.idb) and l.conciliacao = 'pendente' returning 1)
  select count(*) into n from u;
  return n;
end $$;
revoke execute on function public.extrato_compensar_pares(bigint) from public, anon;
grant execute on function public.extrato_compensar_pares(bigint) to authenticated, service_role;

-- aplica agora nas contas do Mercado Pago (a compensação geral também lança os saques com conta padrão)
do $$ declare c record; begin
  for c in select id from public.contas_bancarias where tipo = 'pagamentos' and situacao = 'ativo' loop
    perform public.extrato_compensar(c.id);
  end loop;
end $$;

-- resultado: pendentes por conta depois da regra nova
select c.descricao conta,
       (select count(*) from public.extrato_lancamentos x where x.conta_bancaria_id = c.id and x.conciliacao = 'pendente') pendentes_agora,
       (select count(*) from public.extrato_lancamentos x where x.conta_bancaria_id = c.id and x.conciliado_em > now() - interval '5 minutes' and x.conciliacao = 'compensado') compensadas_agora
  from public.contas_bancarias c where c.tipo = 'pagamentos' and c.situacao = 'ativo' order by c.id;
