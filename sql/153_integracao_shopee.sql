-- =====================================================================
-- 153 · Integração direta com a Shopee (loja do CNPJ 37) — vendas entram sozinhas no sistema
--  · Mesmo modelo do Mercado Livre: em Cadastros › Canais de venda › Shopee, o botão "Autorizar loja Shopee"
--    abre a Shopee; o dono da loja entra e autoriza. A partir daí o sistema busca as vendas sozinho
--    (a cada 30 min, as alteradas nos últimos 2 dias) e dá para buscar um período no botão "Buscar vendas".
--  · Cada venda vira pedido de venda (canal Shopee): itens (ligados ao produto pelo SKU do anúncio),
--    tarifas da Shopee (comissão, taxa de serviço, processamento, frete) pelo extrato da venda (escrow) e o
--    título a receber. Venda cancelada na Shopee cancela o pedido e o título em aberto.
--  · Acessos (tokens) ficam em tabela que só o servidor lê; a chave da Shopee fica nos segredos do Supabase
--    (SHOPEE_PARTNER_KEY) — nunca no sistema nem no repositório.
--  · Nada muda nas vendas que já existem.
-- =====================================================================

create table if not exists public.shopee_contas (
  id              bigserial primary key,
  canal_id        bigint not null unique references public.canais_venda(id),
  shop_id         bigint not null unique,
  loja            text,
  access_token    text,
  refresh_token   text,
  expira_em       timestamptz,
  refresh_expira_em timestamptz,
  autorizado_em   timestamptz not null default now(),
  autorizado_por  uuid references public.usuarios(id),
  ultima_sync     timestamptz,
  ultimo_erro     text,
  situacao        text not null default 'ativo' check (situacao in ('ativo','revogado','erro')),
  atualizado_em   timestamptz not null default now()
);

create table if not exists public.shopee_autorizacoes (
  state      uuid primary key default gen_random_uuid(),
  canal_id   bigint not null references public.canais_venda(id),
  criado_por uuid references public.usuarios(id),
  criado_em  timestamptz not null default now(),
  usado_em   timestamptz
);

create table if not exists public.shopee_pedidos_brutos (
  order_sn        text primary key,
  canal_id        bigint not null references public.canais_venda(id),
  detalhe         jsonb not null,            -- get_order_detail
  escrow          jsonb,                     -- get_escrow_detail (valores e tarifas)
  atualizado_shopee bigint,                  -- update_time da Shopee (pula a venda se não mudou)
  buscado_em      timestamptz not null default now(),
  processado_em   timestamptz,
  erro            text,
  pedido_venda_id bigint references public.pedidos_venda(id)
);
create index if not exists shopee_brutos_canal_idx on public.shopee_pedidos_brutos (canal_id, processado_em);

alter table public.shopee_contas enable row level security;
alter table public.shopee_autorizacoes enable row level security;
alter table public.shopee_pedidos_brutos enable row level security;
revoke all on public.shopee_contas, public.shopee_autorizacoes, public.shopee_pedidos_brutos from anon, authenticated;

-- tarifa de frete cobrada pela Shopee (as demais já existem)
insert into public.encargos_tipos (plataforma, codigo, nome, categoria_financeira_id)
select 'shopee', 'envio', 'Frete cobrado pela Shopee', (select categoria_financeira_id from public.encargos_tipos where plataforma = 'geral' and codigo = 'frete_nox')
 where not exists (select 1 from public.encargos_tipos where plataforma = 'shopee' and codigo = 'envio');

-- Situação para a tela (sem tokens)
create or replace function public.shopee_status()
returns table (canal_id bigint, shop_id bigint, loja text, autorizado_em timestamptz, refresh_expira_em timestamptz,
               ultima_sync timestamptz, ultimo_erro text, situacao text, pedidos bigint)
language sql stable security definer set search_path = public as $$
  select c.canal_id, c.shop_id, c.loja, c.autorizado_em, c.refresh_expira_em, c.ultima_sync, c.ultimo_erro, c.situacao,
         (select count(*) from public.shopee_pedidos_brutos b where b.canal_id = c.canal_id)
    from public.shopee_contas c
   where (select public.pode('canais_venda')) or (select public.pode('marketplaces'))
$$;
revoke execute on function public.shopee_status() from public, anon;
grant execute on function public.shopee_status() to authenticated;

-- Início da autorização: devolve o link (a função shopee-auth assina e manda para a Shopee)
create or replace function public.shopee_iniciar_autorizacao(p_canal_id bigint)
returns text language plpgsql security definer set search_path = public as $$
declare v_state uuid; v_plat text;
begin
  if not (public.eh_admin() or public.pode('canais_venda', 'editar')) then raise exception 'Sem permissão para autorizar integração'; end if;
  select plataforma into v_plat from public.canais_venda where id = p_canal_id;
  if v_plat is distinct from 'shopee' then raise exception 'Canal não é da Shopee'; end if;
  insert into public.shopee_autorizacoes (canal_id, criado_por) values (p_canal_id, auth.uid()) returning state into v_state;
  return 'https://qijeqdfhwwruhoruvvgb.supabase.co/functions/v1/shopee-auth?inicio=' || v_state::text;
end $$;
revoke execute on function public.shopee_iniciar_autorizacao(bigint) from public, anon;
grant execute on function public.shopee_iniciar_autorizacao(bigint) to authenticated;

-- Venda da Shopee → pedido de venda (itens, tarifas, título a receber)
create or replace function public.processar_pedido_shopee(p_order_sn text)
returns bigint language plpgsql security definer set search_path = public as $$
declare b record; c record; o jsonb; e jsonb; v_id bigint; v_sit text; v_status text; v_data date; v_tem_receb boolean; it jsonb;
        v_comprador text; v_itens jsonb; v_encs jsonb; v_com numeric(14,2); v_srv numeric(14,2); v_proc numeric(14,2); v_frete numeric(14,2);
begin
  select * into b from public.shopee_pedidos_brutos where order_sn = p_order_sn;
  if not found then raise exception 'Venda % não encontrada', p_order_sn; end if;
  select * into c from public.canais_venda where id = b.canal_id;
  o := b.detalhe; e := coalesce(b.escrow->'order_income', '{}'::jsonb);
  v_status := o->>'order_status';
  v_data := (to_timestamp((o->>'create_time')::bigint) at time zone 'America/Sao_Paulo')::date;
  v_comprador := nullif(o->'recipient_address'->>'name', '');
  if v_comprador ~ '^\*+$' or v_comprador like '%***%' then v_comprador := null; end if;
  v_comprador := coalesce(v_comprador, nullif(o->>'buyer_username', ''), 'Comprador Shopee');
  v_sit := case when v_status = 'CANCELLED' then 'cancelado' when v_status in ('UNPAID', 'IN_CANCEL') then 'orcamento' else 'aberto' end;

  select id into v_id from public.pedidos_venda where canal_id = b.canal_id and numero_externo = p_order_sn;
  perform set_config('nox.pedido_rpc', '1', true);
  if v_id is null then
    insert into public.pedidos_venda (empresa_id, canal_id, tipo, numero_externo, envio_id, cliente_nome, data_pedido, situacao, origem, origem_ref)
    values (c.empresa_id, b.canal_id, 'marketplace', p_order_sn, o->'package_list'->0->>'package_number', v_comprador, v_data,
            case when v_sit = 'cancelado' then 'orcamento' else v_sit end, 'api', jsonb_build_object('shopee_status', v_status, 'order_sn', p_order_sn))
    returning id into v_id;
  else
    update public.pedidos_venda set cliente_nome = coalesce(cliente_nome, v_comprador), envio_id = coalesce(envio_id, o->'package_list'->0->>'package_number'),
           origem_ref = coalesce(origem_ref, '{}') || jsonb_build_object('shopee_status', v_status)
     where id = v_id;
  end if;

  select exists (select 1 from public.titulos_receber where pedido_venda_id = v_id and situacao <> 'cancelado') into v_tem_receb;
  if not v_tem_receb then
    for it in select * from jsonb_array_elements(coalesce(o->'item_list', '[]'::jsonb)) loop
      insert into public.anuncios (canal_id, anuncio_id, variacao_id, sku, titulo, produto_id)
      values (b.canal_id, it->>'item_id', coalesce(nullif(it->>'model_id', '0'), ''), nullif(coalesce(nullif(it->>'model_sku', ''), it->>'item_sku'), ''),
              concat_ws(' · ', it->>'item_name', nullif(it->>'model_name', '')),
              (select id from public.produtos where upper(codigo) = upper(nullif(coalesce(nullif(it->>'model_sku', ''), it->>'item_sku'), '')) limit 1))
      on conflict (canal_id, anuncio_id, variacao_id) do update set sku = coalesce(excluded.sku, anuncios.sku), titulo = excluded.titulo,
         produto_id = coalesce(anuncios.produto_id, excluded.produto_id);
    end loop;
    select coalesce(jsonb_agg(jsonb_build_object('anuncio_id', x->>'item_id', 'variacao_id', coalesce(nullif(x->>'model_id', '0'), ''),
             'sku', coalesce(nullif(x->>'model_sku', ''), x->>'item_sku'), 'descricao', concat_ws(' · ', x->>'item_name', nullif(x->>'model_name', '')),
             'quantidade', coalesce((x->>'model_quantity_purchased')::numeric, 1),
             'valor_unitario', coalesce(nullif(x->>'model_discounted_price', '')::numeric, (x->>'model_original_price')::numeric, 0))), '[]')
      into v_itens from jsonb_array_elements(coalesce(o->'item_list', '[]'::jsonb)) x;
    v_com := coalesce(nullif(e->>'commission_fee', '')::numeric, 0);
    v_srv := coalesce(nullif(e->>'service_fee', '')::numeric, 0);
    v_proc := coalesce(nullif(e->>'seller_transaction_fee', '')::numeric, 0) + coalesce(nullif(e->>'credit_card_transaction_fee', '')::numeric, 0);
    -- frete: o que a Shopee cobrou da loja além do que o comprador pagou e do subsídio dela
    v_frete := greatest(coalesce(nullif(e->>'actual_shipping_fee', '')::numeric, 0) - coalesce(nullif(e->>'shopee_shipping_rebate', '')::numeric, 0)
                        - coalesce(nullif(e->>'buyer_paid_shipping_fee', '')::numeric, 0), 0);
    v_encs := jsonb_build_array(
      jsonb_build_object('tipo_codigo', 'comissao', 'descricao', 'Comissão Shopee', 'categoria_financeira_id',
        (select categoria_financeira_id from public.encargos_tipos where plataforma = 'shopee' and codigo = 'comissao'), 'valor', v_com),
      jsonb_build_object('tipo_codigo', 'servico', 'descricao', 'Taxa de serviço Shopee', 'categoria_financeira_id',
        (select categoria_financeira_id from public.encargos_tipos where plataforma = 'shopee' and codigo = 'servico'), 'valor', v_srv),
      jsonb_build_object('tipo_codigo', 'processamento', 'descricao', 'Processamento de pagamento', 'categoria_financeira_id',
        (select categoria_financeira_id from public.encargos_tipos where plataforma = 'shopee' and codigo = 'processamento'), 'valor', v_proc),
      jsonb_build_object('tipo_codigo', 'envio', 'descricao', 'Frete cobrado pela Shopee', 'categoria_financeira_id',
        (select categoria_financeira_id from public.encargos_tipos where plataforma = 'shopee' and codigo = 'envio'), 'valor', v_frete));
    perform public.salvar_pedido_venda(jsonb_build_object('id', v_id), v_itens, v_encs);
  end if;

  if v_sit = 'cancelado' then
    update public.titulos_receber set situacao = 'cancelado', motivo_cancelamento = 'Venda cancelada na Shopee'
     where pedido_venda_id = v_id and situacao = 'aberto' and valor_recebido = 0;
    update public.pedidos_venda set situacao = 'cancelado', motivo_cancelamento = coalesce(motivo_cancelamento, 'Cancelada na Shopee')
     where id = v_id and situacao <> 'cancelado';
  elsif v_sit = 'aberto' then
    update public.pedidos_venda set situacao = 'aberto' where id = v_id and situacao = 'orcamento';
    perform public.gerar_titulos_pedido_interno(v_id);
  end if;
  perform set_config('nox.pedido_rpc', '', true);
  update public.shopee_pedidos_brutos set processado_em = now(), erro = null, pedido_venda_id = v_id where order_sn = p_order_sn;
  return v_id;
end $$;
revoke execute on function public.processar_pedido_shopee(text) from public, anon, authenticated;

-- Busca automática: a cada 30 min, as vendas alteradas nos últimos 2 dias (só roda depois que a loja for autorizada)
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'nox-shopee-vendas') then
    perform cron.schedule('nox-shopee-vendas', '7,37 * * * *', $c$select public.integracao_disparar('shopee-sync', '{"acao":"recentes"}'::jsonb)$c$);
  end if;
end $$;
