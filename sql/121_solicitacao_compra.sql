-- =====================================================================
-- 121 · Solicitação de compras (etapa antes do pedido de compra)
--  · Tela própria, separada do pedido de compra (quem solicita não precisa ter acesso a pedidos).
--  · Qualquer usuário com a tela "Solicitações de compra" pede produtos/serviços do cadastro, com quantidade,
--    urgência de cada item, data de necessidade e justificativa. Não precisa de fornecedor nem preço.
--  · A solicitação vai para a central de Aprovações. Aprova o administrador e quem tiver a nova ação
--    "Aprovar solicitações de compra" (Usuários e perfis). Recusada volta para quem pediu ajustar e reenviar.
--  · Aprovada, cai na fila do comprador (quem cria pedidos de compra): ele marca itens de uma ou várias
--    solicitações, escolhe o fornecedor e o sistema gera o pedido em rascunho já com os itens.
--  · Rastreio: cada item da solicitação guarda o pedido gerado; o pedido registra na linha do tempo
--    de quais solicitações veio. Pedido cancelado devolve os itens para a fila do comprador.
--  · Corrige na central de aprovações: categorias financeiras novas apareciam com a lista de
--    comprovantes divergentes no lugar das categorias.
-- =====================================================================

-- ---------- Tela, permissões e ação de aprovar ----------
insert into public.modulos (id, grupo, nome, ordem) values ('solicitacoes_compra', 'suprimentos', 'Solicitações de compra', 30)
on conflict (id) do nothing;
-- todos os perfis podem pedir (e ajustar a própria solicitação recusada); Compras vê e atende todas
insert into public.permissoes (perfil_id, modulo_id, nivel)
select p.id, 'solicitacoes_compra', case when p.id = 'compras' then 'editar' else 'alterar' end
  from public.perfis p where p.id <> 'admin'
on conflict do nothing;
insert into public.acoes (id, modulo_id, nome, descricao, ordem)
values ('compras.aprovar_solicitacao', 'solicitacoes_compra', 'Aprovar solicitações de compra',
        'Aprova ou recusa as solicitações de compra antes de irem para o comprador (diretoria).', 30)
on conflict (id) do nothing;

-- ---------- Tabelas ----------
create table if not exists public.solicitacoes_compra (
  id              bigserial primary key,
  numero          text unique,
  empresa_id      integer references public.empresas(id),
  solicitante_id  uuid not null default auth.uid() references public.usuarios(id),
  data_solicitacao date not null default current_date,
  data_necessidade date,
  justificativa   text not null,
  situacao        text not null default 'em_aprovacao' check (situacao in ('em_aprovacao','recusado','aprovado','cancelado')),
  motivo_recusa   text,
  motivo_cancelamento text,
  decidido_por    uuid references public.usuarios(id),
  decidido_em     timestamptz,
  criado_em timestamptz default now(), criado_por uuid, atualizado_em timestamptz default now(), atualizado_por uuid
);
create index if not exists solicitacoes_compra_situacao_idx on public.solicitacoes_compra (situacao);
create index if not exists solicitacoes_compra_solicitante_idx on public.solicitacoes_compra (solicitante_id);

create table if not exists public.solicitacoes_compra_itens (
  id              bigserial primary key,
  solicitacao_id  bigint not null references public.solicitacoes_compra(id) on delete cascade,
  produto_id      bigint references public.produtos(id),
  servico_id      bigint references public.servicos(id),
  descricao       text,
  unidade         text,
  quantidade      numeric not null check (quantidade > 0),
  urgencia        text not null default 'normal' check (urgencia in ('baixa','normal','alta','urgente')),
  observacao      text,
  pedido_id       bigint references public.pedidos_compra(id) on delete set null,
  constraint solicitacao_item_do_cadastro check ((produto_id is not null) <> (servico_id is not null))
);
create index if not exists solicitacoes_compra_itens_sol_idx on public.solicitacoes_compra_itens (solicitacao_id);
create index if not exists solicitacoes_compra_itens_ped_idx on public.solicitacoes_compra_itens (pedido_id);

drop trigger if exists carimbo on public.solicitacoes_compra;
create trigger carimbo before insert or update on public.solicitacoes_compra for each row execute function public.carimbo_cadastro();

-- ---------- Segurança: leitura pela política, gravação só pelas funções abaixo ----------
alter table public.solicitacoes_compra enable row level security;
alter table public.solicitacoes_compra_itens enable row level security;

-- quem vê todas: Compras (nível total na tela), comprador (cria pedido) e quem aprova; os demais, só as próprias
create or replace function public.sc_ve_todas()
returns boolean language sql stable security definer set search_path = public as $$
  select public.pode('solicitacoes_compra', 'total') or public.pode('compras', 'criar') or public.pode_acao('compras.aprovar_solicitacao')
$$;
revoke execute on function public.sc_ve_todas() from public, anon;
grant execute on function public.sc_ve_todas() to authenticated;

drop policy if exists "ver solicitacoes compra" on public.solicitacoes_compra;
create policy "ver solicitacoes compra" on public.solicitacoes_compra for select to authenticated
  using ((select public.pode('solicitacoes_compra')) and (solicitante_id = (select auth.uid()) or (select public.sc_ve_todas())));
drop policy if exists "ver solicitacoes compra itens" on public.solicitacoes_compra_itens;
create policy "ver solicitacoes compra itens" on public.solicitacoes_compra_itens for select to authenticated
  using ((select public.pode('solicitacoes_compra')) and ((select public.sc_ve_todas())
         or exists (select 1 from public.solicitacoes_compra s where s.id = solicitacao_id and s.solicitante_id = (select auth.uid()))));
-- sem políticas de insert/update/delete: tudo passa pelas funções (que conferem dono, situação e permissão)
revoke insert, update, delete on public.solicitacoes_compra, public.solicitacoes_compra_itens from anon, authenticated;

-- ---------- Listas da tela (quem pede nem sempre enxerga o cadastro de produtos nem os pedidos) ----------
-- produtos e serviços ativos que podem ser pedidos (produto recusado no cadastro fica de fora)
create or replace function public.sc_catalogo()
returns table (tipo text, id bigint, codigo text, descricao text, unidade text, pendente boolean)
language sql stable security definer set search_path = public as $$
  select 'produto', p.id, p.codigo, p.descricao, p.unidade, coalesce(p.aprovacao, 'aprovado') = 'pendente'
    from public.produtos p where (select public.pode('solicitacoes_compra')) and p.situacao = 'ativo' and coalesce(p.aprovacao, 'aprovado') <> 'recusado'
  union all
  select 'servico', s.id, null, s.nome, s.unidade, false
    from public.servicos s where (select public.pode('solicitacoes_compra')) and s.situacao = 'ativo'
$$;
revoke execute on function public.sc_catalogo() from public, anon;
grant execute on function public.sc_catalogo() to authenticated;

-- pedidos gerados das solicitações que a pessoa enxerga (rastreio: número, situação e fornecedor)
create or replace function public.sc_pedidos()
returns table (id bigint, numero text, situacao text, fornecedor text)
language sql stable security definer set search_path = public as $$
  select distinct p.id, p.numero, p.situacao, f.nome
    from public.solicitacoes_compra_itens i join public.solicitacoes_compra s on s.id = i.solicitacao_id
    join public.pedidos_compra p on p.id = i.pedido_id left join public.fornecedores f on f.id = p.fornecedor_id
   where (select public.pode('solicitacoes_compra')) and (s.solicitante_id = auth.uid() or (select public.sc_ve_todas()))
$$;
revoke execute on function public.sc_pedidos() from public, anon;
grant execute on function public.sc_pedidos() to authenticated;

-- ---------- Valor estimado (última compra aprovada de cada item; só referência para a diretoria) ----------
create or replace function public.sc_valor_estimado(p_id bigint)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(i.quantidade * coalesce((
           select pi.valor_unitario from public.pedidos_compra_itens pi join public.pedidos_compra p on p.id = pi.pedido_id
            where p.situacao in ('aprovado','enviado','recebido_parcial','recebido') and pi.valor_unitario > 0
              and pi.produto_id is not distinct from i.produto_id and pi.servico_id is not distinct from i.servico_id
            order by p.data_pedido desc, p.id desc limit 1), 0)), 0)
    from public.solicitacoes_compra_itens i where i.solicitacao_id = p_id
$$;
revoke execute on function public.sc_valor_estimado(bigint) from public, anon, authenticated;

-- ---------- Salvar (nova ou reenvio da recusada) ----------
create or replace function public.solicitacao_compra_salvar(p_sol jsonb, p_itens jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p_sol->>'id', '')::bigint; s public.solicitacoes_compra; v_just text := nullif(trim(coalesce(p_sol->>'justificativa', '')), '');
begin
  if v_just is null then raise exception 'Informe a justificativa (para que é a compra)'; end if;
  if coalesce(jsonb_array_length(p_itens), 0) = 0 then raise exception 'Inclua pelo menos um item'; end if;
  if exists (select 1 from jsonb_array_elements(p_itens) x
              where coalesce(nullif(x->>'quantidade', '')::numeric, 0) <= 0
                 or (nullif(x->>'produto_id', '') is null) = (nullif(x->>'servico_id', '') is null)) then
    raise exception 'Cada item precisa de um produto ou serviço do cadastro e de quantidade';
  end if;
  if v_id is null then
    if not public.pode('solicitacoes_compra', 'criar') then raise exception 'Sem permissão para criar solicitação de compra'; end if;
    insert into public.solicitacoes_compra (empresa_id, solicitante_id, data_necessidade, justificativa)
    values (nullif(p_sol->>'empresa_id', '')::int, auth.uid(), nullif(p_sol->>'data_necessidade', '')::date, upper(v_just))
    returning id into v_id;
    update public.solicitacoes_compra set numero = 'SC-' || lpad(v_id::text, 5, '0') where id = v_id;
  else
    select * into s from public.solicitacoes_compra where id = v_id for update;
    if s.id is null then raise exception 'Solicitação não encontrada'; end if;
    if not public.pode('solicitacoes_compra', 'alterar') or (s.solicitante_id <> auth.uid() and not public.pode('solicitacoes_compra', 'total')) then
      raise exception 'Só quem pediu (ou Compras) altera a solicitação'; end if;
    if s.situacao not in ('em_aprovacao', 'recusado') then raise exception 'Solicitação % já foi % e não pode mais ser alterada', s.numero, s.situacao; end if;
    -- alterar (inclusive a recusada) manda de novo para aprovação
    update public.solicitacoes_compra set empresa_id = nullif(p_sol->>'empresa_id', '')::int, data_necessidade = nullif(p_sol->>'data_necessidade', '')::date,
      justificativa = upper(v_just), situacao = 'em_aprovacao', motivo_recusa = null, decidido_por = null, decidido_em = null
    where id = v_id;
    delete from public.solicitacoes_compra_itens where solicitacao_id = v_id;
  end if;
  if exists (select 1 from jsonb_array_elements(p_itens) x where coalesce(nullif(x->>'urgencia', ''), 'normal') not in ('baixa','normal','alta','urgente')) then
    raise exception 'Urgência inválida (use baixa, normal, alta ou urgente)';
  end if;
  insert into public.solicitacoes_compra_itens (solicitacao_id, produto_id, servico_id, descricao, unidade, quantidade, urgencia, observacao)
  select v_id, pr.id, sv.id, coalesce(pr.descricao, sv.nome), coalesce(nullif(x->>'unidade', ''), pr.unidade, sv.unidade),
         (x->>'quantidade')::numeric, coalesce(nullif(x->>'urgencia', ''), 'normal'), upper(nullif(trim(coalesce(x->>'observacao', '')), ''))
    from jsonb_array_elements(p_itens) x
    left join public.produtos pr on pr.id = nullif(x->>'produto_id', '')::bigint and pr.situacao = 'ativo' and coalesce(pr.aprovacao, 'aprovado') <> 'recusado'
    left join public.servicos sv on sv.id = nullif(x->>'servico_id', '')::bigint and sv.situacao = 'ativo';
  if exists (select 1 from public.solicitacoes_compra_itens where solicitacao_id = v_id and produto_id is null and servico_id is null) then
    raise exception 'Produto ou serviço não encontrado no cadastro (ou inativo)';
  end if;
  return v_id;
end $$;
revoke execute on function public.solicitacao_compra_salvar(jsonb, jsonb) from public, anon;
grant execute on function public.solicitacao_compra_salvar(jsonb, jsonb) to authenticated;

-- ---------- Aprovar / recusar (chamada pela central de aprovações) ----------
create or replace function public.solicitacao_compra_decidir(p_id bigint, p_aprovar boolean, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_sit text; v_sol uuid; v_mot text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.pode_acao('compras.aprovar_solicitacao') then raise exception 'Sem permissão para aprovar solicitações de compra'; end if;
  if not p_aprovar and v_mot is null then raise exception 'Informe o motivo da recusa'; end if;
  select situacao, solicitante_id into v_sit, v_sol from public.solicitacoes_compra where id = p_id for update;
  -- ninguém aprova o próprio pedido (só o administrador)
  if p_aprovar and v_sol = auth.uid() and not public.eh_admin() then raise exception 'A própria solicitação precisa ser aprovada por outra pessoa da diretoria'; end if;
  if v_sit is distinct from 'em_aprovacao' then raise exception 'Solicitação % não está aguardando aprovação', p_id; end if;
  update public.solicitacoes_compra set situacao = case when p_aprovar then 'aprovado' else 'recusado' end,
    motivo_recusa = case when p_aprovar then null else upper(v_mot) end, decidido_por = auth.uid(), decidido_em = now()
  where id = p_id;
end $$;
revoke execute on function public.solicitacao_compra_decidir(bigint, boolean, text) from public, anon, authenticated;

-- ---------- Cancelar (quem pediu ou Compras; só se nada virou pedido) ----------
create or replace function public.solicitacao_compra_cancelar(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare s public.solicitacoes_compra; v_mot text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if v_mot is null then raise exception 'Informe o motivo do cancelamento'; end if;
  select * into s from public.solicitacoes_compra where id = p_id for update;
  if s.id is null then raise exception 'Solicitação não encontrada'; end if;
  if not public.pode('solicitacoes_compra', 'alterar') or (s.solicitante_id <> auth.uid() and not public.pode('solicitacoes_compra', 'total')) then
    raise exception 'Só quem pediu (ou Compras) cancela a solicitação'; end if;
  if s.situacao = 'cancelado' then return; end if;
  if exists (select 1 from public.solicitacoes_compra_itens i join public.pedidos_compra p on p.id = i.pedido_id
              where i.solicitacao_id = p_id and p.situacao <> 'cancelado') then
    raise exception 'Já existe pedido de compra para itens desta solicitação: cancele o pedido antes';
  end if;
  update public.solicitacoes_compra set situacao = 'cancelado', motivo_cancelamento = upper(v_mot) where id = p_id;
end $$;
revoke execute on function public.solicitacao_compra_cancelar(bigint, text) from public, anon;
grant execute on function public.solicitacao_compra_cancelar(bigint, text) to authenticated;

-- ---------- Comprador: gera o pedido de compra (rascunho) com os itens marcados ----------
create or replace function public.solicitacao_compra_gerar_pedido(p_itens bigint[], p_fornecedor bigint, p_empresa integer)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_ped bigint; v_scs text; v_its jsonb; n int;
begin
  if not public.pode('compras', 'criar') then raise exception 'Sem permissão para incluir pedidos de compra'; end if;
  if p_fornecedor is null then raise exception 'Escolha o fornecedor'; end if;
  if p_empresa is null then raise exception 'Escolha a empresa do pedido'; end if;
  if coalesce(array_length(p_itens, 1), 0) = 0 then raise exception 'Marque pelo menos um item'; end if;
  -- trava os itens e confere: solicitação aprovada e item ainda sem pedido ativo
  perform 1 from public.solicitacoes_compra_itens where id = any(p_itens) for update;
  select count(*) into n from public.solicitacoes_compra_itens i join public.solicitacoes_compra s on s.id = i.solicitacao_id
    left join public.pedidos_compra p on p.id = i.pedido_id
   where i.id = any(p_itens) and s.situacao = 'aprovado' and (i.pedido_id is null or p.situacao = 'cancelado');
  if n <> (select count(distinct x) from unnest(p_itens) x) then
    raise exception 'Algum item não está mais disponível (solicitação não aprovada ou já virou pedido). Atualize a tela.';
  end if;
  select string_agg(distinct s.numero, ', '),
         jsonb_agg(jsonb_build_object('produto_id', i.produto_id, 'servico_id', i.servico_id,
           'descricao', case when i.servico_id is not null then sv.nome end,
           'unidade', i.unidade, 'quantidade', i.quantidade,
           'valor_unitario', coalesce(case when i.produto_id is not null then pf.preco end, 0),
           'codigo_fornecedor', pf.codigo_fornecedor,
           'observacao', s.numero || case when i.urgencia in ('alta', 'urgente') then ' · ' || upper(i.urgencia) else '' end || coalesce(' · ' || i.observacao, '')) order by s.id, i.id)
    into v_scs, v_its
    from public.solicitacoes_compra_itens i join public.solicitacoes_compra s on s.id = i.solicitacao_id
    left join public.servicos sv on sv.id = i.servico_id
    left join lateral (select x.preco, x.codigo_fornecedor from public.produto_fornecedores x
                        where x.produto_id = i.produto_id and x.fornecedor_id = p_fornecedor order by x.preferencial desc nulls last, x.id desc limit 1) pf on true
   where i.id = any(p_itens);
  v_ped := public.pedido_compra_salvar(jsonb_build_object('empresa_id', p_empresa, 'fornecedor_id', p_fornecedor,
             'observacoes_internas', 'GERADO DAS SOLICITAÇÕES DE COMPRA ' || v_scs), v_its);
  update public.solicitacoes_compra_itens set pedido_id = v_ped where id = any(p_itens);
  perform public.pc_evento(v_ped, 'solicitacao', 'Gerado das solicitações de compra ' || v_scs, jsonb_build_object('itens_solicitacao', p_itens));
  return v_ped;
end $$;
revoke execute on function public.solicitacao_compra_gerar_pedido(bigint[], bigint, integer) from public, anon;
grant execute on function public.solicitacao_compra_gerar_pedido(bigint[], bigint, integer) to authenticated;

-- ---------- Central de aprovações: novo tipo "solicitacao_compra" ----------
do $$
declare d text; a text;
begin
  -- aprovacao_decidir: novo ramo antes do "tipo desconhecido"
  d := pg_get_functiondef('public.aprovacao_decidir(text,bigint[],boolean,text)'::regprocedure);
  if position('solicitacao_compra' in d) = 0 then
    a := '    else raise exception ''Tipo de aprovação desconhecido: %'', p_tipo; end if;';
    if position(a in d) = 0 then raise exception '121: trecho esperado não encontrado em aprovacao_decidir'; end if;
    d := replace(d, a, '    elsif p_tipo = ''solicitacao_compra'' then
      perform public.solicitacao_compra_decidir(v_id, p_aprovar, v_mot);
      select s.numero || '' · '' || left(s.justificativa, 80), public.sc_valor_estimado(s.id), s.solicitante_id into v_txt, v_val, v_cri
        from public.solicitacoes_compra s where s.id = v_id;
' || a);
    execute d;
  end if;

  -- minhas_aprovacoes: grupo novo em Compras + devolvidos para quem pediu + correção das categorias novas
  d := pg_get_functiondef('public.minhas_aprovacoes()'::regprocedure);
  if position('solicitacao_compra' in d) = 0 then
    a := 'v := v || jsonb_build_object(''tipo'', ''pedido_compra'', ''area'', ''Compras'', ''titulo'', ''Pedidos de compra para aprovar'', ''itens'', v_itens, ''aprovar_aqui'', true);';
    if position(a in d) = 0 then raise exception '121: trecho do pedido de compra não encontrado em minhas_aprovacoes'; end if;
    d := replace(d, a, a || '
  if (select public.pode_acao(''compras.aprovar_solicitacao'')) then
    select coalesce(jsonb_agg(jsonb_build_object(''id'', s.id, ''texto'', s.numero || '' · '' ||
             coalesce((select ''⚠ '' || upper(max(i.urgencia)) || '' · '' from public.solicitacoes_compra_itens i where i.solicitacao_id = s.id and i.urgencia in (''alta'', ''urgente'')), '''') ||
             (select string_agg(trim(to_char(i.quantidade, ''FM999999990.999''), ''.'') || ''× '' || coalesce(pr.codigo, i.descricao), '', '' order by i.id)
                from public.solicitacoes_compra_itens i left join public.produtos pr on pr.id = i.produto_id where i.solicitacao_id = s.id)
             || '' · '' || s.justificativa || coalesce('' · precisa até '' || to_char(s.data_necessidade, ''DD/MM/YYYY''), ''''),
             ''valor'', nullif(public.sc_valor_estimado(s.id), 0), ''data'', s.data_solicitacao, ''quem'', u.nome,
             ''link'', ''pages/compras/solicitacoes.html?abrir='' || s.id) order by s.data_solicitacao, s.id), ''[]'') into v_itens
      from public.solicitacoes_compra s left join public.usuarios u on u.id = s.solicitante_id where s.situacao = ''em_aprovacao'';
    v := v || jsonb_build_object(''tipo'', ''solicitacao_compra'', ''area'', ''Compras'', ''titulo'', ''Solicitações de compra para aprovar (valor estimado pela última compra)'', ''itens'', v_itens, ''aprovar_aqui'', true);
  end if;');
    a := 'where x.situacao = ''previsto'' and x.recusa_motivo is not null and (select public.pode(''vale_transporte'', ''editar''))) z;';
    if position(a in d) = 0 then raise exception '121: trecho dos devolvidos não encontrado em minhas_aprovacoes'; end if;
    d := replace(d, a, replace(a, ') z;', '') || '
    union all
    select jsonb_build_object(''id'', s.id, ''texto'', ''Solicitação de compra '' || s.numero || '' · '' || coalesce(s.motivo_recusa, ''''), ''data'', s.decidido_em,
           ''link'', ''pages/compras/solicitacoes.html?abrir='' || s.id)
      from public.solicitacoes_compra s where s.situacao = ''recusado'' and s.solicitante_id = v_eu) z;');
    -- categorias novas: o grupo era montado depois da consulta dos comprovantes e herdava a lista errada
    a := '    v := v || jsonb_build_object(''tipo'', ''categoria_nova'', ''area'', ''Cadastros'', ''titulo'', ''Categorias financeiras novas para aprovar'', ''itens'', v_itens, ''aprovar_aqui'', true);
';
    if position(a in d) > 0 then
      d := replace(d, a, '');
      d := replace(d, 'where c.aprovacao = ''pendente'';
', 'where c.aprovacao = ''pendente'';
' || a);
    end if;
    execute d;
  end if;
end $$;

select public.ligar_auditoria('solicitacoes_compra');
select public.ligar_auditoria('solicitacoes_compra_itens');
