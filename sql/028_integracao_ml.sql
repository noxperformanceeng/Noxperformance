-- =====================================================================
-- ERP NOX · 028_integracao_ml.sql
-- Integração de LEITURA com o Mercado Livre (fase de testes).
--  - ml_contas: cada conta do ML (ML 30, ML 37) ligada ao canal de venda. Os acessos (tokens) ficam
--    numa tabela que NINGUÉM lê pelo navegador: só as funções do servidor (Edge Functions).
--  - ml_pedidos_brutos: a venda exatamente como veio do ML (pedido, envio, pagamentos). Guardar o bruto
--    permite recalibrar a leitura sem consultar o ML de novo.
--  - processar_pedido_ml: transforma o bruto em pedido de venda + itens + tarifas, cria/atualiza o vínculo
--    anúncio × produto (pelo SKU = código do produto) e gera o título a receber das vendas pagas.
--  - ml_eventos: avisos que o ML manda (venda nova/alterada, pagamento, reclamação), com registro de processamento.
-- Pode rodar mais de uma vez. Sem comandos destrutivos.
-- =====================================================================

create table if not exists public.ml_contas (
  id            bigserial primary key,
  canal_id      bigint not null unique references public.canais_venda(id),
  ml_user_id    bigint not null unique,
  nickname      text,
  access_token  text,
  refresh_token text,
  expira_em     timestamptz,
  escopos       text,
  autorizado_em timestamptz not null default now(),
  autorizado_por uuid references public.usuarios(id),
  ultima_sync   timestamptz,
  ultimo_erro   text,
  situacao      text not null default 'ativo' check (situacao in ('ativo','revogado','erro')),
  atualizado_em timestamptz not null default now()
);

-- Pedido de autorização em andamento (liga o retorno do ML ao canal certo)
create table if not exists public.ml_autorizacoes (
  state      uuid primary key default gen_random_uuid(),
  canal_id   bigint not null references public.canais_venda(id),
  criado_por uuid references public.usuarios(id),
  criado_em  timestamptz not null default now(),
  usado_em   timestamptz
);

create table if not exists public.ml_pedidos_brutos (
  ml_order_id   bigint primary key,
  canal_id      bigint not null references public.canais_venda(id),
  ordem         jsonb not null,
  envio_custos  jsonb,
  pagamentos    jsonb,                      -- pagamentos do Mercado Pago (tarifas detalhadas, liberação)
  buscado_em    timestamptz not null default now(),
  processado_em timestamptz,
  erro          text,
  pedido_venda_id bigint references public.pedidos_venda(id)
);
create index if not exists ml_brutos_canal_idx on public.ml_pedidos_brutos (canal_id, processado_em);

create table if not exists public.ml_eventos (
  id           bigserial primary key,
  recebido_em  timestamptz not null default now(),
  topic        text,
  resource     text,
  ml_user_id   bigint,
  tentativas   int,
  payload      jsonb,
  processado_em timestamptz,
  erro         text
);
create index if not exists ml_eventos_pend_idx on public.ml_eventos (processado_em) where processado_em is null;

-- Segurança: RLS ligado e nenhuma regra para usuários → só o servidor (service role) acessa.
alter table public.ml_contas enable row level security;
alter table public.ml_autorizacoes enable row level security;
alter table public.ml_pedidos_brutos enable row level security;
alter table public.ml_eventos enable row level security;
revoke all on public.ml_contas, public.ml_autorizacoes, public.ml_pedidos_brutos, public.ml_eventos from anon, authenticated;

-- Situação das contas para a tela (sem tokens)
create or replace function public.ml_status()
returns table (canal_id bigint, ml_user_id bigint, nickname text, autorizado_em timestamptz, expira_em timestamptz,
               ultima_sync timestamptz, ultimo_erro text, situacao text, pedidos bigint, eventos_pendentes bigint)
language sql stable security definer set search_path = public as $$
  select c.canal_id, c.ml_user_id, c.nickname, c.autorizado_em, c.expira_em, c.ultima_sync, c.ultimo_erro, c.situacao,
         (select count(*) from public.ml_pedidos_brutos b where b.canal_id = c.canal_id),
         (select count(*) from public.ml_eventos e where e.ml_user_id = c.ml_user_id and e.processado_em is null)
  from public.ml_contas c
  where public.pode('canais_venda') or public.pode('marketplaces')
$$;

-- Início da autorização: devolve o link que o usuário principal da conta abre para clicar em "Permitir"
create or replace function public.ml_iniciar_autorizacao(p_canal_id bigint, p_client_id text)
returns text language plpgsql security definer set search_path = public as $$
declare v_state uuid; v_plat text;
begin
  if not (public.eh_admin() or public.pode('canais_venda', 'editar')) then raise exception 'Sem permissão para autorizar integração'; end if;
  select plataforma into v_plat from public.canais_venda where id = p_canal_id;
  if v_plat is distinct from 'mercado_livre' then raise exception 'Canal não é do Mercado Livre'; end if;
  insert into public.ml_autorizacoes (canal_id, criado_por) values (p_canal_id, auth.uid()) returning state into v_state;
  return 'https://auth.mercadolivre.com.br/authorization?response_type=code&client_id=' || p_client_id
      || '&redirect_uri=' || 'https%3A%2F%2Fqijeqdfhwwruhoruvvgb.supabase.co%2Ffunctions%2Fv1%2Fml-auth'
      || '&state=' || v_state::text;
end $$;

-- Gera títulos sem checar permissão do usuário (uso interno: integração). A versão da tela continua checando.
create or replace function public.gerar_titulos_pedido_interno(p_pedido_id bigint)
returns int language plpgsql security definer set search_path = public as $$
declare p record; c record; v_cat bigint; v_tid bigint; e record;
begin
  select * into p from public.pedidos_venda where id = p_pedido_id;
  if not found or p.situacao in ('orcamento', 'cancelado') or p.tipo <> 'marketplace' or p.valor_liquido <= 0 then return 0; end if;
  if exists (select 1 from public.titulos_receber where pedido_venda_id = p.id and situacao <> 'cancelado') then return 0; end if;
  if exists (select 1 from public.pedidos_venda_encargos where pedido_id = p.id and categoria_financeira_id is null) then return 0; end if;
  select * into c from public.canais_venda where id = p.canal_id;
  v_cat := coalesce(c.categoria_receita_id, (select id from public.categorias_financeiras where codigo = '1.01.001'));
  insert into public.titulos_receber (empresa_id, cliente_id, canal_id, pedido_venda_id, numero_externo, documento, descricao, valor,
    data_emissao, data_vencimento, conta_bancaria_id, origem)
  values (p.empresa_id, p.cliente_id, p.canal_id, p.id, coalesce(p.pack_id, p.numero_externo), coalesce('NF ' || p.nf_numero, 'Venda ' || p.numero_externo),
    c.nome || ' · venda ' || p.numero_externo, p.valor_liquido, coalesce(p.nf_data, p.data_pedido),
    greatest(coalesce(p.data_prev_recebimento, p.data_pedido + c.prazo_repasse_dias), coalesce(p.nf_data, p.data_pedido)), c.conta_bancaria_id, 'marketplace')
  returning id into v_tid;
  insert into public.titulos_receber_rateio (titulo_id, categoria_financeira_id, valor, tipo_codigo, observacao)
    values (v_tid, v_cat, p.valor_produtos - p.desconto + p.outras_receitas, 'receita', 'Receita bruta dos produtos');
  if p.frete_cliente <> 0 then
    insert into public.titulos_receber_rateio (titulo_id, categoria_financeira_id, valor, tipo_codigo, observacao)
    values (v_tid, coalesce((select categoria_financeira_id from public.encargos_tipos where plataforma in (c.plataforma, 'geral') and codigo = 'frete_cliente' order by plataforma = 'geral' limit 1), v_cat),
            p.frete_cliente, 'frete_cliente', 'Frete pago pelo comprador');
  end if;
  for e in select categoria_financeira_id, tipo_codigo, string_agg(coalesce(descricao, tipo_codigo), ', ') d, sum(valor) v
           from public.pedidos_venda_encargos where pedido_id = p.id group by 1, 2 loop
    insert into public.titulos_receber_rateio (titulo_id, categoria_financeira_id, valor, tipo_codigo, observacao)
    values (v_tid, e.categoria_financeira_id, -e.v, e.tipo_codigo, e.d);
  end loop;
  return 1;
end $$;

-- Transforma a venda bruta do ML em pedido de venda
create or replace function public.processar_pedido_ml(p_ml_order_id bigint)
returns bigint language plpgsql security definer set search_path = public as $$
declare b record; c record; o jsonb; v_id bigint; v_sit text; v_status text; v_data date; v_prev date; v_tem_receb boolean;
        it jsonb; v_cat_fee bigint; v_cat_fin bigint; v_cat_env bigint; v_fee numeric(14,2) := 0; v_fin numeric(14,2) := 0; v_env numeric(14,2) := 0;
        v_fee_mp numeric(14,2); v_fin_mp numeric(14,2); v_env_mp numeric(14,2); pg jsonb; fd jsonb; v_comprador text; v_itens jsonb; v_encs jsonb;
begin
  select * into b from public.ml_pedidos_brutos where ml_order_id = p_ml_order_id;
  if not found then raise exception 'Venda % não encontrada', p_ml_order_id; end if;
  select * into c from public.canais_venda where id = b.canal_id;
  o := b.ordem;
  v_status := o->>'status';
  v_data := ((o->>'date_created')::timestamptz at time zone 'America/Sao_Paulo')::date;
  v_comprador := nullif(trim(concat_ws(' ', o->'buyer'->>'first_name', o->'buyer'->>'last_name')), '');
  v_comprador := coalesce(v_comprador, o->'buyer'->>'nickname', 'Comprador ML ' || coalesce(o->'buyer'->>'id', ''));

  -- Tarifas: pelo detalhe do pagamento no Mercado Pago (mais preciso); senão pelo pedido/envio do ML
  for pg in select * from jsonb_array_elements(coalesce(b.pagamentos, '[]'::jsonb)) loop
    if pg->>'status' in ('approved', 'refunded', 'charged_back', 'in_mediation') then
      for fd in select * from jsonb_array_elements(coalesce(pg->'fee_details', '[]'::jsonb)) loop
        if fd->>'type' in ('ml_fee', 'application_fee', 'mercadopago_fee') then v_fee_mp := coalesce(v_fee_mp, 0) + (fd->>'amount')::numeric;
        elsif fd->>'type' = 'financing_fee' then v_fin_mp := coalesce(v_fin_mp, 0) + (fd->>'amount')::numeric;
        elsif fd->>'type' = 'shipping_fee' then v_env_mp := coalesce(v_env_mp, 0) + (fd->>'amount')::numeric;
        end if;
      end loop;
      v_prev := greatest(v_prev, nullif(pg->>'money_release_date', '')::timestamptz::date);
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

  select exists (select 1 from public.titulos_receber where pedido_venda_id = v_id and situacao <> 'cancelado') into v_tem_receb;
  if not v_tem_receb then
    -- itens (e vínculo anúncio × produto pelo SKU) e tarifas: regravados pela mesma função da tela
    for it in select * from jsonb_array_elements(coalesce(o->'order_items', '[]'::jsonb)) loop
      insert into public.anuncios (canal_id, anuncio_id, variacao_id, sku, titulo, produto_id)
      values (b.canal_id, it->'item'->>'id', coalesce(it->'item'->>'variation_id', ''), nullif(it->'item'->>'seller_sku', ''), it->'item'->>'title',
              (select id from public.produtos where upper(codigo) = upper(nullif(it->'item'->>'seller_sku', '')) limit 1))
      on conflict (canal_id, anuncio_id, variacao_id) do update set sku = coalesce(excluded.sku, anuncios.sku), titulo = excluded.titulo,
         produto_id = coalesce(anuncios.produto_id, excluded.produto_id);
    end loop;
    select coalesce(jsonb_agg(jsonb_build_object('anuncio_id', x->'item'->>'id', 'variacao_id', x->'item'->>'variation_id', 'sku', x->'item'->>'seller_sku',
             'descricao', x->'item'->>'title', 'quantidade', coalesce((x->>'quantity')::numeric, 1), 'valor_unitario', coalesce((x->>'unit_price')::numeric, 0))), '[]')
      into v_itens from jsonb_array_elements(coalesce(o->'order_items', '[]'::jsonb)) x;
    select categoria_financeira_id into v_cat_fee from public.encargos_tipos where plataforma = 'mercado_livre' and codigo = 'tarifa_venda';
    select categoria_financeira_id into v_cat_fin from public.encargos_tipos where plataforma = 'mercado_livre' and codigo = 'parcelamento';
    select categoria_financeira_id into v_cat_env from public.encargos_tipos where plataforma = 'mercado_livre'
      and codigo = case when b.envio_custos->>'logistic_type' = 'fulfillment' or o->'shipping'->>'logistic_type' = 'fulfillment' then 'envio_full' else 'envio' end;
    v_encs := jsonb_build_array(
      jsonb_build_object('tipo_codigo', 'tarifa_venda', 'descricao', 'Tarifa de venda', 'categoria_financeira_id', v_cat_fee, 'valor', v_fee),
      jsonb_build_object('tipo_codigo', 'parcelamento', 'descricao', 'Taxa de parcelamento', 'categoria_financeira_id', v_cat_fin, 'valor', v_fin),
      jsonb_build_object('tipo_codigo', 'envio', 'descricao', 'Tarifa de envio', 'categoria_financeira_id', v_cat_env, 'valor', v_env));
    perform public.salvar_pedido_venda(jsonb_build_object('id', v_id), v_itens, v_encs);
  end if;

  -- situação: cancelada no ML cancela o pedido e os títulos em aberto sem recebimento
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

-- Reprocessa todas as vendas guardadas (depois de recalibrar a leitura), sem chamar o ML
create or replace function public.reprocessar_pedidos_ml(p_canal_id bigint default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if not (public.eh_admin() or public.pode('canais_venda', 'editar')) then raise exception 'Sem permissão'; end if;
  for r in select ml_order_id from public.ml_pedidos_brutos where p_canal_id is null or canal_id = p_canal_id loop
    begin
      perform public.processar_pedido_ml(r.ml_order_id); n := n + 1;
    exception when others then
      update public.ml_pedidos_brutos set erro = sqlerrm where ml_order_id = r.ml_order_id;
    end;
  end loop;
  return n;
end $$;

revoke execute on function public.processar_pedido_ml(bigint), public.gerar_titulos_pedido_interno(bigint) from public, anon, authenticated;
revoke execute on function public.ml_status(), public.ml_iniciar_autorizacao(bigint, text), public.reprocessar_pedidos_ml(bigint) from public, anon;
grant execute on function public.ml_status(), public.ml_iniciar_autorizacao(bigint, text), public.reprocessar_pedidos_ml(bigint) to authenticated;
