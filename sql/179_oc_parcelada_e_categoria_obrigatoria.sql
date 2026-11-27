-- =====================================================================
-- 179 · Compra já paga e parcelada (cartão) vira uma conta a pagar por parcela
--       + categoria financeira válida obrigatória em todo item
--  · Pedido com "pagamento antecipado / já pago" e condição de pagamento com 2 ou mais parcelas
--    (ex.: cartão em 7x) passa a gerar UM TÍTULO POR PARCELA no contas a pagar, vencendo na data
--    do pagamento + os dias de cada parcela (ex.: pago em 24/11 no cartão que vence dia 19 → 25/56/87…
--    dias = 19/12, 19/01, 19/02…). Antes gerava um título só, com o valor todo.
--  · Pedido antecipado à vista (ou com uma parcela só) continua igual: um título na data do pagamento.
--  · Item de pedido de compra sem categoria financeira, ou com categoria de GRUPO (que não aceita
--    lançamento, ex.: "Informática e eletrônicos") ou inativa, BLOQUEIA o envio para aprovação —
--    vale também para item sem cadastro (compra ocasional).
--  · Para desfazer: voltar a versão anterior das funções pc_projetar e pc_pendencias (sql 176 / 166).
-- =====================================================================

-- 1) Antecipado parcelado: um título por parcela
do $$ declare d text; n text; begin
  d := pg_get_functiondef('public.pc_projetar(bigint)'::regprocedure);
  if position('PARCELA '' ||' in d) > 0 then return; end if;   -- já aplicado
  n := replace(d,
$x$    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao,
      data_vencimento, data_programada, conta_bancaria_id, forma_pagamento_id, codigo_barras, pix, link_pagamento, urgente, parcela, parcelas,
      origem, origem_ref, projecao, pedido_compra_id, situacao, valor_pago, saldo, observacoes)
    values (p.empresa_id, p.fornecedor_id, p.numero,
      'Pedido ' || p.numero || case when p.pagamento_antecipado then ' · PAGAMENTO ANTECIPADO' else ' · TRANSPORTE (SEM ENTRADA DE MERCADORIA)' end
        || case when p.pagamento_urgente then ' · URGENTE' else '' end,
      (select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) from public.pedidos_compra_itens i left join public.produtos pr on pr.id = i.produto_id
        where i.pedido_id = p_id group by 1 order by sum(i.valor_total) desc nulls last limit 1),
      p.valor_total, current_date,
      coalesce(p.pagamento_data, case when v_transp then coalesce(p.data_entrega_prevista, p.data_pedido) end, current_date),
      coalesce(p.pagamento_data, case when v_transp then coalesce(p.data_entrega_prevista, p.data_pedido) end, current_date),
      p.conta_bancaria_id, p.forma_pagamento_id,
      p.pagamento_codigo_barras, p.pagamento_pix, p.pagamento_link, p.pagamento_urgente, 1, 1, 'pedido_compra',
      jsonb_build_object('pedido_compra', p.numero, 'antecipado', true, 'transporte', v_transp), false, p_id, 'aberto', 0, p.valor_total,
      case when p.pagamento_antecipado then 'Pagamento antecipado do pedido aprovado (pagar antes de receber). Na entrada da mercadoria não nasce outro título.'
           else 'Serviço de transporte: não passa pelo almoxarifado, então o título já nasce real na aprovação do pedido.' end);
    return 1;$x$,
$x$    -- parcelado (2 ou mais parcelas, ex.: cartão em 7x): um título por parcela, a partir da data do pagamento
    select dias into v_dias from public.condicoes_pagamento where id = p.condicao_pagamento_id;
    if v_dias is null or cardinality(v_dias) = 0 then v_dias := p.prazo_livre_dias; end if;
    if not p.pagamento_antecipado or v_dias is null or cardinality(v_dias) < 2 then v_dias := array[0]; end if;
    v_n := cardinality(v_dias); v_acum := 0;
    v_base := coalesce(p.pagamento_data, case when v_transp then coalesce(p.data_entrega_prevista, p.data_pedido) end, current_date);
    select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) into v_cat from public.pedidos_compra_itens i left join public.produtos pr on pr.id = i.produto_id
      where i.pedido_id = p_id group by 1 order by sum(i.valor_total) desc nulls last limit 1;
    for v_i in 1..v_n loop
      v_v := case when v_i = v_n then p.valor_total - v_acum else round(p.valor_total / v_n, 2) end; v_acum := v_acum + v_v;
      insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao,
        data_vencimento, data_programada, conta_bancaria_id, forma_pagamento_id, codigo_barras, pix, link_pagamento, urgente, parcela, parcelas,
        origem, origem_ref, projecao, pedido_compra_id, situacao, valor_pago, saldo, observacoes)
      values (p.empresa_id, p.fornecedor_id, p.numero,
        'Pedido ' || p.numero || case when p.pagamento_antecipado then ' · PAGAMENTO ANTECIPADO' else ' · TRANSPORTE (SEM ENTRADA DE MERCADORIA)' end
          || case when v_n > 1 then ' · PARCELA ' || v_i || '/' || v_n else '' end
          || case when p.pagamento_urgente then ' · URGENTE' else '' end,
        v_cat, v_v, current_date, v_base + v_dias[v_i], v_base + v_dias[v_i],
        p.conta_bancaria_id, p.forma_pagamento_id,
        p.pagamento_codigo_barras, p.pagamento_pix, p.pagamento_link, p.pagamento_urgente, v_i, v_n, 'pedido_compra',
        jsonb_build_object('pedido_compra', p.numero, 'antecipado', true, 'transporte', v_transp), false, p_id, 'aberto', 0, v_v,
        case when p.pagamento_antecipado then 'Pagamento antecipado do pedido aprovado (pagar antes de receber). Na entrada da mercadoria não nasce outro título.'
             else 'Serviço de transporte: não passa pelo almoxarifado, então o título já nasce real na aprovação do pedido.' end);
    end loop;
    return v_n;$x$);
  if n = d then raise exception 'pc_projetar: ponto de troca não encontrado'; end if;
  execute n;
end $$;

-- 2) Categoria financeira válida (de lançamento e ativa) obrigatória em todo item, com ou sem cadastro
do $$ declare d text; n text; begin
  d := pg_get_functiondef('public.pc_pendencias(bigint)'::regprocedure);
  if position('categoria financeira válida' in d) > 0 then return; end if;   -- já aplicado
  n := replace(d,
    $x$count(*) || ' item(ns) sem categoria financeira') x
      from public.pedidos_compra_itens i where i.pedido_id = p_id and i.categoria_financeira_id is null having count(*) > 0$x$,
    $x$count(*) || ' item(ns) sem categoria financeira válida (vazia, de grupo ou inativa): ' || string_agg(i.descricao, ', ')) x
      from public.pedidos_compra_itens i where i.pedido_id = p_id
       and (i.categoria_financeira_id is null or not exists (select 1 from public.categorias_financeiras c
             where c.id = i.categoria_financeira_id and c.aceita_lancamento and c.situacao = 'ativo')) having count(*) > 0$x$);
  if n = d then raise exception 'pc_pendencias: ponto de troca não encontrado'; end if;
  execute n;
end $$;
