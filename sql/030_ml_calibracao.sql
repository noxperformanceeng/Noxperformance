-- =====================================================================
-- ERP NOX · 030_ml_calibracao.sql
-- Calibração com a primeira venda real do ML (14/10/2026):
--  - A tarifa de venda chega no pedido (sale_fee) alguns instantes depois; o aviso inicial veio sem ela e o
--    título ficou maior que o real. Agora, enquanto o título não tiver recebimento, cada novo aviso/busca
--    atualiza itens, tarifas, valor e composição do título.
--  - O Mercado Pago informa o líquido que vai cair (net_received_amount). Se a conta (total − tarifas) não bater,
--    a diferença entra como encargo "diferença a menor/maior" — o título fica exatamente no valor do repasse.
--  - Data de liberação convertida no fuso de São Paulo.
-- =====================================================================

-- O pedido de marketplace é atualizado pela integração mesmo com título (sem recebimento)
create or replace function public.salvar_pedido_venda(p_pedido jsonb, p_itens jsonb, p_encargos jsonb default null)
returns bigint language plpgsql security invoker set search_path = public as $$
declare v_id bigint := nullif(p_pedido->>'id', '')::bigint; v_dados jsonb := p_pedido - 'id'; v_tem_titulo boolean;
begin
  if v_id is null then
    insert into public.pedidos_venda select * from jsonb_populate_record(null::public.pedidos_venda,
      v_dados || jsonb_build_object('id', nextval(pg_get_serial_sequence('public.pedidos_venda', 'id')), 'criado_em', now(), 'atualizado_em', now(),
        'situacao', coalesce(nullif(v_dados->>'situacao', ''), 'aberto'), 'origem', coalesce(nullif(v_dados->>'origem', ''), 'manual'),
        'desconto', coalesce(v_dados->'desconto', '0'), 'frete_cliente', coalesce(v_dados->'frete_cliente', '0'), 'outras_receitas', coalesce(v_dados->'outras_receitas', '0'),
        'valor_produtos', 0, 'valor_total', 0, 'encargos', 0, 'valor_liquido', 0))
    returning id into v_id;
  else
    select exists (select 1 from public.titulos_receber where pedido_venda_id = v_id and situacao <> 'cancelado') into v_tem_titulo;
    if (v_tem_titulo or exists (select 1 from public.pedidos_venda where id = v_id and nf_numero is not null))
       and p_itens is not null and not public.pode_acao('pedidos.editar_faturado')
       and coalesce(current_setting('nox.pedido_rpc', true), '') <> '1' then
      raise exception 'Pedido já faturado/com título: alterar itens só com permissão do gestor';
    end if;
    update public.pedidos_venda p set (empresa_id, canal_id, tipo, numero_externo, pack_id, envio_id, codigo_rastreio, logistica, cliente_id, cliente_nome,
        representante_id, vendedor_id, data_pedido, data_envio, data_entrega, situacao, desconto, frete_cliente, outras_receitas, condicao_pagamento_id,
        forma_pagamento_id, data_prev_recebimento, nf_numero, nf_serie, nf_chave, nf_data, observacoes, observacoes_internas) =
      (select r.empresa_id, r.canal_id, r.tipo, r.numero_externo, r.pack_id, r.envio_id, r.codigo_rastreio, r.logistica, r.cliente_id, r.cliente_nome,
        r.representante_id, r.vendedor_id, r.data_pedido, r.data_envio, r.data_entrega, case when p.situacao = 'cancelado' then p.situacao else coalesce(r.situacao, p.situacao) end,
        coalesce(r.desconto, 0), coalesce(r.frete_cliente, 0), coalesce(r.outras_receitas, 0), r.condicao_pagamento_id,
        r.forma_pagamento_id, r.data_prev_recebimento, r.nf_numero, r.nf_serie, r.nf_chave, r.nf_data, r.observacoes, r.observacoes_internas
       from jsonb_populate_record(p, v_dados) r)
    where p.id = v_id;
    if not found then raise exception 'Pedido % não encontrado ou sem permissão', v_id; end if;
  end if;
  if p_itens is not null then
    delete from public.pedidos_venda_itens where pedido_id = v_id;
    insert into public.pedidos_venda_itens (pedido_id, produto_id, anuncio_ref, anuncio_id, variacao_id, sku, descricao, quantidade, valor_unitario, desconto)
    select v_id, nullif(x->>'produto_id', '')::bigint, nullif(x->>'anuncio_ref', '')::bigint, nullif(x->>'anuncio_id', ''), nullif(x->>'variacao_id', ''),
           nullif(x->>'sku', ''), x->>'descricao', (x->>'quantidade')::numeric, coalesce((x->>'valor_unitario')::numeric, 0), coalesce((x->>'desconto')::numeric, 0)
    from jsonb_array_elements(p_itens) x where coalesce((x->>'quantidade')::numeric, 0) > 0;
  end if;
  if p_encargos is not null then
    delete from public.pedidos_venda_encargos where pedido_id = v_id;
    insert into public.pedidos_venda_encargos (pedido_id, tipo_codigo, descricao, categoria_financeira_id, valor)
    select v_id, nullif(x->>'tipo_codigo', ''), x->>'descricao', nullif(x->>'categoria_financeira_id', '')::bigint, (x->>'valor')::numeric
    from jsonb_array_elements(p_encargos) x where coalesce((x->>'valor')::numeric, 0) <> 0;
  end if;
  perform public.pedido_venda_recalcular(v_id);
  return v_id;
end $$;

create or replace function public.processar_pedido_ml(p_ml_order_id bigint)
returns bigint language plpgsql security definer set search_path = public as $$
declare b record; c record; o jsonb; v_id bigint; v_sit text; v_status text; v_data date; v_prev date; v_recebido boolean;
        it jsonb; v_cat_fee bigint; v_cat_fin bigint; v_cat_env bigint; v_cat_dif bigint; v_fee numeric(14,2) := 0; v_fin numeric(14,2) := 0; v_env numeric(14,2) := 0;
        v_fee_mp numeric(14,2); v_fin_mp numeric(14,2); v_env_mp numeric(14,2); v_net numeric(14,2); v_total numeric(14,2); v_dif numeric(14,2);
        pg jsonb; fd jsonb; v_comprador text; v_itens jsonb; v_encs jsonb; t record; v_rateio jsonb; v_cat_rec bigint;
begin
  select * into b from public.ml_pedidos_brutos where ml_order_id = p_ml_order_id;
  if not found then raise exception 'Venda % não encontrada', p_ml_order_id; end if;
  select * into c from public.canais_venda where id = b.canal_id;
  o := b.ordem;
  v_status := o->>'status';
  v_data := ((o->>'date_created')::timestamptz at time zone 'America/Sao_Paulo')::date;
  v_comprador := nullif(trim(concat_ws(' ', o->'buyer'->>'first_name', o->'buyer'->>'last_name')), '');
  v_comprador := coalesce(v_comprador, o->'buyer'->>'nickname', 'Comprador ML ' || coalesce(o->'buyer'->>'id', ''));
  -- pagamentos aprovados: tarifas detalhadas (quando vierem), líquido e data de liberação
  for pg in select * from jsonb_array_elements(coalesce(b.pagamentos, '[]'::jsonb)) loop
    if pg->>'status' in ('approved', 'refunded', 'charged_back', 'in_mediation') then
      for fd in select * from jsonb_array_elements(coalesce(pg->'fee_details', '[]'::jsonb)) loop
        if fd->>'type' in ('ml_fee', 'application_fee', 'mercadopago_fee') then v_fee_mp := coalesce(v_fee_mp, 0) + (fd->>'amount')::numeric;
        elsif fd->>'type' = 'financing_fee' then v_fin_mp := coalesce(v_fin_mp, 0) + (fd->>'amount')::numeric;
        elsif fd->>'type' = 'shipping_fee' then v_env_mp := coalesce(v_env_mp, 0) + (fd->>'amount')::numeric;
        end if;
      end loop;
      if pg->'transaction_details'->>'net_received_amount' is not null then
        v_net := coalesce(v_net, 0) + (pg->'transaction_details'->>'net_received_amount')::numeric;
      end if;
      v_prev := greatest(v_prev, (nullif(pg->>'money_release_date', '')::timestamptz at time zone 'America/Sao_Paulo')::date);
    end if;
  end loop;
  select coalesce(sum(coalesce((x->>'sale_fee')::numeric, 0) * coalesce((x->>'quantity')::numeric, 1)), 0) into v_fee
    from jsonb_array_elements(coalesce(o->'order_items', '[]'::jsonb)) x;
  select coalesce(sum(coalesce((s->>'cost')::numeric, 0)), 0) into v_env
    from jsonb_array_elements(coalesce(b.envio_custos->'senders', '[]'::jsonb)) s;
  v_fee := coalesce(v_fee_mp, v_fee); v_env := coalesce(v_env_mp, v_env); v_fin := coalesce(v_fin_mp, 0);
  v_sit := case when v_status = 'cancelled' then 'cancelado' when v_status in ('paid', 'partially_paid', 'partially_refunded') then 'aberto' else 'orcamento' end;

  select id into v_id from public.pedidos_venda where canal_id = b.canal_id and numero_externo = o->>'id';
  perform set_config('nox.pedido_rpc', '1', true);
  if v_id is null then
    insert into public.pedidos_venda (empresa_id, canal_id, tipo, numero_externo, pack_id, envio_id, cliente_nome, data_pedido, situacao,
      data_prev_recebimento, origem, origem_ref)
    values (c.empresa_id, b.canal_id, 'marketplace', o->>'id', o->>'pack_id', o->'shipping'->>'id', v_comprador, v_data,
      case when v_sit = 'cancelado' then 'orcamento' else v_sit end, v_prev, 'api', jsonb_build_object('ml_status', v_status, 'ml_order_id', o->>'id'))
    returning id into v_id;
  else
    update public.pedidos_venda set pack_id = o->>'pack_id', envio_id = o->'shipping'->>'id', cliente_nome = coalesce(cliente_nome, v_comprador),
      data_prev_recebimento = coalesce(v_prev, data_prev_recebimento), origem_ref = coalesce(origem_ref, '{}') || jsonb_build_object('ml_status', v_status)
    where id = v_id;
  end if;

  -- já recebido: não mexe mais (diferenças ficam para a conciliação)
  select exists (select 1 from public.titulos_receber where pedido_venda_id = v_id and situacao <> 'cancelado' and valor_recebido > 0) into v_recebido;
  if not v_recebido then
    for it in select * from jsonb_array_elements(coalesce(o->'order_items', '[]'::jsonb)) loop
      insert into public.anuncios (canal_id, anuncio_id, variacao_id, sku, titulo, produto_id)
      values (b.canal_id, it->'item'->>'id', coalesce(it->'item'->>'variation_id', ''), nullif(it->'item'->>'seller_sku', ''), it->'item'->>'title',
              (select id from public.produtos where upper(codigo) = upper(nullif(it->'item'->>'seller_sku', '')) limit 1))
      on conflict (canal_id, anuncio_id, variacao_id) do update set sku = coalesce(excluded.sku, anuncios.sku), titulo = excluded.titulo,
         produto_id = coalesce(anuncios.produto_id, excluded.produto_id);
    end loop;
    select coalesce(jsonb_agg(jsonb_build_object('anuncio_id', x->'item'->>'id', 'variacao_id', x->'item'->>'variation_id', 'sku', x->'item'->>'seller_sku',
             'descricao', x->'item'->>'title', 'quantidade', coalesce((x->>'quantity')::numeric, 1), 'valor_unitario', coalesce((x->>'unit_price')::numeric, 0))), '[]'),
           coalesce(sum(coalesce((x->>'quantity')::numeric, 1) * coalesce((x->>'unit_price')::numeric, 0)), 0)
      into v_itens, v_total from jsonb_array_elements(coalesce(o->'order_items', '[]'::jsonb)) x;
    select categoria_financeira_id into v_cat_fee from public.encargos_tipos where plataforma = 'mercado_livre' and codigo = 'tarifa_venda';
    select categoria_financeira_id into v_cat_fin from public.encargos_tipos where plataforma = 'mercado_livre' and codigo = 'parcelamento';
    select categoria_financeira_id into v_cat_env from public.encargos_tipos where plataforma = 'mercado_livre'
      and codigo = case when b.envio_custos->>'logistic_type' = 'fulfillment' or o->'shipping'->>'logistic_type' = 'fulfillment' then 'envio_full' else 'envio' end;
    -- conferência com o líquido do Mercado Pago
    v_dif := case when v_net is not null then round((v_total - v_fee - v_fin - v_env) - v_net, 2) else 0 end;
    select categoria_financeira_id into v_cat_dif from public.encargos_tipos where plataforma = 'mercado_livre'
      and codigo = case when v_dif > 0 then 'diferenca_debito' else 'diferenca_credito' end;
    v_encs := jsonb_build_array(
      jsonb_build_object('tipo_codigo', 'tarifa_venda', 'descricao', 'Tarifa de venda', 'categoria_financeira_id', v_cat_fee, 'valor', v_fee),
      jsonb_build_object('tipo_codigo', 'parcelamento', 'descricao', 'Taxa de parcelamento', 'categoria_financeira_id', v_cat_fin, 'valor', v_fin),
      jsonb_build_object('tipo_codigo', 'envio', 'descricao', 'Tarifa de envio', 'categoria_financeira_id', v_cat_env, 'valor', v_env),
      jsonb_build_object('tipo_codigo', case when v_dif > 0 then 'diferenca_debito' else 'diferenca_credito' end,
        'descricao', 'Diferença para o líquido do Mercado Pago', 'categoria_financeira_id', v_cat_dif, 'valor', v_dif));
    perform public.salvar_pedido_venda(jsonb_build_object('id', v_id), v_itens, v_encs);

    -- título em aberto sem recebimento: acompanha o pedido (valor, liberação e composição)
    select * into t from public.titulos_receber where pedido_venda_id = v_id and situacao = 'aberto' and valor_recebido = 0 order by id limit 1;
    if found and v_sit = 'aberto' then
      v_cat_rec := coalesce(c.categoria_receita_id, (select id from public.categorias_financeiras where codigo = '1.01.001'));
      select jsonb_build_array(jsonb_build_object('categoria_financeira_id', v_cat_rec, 'valor', p.valor_produtos - p.desconto + p.outras_receitas,
               'tipo_codigo', 'receita', 'observacao', 'Receita bruta dos produtos'))
             || coalesce((select jsonb_agg(jsonb_build_object('categoria_financeira_id', e.categoria_financeira_id, 'valor', -sum_v, 'tipo_codigo', e.tipo_codigo, 'observacao', e.d))
                          from (select categoria_financeira_id, tipo_codigo, string_agg(coalesce(descricao, tipo_codigo), ', ') d, sum(valor) sum_v
                                from public.pedidos_venda_encargos where pedido_id = v_id group by 1, 2) e), '[]'),
             p.valor_liquido
        into v_rateio, v_total
        from public.pedidos_venda p where p.id = v_id;
      if v_total > 0 then
        perform public.salvar_titulo_receber(jsonb_build_object('id', t.id, 'valor', v_total,
          'data_vencimento', greatest(coalesce(v_prev, t.data_vencimento), t.data_emissao)), v_rateio);
      end if;
    end if;
  end if;

  if v_sit = 'cancelado' then
    update public.titulos_receber set situacao = 'cancelado', motivo_cancelamento = 'Venda cancelada no Mercado Livre'
     where pedido_venda_id = v_id and situacao = 'aberto' and valor_recebido = 0;
    update public.pedidos_venda set situacao = 'cancelado', motivo_cancelamento = coalesce(motivo_cancelamento, 'Cancelada no Mercado Livre')
     where id = v_id and situacao <> 'cancelado';
  elsif v_sit = 'aberto' then
    update public.pedidos_venda set situacao = 'aberto' where id = v_id and situacao = 'orcamento';
    perform public.gerar_titulos_pedido_interno(v_id);
  end if;
  perform set_config('nox.pedido_rpc', '', true);
  update public.ml_pedidos_brutos set processado_em = now(), erro = null, pedido_venda_id = v_id where ml_order_id = p_ml_order_id;
  return v_id;
end $$;
revoke execute on function public.processar_pedido_ml(bigint) from public, anon, authenticated;
grant execute on function public.processar_pedido_ml(bigint) to service_role;
