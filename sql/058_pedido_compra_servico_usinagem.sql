-- ============================================================================
-- 058 · Pedido de compra: serviço de usinagem (terceirizado)
--   Na usinagem a NOX manda o material (barra comprada para esse fim, tirada do nosso estoque) e paga só o serviço.
--   Por isso o item do pedido passa a ter um tipo:
--     · normal            → como sempre (compra de produto);
--     · servico_usinagem  → o item é a PEÇA que volta usinada (produto_id), a quantidade é de peças, o preço é o do
--                           serviço por peça (vem da ficha de usinagem) e o pedido mostra o MATERIAL A ENVIAR
--                           (barras = peças ÷ peças por barra, igual à planilha de reposição).
--   Recebimento: as peças que voltam são contadas como recebidas (entrada de produto acabado/semiacabado); o serviço
--   em si não é produto de estoque. Enquanto não houver o módulo de Estoque, a entrada fica só registrada no pedido.
--   Sem nota fiscal por enquanto: o recebimento que traz só itens de serviço de usinagem pode ser registrado sem NF
--   (gera o contas a pagar normalmente, com o documento "Pedido PC-xxxx"). Recebimento com produto exige a NF.
--   Quem trabalha em Compras também passa a enxergar a ficha de usinagem (só leitura) para montar o pedido.
-- ============================================================================
alter table public.pedidos_compra_itens add column if not exists tipo_item text not null default 'normal';
alter table public.pedidos_compra_itens add column if not exists material text;             -- material bruto que a NOX envia
alter table public.pedidos_compra_itens add column if not exists comprimento_mm numeric;      -- comprimento da peça
alter table public.pedidos_compra_itens add column if not exists perda_mm numeric;            -- perda de corte por peça
alter table public.pedidos_compra_itens add column if not exists barra_mm numeric;            -- comprimento da barra enviada
alter table public.pedidos_compra_itens add column if not exists pecas_por_barra numeric;     -- calculado ao salvar
alter table public.pedidos_compra_itens add column if not exists barras_enviar numeric;       -- calculado ao salvar

alter table public.pedidos_compra_itens drop constraint if exists pedidos_compra_itens_tipo_chk;
alter table public.pedidos_compra_itens add constraint pedidos_compra_itens_tipo_chk
  check (tipo_item in ('normal', 'servico_usinagem') and (tipo_item = 'normal' or produto_id is not null));

-- compras enxerga a ficha de usinagem (somente leitura)
drop policy if exists "ver produto_usinagem compras" on public.produto_usinagem;
create policy "ver produto_usinagem compras" on public.produto_usinagem for select to authenticated using ((select public.pode('compras')));

-- salvar: grava o tipo do item e calcula o material a enviar
create or replace function public.pedido_compra_salvar(p_pedido jsonb, p_itens jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p_pedido->>'id', '')::bigint; d public.pedidos_compra; v_sit text; v_cat_usi bigint;
begin
  d := jsonb_populate_record(null::public.pedidos_compra, p_pedido - 'id' - 'numero');
  if v_id is null then
    if not public.pode('compras', 'criar') then raise exception 'Sem permissão para incluir pedidos de compra'; end if;
    insert into public.pedidos_compra (empresa_id, fornecedor_id, comprador_id, data_pedido, data_entrega_prevista, condicao_pagamento_id, forma_pagamento_id,
      conta_bancaria_id, frete, outras_despesas, desconto, contato_fornecedor, email_fornecedor, whatsapp_fornecedor, observacoes, observacoes_internas)
    values (d.empresa_id, d.fornecedor_id, coalesce(d.comprador_id, auth.uid()), coalesce(d.data_pedido, current_date), d.data_entrega_prevista, d.condicao_pagamento_id,
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
      perform public.pc_projetar(v_id);
      return v_id;
    end if;
    update public.pedidos_compra set empresa_id = d.empresa_id, fornecedor_id = d.fornecedor_id, data_pedido = coalesce(d.data_pedido, data_pedido),
      data_entrega_prevista = d.data_entrega_prevista, condicao_pagamento_id = d.condicao_pagamento_id, forma_pagamento_id = d.forma_pagamento_id,
      conta_bancaria_id = d.conta_bancaria_id, frete = coalesce(d.frete, 0), outras_despesas = coalesce(d.outras_despesas, 0), desconto = coalesce(d.desconto, 0),
      contato_fornecedor = d.contato_fornecedor, email_fornecedor = d.email_fornecedor, whatsapp_fornecedor = d.whatsapp_fornecedor,
      observacoes = d.observacoes, observacoes_internas = d.observacoes_internas
    where id = v_id;
    perform public.pc_evento(v_id, 'alterado', 'Pedido alterado');
  end if;
  if p_itens is not null then
    if exists (select 1 from jsonb_array_elements(p_itens) x where x->>'tipo_item' = 'servico_usinagem' and nullif(x->>'produto_id', '') is null) then
      raise exception 'Serviço de usinagem precisa da peça (produto) que volta usinada';
    end if;
    select id into v_cat_usi from public.categorias_financeiras where codigo = '3.05.005' limit 1;   -- TERCEIRIZADO - USINAGEM
    delete from public.pedidos_compra_itens where pedido_id = v_id;
    insert into public.pedidos_compra_itens (pedido_id, produto_id, descricao, unidade, codigo_fornecedor, quantidade, valor_unitario, desconto, categoria_financeira_id, observacao,
      tipo_item, material, comprimento_mm, perda_mm, barra_mm, pecas_por_barra, barras_enviar)
    select v_id, nullif(s.x->>'produto_id', '')::bigint,
           coalesce(nullif(s.x->>'descricao', ''), case when s.srv then 'SERVIÇO DE USINAGEM · ' else '' end || (select descricao from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint), 'Item'),
           coalesce(nullif(s.x->>'unidade', ''), case when s.srv then 'PÇ' end), nullif(s.x->>'codigo_fornecedor', ''), (s.x->>'quantidade')::numeric,
           coalesce((s.x->>'valor_unitario')::numeric, 0), coalesce((s.x->>'desconto')::numeric, 0),
           coalesce(nullif(s.x->>'categoria_financeira_id', '')::bigint, case when s.srv then v_cat_usi end,
                    (select categoria_financeira_id from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint)),
           nullif(s.x->>'observacao', ''),
           case when s.srv then 'servico_usinagem' else 'normal' end,
           case when s.srv then coalesce(nullif(s.x->>'material', ''), u.material) end,
           case when s.srv then coalesce(nullif(s.x->>'comprimento_mm', '')::numeric, u.comprimento_mm) end,
           case when s.srv then coalesce(nullif(s.x->>'perda_mm', '')::numeric, u.perda_mm) end,
           case when s.srv then nullif(s.x->>'barra_mm', '')::numeric end,
           case when s.srv then s.pb end,
           case when s.srv and s.pb > 0 then ceil((s.x->>'quantidade')::numeric / s.pb) end
    from (select x, (x->>'tipo_item') = 'servico_usinagem' as srv,
                 floor(nullif(x->>'barra_mm', '')::numeric / nullif(coalesce(nullif(x->>'comprimento_mm', '')::numeric, u2.comprimento_mm) + coalesce(nullif(x->>'perda_mm', '')::numeric, u2.perda_mm, 0), 0)) as pb
          from jsonb_array_elements(p_itens) x
          left join public.produto_usinagem u2 on u2.produto_id = nullif(x->>'produto_id', '')::bigint
          where coalesce((x->>'quantidade')::numeric, 0) > 0) s
    left join public.produto_usinagem u on u.produto_id = nullif(s.x->>'produto_id', '')::bigint;
  end if;
  perform public.pc_recalcular(v_id);
  return v_id;
end $$;
revoke execute on function public.pedido_compra_salvar(jsonb, jsonb) from public, anon;
grant execute on function public.pedido_compra_salvar(jsonb, jsonb) to authenticated;

-- receber: pedido só de serviço de usinagem pode ser recebido sem NF (documento "Pedido PC-xxxx")
create or replace function public.pedido_compra_receber(p_id bigint, p_nf jsonb, p_itens jsonb, p_parcelas jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare p public.pedidos_compra; v_rec bigint; v_valor numeric; v_soma numeric; x jsonb; v_n int; v_i int := 0; v_tid bigint;
        v_cats jsonb; v_c record; v_acum numeric; v_parte numeric; v_ncat int; v_k int; v_nf text; v_venc date; v_item_tot numeric;
        v_servico boolean; v_sem_nf boolean; v_doc text;
begin
  select * into p from public.pedidos_compra where id = p_id for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if not (public.pode('compras', 'alterar') or public.pode('pagar', 'criar')) then raise exception 'Sem permissão para registrar recebimento'; end if;
  if p.situacao not in ('aprovado','enviado','recebido_parcial') then raise exception 'Pedido precisa estar aprovado para receber'; end if;
  select count(*) > 0 and bool_and(i.tipo_item = 'servico_usinagem') into v_servico
    from jsonb_to_recordset(coalesce(p_itens, '[]')) r(item_id bigint, quantidade numeric)
    join public.pedidos_compra_itens i on i.id = r.item_id and i.pedido_id = p_id where r.quantidade > 0;
  v_nf := nullif(trim(p_nf->>'numero'), '');
  if v_nf is not null and upper(v_nf) = 'SEM NF' then raise exception 'Informe o número da NF'; end if;
  v_sem_nf := v_nf is null and coalesce(v_servico, false);
  if v_nf is null then
    if v_sem_nf then v_nf := 'SEM NF'; else raise exception 'Informe o número da NF'; end if;
  end if;
  v_doc := case when v_sem_nf then 'Pedido ' || p.numero else 'NF ' || v_nf end;
  v_valor := round((p_nf->>'valor')::numeric, 2);
  if coalesce(v_valor, 0) <= 0 then raise exception 'Informe o valor %', case when v_sem_nf then 'do serviço' else 'da NF' end; end if;
  select coalesce(sum(round((y->>'valor')::numeric, 2)), 0), count(*) into v_soma, v_n from jsonb_array_elements(p_parcelas) y;
  if v_n = 0 then raise exception 'Informe as parcelas'; end if;
  if abs(v_soma - v_valor) > 0.01 then raise exception 'Soma das parcelas (%) diferente do valor (%)', v_soma, v_valor; end if;
  for x in select * from jsonb_array_elements(coalesce(p_itens, '[]')) loop
    if coalesce((x->>'quantidade')::numeric, 0) > 0 then
      update public.pedidos_compra_itens set quantidade_recebida = quantidade_recebida + (x->>'quantidade')::numeric
       where id = (x->>'item_id')::bigint and pedido_id = p_id;
    end if;
  end loop;
  insert into public.pedidos_compra_recebimentos (pedido_id, nf_numero, nf_serie, nf_chave, nf_data_emissao, data_recebimento, valor_nf, itens, observacao)
  values (p_id, v_nf, nullif(p_nf->>'serie', ''), nullif(p_nf->>'chave', ''), coalesce(nullif(p_nf->>'data_emissao', '')::date, current_date),
          coalesce(nullif(p_nf->>'data_recebimento', '')::date, current_date), v_valor, p_itens, nullif(p_nf->>'observacao', ''))
  returning id into v_rec;
  select coalesce(jsonb_agg(jsonb_build_object('c', c, 'v', v)), '[]'), count(*) into v_cats, v_ncat from (
    select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) c, sum(round(i.valor_total * (r.quantidade / i.quantidade), 2)) v
    from jsonb_to_recordset(coalesce(p_itens, '[]')) r(item_id bigint, quantidade numeric)
    join public.pedidos_compra_itens i on i.id = r.item_id and i.pedido_id = p_id
    left join public.produtos pr on pr.id = i.produto_id
    where r.quantidade > 0 group by 1) s;
  select coalesce(sum((e->>'v')::numeric), 0) into v_item_tot from jsonb_array_elements(v_cats) e;
  for x in select * from jsonb_array_elements(p_parcelas) loop
    v_i := v_i + 1; v_venc := (x->>'vencimento')::date;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento,
      data_programada, conta_bancaria_id, forma_pagamento_id, codigo_barras, parcela, parcelas, origem, origem_ref, projecao, pedido_compra_id, situacao, valor_pago, saldo)
    values (p.empresa_id, p.fornecedor_id, v_doc, case when v_sem_nf then v_doc || ' · serviço de usinagem' else v_doc || ' · ' || p.numero end,
      case when v_ncat = 1 then ((v_cats->0)->>'c')::bigint end, round((x->>'valor')::numeric, 2),
      coalesce(nullif(p_nf->>'data_emissao', '')::date, current_date), v_venc, v_venc, p.conta_bancaria_id, p.forma_pagamento_id, nullif(x->>'codigo_barras', ''),
      v_i, v_n, 'pedido_compra', jsonb_build_object('pedido_compra', p.numero, 'recebimento_id', v_rec, 'nf', v_nf), false, p_id, 'aberto', 0, round((x->>'valor')::numeric, 2))
    returning id into v_tid;
    if v_ncat > 1 and v_item_tot > 0 and not exists (select 1 from jsonb_array_elements(v_cats) e where e->>'c' is null) then
      v_acum := 0; v_k := 0;
      for v_c in select (e->>'c')::bigint c, (e->>'v')::numeric v from jsonb_array_elements(v_cats) e order by (e->>'v')::numeric loop
        v_k := v_k + 1;
        v_parte := case when v_k = v_ncat then round((x->>'valor')::numeric, 2) - v_acum else round((x->>'valor')::numeric * v_c.v / v_item_tot, 2) end;
        v_acum := v_acum + v_parte;
        insert into public.titulos_pagar_rateio (titulo_id, categoria_financeira_id, valor, observacao) values (v_tid, v_c.c, v_parte, p.numero);
      end loop;
    end if;
  end loop;
  update public.pedidos_compra set valor_recebido = valor_recebido + v_valor,
    situacao = case when not exists (select 1 from public.pedidos_compra_itens where pedido_id = p_id and quantidade_recebida < quantidade) then 'recebido' else 'recebido_parcial' end
  where id = p_id;
  perform public.pc_projetar(p_id);
  perform public.pc_evento(p_id, 'recebido',
    case when v_sem_nf then 'Serviço recebido sem NF · peças entram no estoque (registro no pedido) · ' else 'NF ' || v_nf || ' recebida · ' end
      || 'R$ ' || to_char(v_valor, 'FM999G999G990D00') || ' · ' || v_n || ' parcela(s) no contas a pagar',
    jsonb_build_object('recebimento_id', v_rec));
  return v_rec;
end $$;
revoke execute on function public.pedido_compra_receber(bigint, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.pedido_compra_receber(bigint, jsonb, jsonb, jsonb) to authenticated;
