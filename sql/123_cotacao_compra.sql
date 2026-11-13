-- =====================================================================
-- 123 · Cotação de fornecedores (entre a solicitação aprovada e o pedido de compra)
--  · Rodar DEPOIS do 122 (tempo real): usa public.ligar_tempo_real.
--  · O comprador junta itens de solicitações aprovadas numa cotação. Os fornecedores ligados ao produto
--    no cadastro (e o fornecedor padrão do serviço) já entram sugeridos; dá para trocar ou incluir outros.
--  · Por fornecedor: preço de cada item, condição e forma de pagamento, prazo de entrega, frete e validade.
--  · Análise automática por item: nota de 0 a 100 de cada fornecedor (preço com IPI e frete rateado 50%,
--    prazo de pagamento 20%, prazo de entrega 15%, histórico de entregas no prazo com o fornecedor 15%)
--    e a indicação do mais vantajoso.
--  · O próprio comprador escolhe o vencedor de cada item; se não for o indicado, a justificativa é obrigatória.
--    Depois gera os pedidos:
--    um pedido de compra em rascunho por fornecedor vencedor, já com preços, condição, frete e entrega.
--    O valor continua passando pela escala de aprovação do pedido de compra.
--  · Os preços cotados atualizam o cadastro produto × fornecedor (preço e data da cotação).
--  · Rastreio: solicitação → cotação → pedido, na linha do tempo do pedido e nas telas.
--  · A solicitação aprovada não gera mais pedido direto: passa sempre pela cotação.
--  · Contadores do menu: solicitações aguardando aprovação (amarelo) e aprovadas esperando o comprador
--    (vermelho); cotações em aberto.
-- =====================================================================

-- ---------- Tela e permissões ----------
insert into public.modulos (id, grupo, nome, ordem) values ('cotacoes_compra', 'suprimentos', 'Cotações de fornecedores', 31)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('compras', 'cotacoes_compra', 'editar')
on conflict do nothing;

-- ---------- Tabelas ----------
create table if not exists public.cotacoes_compra (
  id              bigserial primary key,
  numero          text unique,
  empresa_id      integer references public.empresas(id),
  comprador_id    uuid default auth.uid() references public.usuarios(id),
  data_cotacao    date not null default current_date,
  data_limite     date,
  situacao        text not null default 'aberta' check (situacao in ('aberta','concluida','cancelada')),
  observacoes     text,
  motivo_cancelamento text,
  concluida_em    timestamptz,
  criado_em timestamptz default now(), criado_por uuid, atualizado_em timestamptz default now(), atualizado_por uuid
);
create index if not exists cotacoes_compra_situacao_idx on public.cotacoes_compra (situacao);

create table if not exists public.cotacoes_compra_itens (
  id                  bigserial primary key,
  cotacao_id          bigint not null references public.cotacoes_compra(id) on delete cascade,
  solicitacao_item_id bigint references public.solicitacoes_compra_itens(id) on delete set null,
  produto_id          bigint references public.produtos(id),
  servico_id          bigint references public.servicos(id),
  descricao           text,
  unidade             text,
  quantidade          numeric not null check (quantidade > 0),
  vencedor_id         bigint,              -- cotacoes_compra_fornecedores.id escolhido
  motivo_escolha      text,                -- quando o vencedor não é o menor preço
  constraint cotacao_item_do_cadastro check ((produto_id is not null) <> (servico_id is not null))
);
create index if not exists cotacoes_compra_itens_cot_idx on public.cotacoes_compra_itens (cotacao_id);
create index if not exists cotacoes_compra_itens_sol_idx on public.cotacoes_compra_itens (solicitacao_item_id);

create table if not exists public.cotacoes_compra_fornecedores (
  id                    bigserial primary key,
  cotacao_id            bigint not null references public.cotacoes_compra(id) on delete cascade,
  fornecedor_id         bigint not null references public.fornecedores(id),
  condicao_pagamento_id bigint references public.condicoes_pagamento(id),
  forma_pagamento_id    bigint references public.formas_pagamento(id),
  prazo_entrega_dias    integer check (prazo_entrega_dias is null or prazo_entrega_dias >= 0),
  frete                 numeric not null default 0 check (frete >= 0),
  validade              date,
  contato               text,
  observacao            text,
  pedido_id             bigint references public.pedidos_compra(id) on delete set null,
  unique (cotacao_id, fornecedor_id)
);
create index if not exists cotacoes_compra_forn_cot_idx on public.cotacoes_compra_fornecedores (cotacao_id);

create table if not exists public.cotacoes_compra_precos (
  id              bigserial primary key,
  cotacao_forn_id bigint not null references public.cotacoes_compra_fornecedores(id) on delete cascade,
  cotacao_item_id bigint not null references public.cotacoes_compra_itens(id) on delete cascade,
  valor_unitario  numeric not null check (valor_unitario >= 0),
  ipi_pct         numeric check (ipi_pct is null or ipi_pct between 0 and 100),
  unique (cotacao_forn_id, cotacao_item_id)
);
create index if not exists cotacoes_compra_precos_item_idx on public.cotacoes_compra_precos (cotacao_item_id);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'cotacao_item_vencedor_fk') then
    alter table public.cotacoes_compra_itens add constraint cotacao_item_vencedor_fk
      foreign key (vencedor_id) references public.cotacoes_compra_fornecedores(id) on delete set null;
  end if;
end $$;

-- solicitação: item em cotação (enquanto a cotação não for cancelada, ele sai da fila do comprador)
alter table public.solicitacoes_compra_itens add column if not exists cotacao_id bigint references public.cotacoes_compra(id) on delete set null;
create index if not exists solicitacoes_compra_itens_cot_idx on public.solicitacoes_compra_itens (cotacao_id);

drop trigger if exists carimbo on public.cotacoes_compra;
create trigger carimbo before insert or update on public.cotacoes_compra for each row execute function public.carimbo_cadastro();

-- ---------- Segurança: leitura pela tela de cotações; gravação só pelas funções ----------
alter table public.cotacoes_compra enable row level security;
alter table public.cotacoes_compra_itens enable row level security;
alter table public.cotacoes_compra_fornecedores enable row level security;
alter table public.cotacoes_compra_precos enable row level security;
drop policy if exists "ver cotacoes" on public.cotacoes_compra;
create policy "ver cotacoes" on public.cotacoes_compra for select to authenticated using ((select public.pode('cotacoes_compra')));
drop policy if exists "ver cotacoes itens" on public.cotacoes_compra_itens;
create policy "ver cotacoes itens" on public.cotacoes_compra_itens for select to authenticated using ((select public.pode('cotacoes_compra')));
drop policy if exists "ver cotacoes fornecedores" on public.cotacoes_compra_fornecedores;
create policy "ver cotacoes fornecedores" on public.cotacoes_compra_fornecedores for select to authenticated using ((select public.pode('cotacoes_compra')));
drop policy if exists "ver cotacoes precos" on public.cotacoes_compra_precos;
create policy "ver cotacoes precos" on public.cotacoes_compra_precos for select to authenticated using ((select public.pode('cotacoes_compra')));
revoke insert, update, delete on public.cotacoes_compra, public.cotacoes_compra_itens, public.cotacoes_compra_fornecedores, public.cotacoes_compra_precos from anon, authenticated;

-- quem cota também enxerga todas as solicitações (fila do comprador)
create or replace function public.sc_ve_todas()
returns boolean language sql stable security definer set search_path = public as $$
  select public.pode('solicitacoes_compra', 'total') or public.pode('compras', 'criar') or public.pode('cotacoes_compra', 'criar')
      or public.pode_acao('compras.aprovar_solicitacao')
$$;

-- a solicitação aprovada não vira mais pedido direto: passa pela cotação
revoke execute on function public.solicitacao_compra_gerar_pedido(bigint[], bigint, integer) from authenticated;

-- cotações dos itens que a pessoa enxerga (rastreio na tela de solicitações)
create or replace function public.sc_cotacoes()
returns table (id bigint, numero text, situacao text)
language sql stable security definer set search_path = public as $$
  select distinct c.id, c.numero, c.situacao
    from public.solicitacoes_compra_itens i join public.solicitacoes_compra s on s.id = i.solicitacao_id
    join public.cotacoes_compra c on c.id = i.cotacao_id
   where (select public.pode('solicitacoes_compra')) and (s.solicitante_id = auth.uid() or (select public.sc_ve_todas()))
$$;
revoke execute on function public.sc_cotacoes() from public, anon;
grant execute on function public.sc_cotacoes() to authenticated;

-- ---------- Criar a cotação a partir dos itens aprovados ----------
create or replace function public.cotacao_criar(p_itens bigint[], p_empresa integer)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; n int;
begin
  if not public.pode('cotacoes_compra', 'criar') then raise exception 'Sem permissão para criar cotação'; end if;
  if coalesce(array_length(p_itens, 1), 0) = 0 then raise exception 'Marque pelo menos um item'; end if;
  perform 1 from public.solicitacoes_compra_itens where id = any(p_itens) for update;
  select count(*) into n from public.solicitacoes_compra_itens i join public.solicitacoes_compra s on s.id = i.solicitacao_id
    left join public.pedidos_compra p on p.id = i.pedido_id left join public.cotacoes_compra c on c.id = i.cotacao_id
   where i.id = any(p_itens) and s.situacao = 'aprovado'
     and (i.pedido_id is null or p.situacao = 'cancelado') and (i.cotacao_id is null or c.situacao = 'cancelada');
  if n <> (select count(distinct x) from unnest(p_itens) x) then
    raise exception 'Algum item não está mais na fila (solicitação não aprovada, já em cotação ou em pedido). Atualize a tela.';
  end if;
  insert into public.cotacoes_compra (empresa_id, comprador_id) values (p_empresa, auth.uid()) returning id into v_id;
  update public.cotacoes_compra set numero = 'CT-' || lpad(v_id::text, 5, '0') where id = v_id;
  insert into public.cotacoes_compra_itens (cotacao_id, solicitacao_item_id, produto_id, servico_id, descricao, unidade, quantidade)
  select v_id, i.id, i.produto_id, i.servico_id, i.descricao, i.unidade, i.quantidade
    from public.solicitacoes_compra_itens i where i.id = any(p_itens) order by i.solicitacao_id, i.id;
  update public.solicitacoes_compra_itens set cotacao_id = v_id where id = any(p_itens);
  -- fornecedores sugeridos: os do cadastro do produto (preferencial primeiro) e o padrão do serviço, com o último preço como ponto de partida
  insert into public.cotacoes_compra_fornecedores (cotacao_id, fornecedor_id)
  select distinct v_id, x.fornecedor_id from (
    select pf.fornecedor_id from public.cotacoes_compra_itens ci join public.produto_fornecedores pf on pf.produto_id = ci.produto_id where ci.cotacao_id = v_id
    union select sv.fornecedor_id from public.cotacoes_compra_itens ci join public.servicos sv on sv.id = ci.servico_id where ci.cotacao_id = v_id and sv.fornecedor_id is not null) x
  join public.fornecedores f on f.id = x.fornecedor_id and coalesce(f.situacao, 'ativo') = 'ativo'
  on conflict do nothing;
  insert into public.cotacoes_compra_precos (cotacao_forn_id, cotacao_item_id, valor_unitario, ipi_pct)
  select cf.id, ci.id, pf.preco, pf.ipi_pct
    from public.cotacoes_compra_itens ci join public.produto_fornecedores pf on pf.produto_id = ci.produto_id and pf.preco > 0
    join public.cotacoes_compra_fornecedores cf on cf.cotacao_id = v_id and cf.fornecedor_id = pf.fornecedor_id
   where ci.cotacao_id = v_id
  on conflict do nothing;
  return v_id;
end $$;
revoke execute on function public.cotacao_criar(bigint[], integer) from public, anon;
grant execute on function public.cotacao_criar(bigint[], integer) to authenticated;

-- ---------- Salvar o mapa da cotação ----------
-- p_cab: {empresa_id, data_limite, observacoes}
-- p_forn: [{fornecedor_id, condicao_pagamento_id, forma_pagamento_id, prazo_entrega_dias, frete, validade, contato, observacao,
--           precos: [{item_id, valor_unitario, ipi_pct}]}]
-- p_itens: [{id, vencedor_fornecedor_id, motivo_escolha}]  (item que sair da lista volta para a fila do comprador)
create or replace function public.cotacao_salvar(p_id bigint, p_cab jsonb, p_forn jsonb, p_itens jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_sit text; f jsonb; v_cf bigint;
begin
  if not public.pode('cotacoes_compra', 'alterar') then raise exception 'Sem permissão para alterar cotação'; end if;
  select situacao into v_sit from public.cotacoes_compra where id = p_id for update;
  if v_sit is null then raise exception 'Cotação não encontrada'; end if;
  if v_sit <> 'aberta' then raise exception 'Cotação % não está aberta', p_id; end if;
  if coalesce(jsonb_array_length(p_itens), 0) = 0 then raise exception 'A cotação precisa de pelo menos um item (para desistir, cancele a cotação)'; end if;
  if exists (select 1 from jsonb_array_elements(p_forn) x group by x->>'fornecedor_id' having count(*) > 1) then
    raise exception 'O mesmo fornecedor aparece duas vezes na cotação';
  end if;
  update public.cotacoes_compra set empresa_id = nullif(p_cab->>'empresa_id', '')::int, data_limite = nullif(p_cab->>'data_limite', '')::date,
    observacoes = upper(nullif(trim(coalesce(p_cab->>'observacoes', '')), '')) where id = p_id;
  -- itens retirados: voltam para a fila
  update public.solicitacoes_compra_itens si set cotacao_id = null
    from public.cotacoes_compra_itens ci
   where ci.cotacao_id = p_id and si.id = ci.solicitacao_item_id
     and ci.id not in (select (x->>'id')::bigint from jsonb_array_elements(p_itens) x);
  delete from public.cotacoes_compra_itens where cotacao_id = p_id and id not in (select (x->>'id')::bigint from jsonb_array_elements(p_itens) x);
  -- fornecedores: refaz a lista (preços vão junto)
  update public.cotacoes_compra_itens set vencedor_id = null where cotacao_id = p_id;
  delete from public.cotacoes_compra_fornecedores where cotacao_id = p_id;
  for f in select * from jsonb_array_elements(coalesce(p_forn, '[]')) loop
    insert into public.cotacoes_compra_fornecedores (cotacao_id, fornecedor_id, condicao_pagamento_id, forma_pagamento_id, prazo_entrega_dias, frete, validade, contato, observacao)
    values (p_id, (f->>'fornecedor_id')::bigint, nullif(f->>'condicao_pagamento_id', '')::bigint, nullif(f->>'forma_pagamento_id', '')::bigint,
            nullif(f->>'prazo_entrega_dias', '')::int, coalesce(nullif(f->>'frete', '')::numeric, 0), nullif(f->>'validade', '')::date,
            nullif(trim(coalesce(f->>'contato', '')), ''), upper(nullif(trim(coalesce(f->>'observacao', '')), '')))
    returning id into v_cf;
    insert into public.cotacoes_compra_precos (cotacao_forn_id, cotacao_item_id, valor_unitario, ipi_pct)
    select v_cf, (x->>'item_id')::bigint, (x->>'valor_unitario')::numeric, nullif(x->>'ipi_pct', '')::numeric
      from jsonb_array_elements(coalesce(f->'precos', '[]')) x
      join public.cotacoes_compra_itens ci on ci.id = (x->>'item_id')::bigint and ci.cotacao_id = p_id
     where nullif(x->>'valor_unitario', '') is not null;
  end loop;
  -- vencedor de cada item (precisa ter preço do fornecedor escolhido)
  update public.cotacoes_compra_itens ci set vencedor_id = cf.id, motivo_escolha = upper(nullif(trim(coalesce(x->>'motivo_escolha', '')), ''))
    from jsonb_array_elements(p_itens) x
    join public.cotacoes_compra_fornecedores cf on cf.cotacao_id = p_id and cf.fornecedor_id = nullif(x->>'vencedor_fornecedor_id', '')::bigint
   where ci.id = (x->>'id')::bigint and ci.cotacao_id = p_id
     and exists (select 1 from public.cotacoes_compra_precos pr where pr.cotacao_forn_id = cf.id and pr.cotacao_item_id = ci.id);
  return p_id;
end $$;
revoke execute on function public.cotacao_salvar(bigint, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.cotacao_salvar(bigint, jsonb, jsonb, jsonb) to authenticated;

-- ---------- Análise automática: nota de cada fornecedor em cada item e indicação ----------
-- preço efetivo = unitário + IPI + frete do fornecedor rateado pelo valor dos itens que ele cotou
-- prazo de pagamento = média dos dias da condição (mais prazo, melhor); sem condição conta como à vista
-- entrega = dias informados (menos, melhor); sem prazo informado fica com nota média
-- histórico = pedidos recebidos desse fornecedor que chegaram até a data prevista (sem histórico: nota média)
create or replace function public.cotacao_analise(p_id bigint)
returns table (item_id bigint, cotacao_forn_id bigint, fornecedor_id bigint, preco_efetivo numeric, dias_pagamento numeric,
               prazo_entrega_dias integer, compras_recebidas integer, no_prazo integer,
               n_preco numeric, n_pagamento numeric, n_entrega numeric, n_historico numeric, nota numeric, recomendado boolean)
language sql stable security definer set search_path = public as $$
  with base as (
    select ci.id item_id, cf.id cf_id, cf.fornecedor_id, ci.quantidade, pr.valor_unitario * (1 + coalesce(pr.ipi_pct, 0) / 100) unit_ipi,
           cf.frete, cf.prazo_entrega_dias,
           coalesce((select avg(d) from unnest(cp.dias) d), 0) dias_pag
      from public.cotacoes_compra_itens ci
      join public.cotacoes_compra_precos pr on pr.cotacao_item_id = ci.id
      join public.cotacoes_compra_fornecedores cf on cf.id = pr.cotacao_forn_id
      left join public.condicoes_pagamento cp on cp.id = cf.condicao_pagamento_id
     where ci.cotacao_id = p_id and pr.valor_unitario > 0 and (select public.pode('cotacoes_compra'))
  ), tot as (select cf_id, sum(unit_ipi * quantidade) total from base group by cf_id),
  hist as (
    select p.fornecedor_id, count(*)::int n,
           count(*) filter (where p.data_entrega_prevista is null or r.primeiro <= p.data_entrega_prevista)::int ok
      from public.pedidos_compra p
      join (select pedido_id, min(data_recebimento) primeiro from public.pedidos_compra_recebimentos group by pedido_id) r on r.pedido_id = p.id
     where p.situacao in ('recebido', 'recebido_parcial') and p.fornecedor_id in (select fornecedor_id from base)
     group by p.fornecedor_id
  ), ef as (
    select b.*, b.unit_ipi + case when t.total > 0 then b.frete * (b.unit_ipi * b.quantidade / t.total) / b.quantidade else 0 end preco_ef,
           coalesce(h.n, 0) n_hist, coalesce(h.ok, 0) ok_hist
      from base b join tot t on t.cf_id = b.cf_id left join hist h on h.fornecedor_id = b.fornecedor_id
  ), notas as (
    select e.*,
           min(preco_ef) over w / nullif(preco_ef, 0) np,
           case when max(dias_pag) over w > 0 then dias_pag / max(dias_pag) over w else 1 end npg,
           case when prazo_entrega_dias is null then 0.5 else (min(prazo_entrega_dias) over w + 1)::numeric / (prazo_entrega_dias + 1) end ne,
           case when n_hist = 0 then 0.5 else (ok_hist + 1)::numeric / (n_hist + 2) end nh
      from ef e window w as (partition by item_id)
  ), fim as (
    select n.*, round(100 * (0.5 * np + 0.2 * npg + 0.15 * ne + 0.15 * nh), 1) nt from notas n
  )
  select item_id, cf_id, fornecedor_id, round(preco_ef, 4), round(dias_pag, 1), prazo_entrega_dias, n_hist, ok_hist,
         round(100 * np, 1), round(100 * npg, 1), round(100 * ne, 1), round(100 * nh, 1), nt,
         row_number() over (partition by item_id order by nt desc, preco_ef, cf_id) = 1
    from fim
$$;
revoke execute on function public.cotacao_analise(bigint) from public, anon;
grant execute on function public.cotacao_analise(bigint) to authenticated;

-- ---------- Gerar os pedidos: um por fornecedor vencedor ----------
create or replace function public.cotacao_gerar_pedidos(p_id bigint)
returns bigint[] language plpgsql security definer set search_path = public as $$
declare c public.cotacoes_compra; f record; v_ped bigint; v_peds bigint[] := '{}'; v_scs text;
begin
  if not public.pode('cotacoes_compra', 'criar') or not public.pode('compras', 'criar') then raise exception 'Sem permissão para gerar pedidos de compra'; end if;
  select * into c from public.cotacoes_compra where id = p_id for update;
  if c.id is null then raise exception 'Cotação não encontrada'; end if;
  if c.situacao <> 'aberta' then raise exception 'Cotação % não está aberta', c.numero; end if;
  if c.empresa_id is null then raise exception 'Escolha a empresa da cotação (CNPJ dos pedidos)'; end if;
  if exists (select 1 from public.cotacoes_compra_itens where cotacao_id = p_id and vencedor_id is null) then
    raise exception 'Escolha o fornecedor vencedor de todos os itens (ou retire o item da cotação)';
  end if;
  -- escolheu outro que não o indicado pela análise: precisa de justificativa
  if exists (select 1 from public.cotacoes_compra_itens ci join public.cotacao_analise(p_id) a on a.item_id = ci.id and a.recomendado
              where ci.cotacao_id = p_id and ci.vencedor_id <> a.cotacao_forn_id and ci.motivo_escolha is null) then
    raise exception 'Há item com fornecedor diferente do indicado pela análise sem justificativa da escolha';
  end if;
  for f in select cf.*, fo.email, fo.telefone, fo.contato as contato_cad from public.cotacoes_compra_fornecedores cf join public.fornecedores fo on fo.id = cf.fornecedor_id
            where cf.cotacao_id = p_id and exists (select 1 from public.cotacoes_compra_itens ci where ci.vencedor_id = cf.id) order by cf.id loop
    select string_agg(distinct s.numero, ', ') into v_scs
      from public.cotacoes_compra_itens ci join public.solicitacoes_compra_itens si on si.id = ci.solicitacao_item_id join public.solicitacoes_compra s on s.id = si.solicitacao_id
     where ci.vencedor_id = f.id;
    v_ped := public.pedido_compra_salvar(jsonb_build_object('empresa_id', c.empresa_id, 'fornecedor_id', f.fornecedor_id,
               'condicao_pagamento_id', f.condicao_pagamento_id, 'forma_pagamento_id', f.forma_pagamento_id, 'frete', f.frete,
               'data_entrega_prevista', case when f.prazo_entrega_dias is not null then current_date + f.prazo_entrega_dias end,
               'contato_fornecedor', coalesce(f.contato, f.contato_cad), 'email_fornecedor', f.email, 'whatsapp_fornecedor', f.telefone,
               'observacoes_internas', 'GERADO DA COTAÇÃO ' || c.numero || coalesce(' · SOLICITAÇÕES ' || v_scs, '')),
             (select jsonb_agg(jsonb_build_object('produto_id', ci.produto_id, 'servico_id', ci.servico_id,
                       'descricao', case when ci.servico_id is not null then ci.descricao end, 'unidade', ci.unidade, 'quantidade', ci.quantidade,
                       'valor_unitario', pr.valor_unitario, 'codigo_fornecedor', pf.codigo_fornecedor,
                       'observacao', c.numero || coalesce(' · ' || s.numero, '') || case when si.urgencia in ('alta','urgente') then ' · ' || upper(si.urgencia) else '' end
                                     || coalesce(' · ' || si.observacao, '')) order by ci.id)
                from public.cotacoes_compra_itens ci join public.cotacoes_compra_precos pr on pr.cotacao_forn_id = f.id and pr.cotacao_item_id = ci.id
                left join public.solicitacoes_compra_itens si on si.id = ci.solicitacao_item_id left join public.solicitacoes_compra s on s.id = si.solicitacao_id
                left join public.produto_fornecedores pf on pf.produto_id = ci.produto_id and pf.fornecedor_id = f.fornecedor_id
               where ci.vencedor_id = f.id));
    update public.cotacoes_compra_fornecedores set pedido_id = v_ped where id = f.id;
    update public.solicitacoes_compra_itens si set pedido_id = v_ped
      from public.cotacoes_compra_itens ci where ci.vencedor_id = f.id and si.id = ci.solicitacao_item_id;
    perform public.pc_evento(v_ped, 'cotacao', 'Gerado da cotação ' || c.numero || coalesce(' (solicitações ' || v_scs || ')', ''), jsonb_build_object('cotacao_id', p_id));
    v_peds := v_peds || v_ped;
  end loop;
  -- preços cotados (de todos os fornecedores) atualizam o cadastro produto × fornecedor
  insert into public.produto_fornecedores (produto_id, fornecedor_id, preco, ipi_pct, cotacao_data, cotacao_ref)
  select ci.produto_id, cf.fornecedor_id, pr.valor_unitario, pr.ipi_pct, current_date, c.numero
    from public.cotacoes_compra_precos pr join public.cotacoes_compra_itens ci on ci.id = pr.cotacao_item_id
    join public.cotacoes_compra_fornecedores cf on cf.id = pr.cotacao_forn_id
   where ci.cotacao_id = p_id and ci.produto_id is not null and pr.valor_unitario > 0
  on conflict (produto_id, fornecedor_id) do update set preco = excluded.preco, ipi_pct = coalesce(excluded.ipi_pct, produto_fornecedores.ipi_pct),
    cotacao_data = excluded.cotacao_data, cotacao_ref = excluded.cotacao_ref;
  update public.cotacoes_compra set situacao = 'concluida', concluida_em = now() where id = p_id;
  return v_peds;
end $$;
revoke execute on function public.cotacao_gerar_pedidos(bigint) from public, anon;
grant execute on function public.cotacao_gerar_pedidos(bigint) to authenticated;

-- ---------- Cancelar a cotação (itens voltam para a fila do comprador) ----------
create or replace function public.cotacao_cancelar(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_sit text; v_mot text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.pode('cotacoes_compra', 'alterar') then raise exception 'Sem permissão para cancelar cotação'; end if;
  if v_mot is null then raise exception 'Informe o motivo do cancelamento'; end if;
  select situacao into v_sit from public.cotacoes_compra where id = p_id for update;
  if v_sit is distinct from 'aberta' then raise exception 'Só cotação aberta pode ser cancelada'; end if;
  update public.solicitacoes_compra_itens set cotacao_id = null where cotacao_id = p_id;
  update public.cotacoes_compra set situacao = 'cancelada', motivo_cancelamento = upper(v_mot) where id = p_id;
end $$;
revoke execute on function public.cotacao_cancelar(bigint, text) from public, anon;
grant execute on function public.cotacao_cancelar(bigint, text) to authenticated;

-- ---------- Contadores do menu ----------
-- { "solicitacoes_compra": {"amarelo": aguardando aprovação, "vermelho": aprovadas esperando o comprador},
--   "cotacoes_compra": {"amarelo": cotações abertas} }
create or replace function public.menu_contadores()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb := '{}'; v_eu uuid := auth.uid(); a int; r int;
begin
  if (select public.pode('solicitacoes_compra')) then
    select count(*) into a from public.solicitacoes_compra s
     where s.situacao = 'em_aprovacao' and (s.solicitante_id = v_eu or (select public.pode_acao('compras.aprovar_solicitacao')));
    r := 0;
    if (select public.pode('cotacoes_compra', 'criar')) or (select public.pode('compras', 'criar')) then
      select count(distinct s.id) into r from public.solicitacoes_compra s join public.solicitacoes_compra_itens i on i.solicitacao_id = s.id
        left join public.pedidos_compra p on p.id = i.pedido_id left join public.cotacoes_compra c on c.id = i.cotacao_id
       where s.situacao = 'aprovado' and (i.pedido_id is null or p.situacao = 'cancelado') and (i.cotacao_id is null or c.situacao = 'cancelada');
    end if;
    v := v || jsonb_build_object('solicitacoes_compra', jsonb_build_object('amarelo', a, 'vermelho', r));
  end if;
  if (select public.pode('cotacoes_compra')) then
    select count(*) into a from public.cotacoes_compra where situacao = 'aberta';
    v := v || jsonb_build_object('cotacoes_compra', jsonb_build_object('amarelo', a, 'vermelho', 0));
  end if;
  return v;
end $$;
revoke execute on function public.menu_contadores() from public, anon;
grant execute on function public.menu_contadores() to authenticated;

select public.ligar_auditoria('cotacoes_compra');
select public.ligar_auditoria('cotacoes_compra_itens');
select public.ligar_auditoria('cotacoes_compra_fornecedores');
select public.ligar_auditoria('cotacoes_compra_precos');
select public.ligar_tempo_real('cotacoes_compra');
select public.ligar_tempo_real('cotacoes_compra_itens');
select public.ligar_tempo_real('cotacoes_compra_fornecedores');
select public.ligar_tempo_real('cotacoes_compra_precos');
