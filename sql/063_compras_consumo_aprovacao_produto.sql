-- =====================================================================
-- 063 · Compras: uso e consumo interno, categoria do produto, aprovação de produto novo e central de aprovações
--  · Item do pedido de compra pode ser marcado "uso e consumo interno" (ex.: mesmo produto comprado para manutenção):
--    não entra no estoque e a categoria financeira é escolhida no pedido.
--  · Item normal com produto usa SEMPRE a categoria financeira do cadastro do produto.
--  · Produto novo cadastrado por quem não é master fica "aguardando aprovação" e não pode ir em pedido de compra
--    até o master aprovar. Produtos já existentes ficam aprovados.
--  · minhas_aprovacoes(): o que está esperando a decisão de quem está logado (tela Aprovações pendentes).
-- =====================================================================

-- ---------- Uso e consumo interno ----------
alter table public.pedidos_compra_itens add column if not exists uso_consumo boolean not null default false;

do $$ declare d text; begin
  d := pg_get_functiondef('public.pedido_compra_salvar(jsonb,jsonb)'::regprocedure);
  if position('uso_consumo' in d) = 0 then
    d := replace(d, 'barras_enviar)
    select v_id,', 'barras_enviar, uso_consumo)
    select v_id,');
    d := replace(d, 'case when s.srv and s.pb > 0 then ceil((s.x->>''quantidade'')::numeric / s.pb) end
    from (select x,', 'case when s.srv and s.pb > 0 then ceil((s.x->>''quantidade'')::numeric / s.pb) end,
           coalesce((s.x->>''uso_consumo'')::boolean, false)
    from (select x,');
    if position('uso_consumo' in d) = 0 then raise exception 'pedido_compra_salvar mudou: ajuste o replace do 063'; end if;
    execute d;
  end if;
end $$;

-- Categoria do produto (item normal) e produto precisa estar aprovado
create or replace function public.pc_item_regras()
returns trigger language plpgsql set search_path = public as $$
declare p record;
begin
  if new.produto_id is null then return new; end if;
  select descricao, categoria_financeira_id, coalesce(aprovacao, 'aprovado') aprovacao into p from public.produtos where id = new.produto_id;
  if p.aprovacao <> 'aprovado' and (tg_op = 'INSERT' or new.produto_id is distinct from old.produto_id) then
    raise exception 'Produto "%" ainda não foi aprovado pelo master (cadastro novo)', p.descricao;
  end if;
  if not new.uso_consumo and coalesce(new.tipo_item, 'normal') = 'normal' and p.categoria_financeira_id is not null then
    new.categoria_financeira_id := p.categoria_financeira_id;
  end if;
  return new;
end $$;
revoke execute on function public.pc_item_regras() from public, anon, authenticated;
create or replace trigger regras before insert or update on public.pedidos_compra_itens for each row execute function public.pc_item_regras();

-- Estoque: item de uso e consumo não entra
do $$ declare d text; begin
  d := pg_get_functiondef('public.pc_recebimento_estoque()'::regprocedure);
  if position('uso_consumo' in d) = 0 then
    d := replace(d, 'where r.quantidade > 0 and pr.controla_estoque;', 'where r.quantidade > 0 and pr.controla_estoque and not i.uso_consumo;');
    execute d;
  end if;
end $$;

-- ---------- Aprovação de produto novo ----------
alter table public.produtos add column if not exists aprovacao text not null default 'aprovado',
  add column if not exists aprovacao_por uuid, add column if not exists aprovacao_em timestamptz, add column if not exists aprovacao_motivo text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'produtos_aprovacao_check') then
    alter table public.produtos add constraint produtos_aprovacao_check check (aprovacao in ('pendente','aprovado','recusado'));
  end if;
end $$;

create or replace function public.produto_novo_aprovacao()
returns trigger language plpgsql set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;                 -- cargas do sistema entram aprovadas
  if (select public.eh_admin()) then
    new.aprovacao := 'aprovado'; new.aprovacao_por := auth.uid(); new.aprovacao_em := now();
  else
    new.aprovacao := 'pendente'; new.aprovacao_por := null; new.aprovacao_em := null;
  end if;
  return new;
end $$;
revoke execute on function public.produto_novo_aprovacao() from public, anon, authenticated;
create or replace trigger aprovacao_novo before insert on public.produtos for each row execute function public.produto_novo_aprovacao();

-- Só o master muda a aprovação
create or replace function public.produto_aprovacao_protege()
returns trigger language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and new.aprovacao is distinct from old.aprovacao and not (select public.eh_admin()) then
    raise exception 'Só o master aprova ou recusa produto novo';
  end if;
  return new;
end $$;
revoke execute on function public.produto_aprovacao_protege() from public, anon, authenticated;
create or replace trigger aprovacao_protege before update on public.produtos for each row execute function public.produto_aprovacao_protege();

create or replace function public.produto_aprovar(p_ids bigint[], p_aprovar boolean, p_motivo text default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not (select public.eh_admin()) then raise exception 'Só o master aprova produto novo'; end if;
  if not p_aprovar and coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo da recusa'; end if;
  update public.produtos set aprovacao = case when p_aprovar then 'aprovado' else 'recusado' end, aprovacao_por = auth.uid(), aprovacao_em = now(),
    aprovacao_motivo = case when p_aprovar then null else p_motivo end
   where id = any(p_ids) and aprovacao <> case when p_aprovar then 'aprovado' else 'recusado' end;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.produto_aprovar(bigint[], boolean, text) from public, anon;
grant execute on function public.produto_aprovar(bigint[], boolean, text) to authenticated;

-- ---------- Central de aprovações ----------
create or replace function public.minhas_aprovacoes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb := '[]'; v_admin boolean := (select public.eh_admin()); v_itens jsonb;
begin
  -- pedidos de compra na minha vez
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'texto', p.numero || ' · ' || f.nome, 'valor', p.valor_total, 'data', p.data_pedido,
           'link', 'pages/compras/pedidos.html?abrir=' || p.id) order by p.data_pedido), '[]') into v_itens
    from public.pedidos_compra p join public.fornecedores f on f.id = p.fornecedor_id
   where p.situacao = 'em_aprovacao' and public.pc_pode_aprovar(p.id);
  v := v || jsonb_build_object('tipo', 'pedido_compra', 'titulo', 'Pedidos de compra para aprovar', 'itens', v_itens);
  if v_admin or (select public.pode_acao('compras.liberar_avulso')) then
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'texto', p.numero || ' · ' || array_to_string(public.pc_avulsos_pendentes(p.id), ', '),
             'valor', p.valor_total, 'data', p.data_pedido, 'link', 'pages/compras/pedidos.html?abrir=' || p.id)), '[]') into v_itens
      from public.pedidos_compra p where p.situacao in ('rascunho','recusado') and cardinality(public.pc_avulsos_pendentes(p.id)) > 0;
    v := v || jsonb_build_object('tipo', 'item_avulso', 'titulo', 'Itens sem cadastro para liberar', 'itens', v_itens);
  end if;
  if v_admin then
    select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'texto', 'NF ' || n.numero || ' · ' || coalesce(n.emitente_nome, '') || ' · ' || coalesce(n.motivo_sem_pedido, ''),
             'valor', n.valor_total, 'data', n.data_emissao, 'link', 'pages/financeiro/notas-fiscais.html?abrir=' || n.id)), '[]') into v_itens
      from public.nfe_entrada n where n.situacao = 'aguardando_aprovacao';
    v := v || jsonb_build_object('tipo', 'nf_sem_pedido', 'titulo', 'Notas fiscais sem pedido de compra', 'itens', v_itens);
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'texto', coalesce(p.codigo, '—') || ' · ' || p.descricao || ' · cadastrado por ' || coalesce(u.nome, '?'),
             'data', p.criado_em, 'link', 'pages/cadastros/produtos.html?abrir=' || p.id)), '[]') into v_itens
      from public.produtos p left join public.usuarios u on u.id = p.criado_por where p.aprovacao = 'pendente';
    v := v || jsonb_build_object('tipo', 'produto_novo', 'titulo', 'Produtos novos para aprovar', 'itens', v_itens, 'aprovar_aqui', true);
  end if;
  if (select public.pode('vale_transporte', 'editar')) then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'texto', fu.nome || ' · VT ' || to_char(x.competencia, 'MM/YYYY'), 'valor', x.valor_total, 'data', x.competencia,
             'link', 'pages/rh/vale-transporte.html?abrir=' || x.id)), '[]') into v_itens
      from public.rh_vale_transporte x join public.funcionarios fu on fu.id = x.funcionario_id where x.situacao = 'previsto';
    v := v || jsonb_build_object('tipo', 'vt', 'titulo', 'Vale-transporte aguardando aprovação', 'itens', v_itens);
  end if;
  return v;
end $$;
revoke execute on function public.minhas_aprovacoes() from public, anon;
grant execute on function public.minhas_aprovacoes() to authenticated;

insert into public.acoes (id, modulo_id, nome, descricao, ordem) values
  ('compras.liberar_avulso', 'compras', 'Liberar item sem cadastro em pedido de compra', 'Compra ocasional sem SKU. Administrador sempre pode.', 2)
on conflict (id) do nothing;
