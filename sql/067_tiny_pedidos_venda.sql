-- =====================================================================
-- 067 · Histórico de pedidos de venda do Tiny (distribuidores e venda direta)
--  · A leitura do Tiny marca e pula os pedidos de e-commerce (Mercado Livre, Shopee…), que já vêm
--    pela integração direta. Só os pedidos sem origem de e-commerce são detalhados e carregados.
--  · Limite do plano do Tiny: a API só devolve os últimos 2 anos.
-- =====================================================================
create or replace function public.tiny_pedidos_pular_ecommerce(p_empresa int)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.tiny_brutos set detalhe = jsonb_build_object('pulado', 'ecommerce'), detalhado_em = now()
   where empresa_id = p_empresa and recurso = 'pedidos' and detalhe is null
     and coalesce(nullif(trim(resumo->>'numero_ecommerce'), ''), nullif(trim(resumo->>'numeroPedidoEcommerce'), '')) is not null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.tiny_pedidos_pular_ecommerce(int) from public, anon, authenticated;
grant execute on function public.tiny_pedidos_pular_ecommerce(int) to service_role;

-- Carga: clientes + pedidos de venda + itens, a partir dos pedidos do Tiny já detalhados (sem e-commerce).
--  · Cliente: procura pelo CPF/CNPJ (ou nome, quando não tem documento); se não existir, cadastra.
--  · Pedido: nº "30-4078" (empresa + nº do Tiny), origem Tiny; distribuidor/revenda/oficina → canal Distribuidores,
--    demais → Venda direta. Itens ligados ao produto pelo código; sem cadastro ficam com SKU e descrição.
--  · Não gera títulos a receber (o histórico financeiro segue no Tiny). Rodar de novo atualiza a situação.
create or replace function public.tiny_carregar_pedidos_venda(p_empresa int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b record; d jsonb; c jsonb; v_doc text; v_cli bigint; v_tipo text; v_ped bigint; v_suf text; v_num text; v_sit text;
        n_cli int := 0; n_ped int := 0; n_atu int := 0; n_item_sem int := 0; v_canal bigint;
  dt constant text := 'DD/MM/YYYY';
begin
  if auth.uid() is not null and not (select public.eh_admin()) then raise exception 'Só o master roda a carga do Tiny'; end if;
  select case when nome ilike 'NOX 30%' then '30' else '37' end into v_suf from public.empresas where id = p_empresa;
  for b in select * from public.tiny_brutos where empresa_id = p_empresa and recurso = 'pedidos' and detalhe ? 'itens' and processado_em is null loop
    d := b.detalhe; c := d->'cliente';
    v_sit := case d->>'situacao' when 'Faturado' then 'faturado' when 'Pronto para envio' then 'faturado' when 'Enviado' then 'enviado'
               when 'Entregue' then 'entregue' when 'Cancelado' then 'cancelado' else 'aberto' end;
    v_num := v_suf || '-' || (d->>'numero');
    select id into v_ped from public.pedidos_venda where id_tiny = b.tiny_id and empresa_id = p_empresa;
    if v_ped is not null then
      update public.pedidos_venda set situacao = v_sit where id = v_ped and situacao is distinct from v_sit;
      if found then n_atu := n_atu + 1; end if;
      update public.tiny_brutos set processado_em = now() where id = b.id;
      continue;
    end if;
    -- cliente
    v_doc := nullif(regexp_replace(coalesce(c->>'cpf_cnpj', ''), '\D', '', 'g'), '');
    v_tipo := case when d->>'descricao_lista_preco' ilike '%distrib%' then 'distribuidor' when d->>'descricao_lista_preco' ilike '%revenda%' then 'revenda'
                   when length(v_doc) = 14 then 'revenda' else 'consumidor' end;
    v_cli := null;
    if v_doc is not null then select id into v_cli from public.clientes where regexp_replace(coalesce(cpf_cnpj, ''), '\D', '', 'g') = v_doc limit 1;
    elsif coalesce(trim(c->>'nome'), '') <> '' then select id into v_cli from public.clientes where upper(nome) = upper(trim(c->>'nome')) limit 1; end if;
    if v_cli is null and coalesce(trim(c->>'nome'), '') <> '' then
      insert into public.clientes (tipo_pessoa, cpf_cnpj, rg_ie, nome, nome_fantasia, tipo_cliente, canal_origem, telefone, email, cep, endereco, numero,
                                   complemento, bairro, cidade, uf, situacao, observacoes)
      values (case when c->>'tipo_pessoa' = 'J' or length(v_doc) = 14 then 'J' else 'F' end, v_doc,
              nullif(coalesce(nullif(c->>'ie', ''), c->>'rg'), ''), upper(trim(c->>'nome')), nullif(upper(trim(c->>'nome_fantasia')), ''), v_tipo, 'tiny',
              nullif(c->>'fone', ''), nullif(lower(c->>'email'), ''), nullif(regexp_replace(coalesce(c->>'cep', ''), '\D', '', 'g'), ''),
              nullif(upper(c->>'endereco'), ''), nullif(c->>'numero', ''), nullif(upper(c->>'complemento'), ''), nullif(upper(c->>'bairro'), ''),
              nullif(upper(c->>'cidade'), ''), nullif(upper(c->>'uf'), ''), 'ativo', 'CADASTRADO PELA CARGA DO HISTÓRICO DE PEDIDOS DO TINY')
      returning id into v_cli;
      n_cli := n_cli + 1;
    end if;
    if v_cli is not null then select tipo_cliente into v_tipo from public.clientes where id = v_cli; end if;
    v_canal := case when v_tipo in ('distribuidor','revenda','oficina') then 4 else 5 end;
    insert into public.pedidos_venda (empresa_id, canal_id, tipo, numero_externo, cliente_id, cliente_nome, data_pedido, data_envio, data_entrega, situacao,
        desconto, frete_cliente, outras_receitas, valor_produtos, valor_total, encargos, valor_liquido, codigo_rastreio, id_tiny, origem, origem_ref,
        observacoes, observacoes_internas, entrega_parcial)
    values (p_empresa, v_canal, case when v_canal = 4 then 'distribuidor' else 'direta' end, v_num, v_cli, upper(c->>'nome'),
        to_date(d->>'data_pedido', dt), case when coalesce(d->>'data_envio', '') <> '' then to_date(d->>'data_envio', dt) end,
        case when coalesce(d->>'data_entrega', '') <> '' then to_date(d->>'data_entrega', dt) end, v_sit,
        coalesce(nullif(d->>'valor_desconto', '')::numeric, 0), coalesce(nullif(d->>'valor_frete', '')::numeric, 0), coalesce(nullif(d->>'outras_despesas', '')::numeric, 0),
        0, 0, 0, 0, nullif(d->>'codigo_rastreamento', ''), b.tiny_id, 'tiny',
        jsonb_build_object('tiny_id', b.tiny_id, 'tiny_numero', d->>'numero', 'lista_preco', d->>'descricao_lista_preco', 'condicao', d->>'condicao_pagamento',
                           'parcelas', d->'parcelas', 'situacao_tiny', d->>'situacao', 'nota_fiscal_tiny', nullif(d->>'id_nota_fiscal', '0')),
        nullif(d->>'obs', ''), trim(both ' ·' from concat_ws(' · ', 'HISTÓRICO DO TINY Nº ' || (d->>'numero'),
            nullif('CONDIÇÃO ' || coalesce(d->>'condicao_pagamento', ''), 'CONDIÇÃO '), nullif(d->>'obs_interna', ''))), false)
    returning id into v_ped;
    insert into public.pedidos_venda_itens (pedido_id, produto_id, sku, descricao, quantidade, valor_unitario, desconto)
    select v_ped, (select p.id from public.produtos p where upper(p.codigo) = upper(i->'item'->>'codigo') limit 1),
           nullif(i->'item'->>'codigo', ''), upper(i->'item'->>'descricao'), (i->'item'->>'quantidade')::numeric, (i->'item'->>'valor_unitario')::numeric, 0
      from jsonb_array_elements(d->'itens') i where coalesce((i->'item'->>'quantidade')::numeric, 0) > 0;
    n_item_sem := n_item_sem + (select count(*) from public.pedidos_venda_itens where pedido_id = v_ped and produto_id is null);
    perform public.pedido_venda_recalcular(v_ped);
    update public.tiny_brutos set processado_em = now() where id = b.id;
    n_ped := n_ped + 1;
  end loop;
  return jsonb_build_object('pedidos', n_ped, 'clientes_novos', n_cli, 'atualizados', n_atu, 'itens_sem_produto', n_item_sem);
end $$;
revoke execute on function public.tiny_carregar_pedidos_venda(int) from public, anon;
grant execute on function public.tiny_carregar_pedidos_venda(int) to authenticated, service_role;
