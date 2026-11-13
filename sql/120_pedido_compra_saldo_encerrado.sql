-- =====================================================================
-- 120 · Pedido de compra: entrega parcial e saldo encerrado por item
--  · Já funcionava: pedido de 10 com entrega de 6 fica "Entregue parcial", os 4 seguem em aberto
--    (contas a pagar como projeção, sugestão de compra) e a próxima NF recebe o saldo.
--  · O que muda: ao "Encerrar saldo" (o fornecedor não vai entregar o resto), cada item guarda
--    quanto foi cancelado (ex.: 6 recebidos · 4 cancelados), e o pedido guarda quem encerrou,
--    quando e o motivo — antes ficava só "Recebido", como se tivesse chegado tudo.
--  · Nada muda nos pedidos que já existem (nenhum está entregue parcial hoje).
-- =====================================================================
alter table public.pedidos_compra_itens add column if not exists quantidade_cancelada numeric(14,4) not null default 0;
alter table public.pedidos_compra add column if not exists saldo_encerrado_em timestamptz;
alter table public.pedidos_compra add column if not exists saldo_encerrado_por uuid;
alter table public.pedidos_compra add column if not exists motivo_encerramento text;

-- Encerrar saldo: o que falta de cada item vira "cancelado"; pedido fecha como recebido; projeção sai do contas a pagar
create or replace function public.pedido_compra_encerrar(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_lista text;
begin
  if not public.pode('compras', 'alterar') then raise exception 'Sem permissão'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo'; end if;
  perform 1 from public.pedidos_compra where id = p_id and situacao = 'recebido_parcial' for update;
  if not found then raise exception 'Só pedido entregue parcialmente pode ter o saldo encerrado'; end if;
  select string_agg(replace(trim_scale(quantidade - quantidade_recebida)::text, '.', ',') || ' ' || coalesce(unidade, 'un') || ' ' || descricao, '; ' order by id)
    into v_lista from public.pedidos_compra_itens where pedido_id = p_id and quantidade_recebida < quantidade;
  update public.pedidos_compra_itens set quantidade_cancelada = quantidade - quantidade_recebida
   where pedido_id = p_id and quantidade_recebida < quantidade;
  update public.pedidos_compra set situacao = 'recebido', saldo_encerrado_em = now(), saldo_encerrado_por = auth.uid(),
    motivo_encerramento = trim(p_motivo) where id = p_id;
  perform public.pc_projetar(p_id);
  perform public.pc_evento(p_id, 'encerrado', 'Saldo encerrado (não será mais entregue): ' || trim(p_motivo) || coalesce(' · cancelado: ' || v_lista, ''));
end $$;
revoke execute on function public.pedido_compra_encerrar(bigint, text) from public, anon;
grant execute on function public.pedido_compra_encerrar(bigint, text) to authenticated;
