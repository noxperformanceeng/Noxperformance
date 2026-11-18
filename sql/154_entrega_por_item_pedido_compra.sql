-- =====================================================================
-- 154 · Pedido de compra: data de entrega prevista em cada item (e no fluxo de caixa)
--  · Pedido da equipe de Compras (18/11): em cada linha de item do pedido, a data em que o
--    fornecedor vai entregar aquele item, para organizar as entregas e provisionar o caixa.
--  · Nova coluna "data_entrega_prevista" nos itens do pedido. Item sem data = vale a "Entrega
--    prevista" do pedido (cabeçalho), que continua existindo. Pedido sem data no cabeçalho e com
--    datas nos itens: o cabeçalho passa a ser a data mais cedo dos itens.
--  · Depois de aprovado/enviado, dá para mudar a data de entrega de cada item (como já dá no
--    cabeçalho), sem voltar o pedido para aprovação.
--  · Contas a pagar / fluxo (previsão do pedido aprovado, "aguardando NF"): o valor que falta
--    entregar é dividido pelas datas de entrega dos itens, e cada parte gera as parcelas da
--    condição de pagamento a partir da sua data. Ex.: R$ 10.000 em 30 dias, metade entrega 01/12
--    e metade 15/12 → R$ 5.000 vence 31/12 e R$ 5.000 vence 14/01. Pedido com uma data só (ou
--    sem datas nos itens) gera exatamente as mesmas parcelas de hoje.
--  · Títulos reais (depois da NF), pagamento antecipado e pedidos do Tiny: não mudam.
--  · Nada é apagado. Para desfazer: voltar as funções ao texto anterior (SQL 130/151); a coluna
--    nova pode ficar vazia sem efeito.
-- =====================================================================

alter table public.pedidos_compra_itens add column if not exists data_entrega_prevista date;

-- ---------- Salvar pedido: grava a data de cada item ----------
create or replace function public.pedido_compra_salvar(p_pedido jsonb, p_itens jsonb)
returns bigint language plpgsql security definer set search_path = public as $function$
declare v_id bigint := nullif(p_pedido->>'id', '')::bigint; d public.pedidos_compra; v_sit text; v_cat_usi bigint; v_prazo int[];
begin
  d := jsonb_populate_record(null::public.pedidos_compra, p_pedido - 'id' - 'numero' - 'entregas_itens');
  if d.condicao_pagamento_id is null and cardinality(d.prazo_livre_dias) > 0 then
    select array_agg(distinct x order by x) into v_prazo from unnest(d.prazo_livre_dias) x where x is not null;
    if cardinality(v_prazo) > 24 then raise exception 'Prazos de pagamento: no máximo 24 parcelas'; end if;
    if v_prazo[1] < 0 or v_prazo[cardinality(v_prazo)] > 720 then raise exception 'Prazos de pagamento entre 0 e 720 dias'; end if;
  end if;
  if v_id is null then
    if not public.pode('compras', 'criar') then raise exception 'Sem permissão para incluir pedidos de compra'; end if;
    insert into public.pedidos_compra (empresa_id, fornecedor_id, comprador_id, data_pedido, data_entrega_prevista, condicao_pagamento_id, prazo_livre_dias, forma_pagamento_id,
      conta_bancaria_id, frete, outras_despesas, desconto, contato_fornecedor, email_fornecedor, whatsapp_fornecedor, observacoes, observacoes_internas)
    values (d.empresa_id, d.fornecedor_id, coalesce(d.comprador_id, auth.uid()), coalesce(d.data_pedido, current_date), d.data_entrega_prevista, d.condicao_pagamento_id, v_prazo,
      d.forma_pagamento_id, d.conta_bancaria_id, coalesce(d.frete, 0), coalesce(d.outras_despesas, 0), coalesce(d.desconto, 0), d.contato_fornecedor,
      d.email_fornecedor, d.whatsapp_fornecedor, d.observacoes, d.observacoes_internas)
    returning id into v_id;
    perform public.pc_evento(v_id, 'criado', 'Pedido criado (rascunho)');
  else
    select situacao into v_sit from public.pedidos_compra where id = v_id for update;
    if v_sit is null then raise exception 'Pedido não encontrado'; end if;
    if not public.pode('compras', 'alterar') then raise exception 'Sem permissão para alterar pedidos de compra'; end if;
    if v_sit not in ('rascunho','recusado') then
      update public.pedidos_compra set contato_fornecedor = d.contato_fornecedor, email_fornecedor = d.email_fornecedor,
        whatsapp_fornecedor = d.whatsapp_fornecedor, observacoes_internas = d.observacoes_internas, data_entrega_prevista = d.data_entrega_prevista
      where id = v_id;
      -- aprovado/enviado: só a data de entrega de cada item pode mudar
      if jsonb_typeof(p_pedido->'entregas_itens') = 'array' and v_sit not in ('recebido', 'cancelado') then
        update public.pedidos_compra_itens i set data_entrega_prevista = nullif(e->>'data', '')::date
          from jsonb_array_elements(p_pedido->'entregas_itens') e
         where i.pedido_id = v_id and i.id = nullif(e->>'id', '')::bigint
           and i.data_entrega_prevista is distinct from nullif(e->>'data', '')::date;
      end if;
      update public.pedidos_compra set data_entrega_prevista = (select min(data_entrega_prevista) from public.pedidos_compra_itens where pedido_id = v_id)
       where id = v_id and data_entrega_prevista is null;
      perform public.pc_projetar(v_id);
      return v_id;
    end if;
    update public.pedidos_compra set empresa_id = d.empresa_id, fornecedor_id = d.fornecedor_id, data_pedido = coalesce(d.data_pedido, data_pedido),
      data_entrega_prevista = d.data_entrega_prevista, condicao_pagamento_id = d.condicao_pagamento_id, prazo_livre_dias = v_prazo, forma_pagamento_id = d.forma_pagamento_id,
      conta_bancaria_id = d.conta_bancaria_id, frete = coalesce(d.frete, 0), outras_despesas = coalesce(d.outras_despesas, 0), desconto = coalesce(d.desconto, 0),
      contato_fornecedor = d.contato_fornecedor, email_fornecedor = d.email_fornecedor, whatsapp_fornecedor = d.whatsapp_fornecedor,
      observacoes = d.observacoes, observacoes_internas = d.observacoes_internas
    where id = v_id;
    perform public.pc_evento(v_id, 'alterado', 'Pedido alterado');
  end if;
  if p_pedido ? 'pagamento_antecipado' and (select situacao from public.pedidos_compra where id = v_id) in ('rascunho', 'recusado') then
    update public.pedidos_compra set pagamento_antecipado = coalesce(d.pagamento_antecipado, false),
      pagamento_urgente = coalesce(d.pagamento_antecipado, false) and coalesce(d.pagamento_urgente, false),
      pagamento_data = case when d.pagamento_antecipado then d.pagamento_data end,
      pagamento_pix = case when d.pagamento_antecipado then nullif(trim(d.pagamento_pix), '') end,
      pagamento_codigo_barras = case when d.pagamento_antecipado then nullif(trim(d.pagamento_codigo_barras), '') end,
      pagamento_link = case when d.pagamento_antecipado then nullif(trim(d.pagamento_link), '') end
    where id = v_id;
  end if;
  if p_itens is not null then
    if exists (select 1 from jsonb_array_elements(p_itens) x where x->>'tipo_item' = 'servico_usinagem' and nullif(x->>'produto_id', '') is null) then
      raise exception 'Serviço de usinagem precisa da peça (produto) que volta usinada';
    end if;
    if exists (select 1 from jsonb_array_elements(p_itens) x left join public.servicos s on s.id = nullif(x->>'servico_id', '')::bigint
                where nullif(x->>'servico_id', '') is not null and s.id is null) then
      raise exception 'Serviço não encontrado no cadastro';
    end if;
    select id into v_cat_usi from public.categorias_financeiras where codigo = '3.05.005' limit 1;
    delete from public.pedidos_compra_itens where pedido_id = v_id;
    insert into public.pedidos_compra_itens (pedido_id, produto_id, servico_id, descricao, unidade, codigo_fornecedor, quantidade, valor_unitario, desconto, ipi_pct, categoria_financeira_id, observacao,
      tipo_item, material, comprimento_mm, perda_mm, barra_mm, pecas_por_barra, barras_enviar, uso_consumo, data_entrega_prevista)
    select v_id, case when s.sv is not null and not s.srv then null else nullif(s.x->>'produto_id', '')::bigint end, s.sv,
           coalesce(nullif(s.x->>'descricao', ''),
                    case when s.srv then coalesce(sv.nome, 'USINAGEM') || ' · ' || (select descricao from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint) end,
                    sv.nome, (select descricao from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint), 'Item'),
           coalesce(nullif(s.x->>'unidade', ''), sv.unidade, case when s.srv then 'PÇ' end), nullif(s.x->>'codigo_fornecedor', ''), (s.x->>'quantidade')::numeric,
           coalesce((s.x->>'valor_unitario')::numeric, 0), coalesce((s.x->>'desconto')::numeric, 0), least(greatest(coalesce(nullif(s.x->>'ipi_pct', '')::numeric, 0), 0), 100),
           case when s.sv is not null then coalesce(sv.categoria_financeira_id, nullif(s.x->>'categoria_financeira_id', '')::bigint)
                else coalesce(nullif(s.x->>'categoria_financeira_id', '')::bigint, case when s.srv then v_cat_usi end,
                              (select categoria_financeira_id from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint)) end,
           nullif(s.x->>'observacao', ''),
           case when s.srv then 'servico_usinagem' else 'normal' end,
           case when s.srv then coalesce(nullif(s.x->>'material', ''), u.material) end,
           case when s.srv then coalesce(nullif(s.x->>'comprimento_mm', '')::numeric, u.comprimento_mm) end,
           case when s.srv then coalesce(nullif(s.x->>'perda_mm', '')::numeric, u.perda_mm) end,
           case when s.srv then nullif(s.x->>'barra_mm', '')::numeric end,
           case when s.srv then s.pb end,
           case when s.srv and s.pb > 0 then ceil((s.x->>'quantidade')::numeric / s.pb) end,
           case when s.sv is not null then false else coalesce((s.x->>'uso_consumo')::boolean, false) end,
           nullif(s.x->>'data_entrega_prevista', '')::date
    from (select x, coalesce((x->>'tipo_item') = 'servico_usinagem', false) as srv, nullif(x->>'servico_id', '')::bigint as sv,
                 floor(nullif(x->>'barra_mm', '')::numeric / nullif(coalesce(nullif(x->>'comprimento_mm', '')::numeric, u2.comprimento_mm) + coalesce(nullif(x->>'perda_mm', '')::numeric, u2.perda_mm, 0), 0)) as pb
          from jsonb_array_elements(p_itens) x
          left join public.produto_usinagem u2 on u2.produto_id = nullif(x->>'produto_id', '')::bigint
          where coalesce((x->>'quantidade')::numeric, 0) > 0) s
    left join public.servicos sv on sv.id = s.sv
    left join public.produto_usinagem u on u.produto_id = nullif(s.x->>'produto_id', '')::bigint;
    update public.pedidos_compra set data_entrega_prevista = (select min(data_entrega_prevista) from public.pedidos_compra_itens where pedido_id = v_id)
     where id = v_id and data_entrega_prevista is null;
  end if;
  perform public.pc_recalcular(v_id);
  return v_id;
end $function$;
revoke execute on function public.pedido_compra_salvar(jsonb, jsonb) from public, anon;
grant execute on function public.pedido_compra_salvar(jsonb, jsonb) to authenticated;

-- ---------- Previsão no contas a pagar: parcelas a partir da entrega de cada item ----------
create or replace function public.pc_projetar(p_id bigint)
returns integer language plpgsql security definer set search_path = public as $function$
declare p public.pedidos_compra; v_pend numeric; v_dias int[]; v_n int; v_cat bigint; v_i int; v_v numeric; v_acum numeric;
  v_grupos jsonb; v_ng int; v_g int; v_parte numeric; v_partes numeric := 0; v_peso_tot numeric; v_data date; v_base date; v_k int := 0;
begin
  select * into p from public.pedidos_compra where id = p_id;
  delete from public.titulos_pagar where pedido_compra_id = p_id and projecao and coalesce(valor_pago, 0) = 0 and origem = 'pedido_compra'
     and not (coalesce(origem_ref, '{}') ? 'recebimento_id');
  if p.pagamento_antecipado then
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
      'Pedido ' || p.numero || ' · PAGAMENTO ANTECIPADO' || case when p.pagamento_urgente then ' · URGENTE' else '' end,
      (select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) from public.pedidos_compra_itens i left join public.produtos pr on pr.id = i.produto_id
        where i.pedido_id = p_id group by 1 order by sum(i.valor_total) desc nulls last limit 1),
      p.valor_total, current_date, coalesce(p.pagamento_data, current_date), coalesce(p.pagamento_data, current_date), p.conta_bancaria_id, p.forma_pagamento_id,
      p.pagamento_codigo_barras, p.pagamento_pix, p.pagamento_link, p.pagamento_urgente, 1, 1, 'pedido_compra',
      jsonb_build_object('pedido_compra', p.numero, 'antecipado', true), false, p_id, 'aberto', 0, p.valor_total,
      'Pagamento antecipado do pedido aprovado (pagar antes de receber). Na entrada da mercadoria não nasce outro título.');
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
end $function$;
revoke execute on function public.pc_projetar(bigint) from public, anon, authenticated;

select public.ligar_auditoria('pedidos_compra_itens');
select public.ligar_tempo_real('pedidos_compra_itens');
