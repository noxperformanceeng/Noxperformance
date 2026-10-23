-- =====================================================================
-- 049 · Pedidos de compra
--   Fluxo: rascunho → em aprovação (escala por valor) → aprovado → enviado ao fornecedor → recebido (parcial/total)
--          recusado volta para o comprador ajustar (não cancela). Cancelar é ação separada, com motivo.
--   Financeiro:
--     · Aprovado: as parcelas aparecem no contas a pagar como PROJEÇÃO "aguardando NF" (entram no fluxo de caixa).
--     · Recebimento da NF: vira título real (documento = NF), com rateio por categoria dos itens;
--       a projeção fica só com o que falta receber.
--   Rastreio: tudo em pedidos_compra_eventos (quem, quando, o quê).
-- =====================================================================

-- ---------- Escala de aprovação (alçadas) ----------
create table if not exists public.compras_alcadas (
  id            bigserial primary key,
  nivel         int not null,                                   -- ordem: 1, 2, 3...
  nome          text not null,                                  -- ex.: Gerente de produção, Diretoria
  valor_minimo  numeric(14,2) not null default 0,               -- pedidos a partir deste valor passam por este nível
  aprovadores   uuid[] not null default '{}',                   -- usuários que podem aprovar neste nível
  empresa_id    int references public.empresas(id),             -- vazio = todas as empresas
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- ---------- Pedido ----------
create table if not exists public.pedidos_compra (
  id                     bigserial primary key,
  numero                 text generated always as ('PC-' || lpad(id::text, 5, '0')) stored,
  empresa_id             int not null references public.empresas(id),
  fornecedor_id          bigint not null references public.fornecedores(id),
  comprador_id           uuid default auth.uid(),
  data_pedido            date not null default current_date,
  data_entrega_prevista  date,
  condicao_pagamento_id  bigint references public.condicoes_pagamento(id),
  forma_pagamento_id     bigint references public.formas_pagamento(id),
  conta_bancaria_id      bigint references public.contas_bancarias(id),
  valor_produtos         numeric(14,2) not null default 0,
  frete                  numeric(14,2) not null default 0,
  outras_despesas        numeric(14,2) not null default 0,
  desconto               numeric(14,2) not null default 0,
  valor_total            numeric(14,2) not null default 0,
  valor_recebido         numeric(14,2) not null default 0,
  situacao               text not null default 'rascunho'
                         check (situacao in ('rascunho','em_aprovacao','recusado','aprovado','enviado','recebido_parcial','recebido','cancelado')),
  niveis_exigidos        int[] not null default '{}',
  niveis_aprovados       int[] not null default '{}',
  motivo_recusa          text,
  motivo_cancelamento    text,
  contato_fornecedor     text,
  email_fornecedor       text,
  whatsapp_fornecedor    text,
  enviado_em             timestamptz,
  enviado_por            uuid,
  enviado_via            text,
  enviado_para           text,
  pdf_path               text,
  observacoes            text,          -- vão no PDF para o fornecedor
  observacoes_internas   text,
  criado_em              timestamptz not null default now(),
  criado_por             uuid,
  atualizado_em          timestamptz not null default now(),
  atualizado_por         uuid
);
create index if not exists pedidos_compra_sit_idx on public.pedidos_compra (empresa_id, situacao);
create index if not exists pedidos_compra_forn_idx on public.pedidos_compra (fornecedor_id);

create table if not exists public.pedidos_compra_itens (
  id                       bigserial primary key,
  pedido_id                bigint not null references public.pedidos_compra(id) on delete cascade,
  produto_id               bigint references public.produtos(id),
  descricao                text not null,
  unidade                  text,
  codigo_fornecedor        text,
  quantidade               numeric(14,4) not null check (quantidade > 0),
  valor_unitario           numeric(14,4) not null default 0,
  desconto                 numeric(14,2) not null default 0,
  valor_total              numeric(14,2) generated always as (round(quantidade * valor_unitario - desconto, 2)) stored,
  categoria_financeira_id  bigint references public.categorias_financeiras(id),
  quantidade_recebida      numeric(14,4) not null default 0,
  observacao               text
);
create index if not exists pedidos_compra_itens_ped_idx on public.pedidos_compra_itens (pedido_id);

create table if not exists public.pedidos_compra_recebimentos (
  id                bigserial primary key,
  pedido_id         bigint not null references public.pedidos_compra(id),
  nf_numero         text not null,
  nf_serie          text,
  nf_chave          text,
  nf_data_emissao   date not null,
  data_recebimento  date not null default current_date,
  valor_nf          numeric(14,2) not null,
  itens             jsonb,                 -- [{item_id, quantidade}]
  observacao        text,
  criado_em         timestamptz not null default now(),
  criado_por        uuid default auth.uid()
);

create table if not exists public.pedidos_compra_eventos (
  id         bigserial primary key,
  pedido_id  bigint not null references public.pedidos_compra(id) on delete cascade,
  em         timestamptz not null default now(),
  por        uuid default auth.uid(),
  acao       text not null,
  detalhe    text,
  dados      jsonb
);
create index if not exists pedidos_compra_eventos_ped_idx on public.pedidos_compra_eventos (pedido_id, em);

-- vínculo com o contas a pagar (coluna já existia)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'titulos_pagar_pedido_compra_fk') then
    alter table public.titulos_pagar add constraint titulos_pagar_pedido_compra_fk foreign key (pedido_compra_id) references public.pedidos_compra(id) not valid;
  end if;
end $$;
create index if not exists titulos_pagar_pc_idx on public.titulos_pagar (pedido_compra_id) where pedido_compra_id is not null;

-- carimbo / auditoria
drop trigger if exists carimbo on public.pedidos_compra;
create trigger carimbo before insert or update on public.pedidos_compra for each row execute function public.carimbo_cadastro();
select public.ligar_auditoria(t) from unnest(array['pedidos_compra','compras_alcadas']) t;

-- ---------- Acesso: leitura direta; gravação só pelas funções abaixo ----------
alter table public.compras_alcadas enable row level security;
alter table public.pedidos_compra enable row level security;
alter table public.pedidos_compra_itens enable row level security;
alter table public.pedidos_compra_recebimentos enable row level security;
alter table public.pedidos_compra_eventos enable row level security;
drop policy if exists "ver alcadas" on public.compras_alcadas;
create policy "ver alcadas" on public.compras_alcadas for select to authenticated using ((select public.pode('compras')));
drop policy if exists "admin alcadas" on public.compras_alcadas;
create policy "admin alcadas" on public.compras_alcadas for all to authenticated using ((select public.eh_admin())) with check ((select public.eh_admin()));
drop policy if exists "ver pedidos compra" on public.pedidos_compra;
create policy "ver pedidos compra" on public.pedidos_compra for select to authenticated using ((select public.pode('compras')) or (select public.pode('pagar')));
drop policy if exists "ver pc itens" on public.pedidos_compra_itens;
create policy "ver pc itens" on public.pedidos_compra_itens for select to authenticated using ((select public.pode('compras')) or (select public.pode('pagar')));
drop policy if exists "ver pc receb" on public.pedidos_compra_recebimentos;
create policy "ver pc receb" on public.pedidos_compra_recebimentos for select to authenticated using ((select public.pode('compras')) or (select public.pode('pagar')));
drop policy if exists "ver pc eventos" on public.pedidos_compra_eventos;
create policy "ver pc eventos" on public.pedidos_compra_eventos for select to authenticated using ((select public.pode('compras')) or (select public.pode('pagar')));

insert into public.acoes (id, modulo_id, nome, descricao, ordem) values
  ('compras.aprovar', 'compras', 'Aprovar pedidos de compra', 'Usado quando não há escala de aprovação cadastrada (ou para aprovar em qualquer nível).', 1)
on conflict (id) do nothing;

-- ---------- Funções ----------
create or replace function public.pc_evento(p_id bigint, p_acao text, p_detalhe text default null, p_dados jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.pedidos_compra_eventos (pedido_id, acao, detalhe, dados) values (p_id, p_acao, p_detalhe, p_dados);
$$;

create or replace function public.pc_recalcular(p_id bigint)
returns void language sql security definer set search_path = public as $$
  update public.pedidos_compra p set
    valor_produtos = coalesce((select sum(valor_total) from public.pedidos_compra_itens where pedido_id = p_id), 0),
    valor_total = coalesce((select sum(valor_total) from public.pedidos_compra_itens where pedido_id = p_id), 0) + p.frete + p.outras_despesas - p.desconto
  where p.id = p_id;
$$;

-- Pode aprovar o próximo nível deste pedido?
create or replace function public.pc_pode_aprovar(p_id bigint)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare p public.pedidos_compra; v_nivel int;
begin
  select * into p from public.pedidos_compra where id = p_id;
  if p.situacao <> 'em_aprovacao' then return false; end if;
  select n into v_nivel from unnest(p.niveis_exigidos) n where not n = any(p.niveis_aprovados) order by n limit 1;
  if v_nivel is null then return false; end if;
  if public.eh_admin() then return true; end if;
  if v_nivel = 0 then return public.pode_acao('compras.aprovar'); end if;
  return exists (select 1 from public.compras_alcadas a where a.ativo and a.nivel = v_nivel
                  and (a.empresa_id is null or a.empresa_id = p.empresa_id) and auth.uid() = any(a.aprovadores));
end $$;

-- Projeções no contas a pagar (o que ainda falta receber do pedido aprovado)
create or replace function public.pc_projetar(p_id bigint)
returns int language plpgsql security definer set search_path = public as $$
declare p public.pedidos_compra; v_pend numeric; v_dias int[]; v_n int; v_base date; v_cat bigint; v_i int; v_v numeric; v_acum numeric := 0;
begin
  select * into p from public.pedidos_compra where id = p_id;
  delete from public.titulos_pagar where pedido_compra_id = p_id and projecao and coalesce(valor_pago, 0) = 0 and origem = 'pedido_compra';
  if p.situacao not in ('aprovado','enviado','recebido_parcial') then return 0; end if;
  v_pend := round(p.valor_total - p.valor_recebido, 2);
  if v_pend <= 0.009 then return 0; end if;
  select dias into v_dias from public.condicoes_pagamento where id = p.condicao_pagamento_id;
  if v_dias is null or cardinality(v_dias) = 0 then v_dias := array[coalesce(public.p_dias_padrao_fornecedor(p.fornecedor_id), 0)]; end if;
  v_n := cardinality(v_dias);
  v_base := greatest(coalesce(p.data_entrega_prevista, p.data_pedido), current_date);
  -- categoria predominante dos itens (a NF real vem com rateio exato)
  select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) into v_cat
  from public.pedidos_compra_itens i left join public.produtos pr on pr.id = i.produto_id
  where i.pedido_id = p_id group by 1 order by sum(i.valor_total) desc nulls last limit 1;
  for v_i in 1..v_n loop
    v_v := case when v_i = v_n then v_pend - v_acum else round(v_pend / v_n, 2) end; v_acum := v_acum + v_v;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao,
      data_vencimento, data_programada, conta_bancaria_id, forma_pagamento_id, parcela, parcelas, origem, origem_ref, projecao,
      pedido_compra_id, situacao, valor_pago, saldo, observacoes)
    values (p.empresa_id, p.fornecedor_id, p.numero, 'Pedido de compra ' || p.numero || ' · aguardando NF', v_cat, v_v, p.data_pedido,
      v_base + v_dias[v_i], v_base + v_dias[v_i], p.conta_bancaria_id, p.forma_pagamento_id, v_i, v_n, 'pedido_compra',
      jsonb_build_object('pedido_compra', p.numero, 'aguardando_nf', true), true, p_id, 'aberto', 0, v_v,
      'Projeção automática do pedido aprovado. Vira título real no recebimento da NF (tela de Pedidos de compra).');
  end loop;
  return v_n;
end $$;

create or replace function public.p_dias_padrao_fornecedor(p_forn bigint)
returns int language sql stable security definer set search_path = public as $$
  select prazo_pagamento_dias from public.fornecedores where id = p_forn
$$;

-- Salvar (rascunho ou recusado)
create or replace function public.pedido_compra_salvar(p_pedido jsonb, p_itens jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p_pedido->>'id', '')::bigint; d public.pedidos_compra; v_sit text;
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
      -- depois de aprovado só ajusta dados de contato/observações internas (o resto exige "Reabrir")
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
    delete from public.pedidos_compra_itens where pedido_id = v_id;
    insert into public.pedidos_compra_itens (pedido_id, produto_id, descricao, unidade, codigo_fornecedor, quantidade, valor_unitario, desconto, categoria_financeira_id, observacao)
    select v_id, nullif(x->>'produto_id', '')::bigint, coalesce(nullif(x->>'descricao', ''), (select descricao from public.produtos where id = nullif(x->>'produto_id', '')::bigint), 'Item'),
           nullif(x->>'unidade', ''), nullif(x->>'codigo_fornecedor', ''), (x->>'quantidade')::numeric, coalesce((x->>'valor_unitario')::numeric, 0),
           coalesce((x->>'desconto')::numeric, 0),
           coalesce(nullif(x->>'categoria_financeira_id', '')::bigint, (select categoria_financeira_id from public.produtos where id = nullif(x->>'produto_id', '')::bigint)),
           nullif(x->>'observacao', '')
    from jsonb_array_elements(p_itens) x where coalesce((x->>'quantidade')::numeric, 0) > 0;
  end if;
  perform public.pc_recalcular(v_id);
  return v_id;
end $$;

-- Ações do fluxo
create or replace function public.pedido_compra_acao(p_id bigint, p_acao text, p_motivo text default null, p_dados jsonb default null)
returns text language plpgsql security definer set search_path = public as $$
declare p public.pedidos_compra; v_nivel int; v_nome text; v_niveis int[]; v_txt text;
begin
  select * into p from public.pedidos_compra where id = p_id for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if not public.pode('compras') then raise exception 'Sem acesso a compras'; end if;

  if p_acao = 'enviar_aprovacao' then
    if not public.pode('compras', 'criar') then raise exception 'Sem permissão'; end if;
    if p.situacao not in ('rascunho','recusado') then raise exception 'Só rascunho ou recusado vai para aprovação'; end if;
    if not exists (select 1 from public.pedidos_compra_itens where pedido_id = p_id) then raise exception 'Inclua os itens do pedido'; end if;
    if p.valor_total <= 0 then raise exception 'Pedido sem valor'; end if;
    select coalesce(array_agg(distinct a.nivel order by a.nivel), '{}') into v_niveis from public.compras_alcadas a
     where a.ativo and a.valor_minimo <= p.valor_total and (a.empresa_id is null or a.empresa_id = p.empresa_id);
    if cardinality(v_niveis) = 0 then v_niveis := '{0}'; end if;
    update public.pedidos_compra set situacao = 'em_aprovacao', niveis_exigidos = v_niveis, niveis_aprovados = '{}', motivo_recusa = null where id = p_id;
    perform public.pc_evento(p_id, 'enviado_aprovacao', 'Enviado para aprovação · R$ ' || to_char(p.valor_total, 'FM999G999G990D00'),
      jsonb_build_object('niveis', v_niveis));
    return 'em_aprovacao';

  elsif p_acao = 'aprovar' then
    if not public.pc_pode_aprovar(p_id) then raise exception 'Você não é aprovador da etapa atual deste pedido'; end if;
    select n into v_nivel from unnest(p.niveis_exigidos) n where not n = any(p.niveis_aprovados) order by n limit 1;
    select string_agg(distinct nome, ' / ') into v_nome from public.compras_alcadas where nivel = v_nivel and ativo;
    update public.pedidos_compra set niveis_aprovados = niveis_aprovados || v_nivel where id = p_id returning * into p;
    perform public.pc_evento(p_id, 'aprovado_nivel', 'Aprovado' || case when v_nivel > 0 then ' · nível ' || v_nivel || coalesce(' (' || v_nome || ')', '') else '' end
      || coalesce(' · ' || nullif(p_motivo, ''), ''), jsonb_build_object('nivel', v_nivel));
    if not exists (select 1 from unnest(p.niveis_exigidos) n where not n = any(p.niveis_aprovados)) then
      update public.pedidos_compra set situacao = 'aprovado' where id = p_id;
      perform public.pc_projetar(p_id);
      perform public.pc_evento(p_id, 'aprovado', 'Pedido aprovado · parcelas previstas lançadas no contas a pagar (aguardando NF)');
      return 'aprovado';
    end if;
    return 'em_aprovacao';

  elsif p_acao = 'recusar' then
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo da recusa'; end if;
    if p.situacao = 'em_aprovacao' then
      if not public.pc_pode_aprovar(p_id) then raise exception 'Você não é aprovador da etapa atual deste pedido'; end if;
    elsif p.situacao in ('aprovado','enviado') then
      if not (public.eh_admin() or public.pode_acao('compras.aprovar')) then raise exception 'Sem permissão para recusar pedido aprovado'; end if;
      if p.valor_recebido > 0 then raise exception 'Pedido já tem recebimento'; end if;
    else raise exception 'Este pedido não está em aprovação'; end if;
    update public.pedidos_compra set situacao = 'recusado', motivo_recusa = p_motivo, niveis_aprovados = '{}' where id = p_id;
    perform public.pc_projetar(p_id);
    perform public.pc_evento(p_id, 'recusado', 'Recusado: ' || p_motivo);
    return 'recusado';

  elsif p_acao = 'reabrir' then
    if not public.pode('compras', 'alterar') then raise exception 'Sem permissão'; end if;
    if p.situacao not in ('em_aprovacao','aprovado','enviado','recusado') then raise exception 'Não dá para reabrir nesta situação'; end if;
    if p.valor_recebido > 0 then raise exception 'Pedido já tem recebimento: não volta para rascunho'; end if;
    update public.pedidos_compra set situacao = 'rascunho', niveis_aprovados = '{}', niveis_exigidos = '{}' where id = p_id;
    perform public.pc_projetar(p_id);
    perform public.pc_evento(p_id, 'reaberto', 'Voltou para rascunho (aprovação anterior desfeita)' || coalesce(' · ' || nullif(p_motivo, ''), ''));
    return 'rascunho';

  elsif p_acao = 'enviado_fornecedor' then
    if not public.pode('compras', 'criar') then raise exception 'Sem permissão'; end if;
    if p.situacao not in ('aprovado','enviado','recebido_parcial') then raise exception 'Só pedido aprovado pode ir ao fornecedor'; end if;
    update public.pedidos_compra set situacao = case when situacao = 'aprovado' then 'enviado' else situacao end, enviado_em = now(), enviado_por = auth.uid(),
      enviado_via = p_dados->>'via', enviado_para = p_dados->>'para', pdf_path = coalesce(p_dados->>'pdf', pdf_path) where id = p_id;
    perform public.pc_evento(p_id, 'enviado_fornecedor', 'Enviado ao fornecedor por ' || coalesce(p_dados->>'via', '?') || coalesce(' para ' || (p_dados->>'para'), '')
      || ' · confirmado pelo comprador', p_dados);
    return 'enviado';

  elsif p_acao = 'pdf' then
    update public.pedidos_compra set pdf_path = p_dados->>'pdf' where id = p_id;
    perform public.pc_evento(p_id, 'pdf', 'PDF gerado', p_dados);
    return p.situacao;

  elsif p_acao = 'cancelar' then
    if not public.pode('compras', 'total') then raise exception 'Sem permissão para cancelar pedido de compra'; end if;
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo do cancelamento'; end if;
    if p.situacao in ('recebido','cancelado') then raise exception 'Pedido % não pode ser cancelado', p.situacao; end if;
    update public.pedidos_compra set situacao = 'cancelado', motivo_cancelamento = p_motivo where id = p_id;
    perform public.pc_projetar(p_id);
    perform public.pc_evento(p_id, 'cancelado', 'Cancelado: ' || p_motivo);
    return 'cancelado';

  elsif p_acao = 'comentario' then
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Escreva o comentário'; end if;
    perform public.pc_evento(p_id, 'comentario', p_motivo);
    return p.situacao;
  end if;
  raise exception 'Ação desconhecida: %', p_acao;
end $$;

-- Recebimento da NF → títulos reais (rateio pelas categorias dos itens recebidos)
create or replace function public.pedido_compra_receber(p_id bigint, p_nf jsonb, p_itens jsonb, p_parcelas jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare p public.pedidos_compra; v_rec bigint; v_valor numeric; v_soma numeric; x jsonb; v_n int; v_i int := 0; v_tid bigint;
        v_cats jsonb; v_c record; v_acum numeric; v_parte numeric; v_ncat int; v_k int; v_nf text; v_venc date; v_item_tot numeric;
begin
  select * into p from public.pedidos_compra where id = p_id for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if not (public.pode('compras', 'alterar') or public.pode('pagar', 'criar')) then raise exception 'Sem permissão para registrar recebimento'; end if;
  if p.situacao not in ('aprovado','enviado','recebido_parcial') then raise exception 'Pedido precisa estar aprovado para receber'; end if;
  v_nf := nullif(trim(p_nf->>'numero'), '');
  if v_nf is null then raise exception 'Informe o número da NF'; end if;
  v_valor := round((p_nf->>'valor')::numeric, 2);
  if coalesce(v_valor, 0) <= 0 then raise exception 'Informe o valor da NF'; end if;
  select coalesce(sum(round((y->>'valor')::numeric, 2)), 0), count(*) into v_soma, v_n from jsonb_array_elements(p_parcelas) y;
  if v_n = 0 then raise exception 'Informe as parcelas'; end if;
  if abs(v_soma - v_valor) > 0.01 then raise exception 'Soma das parcelas (%) diferente do valor da NF (%)', v_soma, v_valor; end if;

  -- quantidades recebidas
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

  -- peso de cada categoria = valor dos itens recebidos nesta NF
  select coalesce(jsonb_agg(jsonb_build_object('c', c, 'v', v)), '[]'), count(*) into v_cats, v_ncat from (
    select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) c,
           sum(round(i.valor_total * (r.quantidade / i.quantidade), 2)) v
    from jsonb_to_recordset(coalesce(p_itens, '[]')) r(item_id bigint, quantidade numeric)
    join public.pedidos_compra_itens i on i.id = r.item_id and i.pedido_id = p_id
    left join public.produtos pr on pr.id = i.produto_id
    where r.quantidade > 0 group by 1) s;
  select coalesce(sum((e->>'v')::numeric), 0) into v_item_tot from jsonb_array_elements(v_cats) e;

  for x in select * from jsonb_array_elements(p_parcelas) loop
    v_i := v_i + 1; v_venc := (x->>'vencimento')::date;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento,
      data_programada, conta_bancaria_id, forma_pagamento_id, codigo_barras, parcela, parcelas, origem, origem_ref, projecao, pedido_compra_id, situacao, valor_pago, saldo)
    values (p.empresa_id, p.fornecedor_id, 'NF ' || v_nf, 'NF ' || v_nf || ' · ' || p.numero,
      case when v_ncat = 1 then ((v_cats->0)->>'c')::bigint end, round((x->>'valor')::numeric, 2),
      coalesce(nullif(p_nf->>'data_emissao', '')::date, current_date), v_venc, v_venc, p.conta_bancaria_id, p.forma_pagamento_id, nullif(x->>'codigo_barras', ''),
      v_i, v_n, 'pedido_compra', jsonb_build_object('pedido_compra', p.numero, 'recebimento_id', v_rec, 'nf', v_nf), false, p_id, 'aberto', 0, round((x->>'valor')::numeric, 2))
    returning id into v_tid;
    if v_ncat > 1 and v_item_tot > 0 and not exists (select 1 from jsonb_array_elements(v_cats) e where e->>'c' is null) then   -- rateio proporcional; centavos no último
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
    situacao = case when not exists (select 1 from public.pedidos_compra_itens where pedido_id = p_id and quantidade_recebida < quantidade)
                    then 'recebido' else 'recebido_parcial' end
  where id = p_id;
  perform public.pc_projetar(p_id);
  perform public.pc_evento(p_id, 'recebido', 'NF ' || v_nf || ' recebida · R$ ' || to_char(v_valor, 'FM999G999G990D00') || ' · ' || v_n || ' parcela(s) no contas a pagar',
    jsonb_build_object('recebimento_id', v_rec));
  return v_rec;
end $$;

-- Encerrar saldo de pedido recebido parcialmente (o resto não vem mais)
create or replace function public.pedido_compra_encerrar(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.pode('compras', 'alterar') then raise exception 'Sem permissão'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo'; end if;
  update public.pedidos_compra set situacao = 'recebido' where id = p_id and situacao = 'recebido_parcial';
  if not found then raise exception 'Só pedido recebido parcialmente pode ser encerrado'; end if;
  perform public.pc_projetar(p_id);
  perform public.pc_evento(p_id, 'encerrado', 'Saldo encerrado (não será mais entregue): ' || p_motivo);
end $$;

revoke execute on function public.pc_projetar(bigint), public.pc_recalcular(bigint), public.pc_evento(bigint, text, text, jsonb), public.p_dias_padrao_fornecedor(bigint) from public, anon, authenticated;
grant execute on function public.pedido_compra_salvar(jsonb, jsonb), public.pedido_compra_acao(bigint, text, text, jsonb),
  public.pedido_compra_receber(bigint, jsonb, jsonb, jsonb), public.pedido_compra_encerrar(bigint, text), public.pc_pode_aprovar(bigint) to authenticated;

-- Menu: tela Compras passa a existir
update public.modulos set nome = 'Pedidos de compra' where id = 'compras';

-- ---------- Arquivos (PDF do pedido) ----------
insert into storage.buckets (id, name, public) values ('compras', 'compras', false) on conflict (id) do nothing;
drop policy if exists "compras ler" on storage.objects;
create policy "compras ler" on storage.objects for select to authenticated using (bucket_id = 'compras' and (select public.pode('compras')));
drop policy if exists "compras gravar" on storage.objects;
create policy "compras gravar" on storage.objects for insert to authenticated with check (bucket_id = 'compras' and (select public.pode('compras', 'criar')));
drop policy if exists "compras atualizar" on storage.objects;
create policy "compras atualizar" on storage.objects for update to authenticated using (bucket_id = 'compras' and (select public.pode('compras', 'criar')));
