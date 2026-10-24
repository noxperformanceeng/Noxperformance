-- 052 · Pedido de compra: item sem cadastro só com liberação do administrador (ou ação compras.liberar_avulso)
--   A liberação vale para os itens avulsos daquele pedido (descrições gravadas); item avulso novo/alterado exige nova liberação.
alter table public.pedidos_compra add column if not exists liberacao_avulso jsonb;   -- {por, em, motivo, itens:[descrições liberadas]}
insert into public.acoes (id, modulo_id, nome, descricao, ordem) values
  ('compras.liberar_avulso', 'compras', 'Liberar item sem cadastro em pedido de compra', 'Compra ocasional (ex.: manutenção) sem criar SKU. Administrador sempre pode.', 2)
on conflict (id) do nothing;

create or replace function public.pc_avulsos_pendentes(p_id bigint)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(i.descricao order by i.id), '{}') from public.pedidos_compra_itens i, public.pedidos_compra p
   where p.id = p_id and i.pedido_id = p_id and i.produto_id is null
     and not (lower(trim(i.descricao)) in (select lower(trim(x)) from jsonb_array_elements_text(coalesce(p.liberacao_avulso->'itens', '[]')) x))
$$;
grant execute on function public.pc_avulsos_pendentes(bigint) to authenticated;

-- pedido_compra_acao (049) recebeu, via replace no banco:
--  · enviar_aprovacao: raise 'Item sem cadastro precisa de liberação do administrador: ...' se pc_avulsos_pendentes(p_id) não vazio
--  · nova ação 'liberar_avulso' (eh_admin() ou pode_acao('compras.liberar_avulso'); motivo obrigatório; só em rascunho/recusado;
--    grava liberacao_avulso = {por, em, motivo, itens} e registra evento 'liberado_avulso')
