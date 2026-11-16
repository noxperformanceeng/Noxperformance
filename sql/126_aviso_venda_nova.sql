-- =====================================================================
-- 126 · Aviso de venda nova (Comercial e Expedição)
--  · Quando entra uma venda nova (Mercado Livre 30 e 37 e demais canais), quem é do Comercial ou da Expedição
--    recebe na hora um aviso na tela (cartão verde) e um som, em qualquer tela do sistema.
--  · O aviso mostra canal, nº do pedido, cliente e os itens com quantidade. Não mostra valores (a Expedição não
--    vê valores de venda).
--  · Só conta venda com data de ontem ou de hoje (importação de histórico não dispara aviso).
--  · Função só de leitura; quem não tem acesso a Pedidos de venda nem à Expedição não recebe nada.
-- =====================================================================

create or replace function public.vendas_recentes(p_desde timestamptz default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('agora', now(), 'vendas', case when p_desde is null then '[]'::jsonb else coalesce((
    select jsonb_agg(v order by v->>'criado_em') from (
      select jsonb_build_object(
        'id', pv.id, 'canal', cv.nome, 'numero', coalesce(pv.numero_externo, pv.id::text),
        'cliente', coalesce(cl.nome, pv.cliente_nome), 'logistica', pv.logistica, 'criado_em', pv.criado_em,
        'itens', (select jsonb_agg(jsonb_build_object('descricao', coalesce(pr.descricao, i.descricao, i.sku), 'quantidade', i.quantidade) order by i.id)
                    from public.pedidos_venda_itens i left join public.produtos pr on pr.id = i.produto_id where i.pedido_id = pv.id)
      ) v
        from public.pedidos_venda pv
        left join public.canais_venda cv on cv.id = pv.canal_id
        left join public.clientes cl on cl.id = pv.cliente_id
       where pv.criado_em > p_desde
         and pv.data_pedido >= current_date - 1
         and coalesce(pv.situacao, '') not in ('cancelado', 'cancelada')
       order by pv.criado_em limit 20
    ) x), '[]'::jsonb) end)
   where ((select public.pode('pedidos')) or (select public.pode('separacao')))
$$;
revoke execute on function public.vendas_recentes(timestamptz) from public, anon;
grant execute on function public.vendas_recentes(timestamptz) to authenticated;
