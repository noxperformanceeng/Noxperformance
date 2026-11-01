-- =====================================================================
-- 104 · Peça de compra obrigatória no conjunto
--  · Na estrutura do conjunto (Produtos › Componentes do conjunto) a peça pode ser marcada como
--    "compra obrigatória junto": ao comprar o conjunto pelo pedido de compra, ela não pode ser
--    desmarcada nem comprada em quantidade menor que a necessária (ex.: capas do motor dos defletores).
--  · Já marca as capas do motor (e o suporte da capa) dos defletores que têm capa.
-- =====================================================================

alter table public.produto_estrutura add column if not exists compra_obrigatoria boolean not null default false;

update public.produto_estrutura e set compra_obrigatoria = true
  from public.produtos c where c.id = e.componente_id and not e.compra_obrigatoria
   and c.codigo in ('2000417', '2000429', '2000426', '2000430');

create or replace function public.compra_conjunto(p_produto bigint, p_quantidade numeric default 1)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not (select public.pode('compras')) then raise exception 'Sem permissão'; end if;
  with comp as (
    select e.componente_id id, sum(e.quantidade) q, min(e.ordem) ordem, bool_or(e.compra_obrigatoria) obrig
      from public.produto_estrutura e
     where e.produto_id = p_produto and e.ativo and not coalesce(e.opcional, false)
     group by e.componente_id),
  ped as (
    select i.produto_id, sum(i.quantidade - i.quantidade_recebida) q
      from public.pedidos_compra_itens i join public.pedidos_compra p on p.id = i.pedido_id
     where p.situacao in ('em_aprovacao','aprovado','enviado','recebido_parcial')
       and i.servico_id is null and i.quantidade > i.quantidade_recebida and i.produto_id in (select id from comp)
     group by 1),
  arq as (
    select distinct on (a.produto_id, a.finalidade, case when a.finalidade = 'montagem' and not a.obsoleto then a.id end)
           a.produto_id, a.finalidade, a.nome, a.caminho
      from public.produto_arquivos a
     where a.produto_id in (select id from comp union select p_produto)
       and a.finalidade in ('corte_dxf','corte_pdf','dobra_pdf','dobra_dxf','montagem') and not (a.finalidade = 'montagem' and a.obsoleto)
     order by a.produto_id, a.finalidade, case when a.finalidade = 'montagem' and not a.obsoleto then a.id end,
              a.obsoleto, coalesce(a.revisao_data, a.criado_em::date) desc, a.id desc)
  select jsonb_build_object(
    'conjunto', (select jsonb_build_object('id', pr.id, 'codigo', pr.codigo, 'descricao', pr.descricao,
                  'arquivos', coalesce((select jsonb_agg(jsonb_build_object('finalidade', a.finalidade, 'nome', a.nome, 'caminho', a.caminho)) from arq a where a.produto_id = pr.id), '[]'))
                  from public.produtos pr where pr.id = p_produto),
    'pecas', coalesce(jsonb_agg(jsonb_build_object(
      'id', pr.id, 'codigo', pr.codigo, 'descricao', pr.descricao, 'situacao', pr.situacao, 'tipo', pr.tipo,
      'unidade', coalesce(pr.unidade_compra, pr.unidade), 'categoria_financeira_id', pr.categoria_financeira_id,
      'por_conjunto', c.q, 'obrigatorio', c.obrig, 'necessario', c.q * p_quantidade,
      'saldo', public.estoque_saldo(pr.id), 'controla_estoque', pr.controla_estoque, 'em_pedido', coalesce(ped.q, 0),
      'arquivos', coalesce((select jsonb_agg(jsonb_build_object('finalidade', a.finalidade, 'nome', a.nome, 'caminho', a.caminho))
                              from arq a where a.produto_id = pr.id), '[]'))
      order by c.ordem nulls last, pr.codigo), '[]'))
  into v
  from comp c join public.produtos pr on pr.id = c.id left join ped on ped.produto_id = pr.id;
  return v;
end $$;
revoke execute on function public.compra_conjunto(bigint, numeric) from public, anon;
grant execute on function public.compra_conjunto(bigint, numeric) to authenticated;

