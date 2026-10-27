-- =====================================================================
-- 087 · Serviços terceirizados com cadastro próprio e forma de pagamento obrigatória
--  · Nova lista "Serviços terceirizados" (usinagem, desenho técnico, pintura, polimento…): cada serviço
--    tem a sua categoria financeira. Não tem SKU e não entra no estoque.
--  · No pedido de compra cada linha é Produto ou Serviço. O serviço vem dessa lista (e pode ser cadastrado
--    na hora); não precisa de liberação de "item sem cadastro".
--  · O serviço marcado como "usinagem" continua pedindo a peça que volta usinada (ficha, material, barras).
--  · Pedido sem forma de pagamento não vai para aprovação.
--  · Recebimento só de serviços pode ser feito sem NF (como já era para usinagem).
-- =====================================================================
create table if not exists public.servicos (
  id                      bigserial primary key,
  nome                    text not null,
  categoria_financeira_id bigint not null references public.categorias_financeiras(id),
  unidade                 text not null default 'SV',
  usinagem                boolean not null default false,   -- pede a peça que volta usinada (ficha de usinagem)
  fornecedor_id           bigint references public.fornecedores(id),
  preco_referencia        numeric(14,2) check (preco_referencia is null or preco_referencia >= 0),
  descricao               text,
  situacao                text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid default auth.uid() references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists servicos_nome_uk on public.servicos (upper(nome));
create or replace trigger carimbo before insert or update on public.servicos for each row execute function public.carimbo_cadastro();
alter table public.servicos enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'servicos' and policyname = 'ver servicos') then
    create policy "ver servicos" on public.servicos for select to authenticated
      using ((select public.pode('compras')) or (select public.pode('pagar')) or (select public.pode('notas')));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'servicos' and policyname = 'incluir servicos') then
    create policy "incluir servicos" on public.servicos for insert to authenticated with check ((select public.pode('compras', 'criar')));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'servicos' and policyname = 'alterar servicos') then
    create policy "alterar servicos" on public.servicos for update to authenticated
      using ((select public.pode('compras', 'alterar'))) with check ((select public.pode('compras', 'alterar')));
  end if;
end $$;

-- Serviços iniciais
insert into public.servicos (nome, categoria_financeira_id, unidade, usinagem, descricao)
select x.nome, c.id, x.un, x.usi, x.descr
  from (values ('USINAGEM', '3.05.005', 'PÇ', true, 'Usinagem de peça nossa por terceiro: pede a peça que volta usinada e calcula o material a enviar'),
               ('DESENHO TÉCNICO', '6.09.001', 'SV', false, 'Desenho / projeto feito por terceiro'),
               ('PINTURA ELETROSTÁTICA', '3.05.003', 'PÇ', false, null),
               ('POLIMENTO', '3.05.004', 'PÇ', false, null)) x(nome, cod, un, usi, descr)
  join public.categorias_financeiras c on c.codigo = x.cod
on conflict do nothing;

-- Item do pedido aponta para o serviço
alter table public.pedidos_compra_itens add column if not exists servico_id bigint references public.servicos(id);
create index if not exists pedidos_compra_itens_servico_idx on public.pedidos_compra_itens (servico_id);
update public.pedidos_compra_itens set servico_id = (select id from public.servicos where upper(nome) = 'USINAGEM')
 where tipo_item = 'servico_usinagem' and servico_id is null;

-- Serviço cadastrado não é "item sem cadastro"
create or replace function public.pc_avulsos_pendentes(p_id bigint)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(i.descricao order by i.id), '{}') from public.pedidos_compra_itens i, public.pedidos_compra p
   where p.id = p_id and i.pedido_id = p_id and i.produto_id is null and i.servico_id is null
     and not (lower(trim(i.descricao)) in (select lower(trim(x)) from jsonb_array_elements_text(coalesce(p.liberacao_avulso->'itens', '[]')) x))
$$;
revoke execute on function public.pc_avulsos_pendentes(bigint) from public, anon;
grant execute on function public.pc_avulsos_pendentes(bigint) to authenticated;

-- Pendências: sem forma de pagamento passa a bloquear o envio para aprovação
create or replace function public.pc_pendencias(p_id bigint)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]') from (
    select jsonb_build_object('id', 'sem_categoria', 'bloqueia', true, 'texto', count(*) || ' item(ns) sem categoria financeira') x
      from public.pedidos_compra_itens i where i.pedido_id = p_id and i.categoria_financeira_id is null having count(*) > 0
    union all
    select jsonb_build_object('id', 'avulso', 'bloqueia', true, 'texto', 'Item sem cadastro aguardando liberação: ' || array_to_string(public.pc_avulsos_pendentes(p_id), ', '))
     where cardinality(public.pc_avulsos_pendentes(p_id)) > 0
    union all
    select jsonb_build_object('id', 'sem_forma', 'bloqueia', true, 'texto', 'Sem forma de pagamento (combine com o fornecedor: Pix, boleto…)')
      from public.pedidos_compra p where p.id = p_id and p.forma_pagamento_id is null
    union all
    select jsonb_build_object('id', 'produto_sem_categoria', 'bloqueia', false, 'texto', 'Produto sem categoria no cadastro: ' || string_agg(distinct coalesce(pr.codigo, pr.descricao), ', '))
      from public.pedidos_compra_itens i join public.produtos pr on pr.id = i.produto_id
     where i.pedido_id = p_id and pr.categoria_financeira_id is null and not i.uso_consumo and i.servico_id is null having count(*) > 0
    union all
    select jsonb_build_object('id', 'sem_condicao', 'bloqueia', false, 'texto', 'Sem condição de pagamento')
      from public.pedidos_compra p where p.id = p_id and p.condicao_pagamento_id is null
    union all
    select jsonb_build_object('id', 'sem_entrega', 'bloqueia', false, 'texto', 'Sem previsão de entrega')
      from public.pedidos_compra p where p.id = p_id and p.data_entrega_prevista is null
    union all
    select jsonb_build_object('id', 'sem_contato', 'bloqueia', false, 'texto', 'Fornecedor sem e-mail e sem WhatsApp para envio')
      from public.pedidos_compra p join public.fornecedores f on f.id = p.fornecedor_id
     where p.id = p_id and coalesce(nullif(p.email_fornecedor, ''), nullif(f.email, ''), nullif(p.whatsapp_fornecedor, ''), nullif(f.telefone, '')) is null
  ) z
$$;
revoke execute on function public.pc_pendencias(bigint) from public, anon;
grant execute on function public.pc_pendencias(bigint) to authenticated;

-- Salvar o pedido: grava o serviço do item (categoria, descrição e unidade vêm do cadastro do serviço)
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
    if exists (select 1 from jsonb_array_elements(p_itens) x left join public.servicos s on s.id = nullif(x->>'servico_id', '')::bigint
                where nullif(x->>'servico_id', '') is not null and s.id is null) then
      raise exception 'Serviço não encontrado no cadastro';
    end if;
    select id into v_cat_usi from public.categorias_financeiras where codigo = '3.05.005' limit 1;   -- TERCEIRIZADO - USINAGEM
    delete from public.pedidos_compra_itens where pedido_id = v_id;
    insert into public.pedidos_compra_itens (pedido_id, produto_id, servico_id, descricao, unidade, codigo_fornecedor, quantidade, valor_unitario, desconto, categoria_financeira_id, observacao,
      tipo_item, material, comprimento_mm, perda_mm, barra_mm, pecas_por_barra, barras_enviar, uso_consumo)
    select v_id, case when s.sv is not null and not s.srv then null else nullif(s.x->>'produto_id', '')::bigint end, s.sv,
           coalesce(nullif(s.x->>'descricao', ''),
                    case when s.srv then coalesce(sv.nome, 'USINAGEM') || ' · ' || (select descricao from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint) end,
                    sv.nome, (select descricao from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint), 'Item'),
           coalesce(nullif(s.x->>'unidade', ''), sv.unidade, case when s.srv then 'PÇ' end), nullif(s.x->>'codigo_fornecedor', ''), (s.x->>'quantidade')::numeric,
           coalesce((s.x->>'valor_unitario')::numeric, 0), coalesce((s.x->>'desconto')::numeric, 0),
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
           case when s.sv is not null then false else coalesce((s.x->>'uso_consumo')::boolean, false) end
    from (select x, coalesce((x->>'tipo_item') = 'servico_usinagem', false) as srv, nullif(x->>'servico_id', '')::bigint as sv,
                 floor(nullif(x->>'barra_mm', '')::numeric / nullif(coalesce(nullif(x->>'comprimento_mm', '')::numeric, u2.comprimento_mm) + coalesce(nullif(x->>'perda_mm', '')::numeric, u2.perda_mm, 0), 0)) as pb
          from jsonb_array_elements(p_itens) x
          left join public.produto_usinagem u2 on u2.produto_id = nullif(x->>'produto_id', '')::bigint
          where coalesce((x->>'quantidade')::numeric, 0) > 0) s
    left join public.servicos sv on sv.id = s.sv
    left join public.produto_usinagem u on u.produto_id = nullif(s.x->>'produto_id', '')::bigint;
  end if;
  perform public.pc_recalcular(v_id);
  return v_id;
end $$;
revoke execute on function public.pedido_compra_salvar(jsonb, jsonb) from public, anon;
grant execute on function public.pedido_compra_salvar(jsonb, jsonb) to authenticated;

-- Liberação de avulso não lista os serviços cadastrados; recebimento só de serviços pode ser sem NF
do $$
declare v text;
begin
  v := pg_get_functiondef('public.pedido_compra_acao(bigint, text, text, jsonb)'::regprocedure);
  if position('produto_id is null and servico_id is null' in v) = 0 then
    v := replace(v, 'where pedido_id = p_id and produto_id is null', 'where pedido_id = p_id and produto_id is null and servico_id is null');
    execute v;
  end if;
  v := pg_get_functiondef('public.pedido_compra_receber(bigint, jsonb, jsonb, jsonb)'::regprocedure);
  if position('i.servico_id is not null' in v) = 0 then
    v := replace(v, 'bool_and(i.tipo_item = ''servico_usinagem'')', 'bool_and(i.tipo_item = ''servico_usinagem'' or i.servico_id is not null)');
    v := replace(v, 'v_doc || '' · serviço de usinagem''', 'v_doc || '' · serviço''');
    v := replace(v, '''Serviço recebido sem NF · peças entram no estoque (registro no pedido) · ''', '''Serviço recebido sem NF · ''');
    execute v;
  end if;
end $$;

select public.ligar_auditoria('servicos');
