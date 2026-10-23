-- =====================================================================
-- 036 · Extrato do Mercado Pago pela API
-- O relatório do MP traz o ID do pagamento (SOURCE_ID). Aqui cada linha é
-- ligada à venda do ML que tem esse pagamento (mesma empresa da conta),
-- preenchendo o nº da venda — a conciliação automática faz o resto.
-- =====================================================================
create index if not exists ml_brutos_pagamentos_idx on public.ml_pedidos_brutos using gin (pagamentos jsonb_path_ops);

create or replace function public.extrato_ligar_pagamentos_ml(p_conta bigint)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with pg as (
    select (e->>'id') pid, b.ml_order_id, b.canal_id
    from public.ml_pedidos_brutos b cross join jsonb_array_elements(b.pagamentos) e
    join public.canais_venda c on c.id = b.canal_id
    where c.empresa_id = (select empresa_id from public.contas_bancarias where id = p_conta))
  update public.extrato_lancamentos l
     set pedido_externo = coalesce(l.pedido_externo, pg.ml_order_id::text),
         pedido_venda_id = coalesce(l.pedido_venda_id, (select p.id from public.pedidos_venda p where p.canal_id = pg.canal_id and p.numero_externo = pg.ml_order_id::text limit 1))
    from pg
   where l.conta_bancaria_id = p_conta and l.id_operacao = pg.pid and l.conciliacao = 'pendente'
     and (l.pedido_externo is null or l.pedido_venda_id is null);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.extrato_ligar_pagamentos_ml(bigint) from public, anon;
grant execute on function public.extrato_ligar_pagamentos_ml(bigint) to service_role, authenticated;
