-- =====================================================================
-- 176 · Ordem de compra de transporte (frete, coleta) vira conta a pagar de verdade
-- Problema: OC de transporte não passa pelo almoxarifado (171), então ninguém dá
-- entrada de NF e o título ficava para sempre como "previsão", sem poder pagar
-- (caso PC-00053 e PC-00054, Rafael de Arruda, já pagos).
-- O que muda: na aprovação, a OC de transporte gera direto o título real no
-- contas a pagar (como o pagamento antecipado), vencendo na data de pagamento
-- informada ou na data do pedido. As previsões que já existiam viram título real.
-- Para desfazer: cancelar o título no contas a pagar.
-- =====================================================================

create or replace function public.pc_projetar(p_id bigint)
returns integer language plpgsql security definer set search_path = public as $$
declare p public.pedidos_compra; v_pend numeric; v_dias int[]; v_n int; v_cat bigint; v_i int; v_v numeric; v_acum numeric;
  v_grupos jsonb; v_ng int; v_g int; v_parte numeric; v_partes numeric := 0; v_peso_tot numeric; v_data date; v_base date; v_k int := 0;
  v_transp boolean;
begin
  select * into p from public.pedidos_compra where id = p_id;
  delete from public.titulos_pagar where pedido_compra_id = p_id and projecao and coalesce(valor_pago, 0) = 0 and origem = 'pedido_compra'
     and not (coalesce(origem_ref, '{}') ? 'recebimento_id');
  v_transp := coalesce(p.origem, '') <> 'tiny' and public.pc_eh_transporte(p_id);
  -- pagamento antecipado ou transporte (não tem entrada de mercadoria): título real direto
  if p.pagamento_antecipado or v_transp then
    if p.situacao not in ('aprovado','enviado','recebido_parcial','recebido') then
      delete from public.titulos_pagar where pedido_compra_id = p_id and origem = 'pedido_compra' and origem_ref->>'antecipado' = 'true'
         and coalesce(valor_pago, 0) = 0 and situacao in ('aberto', 'programado');
      return 0;
    end if;
    if exists (select 1 from public.titulos_pagar where pedido_compra_id = p_id and origem_ref->>'antecipado' = 'true' and situacao <> 'cancelado') then return 0; end if;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao,
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
    return 1;
  end if;
  if p.situacao not in ('aprovado','enviado','recebido_parcial') or p.origem = 'tiny' then return 0; end if;
  v_pend := round(p.valor_total - p.valor_recebido, 2);
  if v_pend <= 0.009 then return 0; end if;
  select dias into v_dias from public.condicoes_pagamento where id = p.condicao_pagamento_id;
  if v_dias is null or cardinality(v_dias) = 0 then v_dias := p.prazo_livre_dias; end if;
  if v_dias is null or cardinality(v_dias) = 0 then v_dias := array[coalesce(public.p_dias_padrao_fornecedor(p.fornecedor_id), 0)]; end if;
  v_n := cardinality(v_dias);
  select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) into v_cat
  from public.pedidos_compra_itens i left join public.produtos pr on pr.id = i.produto_id
  where i.pedido_id = p_id group by 1 order by sum(i.valor_total) desc nulls last limit 1;
  -- o que falta entregar, agrupado pela data de entrega do item (sem data no item = data do pedido)
  select coalesce(jsonb_agg(jsonb_build_object('d', d, 'peso', peso) order by d), '[]'), coalesce(sum(peso), 0) into v_grupos, v_peso_tot
  from (select coalesce(i.data_entrega_prevista, p.data_entrega_prevista, p.data_pedido) d,
               sum((i.valor_total + coalesce(i.valor_ipi, 0)) * greatest(i.quantidade - coalesce(i.quantidade_recebida, 0) - coalesce(i.quantidade_cancelada, 0), 0) / i.quantidade) peso
          from public.pedidos_compra_itens i where i.pedido_id = p_id and i.quantidade > 0 group by 1) g
  where peso > 0;
  if jsonb_array_length(v_grupos) = 0 or v_peso_tot <= 0 then
    v_grupos := jsonb_build_array(jsonb_build_object('d', coalesce(p.data_entrega_prevista, p.data_pedido), 'peso', 1)); v_peso_tot := 1;
  end if;
  v_ng := jsonb_array_length(v_grupos);
  for v_g in 0..v_ng - 1 loop
    v_data := (v_grupos->v_g->>'d')::date;
    v_parte := case when v_g = v_ng - 1 then v_pend - v_partes else round(v_pend * (v_grupos->v_g->>'peso')::numeric / v_peso_tot, 2) end;
    v_partes := v_partes + v_parte;
    continue when v_parte <= 0.009;
    v_base := greatest(v_data, current_date); v_acum := 0;
    for v_i in 1..v_n loop
      v_v := case when v_i = v_n then v_parte - v_acum else round(v_parte / v_n, 2) end; v_acum := v_acum + v_v; v_k := v_k + 1;
      insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao,
        data_vencimento, data_programada, conta_bancaria_id, forma_pagamento_id, parcela, parcelas, origem, origem_ref, projecao,
        pedido_compra_id, situacao, valor_pago, saldo, observacoes)
      values (p.empresa_id, p.fornecedor_id, p.numero,
        'Pedido de compra ' || p.numero || ' · aguardando NF' || case when v_ng > 1 then ' · entrega ' || to_char(v_data, 'DD/MM/YYYY') else '' end,
        v_cat, v_v, p.data_pedido, v_base + v_dias[v_i], v_base + v_dias[v_i], p.conta_bancaria_id, p.forma_pagamento_id, v_k, v_n * v_ng, 'pedido_compra',
        jsonb_build_object('pedido_compra', p.numero, 'aguardando_nf', true, 'entrega', v_data), true, p_id, 'aberto', 0, v_v,
        'Projeção automática do pedido aprovado. Vira título real depois da entrada da NF (almoxarifado) e do lançamento pelo financeiro.');
    end loop;
  end loop;
  return v_k;
end $$;

-- refaz agora as OCs de transporte aprovadas que ainda estavam como previsão
do $$ declare r record; begin
  for r in select distinct pc.id from public.pedidos_compra pc join public.titulos_pagar t on t.pedido_compra_id = pc.id
            where t.projecao and t.origem = 'pedido_compra' and coalesce(t.valor_pago, 0) = 0
              and pc.situacao in ('aprovado','enviado','recebido_parcial') and coalesce(pc.origem, '') <> 'tiny' and public.pc_eh_transporte(pc.id)
  loop perform public.pc_projetar(r.id); end loop;
end $$;
