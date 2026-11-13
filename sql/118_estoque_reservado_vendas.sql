-- =====================================================================
-- 118 · Estoque reservado pelos pedidos de venda
--  · Cada pedido de venda confirmado reserva a quantidade dos seus produtos (só os que controlam estoque).
--    Posição de estoque passa a mostrar FÍSICO (o que está na prateleira), RESERVADO e DISPONÍVEL (físico − reservado).
--  · A reserva não é digitada: sai da situação do pedido, então nasce, baixa e some sozinha.
--      - Reserva: pedido "aberto" ou "faturado" (ainda não enviado), pela quantidade que falta sair.
--      - Baixa:  cada entrega EXPEDIDA tira da reserva o que saiu (e o estoque físico cai na mesma hora).
--      - Libera: pedido cancelado, enviado, entregue ou devolvido; orçamento não reserva.
--      - Mercado Livre: reserva só enquanto o pedido está "pago" ou "pronto para envio".
--      - Pedidos vindos do Tiny com mais de 120 dias não reservam (os antigos "em aberto" de 2024 já saíram).
--  · Sugestão de compra passa a usar o DISPONÍVEL: o que está reservado para cliente não conta como sobra.
--    Produto comprado pronto (revenda) vendido além do disponível entra na sugestão mesmo sem estoque mínimo.
--  · Pode vender sem disponível (sob encomenda): o pedido só mostra o aviso; a produção e as compras veem a falta.
-- =====================================================================

-- reservas por item de pedido (uso interno: as telas usam as funções abaixo)
create or replace function public.estoque_reservas_itens()
returns table (produto_id bigint, pedido_id bigint, pedido_item_id bigint, quantidade numeric)
language sql stable security definer set search_path = public as $$
  select i.produto_id, pv.id, i.id, i.quantidade - coalesce(sa.saiu, 0)
    from public.pedidos_venda pv
    join public.pedidos_venda_itens i on i.pedido_id = pv.id
    join public.produtos pr on pr.id = i.produto_id and pr.controla_estoque
    left join lateral (select sum(ei.quantidade) saiu from public.pedidos_venda_entregas_itens ei
                         join public.pedidos_venda_entregas e on e.id = ei.entrega_id
                        where ei.pedido_item_id = i.id and e.situacao in ('expedido', 'entregue')) sa on true
   where pv.situacao in ('aberto', 'faturado')
     and (pv.origem is distinct from 'api' or pv.etapa in ('pago', 'pronto_envio'))       -- Mercado Livre: até sair
     and (pv.origem is distinct from 'tiny' or pv.data_pedido >= current_date - 120)      -- Tiny: só os recentes
     and i.quantidade - coalesce(sa.saiu, 0) > 0
$$;
revoke execute on function public.estoque_reservas_itens() from public, anon, authenticated;

-- físico, reservado e disponível por produto (todos, ou só os produtos pedidos)
create or replace function public.estoque_disponivel(p_produtos bigint[] default null)
returns table (produto_id bigint, fisico numeric, reservado numeric, disponivel numeric, pedidos int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('estoque') or public.pode('almoxarifado') or public.pode('inventario') or public.pode('compras')
          or public.pode('ordens') or public.pode('apontamento') or public.pode('pedidos')) then
    raise exception 'Sem permissão para ver estoque';
  end if;
  return query
  with f as (select m.produto_id, sum(m.quantidade) q from public.estoque_movimentos m
              where p_produtos is null or m.produto_id = any(p_produtos) group by 1),
       r as (select x.produto_id, sum(x.quantidade) q, count(distinct x.pedido_id)::int n from public.estoque_reservas_itens() x
              where p_produtos is null or x.produto_id = any(p_produtos) group by 1)
  select coalesce(f.produto_id, r.produto_id), coalesce(f.q, 0), coalesce(r.q, 0), coalesce(f.q, 0) - coalesce(r.q, 0), coalesce(r.n, 0)
    from f full join r on r.produto_id = f.produto_id;
end $$;
revoke execute on function public.estoque_disponivel(bigint[]) from public, anon;
grant execute on function public.estoque_disponivel(bigint[]) to authenticated;

-- pedidos que estão segurando um produto (sem valores: o almoxarifado e a produção também veem)
create or replace function public.estoque_reservas_produto(p_produto bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('estoque') or public.pode('almoxarifado') or public.pode('inventario') or public.pode('compras')
          or public.pode('ordens') or public.pode('apontamento') or public.pode('pedidos')) then
    raise exception 'Sem permissão para ver estoque';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('pedido_id', pv.id, 'pedido', coalesce(pv.numero_externo, pv.id::text),
             'data', pv.data_pedido, 'cliente', coalesce(cl.nome, pv.cliente_nome), 'canal', c.nome, 'situacao', pv.situacao, 'etapa', pv.etapa,
             'quantidade', x.q) order by pv.data_pedido, pv.id)
    from (select r.pedido_id, sum(r.quantidade) q from public.estoque_reservas_itens() r where r.produto_id = p_produto group by 1) x
    join public.pedidos_venda pv on pv.id = x.pedido_id
    left join public.clientes cl on cl.id = pv.cliente_id
    left join public.canais_venda c on c.id = pv.canal_id), '[]'::jsonb);
end $$;
revoke execute on function public.estoque_reservas_produto(bigint) from public, anon;
grant execute on function public.estoque_reservas_produto(bigint) to authenticated;

-- Sugestão de compra: mínimo − DISPONÍVEL (físico − reservado) − o que já está comprado
drop function if exists public.sugestao_compra();
create function public.sugestao_compra()
returns table (produto_id bigint, codigo text, descricao text, tipo text, unidade text, unidade_compra text, fator numeric, saldo numeric,
               inventariado boolean, minimo numeric, em_pedido numeric, sugerido numeric, sugerido_compra numeric, fornecedor_id bigint,
               fornecedor text, ultimo_preco numeric, ultima_compra date, ultimo_pedido text, categoria_financeira_id bigint,
               reservado numeric, fisico numeric)
language sql stable security definer set search_path = public as $$
  with mov as (
    select m.produto_id, sum(m.quantidade) saldo, bool_or(m.tipo = 'inventario') inv from public.estoque_movimentos m group by 1),
  res as (
    select r.produto_id, sum(r.quantidade) q from public.estoque_reservas_itens() r group by 1),
  ped as (
    select i.produto_id, sum((i.quantidade - i.quantidade_recebida) * coalesce(pr.fator_compra, 1)) q
      from public.pedidos_compra_itens i join public.pedidos_compra p on p.id = i.pedido_id join public.produtos pr on pr.id = i.produto_id
     where p.situacao in ('em_aprovacao','aprovado','enviado','recebido_parcial') and i.quantidade > i.quantidade_recebida group by 1),
  ult as (
    select distinct on (i.produto_id) i.produto_id, p.fornecedor_id, i.valor_unitario, p.data_pedido, p.numero
      from public.pedidos_compra_itens i join public.pedidos_compra p on p.id = i.pedido_id
     where p.situacao <> 'cancelado' and i.produto_id is not null and i.valor_unitario > 0
     order by i.produto_id, p.data_pedido desc, p.id desc),
  pref as (
    select distinct on (pf.produto_id) pf.produto_id, pf.fornecedor_id from public.produto_fornecedores pf order by pf.produto_id, pf.preferencial desc, pf.id),
  b as (
    select pr.id, pr.codigo, pr.descricao, pr.tipo, pr.unidade, pr.unidade_compra, pr.fator_compra, coalesce(pr.estoque_minimo, 0) estoque_minimo, pr.categoria_financeira_id,
           coalesce(mov.saldo, 0) fis, coalesce(res.q, 0) resv, coalesce(mov.saldo, 0) - coalesce(res.q, 0) disp,
           coalesce(mov.inv, false) inv, coalesce(ped.q, 0) emp
      from public.produtos pr left join mov on mov.produto_id = pr.id left join res on res.produto_id = pr.id left join ped on ped.produto_id = pr.id
     where pr.situacao = 'ativo' and pr.controla_estoque
       and (coalesce(pr.estoque_minimo, 0) > 0                                    -- abaixo do mínimo, ou
            or (res.q > 0 and pr.tipo in ('componente', 'materia_prima', 'insumo'))))   -- comprado pronto e vendido além do que tem
  select b.id, b.codigo, b.descricao, b.tipo, b.unidade, coalesce(b.unidade_compra, b.unidade), coalesce(b.fator_compra, 1),
         b.disp, b.inv, b.estoque_minimo, b.emp,
         greatest(b.estoque_minimo - b.disp - b.emp, 0),
         ceil(greatest(b.estoque_minimo - b.disp - b.emp, 0) / coalesce(b.fator_compra, 1) * 100) / 100,
         coalesce(ult.fornecedor_id, pref.fornecedor_id), f.nome, ult.valor_unitario, ult.data_pedido, ult.numero, b.categoria_financeira_id,
         b.resv, b.fis
    from b
    left join ult on ult.produto_id = b.id
    left join pref on pref.produto_id = b.id
    left join public.fornecedores f on f.id = coalesce(ult.fornecedor_id, pref.fornecedor_id)
   where (select public.pode('compras')) and b.estoque_minimo - b.disp - b.emp > 0
   order by f.nome nulls last, b.descricao
$$;
revoke execute on function public.sugestao_compra() from public, anon;
grant execute on function public.sugestao_compra() to authenticated;
