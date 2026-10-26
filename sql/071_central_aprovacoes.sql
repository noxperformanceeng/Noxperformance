-- =====================================================================
-- 071 · Central de aprovações: aprovar/recusar ali mesmo (um ou vários), histórico e devolução
--  · Todas as aprovações podem ser decididas direto na tela "Aprovações pendentes", uma a uma ou em lote:
--    pedidos de compra, itens sem cadastro, NF sem pedido, produtos e categorias novas e vale-transporte.
--  · Toda decisão (aprovou/recusou, quem, quando, motivo, valor) fica no histórico de aprovações.
--  · Recusado volta para quem criou: aparece para ele em "Devolvidos para você ajustar"; ao corrigir e
--    salvar (produto, categoria, VT) ou reenviar (pedido de compra), volta para aprovação.
--  · Vale-transporte recusado fica parado (não vai ao financeiro) até o RH ajustar.
-- =====================================================================
create table if not exists public.aprovacoes_historico (
  id          bigserial primary key,
  tipo        text not null,          -- pedido_compra, item_avulso, nf_sem_pedido, produto_novo, categoria_nova, vt
  registro_id bigint not null,
  texto       text,
  valor       numeric(14,2),
  decisao     text not null check (decisao in ('aprovado','recusado')),
  motivo      text,
  criado_por_registro uuid,
  em          timestamptz not null default now(),
  por         uuid default auth.uid() references public.usuarios(id)
);
create index if not exists aprov_hist_em_idx on public.aprovacoes_historico (em desc);
alter table public.aprovacoes_historico enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'aprovacoes_historico' and policyname = 'ver historico aprovacoes') then
    create policy "ver historico aprovacoes" on public.aprovacoes_historico for select to authenticated
      using ((select public.eh_admin()) or por = (select auth.uid()) or criado_por_registro = (select auth.uid()));
  end if;
end $$;

-- VT recusado: motivo guardado; some da fila até o RH ajustar
alter table public.rh_vale_transporte add column if not exists recusa_motivo text;
create or replace function public.vt_reenvio_apos_recusa()
returns trigger language plpgsql set search_path = public as $$
begin
  -- qualquer ajuste do RH num VT recusado (sem mexer no motivo) devolve para a fila de aprovação
  if old.recusa_motivo is not null and new.recusa_motivo is not distinct from old.recusa_motivo and auth.uid() is not null then
    new.recusa_motivo := null;
  end if;
  return new;
end $$;
revoke execute on function public.vt_reenvio_apos_recusa() from public, anon, authenticated;
create or replace trigger reenvio_recusa before update on public.rh_vale_transporte for each row execute function public.vt_reenvio_apos_recusa();

-- Produto e categoria recusados: quem criou corrige e salva → volta a "pendente"
do $$ declare d text; begin
  d := pg_get_functiondef('public.produto_aprovacao_protege()'::regprocedure);
  if position('reenvio' in d) = 0 then
    d := replace(d, $x$begin
  if auth.uid() is not null and new.aprovacao is distinct from old.aprovacao and not (select public.eh_admin()) then$x$,
      $x$begin
  -- reenvio: produto recusado e corrigido por quem não é master volta para aprovação
  if auth.uid() is not null and old.aprovacao = 'recusado' and new.aprovacao = 'recusado' and not (select public.eh_admin()) then
    new.aprovacao := 'pendente'; return new;
  end if;
  if auth.uid() is not null and new.aprovacao is distinct from old.aprovacao and not (select public.eh_admin()) then$x$);
    if position('reenvio' in d) = 0 then raise exception 'produto_aprovacao_protege mudou: revisar 071'; end if;
    execute d;
  end if;
  d := pg_get_functiondef('public.categoria_nova_regras()'::regprocedure);
  if position('reenvio' in d) = 0 then
    d := replace(d, $x$  if (new.aprovacao, new.aprovacao_por, new.aprovacao_em, new.aprovacao_motivo) is distinct from$x$,
      $x$  -- reenvio: categoria recusada e corrigida por quem não é master volta para aprovação
  if old.aprovacao = 'recusado' and new.aprovacao = 'recusado' and not (select public.eh_admin()) then
    new.aprovacao := 'pendente'; return new;
  end if;
  if (new.aprovacao, new.aprovacao_por, new.aprovacao_em, new.aprovacao_motivo) is distinct from$x$);
    if position('reenvio' in d) = 0 then raise exception 'categoria_nova_regras mudou: revisar 071'; end if;
    execute d;
  end if;
end $$;

-- Decide uma ou várias aprovações do mesmo tipo e registra o histórico
create or replace function public.aprovacao_decidir(p_tipo text, p_ids bigint[], p_aprovar boolean, p_motivo text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_id bigint; n int := 0; v_txt text; v_val numeric; v_cri uuid; v_mot text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if coalesce(array_length(p_ids, 1), 0) = 0 then raise exception 'Escolha o que decidir'; end if;
  if not p_aprovar and v_mot is null then raise exception 'Informe o motivo da recusa'; end if;
  foreach v_id in array p_ids loop
    if p_tipo = 'pedido_compra' then
      perform public.pedido_compra_acao(v_id, case when p_aprovar then 'aprovar' else 'recusar' end, v_mot, '{}'::jsonb);
      select p.numero || ' · ' || f.nome, p.valor_total, coalesce(p.comprador_id, p.criado_por) into v_txt, v_val, v_cri
        from public.pedidos_compra p join public.fornecedores f on f.id = p.fornecedor_id where p.id = v_id;
    elsif p_tipo = 'item_avulso' then
      if p_aprovar then
        perform public.pedido_compra_acao(v_id, 'liberar_avulso', coalesce(v_mot, 'LIBERADO NA CENTRAL DE APROVAÇÕES'), '{}'::jsonb);
      else
        perform public.pedido_compra_acao(v_id, 'comentario', 'ITEM SEM CADASTRO RECUSADO: ' || v_mot, '{}'::jsonb);
      end if;
      select p.numero || ' · itens sem cadastro', p.valor_total, coalesce(p.comprador_id, p.criado_por) into v_txt, v_val, v_cri from public.pedidos_compra p where p.id = v_id;
    elsif p_tipo = 'nf_sem_pedido' then
      perform public.nfe_acao(array[v_id], case when p_aprovar then 'aprovar' else 'recusar' end, v_mot);
      select 'NF ' || numero || ' · ' || coalesce(emitente_nome, ''), valor_total, aprovacao_pedida_por into v_txt, v_val, v_cri from public.nfe_entrada where id = v_id;
    elsif p_tipo = 'produto_novo' then
      perform public.produto_aprovar(array[v_id], p_aprovar, v_mot);
      select coalesce(codigo, '—') || ' · ' || descricao, null, criado_por into v_txt, v_val, v_cri from public.produtos where id = v_id;
    elsif p_tipo = 'categoria_nova' then
      perform public.categoria_aprovar(array[v_id], p_aprovar, v_mot);
      select codigo || ' · ' || nome, null, criado_por into v_txt, v_val, v_cri from public.categorias_financeiras where id = v_id;
    elsif p_tipo = 'vt' then
      if not (select public.pode('vale_transporte', 'editar')) then raise exception 'Sem permissão para aprovar vale-transporte'; end if;
      if p_aprovar then
        update public.rh_vale_transporte set situacao = 'confirmado', recusa_motivo = null where id = v_id and situacao = 'previsto';
      else
        update public.rh_vale_transporte set recusa_motivo = upper(v_mot) where id = v_id and situacao = 'previsto';
      end if;
      if not found then raise exception 'VT % não está aguardando aprovação', v_id; end if;
      select fu.nome || ' · VT ' || to_char(x.competencia, 'MM/YYYY'), x.valor_total, x.criado_por into v_txt, v_val, v_cri
        from public.rh_vale_transporte x join public.funcionarios fu on fu.id = x.funcionario_id where x.id = v_id;
    else raise exception 'Tipo de aprovação desconhecido: %', p_tipo; end if;
    insert into public.aprovacoes_historico (tipo, registro_id, texto, valor, decisao, motivo, criado_por_registro)
    values (p_tipo, v_id, v_txt, v_val, case when p_aprovar then 'aprovado' else 'recusado' end, upper(v_mot), v_cri);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.aprovacao_decidir(text, bigint[], boolean, text) from public, anon;
grant execute on function public.aprovacao_decidir(text, bigint[], boolean, text) to authenticated;

-- Histórico (com nome de quem decidiu e de quem criou)
create or replace function public.aprovacoes_historico_lista(p_de date, p_ate date)
returns table (id bigint, tipo text, registro_id bigint, texto text, valor numeric, decisao text, motivo text, em timestamptz, por text, criado_por text)
language sql stable security definer set search_path = public as $$
  select h.id, h.tipo, h.registro_id, h.texto, h.valor, h.decisao, h.motivo, h.em, u.nome, c.nome
    from public.aprovacoes_historico h left join public.usuarios u on u.id = h.por left join public.usuarios c on c.id = h.criado_por_registro
   where ((select public.eh_admin()) or h.por = auth.uid() or h.criado_por_registro = auth.uid())
     and (p_de is null or h.em >= p_de) and (p_ate is null or h.em < p_ate + 1)
   order by h.em desc limit 2000
$$;
revoke execute on function public.aprovacoes_historico_lista(date, date) from public, anon;
grant execute on function public.aprovacoes_historico_lista(date, date) to authenticated;

select public.ligar_auditoria('aprovacoes_historico');

-- O que está esperando decisão de quem está logado (+ o que foi devolvido para ele ajustar)
create or replace function public.minhas_aprovacoes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb := '[]'; v_admin boolean := (select public.eh_admin()); v_itens jsonb; v_eu uuid := auth.uid();
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'texto', p.numero || ' · ' || f.nome, 'valor', p.valor_total, 'data', p.data_pedido,
           'quem', u.nome, 'link', 'pages/compras/pedidos.html?abrir=' || p.id) order by p.data_pedido), '[]') into v_itens
    from public.pedidos_compra p join public.fornecedores f on f.id = p.fornecedor_id left join public.usuarios u on u.id = coalesce(p.comprador_id, p.criado_por)
   where p.situacao = 'em_aprovacao' and public.pc_pode_aprovar(p.id);
  v := v || jsonb_build_object('tipo', 'pedido_compra', 'area', 'Compras', 'titulo', 'Pedidos de compra para aprovar', 'itens', v_itens, 'aprovar_aqui', true);
  if v_admin or (select public.pode_acao('compras.liberar_avulso')) then
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'texto', p.numero || ' · ' || array_to_string(public.pc_avulsos_pendentes(p.id), ', '),
             'valor', p.valor_total, 'data', p.data_pedido, 'quem', u.nome, 'link', 'pages/compras/pedidos.html?abrir=' || p.id)), '[]') into v_itens
      from public.pedidos_compra p left join public.usuarios u on u.id = coalesce(p.comprador_id, p.criado_por)
     where p.situacao in ('rascunho','recusado') and cardinality(public.pc_avulsos_pendentes(p.id)) > 0;
    v := v || jsonb_build_object('tipo', 'item_avulso', 'area', 'Compras', 'titulo', 'Itens sem cadastro para liberar', 'itens', v_itens, 'aprovar_aqui', true);
  end if;
  if v_admin then
    select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'texto', 'NF ' || n.numero || ' · ' || coalesce(n.emitente_nome, '') || ' · ' || coalesce(n.motivo_sem_pedido, ''),
             'valor', n.valor_total, 'data', n.data_emissao, 'quem', u.nome, 'link', 'pages/financeiro/notas-fiscais.html?abrir=' || n.id)), '[]') into v_itens
      from public.nfe_entrada n left join public.usuarios u on u.id = n.aprovacao_pedida_por where n.situacao = 'aguardando_aprovacao';
    v := v || jsonb_build_object('tipo', 'nf_sem_pedido', 'area', 'Financeiro', 'titulo', 'Notas fiscais sem pedido de compra', 'itens', v_itens, 'aprovar_aqui', true);
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'texto', coalesce(p.codigo, '—') || ' · ' || p.descricao,
             'data', p.criado_em, 'quem', u.nome, 'link', 'pages/cadastros/produtos.html?abrir=' || p.id)), '[]') into v_itens
      from public.produtos p left join public.usuarios u on u.id = p.criado_por where p.aprovacao = 'pendente';
    v := v || jsonb_build_object('tipo', 'produto_novo', 'area', 'Cadastros', 'titulo', 'Produtos novos para aprovar', 'itens', v_itens, 'aprovar_aqui', true);
    select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'texto', c.codigo || ' · ' || c.nome,
             'data', c.criado_em, 'quem', u.nome, 'link', 'pages/cadastros/categorias-financeiras.html?abrir=' || c.id)), '[]') into v_itens
      from public.categorias_financeiras c left join public.usuarios u on u.id = c.criado_por where c.aprovacao = 'pendente';
    v := v || jsonb_build_object('tipo', 'categoria_nova', 'area', 'Cadastros', 'titulo', 'Categorias financeiras novas para aprovar', 'itens', v_itens, 'aprovar_aqui', true);
  end if;
  if (select public.pode('vale_transporte', 'editar')) then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'texto', fu.nome || ' · VT ' || to_char(x.competencia, 'MM/YYYY') || ' · ' || coalesce(e.nome, ''),
             'valor', x.valor_total, 'data', x.competencia, 'quem', u.nome, 'link', 'pages/rh/vale-transporte.html?abrir=' || x.id) order by fu.nome), '[]') into v_itens
      from public.rh_vale_transporte x join public.funcionarios fu on fu.id = x.funcionario_id left join public.empresas e on e.id = x.empresa_id
      left join public.usuarios u on u.id = x.criado_por
     where x.situacao = 'previsto' and x.recusa_motivo is null;
    v := v || jsonb_build_object('tipo', 'vt', 'area', 'RH', 'titulo', 'RH · Vale-transporte', 'itens', v_itens, 'aprovar_aqui', true);
  end if;
  -- Devolvidos para quem criou ajustar e reenviar
  select coalesce(jsonb_agg(x order by x->>'data'), '[]') into v_itens from (
    select jsonb_build_object('id', p.id, 'texto', 'Pedido de compra ' || p.numero || ' · ' || coalesce(p.motivo_recusa, ''), 'valor', p.valor_total, 'data', p.atualizado_em,
           'link', 'pages/compras/pedidos.html?abrir=' || p.id) x
      from public.pedidos_compra p where p.situacao = 'recusado' and v_eu in (p.comprador_id, p.criado_por)
    union all
    select jsonb_build_object('id', p.id, 'texto', 'Produto ' || coalesce(p.codigo, '—') || ' · ' || p.descricao || ' · ' || coalesce(p.aprovacao_motivo, ''), 'data', p.aprovacao_em,
           'link', 'pages/cadastros/produtos.html?abrir=' || p.id)
      from public.produtos p where p.aprovacao = 'recusado' and p.criado_por = v_eu
    union all
    select jsonb_build_object('id', c.id, 'texto', 'Categoria ' || c.codigo || ' · ' || c.nome || ' · ' || coalesce(c.aprovacao_motivo, ''), 'data', c.aprovacao_em,
           'link', 'pages/cadastros/categorias-financeiras.html?abrir=' || c.id)
      from public.categorias_financeiras c where c.aprovacao = 'recusado' and c.criado_por = v_eu
    union all
    select jsonb_build_object('id', x.id, 'texto', 'VT ' || fu.nome || ' ' || to_char(x.competencia, 'MM/YYYY') || ' · ' || x.recusa_motivo, 'valor', x.valor_total, 'data', x.atualizado_em,
           'link', 'pages/rh/vale-transporte.html?abrir=' || x.id)
      from public.rh_vale_transporte x join public.funcionarios fu on fu.id = x.funcionario_id
     where x.situacao = 'previsto' and x.recusa_motivo is not null and (select public.pode('vale_transporte', 'editar'))) z;
  v := v || jsonb_build_object('tipo', 'devolvido', 'area', 'Para você', 'titulo', 'Devolvidos para você ajustar e reenviar', 'itens', v_itens, 'devolvido', true);
  -- Avisos (não são aprovação): pedidos com dado faltando e cadastros incompletos — para resolver antes de virar retrabalho
  select coalesce(jsonb_agg(x order by x->>'data'), '[]') into v_itens from (
    select jsonb_build_object('id', p.id, 'texto', p.numero || ' · ' || f.nome || ' — ' || (select string_agg(y->>'texto', '; ') from jsonb_array_elements(public.pc_pendencias(p.id)) y),
           'valor', p.valor_total, 'data', p.data_pedido, 'quem', u.nome, 'link', 'pages/compras/pedidos.html?abrir=' || p.id) x
      from public.pedidos_compra p join public.fornecedores f on f.id = p.fornecedor_id left join public.usuarios u on u.id = coalesce(p.comprador_id, p.criado_por)
     where p.situacao in ('rascunho','recusado','em_aprovacao','aprovado') and coalesce(p.origem, 'sistema') = 'sistema'
       and (v_admin or v_eu in (p.comprador_id, p.criado_por)) and jsonb_array_length(public.pc_pendencias(p.id)) > 0
    union all
    select jsonb_build_object('id', 0, 'texto', count(*) || ' produto(s) ativo(s) sem categoria financeira no cadastro — o pedido de compra pede a categoria item a item',
           'data', current_date, 'link', 'pages/cadastros/produtos.html')
      from public.produtos pr where v_admin and pr.situacao = 'ativo' and pr.categoria_financeira_id is null having count(*) > 0) z;
  v := v || jsonb_build_object('tipo', 'aviso', 'area', 'Avisos', 'titulo', 'Avisos · pendências para resolver (não precisa aprovar)', 'itens', v_itens, 'aviso', true);
  return v;
end $$;
revoke execute on function public.minhas_aprovacoes() from public, anon;
grant execute on function public.minhas_aprovacoes() to authenticated;
