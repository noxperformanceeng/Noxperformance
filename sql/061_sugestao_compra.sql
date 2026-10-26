-- =====================================================================
-- 061 · Sugestão de compra
--  · Lista os produtos que precisam ser comprados: estoque mínimo (cadastro do produto) − saldo em estoque − o que já está
--    em pedido de compra aprovado/enviado. Mostra a quantidade sugerida na unidade de compra, o último fornecedor e preço.
--  · Enquanto o estoque não estiver apurado (sem inventário), o produto aparece com o aviso "estoque não apurado"
--    e a sugestão considera saldo zero. A compra continua livre para qualquer produto.
--  · Só leitura; acesso de quem vê pedidos de compra.
-- =====================================================================
create or replace function public.sugestao_compra()
returns table (produto_id bigint, codigo text, descricao text, tipo text, unidade text, unidade_compra text, fator numeric,
               saldo numeric, inventariado boolean, minimo numeric, em_pedido numeric, sugerido numeric, sugerido_compra numeric,
               fornecedor_id bigint, fornecedor text, ultimo_preco numeric, ultima_compra date, ultimo_pedido text, categoria_financeira_id bigint)
language sql stable security definer set search_path = public as $$
  with mov as (
    select m.produto_id, sum(m.quantidade) saldo, bool_or(m.tipo = 'inventario') inv from public.estoque_movimentos m group by 1),
  ped as (   -- em pedido (unidade de estoque): saldo a receber dos pedidos aprovados/enviados/parciais
    select i.produto_id, sum((i.quantidade - i.quantidade_recebida) * coalesce(pr.fator_compra, 1)) q
      from public.pedidos_compra_itens i join public.pedidos_compra p on p.id = i.pedido_id join public.produtos pr on pr.id = i.produto_id
     where p.situacao in ('em_aprovacao','aprovado','enviado','recebido_parcial') and i.quantidade > i.quantidade_recebida group by 1),
  ult as (   -- última compra de cada produto
    select distinct on (i.produto_id) i.produto_id, p.fornecedor_id, i.valor_unitario, p.data_pedido, p.numero
      from public.pedidos_compra_itens i join public.pedidos_compra p on p.id = i.pedido_id
     where p.situacao <> 'cancelado' and i.produto_id is not null and i.valor_unitario > 0
     order by i.produto_id, p.data_pedido desc, p.id desc),
  pref as (
    select distinct on (pf.produto_id) pf.produto_id, pf.fornecedor_id from public.produto_fornecedores pf order by pf.produto_id, pf.preferencial desc, pf.id)
  select pr.id, pr.codigo, pr.descricao, pr.tipo, pr.unidade, coalesce(pr.unidade_compra, pr.unidade), coalesce(pr.fator_compra, 1),
         coalesce(mov.saldo, 0), coalesce(mov.inv, false), pr.estoque_minimo, coalesce(ped.q, 0),
         greatest(pr.estoque_minimo - coalesce(mov.saldo, 0) - coalesce(ped.q, 0), 0),
         ceil(greatest(pr.estoque_minimo - coalesce(mov.saldo, 0) - coalesce(ped.q, 0), 0) / coalesce(pr.fator_compra, 1) * 100) / 100,
         coalesce(ult.fornecedor_id, pref.fornecedor_id), f.nome, ult.valor_unitario, ult.data_pedido, ult.numero, pr.categoria_financeira_id
    from public.produtos pr
    left join mov on mov.produto_id = pr.id
    left join ped on ped.produto_id = pr.id
    left join ult on ult.produto_id = pr.id
    left join pref on pref.produto_id = pr.id
    left join public.fornecedores f on f.id = coalesce(ult.fornecedor_id, pref.fornecedor_id)
   where (select public.pode('compras')) and pr.situacao = 'ativo' and pr.controla_estoque and coalesce(pr.estoque_minimo, 0) > 0
     and pr.estoque_minimo - coalesce(mov.saldo, 0) - coalesce(ped.q, 0) > 0
   order by f.nome nulls last, pr.descricao
$$;
revoke execute on function public.sugestao_compra() from public, anon;
grant execute on function public.sugestao_compra() to authenticated;
