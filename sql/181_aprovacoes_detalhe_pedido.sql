-- =====================================================================
-- 181 · Aprovações: pedido de compra mostra o que está sendo aprovado
--  · Na central de Aprovações, cada pedido de compra passa a mostrar, além do número e do fornecedor:
--    os itens (quantidade × descrição), a forma de pagamento (com nº de parcelas, se parcelado),
--    se é pagamento antecipado e o nº do pedido no Mercado Livre (quando houver).
--  · Dá para conferir pelo celular sem abrir o pedido. Só muda o texto da lista; nada nos dados.
--  · Para desfazer: voltar o texto anterior em minhas_aprovacoes.
-- =====================================================================

do $$ declare d text; n text; begin
  d := pg_get_functiondef('public.minhas_aprovacoes()'::regprocedure);
  if position('pedido ML' in d) > 0 then return; end if;   -- já aplicado
  n := replace(d,
    $x$'texto', p.numero || ' · ' || f.nome || coalesce($x$,
    $x$'texto', p.numero || ' · ' || coalesce(nullif(f.nome_fantasia, ''), f.nome)
             || ' · ' || coalesce((select left(string_agg(trim(to_char(i.quantidade, 'FM999999990.###'), '.') || '× '
                                    || coalesce(pr.codigo || ' ' || pr.descricao, sv.nome, i.descricao), '; ' order by i.id), 240)
                                   from public.pedidos_compra_itens i left join public.produtos pr on pr.id = i.produto_id
                                   left join public.servicos sv on sv.id = i.servico_id where i.pedido_id = p.id), 'sem itens')
             || coalesce(' · ' || (select fp.nome from public.formas_pagamento fp where fp.id = p.forma_pagamento_id), '')
             || case when coalesce(cardinality(p.prazo_livre_dias), 0) > 1 then ' ' || cardinality(p.prazo_livre_dias) || 'x' else '' end
             || case when p.pagamento_antecipado then ' · pagto antecipado' else '' end
             || coalesce(' · pedido ML ' || substring(p.observacoes_internas from 'PEDIDO ML ([0-9]+)'), '') || coalesce($x$);
  if n = d then raise exception 'minhas_aprovacoes: ponto de troca não encontrado'; end if;
  execute n;
end $$;
