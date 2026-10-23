-- =====================================================================
-- 034 · Etapas do pedido do Mercado Livre (envio e entrega)
-- O envio (shipment) passa a ser guardado junto da venda e a etapa do
-- pedido acompanha: pago → pronto para envio → enviado → entregue
-- (ou não entregue / devolvido / cancelado). Datas de envio e entrega
-- e a logística (Full, Flex, coleta, agência) vêm do próprio ML.
-- =====================================================================
alter table public.ml_pedidos_brutos add column if not exists envio jsonb;
alter table public.pedidos_venda add column if not exists etapa text
  check (etapa in ('aguardando_pagamento','pago','pronto_envio','enviado','entregue','nao_entregue','devolvido','cancelado'));
alter table public.pedidos_venda add column if not exists etapa_em timestamptz;
alter table public.pedidos_venda add column if not exists etapa_detalhe text;

create or replace function public.ml_atualizar_etapa(p_ml_order_id bigint)
returns text language plpgsql security definer set search_path = public as $$
declare b record; o jsonb; e jsonb; v_etapa text; v_det text; v_em timestamptz; v_log text; v_env date; v_ent date;
begin
  select * into b from public.ml_pedidos_brutos where ml_order_id = p_ml_order_id;
  if not found then return null; end if;
  o := b.ordem; e := b.envio;
  v_det := nullif(concat_ws(' / ', e->>'status', e->>'substatus'), '');
  v_etapa := case
    when o->>'status' = 'cancelled' then 'cancelado'
    when e->>'status' = 'delivered' then 'entregue'
    when e->>'status' = 'not_delivered' and coalesce(e->>'substatus','') ~ 'return' then 'devolvido'
    when e->>'status' = 'not_delivered' then 'nao_entregue'
    when e->>'status' = 'shipped' then 'enviado'
    when e->>'status' in ('ready_to_ship','handling') then 'pronto_envio'
    when o->>'status' in ('paid','partially_paid','partially_refunded') then 'pago'
    else 'aguardando_pagamento' end;
  if coalesce(o->'tags', '[]'::jsonb) ? 'returned' or coalesce(e->>'substatus','') in ('returned','returning_to_sender') then v_etapa := 'devolvido'; end if;
  v_env := nullif(coalesce(e->'status_history'->>'date_shipped', e->>'date_shipped'), '')::timestamptz at time zone 'America/Sao_Paulo';
  v_ent := nullif(coalesce(e->'status_history'->>'date_delivered', e->>'date_delivered'), '')::timestamptz at time zone 'America/Sao_Paulo';
  v_em := coalesce(nullif(e->>'last_updated','')::timestamptz, nullif(o->>'last_updated','')::timestamptz, now());
  v_log := case coalesce(e->'logistic'->>'type', e->>'logistic_type', b.envio_custos->>'logistic_type')
    when 'fulfillment' then 'full' when 'self_service' then 'flex' when 'cross_docking' then 'coleta'
    when 'xd_drop_off' then 'agencia' when 'drop_off' then 'correios' else null end;
  update public.pedidos_venda p set
      etapa = v_etapa, etapa_detalhe = v_det,
      etapa_em = case when p.etapa is distinct from v_etapa then v_em else coalesce(p.etapa_em, v_em) end,
      data_envio = coalesce(v_env, p.data_envio), data_entrega = coalesce(v_ent, p.data_entrega),
      logistica = coalesce(v_log, p.logistica),
      codigo_rastreio = coalesce(nullif(e->>'tracking_number',''), p.codigo_rastreio)
   where p.canal_id = b.canal_id and p.numero_externo = b.ml_order_id::text;
  return v_etapa;
end $$;
revoke execute on function public.ml_atualizar_etapa(bigint) from public, anon, authenticated;
grant execute on function public.ml_atualizar_etapa(bigint) to service_role;

-- Já guardadas: etapa pelo que existe hoje (status da venda); o envio completo vem na próxima leitura
select public.ml_atualizar_etapa(ml_order_id) from public.ml_pedidos_brutos;
