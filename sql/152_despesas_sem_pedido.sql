-- =====================================================================
-- 152 · Despesas sem pedido de compra (combustível, mercado, contas fixas, copa…)
--  · Tela nova "Despesas sem pedido" (Financeiro): Compras lança gastos pequenos que não são de
--    estoque nem de produção, sem cadastrar produto e sem passar por solicitação/pedido de compra.
--  · Cada despesa tem: empresa, fornecedor (ou só o nome do estabelecimento), descrição livre
--    ("Gasolina Kagoo"), categoria financeira obrigatória, valor, data, forma de pagamento,
--    vencimento e a FOTO DO CUPOM / NOTA (obrigatória).
--  · Só aparecem as categorias marcadas como "despesa sem pedido" (nova marca no cadastro de
--    categorias). Começa com as do grupo 6 (administrativas, ocupação, consumo, copa, veículos,
--    manutenção); ficam de fora 6.09 (desenvolvimento) e o IRRF. Matéria-prima e insumos de
--    produção continuam exigindo pedido de compra.
--  · Precisa de aprovação antes de ir ao financeiro (pedido do Alexandre, 18/11): aparece na
--    central de Aprovações. Aprova o administrador e quem tiver a nova ação "Aprovar despesas sem
--    pedido" (Usuários e perfis). Ninguém aprova a própria despesa, exceto o administrador.
--  · Aprovada → vira título no contas a pagar (origem manual, com a categoria certa e o cupom anexado
--    como nota). Recusada → volta para quem lançou ajustar e reenviar.
--  · Permissões: perfil Compras lança e ajusta só as próprias; Financeiro (nível total) vê e ajusta todas.
--    Quem lança NÃO passa a ver o contas a pagar.
--  · Para desfazer: tirar a tela do menu/permissões; os títulos já gerados ficam no contas a pagar.
-- =====================================================================

-- ---------- Tela, permissões e ação de aprovar ----------
insert into public.modulos (id, grupo, nome, ordem) values ('despesas', 'financeiro', 'Despesas sem pedido', 60)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values
  ('compras', 'despesas', 'alterar'), ('financeiro', 'despesas', 'editar')
on conflict do nothing;
insert into public.acoes (id, modulo_id, nome, descricao, ordem)
values ('despesas.aprovar', 'despesas', 'Aprovar despesas sem pedido',
        'Aprova ou recusa as despesas lançadas sem pedido de compra antes de irem para o contas a pagar.', 1)
on conflict (id) do nothing;

-- ---------- Categorias liberadas para despesa sem pedido ----------
alter table public.categorias_financeiras add column if not exists despesa_direta boolean not null default false;
comment on column public.categorias_financeiras.despesa_direta is 'Aparece na tela Despesas sem pedido (gasto que não é estoque/produção)';
do $$ begin
  -- marca inicial só uma vez (depois quem manda é o cadastro de categorias)
  if not exists (select 1 from public.categorias_financeiras where despesa_direta) then
    update public.categorias_financeiras set despesa_direta = true
     where codigo like '6.%' and aceita_lancamento and codigo not like '6.09%' and codigo <> '6.08.001';
  end if;
end $$;

-- ---------- Tabela ----------
create table if not exists public.despesas_diretas (
  id                  bigserial primary key,
  numero              text unique,
  empresa_id          integer not null references public.empresas(id),
  fornecedor_id       bigint references public.fornecedores(id),
  estabelecimento     text,
  descricao           text not null,
  categoria_financeira_id bigint not null references public.categorias_financeiras(id),
  valor               numeric(14,2) not null check (valor > 0),
  data_despesa        date not null default current_date,
  forma_pagamento_id  bigint references public.formas_pagamento(id),
  data_vencimento     date not null,
  cupom_caminho       text not null,
  cupom_nome          text,
  cupom_mime          text,
  observacoes         text,
  situacao            text not null default 'em_aprovacao' check (situacao in ('em_aprovacao','recusado','aprovado','cancelado')),
  motivo_recusa       text,
  motivo_cancelamento text,
  decidido_por        uuid references public.usuarios(id),
  decidido_em         timestamptz,
  titulo_id           bigint references public.titulos_pagar(id),
  criado_em timestamptz not null default now(), criado_por uuid default auth.uid(),
  atualizado_em timestamptz not null default now(), atualizado_por uuid
);
create index if not exists despesas_diretas_situacao_idx on public.despesas_diretas (situacao);
create index if not exists despesas_diretas_criado_por_idx on public.despesas_diretas (criado_por);
create index if not exists despesas_diretas_titulo_idx on public.despesas_diretas (titulo_id);
create or replace trigger carimbo before insert or update on public.despesas_diretas
  for each row execute function public.carimbo_cadastro();

-- ---------- Segurança: leitura pela política, gravação só pelas funções abaixo ----------
alter table public.despesas_diretas enable row level security;

-- quem vê todas: Financeiro (nível total na tela) e quem aprova; os demais (ex.: Compras), só as que lançaram
create or replace function public.dd_ve_todas()
returns boolean language sql stable security definer set search_path = public as $$
  select public.pode('despesas', 'total') or public.pode_acao('despesas.aprovar')
$$;
revoke execute on function public.dd_ve_todas() from public, anon;
grant execute on function public.dd_ve_todas() to authenticated;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'despesas_diretas' and policyname = 'ver despesas diretas') then
    create policy "ver despesas diretas" on public.despesas_diretas for select to authenticated
      using ((select public.pode('despesas')) and (criado_por = (select auth.uid()) or (select public.dd_ve_todas())));
  end if;
end $$;
revoke insert, update, delete on public.despesas_diretas from anon, authenticated;
grant select on public.despesas_diretas to authenticated;

-- Cupom / nota: bucket "financeiro", pasta despesas/<usuário>/...
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'despesas gravar cupom') then
    create policy "despesas gravar cupom" on storage.objects for insert to authenticated
      with check (bucket_id = 'financeiro' and split_part(name, '/', 1) = 'despesas'
                  and split_part(name, '/', 2) = (select auth.uid())::text and (select public.pode('despesas', 'criar')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'despesas ler cupom') then
    create policy "despesas ler cupom" on storage.objects for select to authenticated
      using (bucket_id = 'financeiro' and split_part(name, '/', 1) = 'despesas'
             and ((split_part(name, '/', 2) = (select auth.uid())::text and (select public.pode('despesas')))
                  or (select public.dd_ve_todas()) or (select public.pode('pagar'))));
  end if;
end $$;

-- ---------- Listas da tela (quem lança nem sempre enxerga os cadastros) ----------
create or replace function public.dd_listas()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (select public.pode('despesas')) then raise exception 'Sem acesso à tela Despesas sem pedido'; end if;
  return jsonb_build_object(
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'codigo', c.codigo, 'nome', c.nome, 'grupo', m.codigo || ' ' || m.nome,
                     'ativa', c.despesa_direta and c.situacao = 'ativo' and c.aceita_lancamento and coalesce(c.aprovacao, 'aprovado') = 'aprovado')
                     order by c.codigo), '[]')
                     from public.categorias_financeiras c left join public.categorias_financeiras m on m.id = c.pai_id
                    where c.despesa_direta or c.id in (select categoria_financeira_id from public.despesas_diretas)),
    'fornecedores', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'nome', coalesce(nullif(f.nome_fantasia, ''), f.nome), 'ativo', f.situacao = 'ativo') order by f.nome), '[]')
                     from public.fornecedores f),
    'formas', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome, 'ativo', f.situacao = 'ativo') order by f.id), '[]') from public.formas_pagamento f));
end $$;
revoke execute on function public.dd_listas() from public, anon;
grant execute on function public.dd_listas() to authenticated;

-- ---------- Lançar / reenviar ----------
create or replace function public.despesa_direta_salvar(p jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p->>'id', '')::bigint; d public.despesas_diretas; c public.categorias_financeiras;
  v_cat bigint := nullif(p->>'categoria_financeira_id', '')::bigint; v_val numeric := nullif(p->>'valor', '')::numeric;
  v_data date := coalesce(nullif(p->>'data_despesa', '')::date, current_date);
  v_venc date := coalesce(nullif(p->>'data_vencimento', '')::date, nullif(p->>'data_despesa', '')::date, current_date);
  v_desc text := nullif(trim(coalesce(p->>'descricao', '')), ''); v_cupom text := nullif(p->>'cupom_caminho', '');
  v_forn bigint := nullif(p->>'fornecedor_id', '')::bigint; v_est text := nullif(trim(coalesce(p->>'estabelecimento', '')), '');
begin
  if v_id is null then
    if not public.pode('despesas', 'criar') then raise exception 'Sem permissão para lançar despesa'; end if;
  else
    select * into d from public.despesas_diretas where id = v_id for update;
    if not found then raise exception 'Despesa não encontrada'; end if;
    if d.situacao not in ('em_aprovacao', 'recusado') then raise exception 'Despesa % já foi %: não pode mais ser alterada', d.numero, d.situacao; end if;
    if not ((d.criado_por = auth.uid() and public.pode('despesas', 'alterar')) or public.pode('despesas', 'total')) then raise exception 'Só quem lançou (ou o financeiro) altera a despesa'; end if;
    v_cupom := coalesce(v_cupom, d.cupom_caminho);
  end if;
  if v_desc is null then raise exception 'Informe a descrição (ex.: Gasolina Kagoo)'; end if;
  if v_forn is null and v_est is null then raise exception 'Informe o fornecedor ou o nome do estabelecimento'; end if;
  if coalesce(v_val, 0) <= 0 then raise exception 'Informe o valor'; end if;
  if nullif(p->>'empresa_id', '') is null then raise exception 'Escolha a empresa (CNPJ)'; end if;
  select * into c from public.categorias_financeiras where id = v_cat;
  if not found or not c.despesa_direta or c.situacao <> 'ativo' or not c.aceita_lancamento or coalesce(c.aprovacao, 'aprovado') <> 'aprovado' then
    raise exception 'Escolha uma categoria da lista (só as liberadas para despesa sem pedido). Compra de produção/estoque vai pelo pedido de compra';
  end if;
  if v_cupom is null then raise exception 'Anexe a foto do cupom ou da nota (obrigatório)'; end if;
  -- cupom novo: tem que ser um arquivo que a própria pessoa enviou agora (pasta dela no armazenamento)
  if v_cupom is distinct from d.cupom_caminho and (split_part(v_cupom, '/', 1) <> 'despesas' or split_part(v_cupom, '/', 2) <> auth.uid()::text
     or not exists (select 1 from storage.objects o where o.bucket_id = 'financeiro' and o.name = v_cupom)) then
    raise exception 'Cupom inválido: envie a foto de novo';
  end if;
  if v_venc < v_data then raise exception 'O vencimento não pode ser antes da data da despesa'; end if;

  if v_id is null then
    insert into public.despesas_diretas (empresa_id, fornecedor_id, estabelecimento, descricao, categoria_financeira_id, valor, data_despesa,
      forma_pagamento_id, data_vencimento, cupom_caminho, cupom_nome, cupom_mime, observacoes)
    values ((p->>'empresa_id')::int, v_forn, upper(v_est), upper(v_desc), v_cat, round(v_val, 2), v_data,
      nullif(p->>'forma_pagamento_id', '')::bigint, v_venc, v_cupom, nullif(p->>'cupom_nome', ''), nullif(p->>'cupom_mime', ''), nullif(trim(coalesce(p->>'observacoes', '')), ''))
    returning id into v_id;
    update public.despesas_diretas set numero = 'DS-' || lpad(v_id::text, 5, '0') where id = v_id;
  else
    update public.despesas_diretas set empresa_id = (p->>'empresa_id')::int, fornecedor_id = v_forn, estabelecimento = upper(v_est), descricao = upper(v_desc),
      categoria_financeira_id = v_cat, valor = round(v_val, 2), data_despesa = v_data, forma_pagamento_id = nullif(p->>'forma_pagamento_id', '')::bigint,
      data_vencimento = v_venc, cupom_caminho = v_cupom, cupom_nome = coalesce(nullif(p->>'cupom_nome', ''), cupom_nome),
      cupom_mime = coalesce(nullif(p->>'cupom_mime', ''), cupom_mime), observacoes = nullif(trim(coalesce(p->>'observacoes', '')), ''),
      situacao = 'em_aprovacao', motivo_recusa = null
     where id = v_id;
  end if;
  return v_id;
end $$;
revoke execute on function public.despesa_direta_salvar(jsonb) from public, anon;
grant execute on function public.despesa_direta_salvar(jsonb) to authenticated;

-- ---------- Aprovar / recusar (chamada pela central de Aprovações e pela tela) ----------
create or replace function public.despesa_direta_decidir(p_id bigint, p_aprovar boolean, p_motivo text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare d public.despesas_diretas; v_tit bigint; v_mot text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.pode_acao('despesas.aprovar') then raise exception 'Sem permissão para aprovar despesas sem pedido'; end if;
  select * into d from public.despesas_diretas where id = p_id for update;
  if not found then raise exception 'Despesa não encontrada'; end if;
  if d.situacao <> 'em_aprovacao' then raise exception 'Despesa % não está aguardando aprovação', d.numero; end if;
  if d.criado_por = auth.uid() and not public.eh_admin() then raise exception 'Você não pode aprovar a própria despesa'; end if;
  if not p_aprovar then
    if v_mot is null then raise exception 'Informe o motivo da recusa'; end if;
    update public.despesas_diretas set situacao = 'recusado', motivo_recusa = upper(v_mot), decidido_por = auth.uid(), decidido_em = now() where id = p_id;
    return null;
  end if;
  insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento,
    forma_pagamento_id, origem, origem_ref, observacoes, criado_por)
  values (d.empresa_id, d.fornecedor_id, d.numero, d.descricao || coalesce(' · ' || d.estabelecimento, ''), d.categoria_financeira_id, d.valor,
    d.data_despesa, d.data_vencimento, d.forma_pagamento_id, 'manual',
    jsonb_build_object('despesa_direta', d.id, 'numero', d.numero, 'estabelecimento', d.estabelecimento, 'lancado_por', d.criado_por, 'aprovado_por', auth.uid()),
    d.observacoes, d.criado_por)
  returning id into v_tit;
  insert into public.titulos_anexos (tipo, titulo_id, categoria, nome, caminho, mime, criado_por)
  values ('pagar', v_tit, 'nota', coalesce(d.cupom_nome, 'cupom ' || d.numero), d.cupom_caminho, d.cupom_mime, d.criado_por);
  update public.despesas_diretas set situacao = 'aprovado', motivo_recusa = null, decidido_por = auth.uid(), decidido_em = now(), titulo_id = v_tit where id = p_id;
  return v_tit;
end $$;
revoke execute on function public.despesa_direta_decidir(bigint, boolean, text) from public, anon;
grant execute on function public.despesa_direta_decidir(bigint, boolean, text) to authenticated;

-- ---------- Cancelar (antes de aprovada) ----------
create or replace function public.despesa_direta_cancelar(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare d public.despesas_diretas; v_mot text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.pode('despesas') then raise exception 'Sem acesso à tela Despesas sem pedido'; end if;
  select * into d from public.despesas_diretas where id = p_id for update;
  if not found then raise exception 'Despesa não encontrada'; end if;
  if not ((d.criado_por = auth.uid() and public.pode('despesas', 'alterar')) or public.pode('despesas', 'total')) then raise exception 'Só quem lançou (ou o financeiro) cancela a despesa'; end if;
  if d.situacao not in ('em_aprovacao', 'recusado') then raise exception 'Despesa já aprovada: cancele o título no contas a pagar'; end if;
  if v_mot is null then raise exception 'Informe o motivo do cancelamento'; end if;
  update public.despesas_diretas set situacao = 'cancelado', motivo_cancelamento = upper(v_mot) where id = p_id;
end $$;
revoke execute on function public.despesa_direta_cancelar(bigint, text) from public, anon;
grant execute on function public.despesa_direta_cancelar(bigint, text) to authenticated;

-- ---------- Central de Aprovações: novo grupo "Despesas sem pedido" ----------
do $$ declare d text; n text;
begin
  -- quem decide: aprovacao_decidir passa a conhecer o tipo despesa_direta
  d := pg_get_functiondef('public.aprovacao_decidir(text,bigint[],boolean,text)'::regprocedure);
  if position('despesa_direta' in d) = 0 then
    n := replace(d, '    else raise exception ''Tipo de aprovação desconhecido: %'', p_tipo; end if;',
'    elsif p_tipo = ''despesa_direta'' then
      perform public.despesa_direta_decidir(v_id, p_aprovar, v_mot);
      select x.numero || '' · '' || x.descricao || coalesce('' · '' || coalesce(f.nome, x.estabelecimento), ''''), x.valor, x.criado_por into v_txt, v_val, v_cri
        from public.despesas_diretas x left join public.fornecedores f on f.id = x.fornecedor_id where x.id = v_id;
    else raise exception ''Tipo de aprovação desconhecido: %'', p_tipo; end if;');
    if n = d then raise exception 'aprovacao_decidir mudou: não achei onde incluir a despesa sem pedido'; end if;
    execute n;
  end if;

  -- o que aparece para decidir e o que volta recusado para quem lançou
  d := pg_get_functiondef('public.minhas_aprovacoes()'::regprocedure);
  if position('despesas_diretas' in d) = 0 then
    n := replace(d, '  if v_admin or (select public.pode_acao(''compras.liberar_avulso'')) then',
'  if (select public.pode_acao(''despesas.aprovar'')) then
    select coalesce(jsonb_agg(jsonb_build_object(''id'', x.id, ''texto'', x.numero || '' · '' || x.descricao || '' · '' || coalesce(f.nome, x.estabelecimento, '''')
             || '' · '' || c.codigo || '' '' || c.nome, ''valor'', x.valor, ''data'', x.data_despesa, ''quem'', u.nome,
             ''link'', ''pages/financeiro/despesas.html?abrir='' || x.id) order by x.data_despesa, x.id), ''[]'') into v_itens
      from public.despesas_diretas x join public.categorias_financeiras c on c.id = x.categoria_financeira_id
      left join public.fornecedores f on f.id = x.fornecedor_id left join public.usuarios u on u.id = x.criado_por
     where x.situacao = ''em_aprovacao'' and (v_admin or x.criado_por is distinct from v_eu);
    v := v || jsonb_build_object(''tipo'', ''despesa_direta'', ''area'', ''Financeiro'', ''titulo'', ''Despesas sem pedido de compra (combustível, mercado, contas…)'', ''itens'', v_itens, ''aprovar_aqui'', true);
  end if;
  if v_admin or (select public.pode_acao(''compras.liberar_avulso'')) then');
    if n = d then raise exception 'minhas_aprovacoes mudou: não achei onde incluir a despesa sem pedido (1)'; end if;
    d := n;
    n := replace(d, 'from public.solicitacoes_compra s where s.situacao = ''recusado'' and s.solicitante_id = v_eu) z;',
'from public.solicitacoes_compra s where s.situacao = ''recusado'' and s.solicitante_id = v_eu
    union all
    select jsonb_build_object(''id'', x.id, ''texto'', ''Despesa '' || x.numero || '' · '' || x.descricao || '' · '' || coalesce(x.motivo_recusa, ''''), ''valor'', x.valor, ''data'', x.decidido_em,
           ''link'', ''pages/financeiro/despesas.html?abrir='' || x.id)
      from public.despesas_diretas x where x.situacao = ''recusado'' and x.criado_por = v_eu) z;');
    if n = d then raise exception 'minhas_aprovacoes mudou: não achei onde incluir a despesa sem pedido (2)'; end if;
    execute n;
  end if;

  -- contador no menu: amarelo = aguardando aprovação; vermelho = recusada (minha) ou para eu aprovar
  d := pg_get_functiondef('public.menu_contadores()'::regprocedure);
  if position('despesas_diretas' in d) = 0 then
    n := replace(d, E'  return v;\nend', E'  if (select public.pode(''despesas'')) then
    select count(*) filter (where situacao = ''em_aprovacao'' and criado_por = v_eu),
           count(*) filter (where situacao = ''recusado'' and criado_por = v_eu)
         + count(*) filter (where situacao = ''em_aprovacao'' and (select public.pode_acao(''despesas.aprovar'')) and (criado_por is distinct from v_eu or (select public.eh_admin())))
      into a, r from public.despesas_diretas;
    v := v || jsonb_build_object(''despesas'', jsonb_build_object(''amarelo'', a, ''vermelho'', r));
  end if;
  return v;
end');
    if n = d then raise exception 'menu_contadores mudou: não achei onde incluir a despesa sem pedido'; end if;
    execute n;
  end if;
end $$;

select public.ligar_auditoria('despesas_diretas');
select public.ligar_tempo_real('despesas_diretas');
