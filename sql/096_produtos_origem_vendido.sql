-- =====================================================================
-- 096 · Produto: "Origem" (como a peça chega) separada de "Vendido" (automático)
--  · Quem cadastra só responde a origem da peça: matéria-prima, comprada pronta, feita sob desenho por
--    terceiro (usinagem, corte a laser…), fabricada/montada na NOX, kit ou ferramenta. É o antigo "Tipo",
--    com nomes mais claros; o código automático continua seguindo a origem e o grupo.
--  · "Vendido" ninguém informa: o sistema marca sozinho quando o produto tem anúncio (Mercado Livre,
--    Shopee…) ou aparece em pedido de venda (venda direta, distribuidor, Tiny), e mostra onde e a última venda.
--  · Peças usinadas que também são vendidas prontas (NX21, NX28, NX39) voltam para a origem certa
--    (feita por terceiro, grupo Usinagem); a etiqueta "Vendido" mostra que elas também saem como produto.
-- =====================================================================
create or replace function public.produtos_vendas_resumo()
returns table (produto_id bigint, canais text[], pedidos int, ultima_venda date, anuncios int)
language sql stable security definer set search_path = public as $$
  with vendas as (
    select coalesce(i.produto_id, p.id) pid, coalesce(c.nome, case when v.origem = 'tiny' then 'Tiny' else 'Venda direta' end) canal,
           v.id pedido, v.data_pedido
      from public.pedidos_venda_itens i
      join public.pedidos_venda v on v.id = i.pedido_id and v.situacao <> 'cancelado'
      left join public.canais_venda c on c.id = v.canal_id
      left join public.produtos p on i.produto_id is null and upper(p.codigo) = upper(trim(i.sku))
  ), anunc as (
    select coalesce(a.produto_id, p.id) pid, c.nome canal, a.id
      from public.anuncios a
      left join public.canais_venda c on c.id = a.canal_id
      left join public.produtos p on a.produto_id is null and upper(p.codigo) = upper(trim(a.sku))
     where coalesce(a.situacao, 'ativo') not in ('inativo', 'closed', 'encerrado')
  )
  select pid, array_agg(distinct canal order by canal) filter (where canal is not null),
         count(distinct pedido)::int, max(data_pedido)::date, count(distinct anuncio)::int
    from (select pid, canal, pedido, data_pedido, null::bigint anuncio from vendas
          union all select pid, canal, null, null, id from anunc) z
   where pid is not null and ((select public.pode('produtos')) or (select public.pode('pedidos')) or (select public.pode('compras')))
   group by pid
$$;
revoke execute on function public.produtos_vendas_resumo() from public, anon;
grant execute on function public.produtos_vendas_resumo() to authenticated;

-- Peças usinadas vendidas também prontas: origem = feita por terceiro (usinagem)
update public.produtos set tipo = 'semiacabado', grupo = 'Usinagem',
       categoria_financeira_id = coalesce(categoria_financeira_id, (select id from public.categorias_financeiras where codigo = '3.05.005'))
 where codigo in ('NX21', 'NX28', 'NX39') and tipo <> 'semiacabado';
