-- =====================================================================
-- 069 · Extrato do Mercado Pago: anula bloqueio + desbloqueio do mesmo valor
--  · Dentro da mesma operação, o Mercado Pago bloqueia e desbloqueia o dinheiro várias vezes
--    (reserva de disputa, de saque, de devolução…). Cada par "−X / +X" não muda o saldo:
--    agora é marcado como "compensado" automaticamente (com a explicação na linha).
--  · Mediação aberta e depois cancelada (−X / +X) também se anula.
--  · Roda junto com a compensação que já existia (operações que somam zero).
-- =====================================================================
create or replace function public.extrato_compensar_pares(p_conta bigint default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is not null and not (select public.pode('conciliacao', 'alterar')) then raise exception 'Sem permissão'; end if;
  with base as (
    select id, conta_bancaria_id c, id_operacao op, abs(valor) v, sign(valor) s,
           case when tipo like 'reserve%' then 'reserva' when tipo in ('mediation','mediation_cancel') then 'mediacao' end fam
      from public.extrato_lancamentos
     where conciliacao = 'pendente' and id_operacao is not null and valor <> 0
       and (tipo like 'reserve%' or tipo in ('mediation','mediation_cancel'))
       and (p_conta is null or conta_bancaria_id = p_conta)),
  num as (select *, row_number() over (partition by c, op, fam, v, s order by id) rn from base),
  par as (select a.id ida, b.id idb, gen_random_uuid() gid from num a join num b
            on b.c = a.c and b.op = a.op and b.fam = a.fam and b.v = a.v and b.rn = a.rn and a.s > 0 and b.s < 0),
  u as (update public.extrato_lancamentos l set conciliacao = 'compensado', grupo_compensacao = par.gid, conciliado_em = now(), conciliado_por = auth.uid(),
          observacoes = coalesce(l.observacoes || ' · ', '') || case when l.tipo like 'reserve%' then 'Compensado: bloqueio e desbloqueio do mesmo valor na mesma operação (reserva do Mercado Pago, sem efeito no saldo)'
                                                                  else 'Compensado: mediação aberta e cancelada (sem efeito no saldo)' end
        from par where l.id in (par.ida, par.idb) and l.conciliacao = 'pendente' returning 1)
  select count(*) into n from u;
  return n;
end $$;
revoke execute on function public.extrato_compensar_pares(bigint) from public, anon;
grant execute on function public.extrato_compensar_pares(bigint) to authenticated;

do $$ declare d text; begin
  d := pg_get_functiondef('public.extrato_compensar(bigint)'::regprocedure);
  if position('extrato_compensar_pares' in d) = 0 then
    d := replace(d, $x$  select count(*) into n from u;
  return n;$x$, $x$  select count(*) into n from u;
  n := n + public.extrato_compensar_pares(p_conta);   -- bloqueios/desbloqueios iguais dentro da operação
  return n;$x$);
    if position('extrato_compensar_pares' in d) = 0 then raise exception 'extrato_compensar mudou'; end if;
    execute d;
  end if;
end $$;
