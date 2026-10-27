-- =====================================================================
-- 088 · Alerta de aumento de preço no pedido de compra
--  · Cada item é comparado com o último preço pago no mesmo produto/serviço (pedidos aprovados ou já
--    enviados/recebidos, de qualquer fornecedor; unidades diferentes não são comparadas).
--  · Quando o preço está maior, aparece como pendência (não bloqueia) no pedido e, na central de
--    Aprovações, o pedido vem marcado "⚠ AUMENTO DE PREÇO" para quem aprova.
-- =====================================================================
create or replace function public.pc_aumentos(p_id bigint)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('item_id', i.id, 'descricao', coalesce(pr.codigo || ' · ', '') || i.descricao,
           'atual', i.valor_unitario, 'ultimo', u.valor_unitario, 'pct', round((i.valor_unitario / u.valor_unitario - 1) * 100, 1),
           'pedido', u.numero, 'data', u.data_pedido, 'fornecedor', u.fornecedor) order by i.id), '[]')
    from public.pedidos_compra_itens i
    left join public.produtos pr on pr.id = i.produto_id
    cross join lateral (
      select i2.valor_unitario, p2.numero, p2.data_pedido, coalesce(f.nome_fantasia, f.nome) fornecedor
        from public.pedidos_compra_itens i2
        join public.pedidos_compra p2 on p2.id = i2.pedido_id
        left join public.fornecedores f on f.id = p2.fornecedor_id
       where i2.pedido_id <> p_id and p2.situacao in ('aprovado','enviado','recebido_parcial','recebido') and i2.valor_unitario > 0
         and i2.produto_id is not distinct from i.produto_id and i2.servico_id is not distinct from i.servico_id
         and (i2.unidade is null or i.unidade is null or upper(trim(i2.unidade)) = upper(trim(i.unidade)))
       order by p2.data_pedido desc, p2.id desc limit 1) u
   where i.pedido_id = p_id and (i.produto_id is not null or i.servico_id is not null)
     and i.valor_unitario > u.valor_unitario + 0.005
$$;
revoke execute on function public.pc_aumentos(bigint) from public, anon, authenticated;

-- Pendência (não bloqueia) no pedido
do $$
declare v text;
begin
  v := pg_get_functiondef('public.pc_pendencias(bigint)'::regprocedure);
  if position('aumento_preco' in v) = 0 then
    v := replace(v, '    union all
    select jsonb_build_object(''id'', ''sem_condicao''',
      '    union all
    select jsonb_build_object(''id'', ''aumento_preco'', ''bloqueia'', false, ''texto'', ''Preço acima da última compra: '' ||
           string_agg((a->>''descricao'') || '' R$ '' || replace(to_char((a->>''ultimo'')::numeric, ''FM999999990.00''), ''.'', '','') || '' → R$ '' || replace(to_char((a->>''atual'')::numeric, ''FM999999990.00''), ''.'', '','')
                      || '' (+'' || replace(a->>''pct'', ''.'', '','') || ''%)'', ''; ''))
      from jsonb_array_elements(public.pc_aumentos(p_id)) a having count(*) > 0
    union all
    select jsonb_build_object(''id'', ''sem_condicao''');
    execute v;
  end if;
  -- Central de aprovações: pedido com aumento vem marcado
  v := pg_get_functiondef('public.minhas_aprovacoes()'::regprocedure);
  if position('AUMENTO DE PREÇO' in v) = 0 then
    v := replace(v, '''texto'', p.numero || '' · '' || f.nome, ''valor''',
      '''texto'', p.numero || '' · '' || f.nome || coalesce('' · ⚠ AUMENTO DE PREÇO em '' || nullif(jsonb_array_length(public.pc_aumentos(p.id)), 0) || '' item(ns)'', ''''), ''valor''');
    execute v;
  end if;
end $$;
