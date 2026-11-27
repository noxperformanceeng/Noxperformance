-- =====================================================================
-- 188 · Pedido de venda: salvar sem apagar e recriar os itens
-- O que muda:
--   - Ao salvar um pedido de venda, os itens que já existem são ATUALIZADOS (mantêm o mesmo id),
--     os novos são incluídos e só os removidos na tela são apagados.
--   - Antes o sistema apagava todos os itens e criava de novo; com isso, editar um pedido que já
--     tinha entrega (entrega parcial / expedição) dava erro, porque a entrega aponta para o item.
--   - Item que já tem entrega não pode ser removido do pedido (mensagem clara para o usuário).
--   - Resto da regra igual: pedido com título/NF só altera itens com a permissão do gestor.
-- Substitui o "complemento_entregas_parciais.sql" de 26/10 na parte do salvamento.
-- Dá para desfazer: é só voltar a função anterior (026/065).
-- =====================================================================
create or replace function public.salvar_pedido_venda(p_pedido jsonb, p_itens jsonb, p_encargos jsonb default null)
returns bigint
language plpgsql
set search_path = public
as $function$
declare v_id bigint := nullif(p_pedido->>'id', '')::bigint; v_dados jsonb := p_pedido - 'id'; v_tem_titulo boolean; v_preso text;
begin
  if v_id is null then
    insert into public.pedidos_venda select * from jsonb_populate_record(null::public.pedidos_venda,
      v_dados || jsonb_build_object('id', nextval(pg_get_serial_sequence('public.pedidos_venda', 'id')), 'criado_em', now(), 'atualizado_em', now(),
        'situacao', coalesce(nullif(v_dados->>'situacao', ''), 'aberto'), 'origem', coalesce(nullif(v_dados->>'origem', ''), 'manual'),
        'desconto', coalesce(v_dados->'desconto', '0'), 'frete_cliente', coalesce(v_dados->'frete_cliente', '0'), 'outras_receitas', coalesce(v_dados->'outras_receitas', '0'),
        'valor_produtos', 0, 'valor_total', 0, 'encargos', 0, 'valor_liquido', 0, 'entrega_parcial', coalesce(v_dados->'entrega_parcial', 'false')))
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
        forma_pagamento_id, data_prev_recebimento, nf_numero, nf_serie, nf_chave, nf_data, observacoes, observacoes_internas, entrega_parcial) =
      (select r.empresa_id, r.canal_id, r.tipo, r.numero_externo, r.pack_id, r.envio_id, r.codigo_rastreio, r.logistica, r.cliente_id, r.cliente_nome,
        r.representante_id, r.vendedor_id, r.data_pedido, r.data_envio, r.data_entrega, case when p.situacao = 'cancelado' then p.situacao else coalesce(r.situacao, p.situacao) end,
        coalesce(r.desconto, 0), coalesce(r.frete_cliente, 0), coalesce(r.outras_receitas, 0), r.condicao_pagamento_id,
        r.forma_pagamento_id, r.data_prev_recebimento, r.nf_numero, r.nf_serie, r.nf_chave, r.nf_data, r.observacoes, r.observacoes_internas, coalesce(r.entrega_parcial, false)
       from jsonb_populate_record(p, v_dados) r)
    where p.id = v_id;
    if not found then raise exception 'Pedido % não encontrado ou sem permissão', v_id; end if;
  end if;

  if p_itens is not null then
    -- itens removidos na tela: não pode remover o que já tem entrega
    select string_agg(coalesce(pr.codigo, i.sku, i.descricao, '#' || i.id), ', ') into v_preso
    from public.pedidos_venda_itens i left join public.produtos pr on pr.id = i.produto_id
    where i.pedido_id = v_id
      and i.id not in (select (x->>'id')::bigint from jsonb_array_elements(p_itens) x where nullif(x->>'id', '') is not null and coalesce((x->>'quantidade')::numeric, 0) > 0)
      and exists (select 1 from public.pedidos_venda_entregas_itens e where e.pedido_item_id = i.id);
    if v_preso is not null then
      raise exception 'Item já tem entrega e não pode ser removido do pedido: %. Cancele a entrega antes.', v_preso;
    end if;
    delete from public.pedidos_venda_itens i
    where i.pedido_id = v_id
      and i.id not in (select (x->>'id')::bigint from jsonb_array_elements(p_itens) x where nullif(x->>'id', '') is not null and coalesce((x->>'quantidade')::numeric, 0) > 0);
    -- itens que já existem: atualiza (mantém o id, que a entrega usa)
    update public.pedidos_venda_itens i set produto_id = nullif(x->>'produto_id', '')::bigint, anuncio_ref = nullif(x->>'anuncio_ref', '')::bigint,
        anuncio_id = nullif(x->>'anuncio_id', ''), variacao_id = nullif(x->>'variacao_id', ''), sku = nullif(x->>'sku', ''), descricao = x->>'descricao',
        quantidade = (x->>'quantidade')::numeric, valor_unitario = coalesce((x->>'valor_unitario')::numeric, 0), desconto = coalesce((x->>'desconto')::numeric, 0)
    from jsonb_array_elements(p_itens) x
    where nullif(x->>'id', '') is not null and i.id = (x->>'id')::bigint and i.pedido_id = v_id and coalesce((x->>'quantidade')::numeric, 0) > 0
      and (i.produto_id, i.anuncio_ref, i.anuncio_id, i.variacao_id, i.sku, i.descricao, i.quantidade, i.valor_unitario, i.desconto)
          is distinct from (nullif(x->>'produto_id', '')::bigint, nullif(x->>'anuncio_ref', '')::bigint, nullif(x->>'anuncio_id', ''), nullif(x->>'variacao_id', ''),
            nullif(x->>'sku', ''), x->>'descricao', (x->>'quantidade')::numeric, coalesce((x->>'valor_unitario')::numeric, 0), coalesce((x->>'desconto')::numeric, 0));
    -- itens novos (sem id, ou com id que não é deste pedido)
    insert into public.pedidos_venda_itens (pedido_id, produto_id, anuncio_ref, anuncio_id, variacao_id, sku, descricao, quantidade, valor_unitario, desconto)
    select v_id, nullif(x->>'produto_id', '')::bigint, nullif(x->>'anuncio_ref', '')::bigint, nullif(x->>'anuncio_id', ''), nullif(x->>'variacao_id', ''),
           nullif(x->>'sku', ''), x->>'descricao', (x->>'quantidade')::numeric, coalesce((x->>'valor_unitario')::numeric, 0), coalesce((x->>'desconto')::numeric, 0)
    from jsonb_array_elements(p_itens) x
    where coalesce((x->>'quantidade')::numeric, 0) > 0
      and not exists (select 1 from public.pedidos_venda_itens i where nullif(x->>'id', '') is not null and i.id = (x->>'id')::bigint and i.pedido_id = v_id);
  end if;

  if p_encargos is not null then
    delete from public.pedidos_venda_encargos where pedido_id = v_id;
    insert into public.pedidos_venda_encargos (pedido_id, tipo_codigo, descricao, categoria_financeira_id, valor)
    select v_id, nullif(x->>'tipo_codigo', ''), x->>'descricao', nullif(x->>'categoria_financeira_id', '')::bigint, (x->>'valor')::numeric
    from jsonb_array_elements(p_encargos) x where coalesce((x->>'valor')::numeric, 0) <> 0;
  end if;
  perform public.pedido_venda_recalcular(v_id);
  return v_id;
end $function$;
