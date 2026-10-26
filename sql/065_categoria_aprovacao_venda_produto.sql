-- =====================================================================
-- 065 · Categoria financeira com aprovação e código automático; pedido de venda só com produto cadastrado
--  · Categoria nova: o código é gerado sozinho, em sequência, a partir do grupo pai
--    (grupo 2.01 → próxima 2.01.008; sem pai → próximo número de topo). Ninguém digita código.
--  · Categoria criada por quem não é master fica "aguardando aprovação" e aparece em Aprovações pendentes.
--    Enquanto não for aprovada não pode ser usada em título, rateio, produto, pedido, extrato, tarifa ou canal.
--  · Pedido de venda: item novo precisa de produto cadastrado e aprovado (igual ao pedido de compra).
--    Exceção: venda de marketplace com anúncio/SKU ainda sem produto ligado (fica na pendência "Item sem produto").
--    Pedidos antigos e os que vêm das integrações (Mercado Livre) continuam como estão.
--  · Salvar o pedido de venda passa a manter os itens (antes apagava e regravava): as entregas parciais
--    ficam presas aos itens. Item com entrega não pode ser removido nem ficar com quantidade menor que a entregue.
-- =====================================================================

-- ---------- Categoria: aprovação ----------
alter table public.categorias_financeiras add column if not exists aprovacao text not null default 'aprovado';
alter table public.categorias_financeiras add column if not exists aprovacao_por uuid references public.usuarios(id);
alter table public.categorias_financeiras add column if not exists aprovacao_em timestamptz;
alter table public.categorias_financeiras add column if not exists aprovacao_motivo text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'categorias_fin_aprovacao_ck') then
    alter table public.categorias_financeiras add constraint categorias_fin_aprovacao_ck check (aprovacao in ('pendente','aprovado','recusado'));
  end if;
end $$;

-- Próximo código livre dentro do grupo (ou de topo)
create or replace function public.categoria_proximo_codigo(p_pai bigint)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_pai text; v_n int; v_dig int;
begin
  if auth.uid() is not null and not (select public.pode('categorias_fin')) then raise exception 'Sem permissão'; end if;
  if p_pai is null then
    select coalesce(max(codigo::int), 0) + 1 into v_n from public.categorias_financeiras where codigo ~ '^\d+$' and codigo::int < 99;  -- 99 = antigas do Tiny
    return v_n::text;
  end if;
  select codigo into v_pai from public.categorias_financeiras where id = p_pai;
  if v_pai is null then raise exception 'Grupo pai não encontrado'; end if;
  select coalesce(max(substr(codigo, length(v_pai) + 2)::int), 0) + 1, max(length(substr(codigo, length(v_pai) + 2)))
    into v_n, v_dig
    from public.categorias_financeiras where codigo ~ ('^' || replace(v_pai, '.', '\.') || '\.\d+$');
  v_dig := coalesce(v_dig, case when v_pai like '%.%' then 3 else 2 end);
  return v_pai || '.' || lpad(v_n::text, v_dig, '0');
end $$;
revoke execute on function public.categoria_proximo_codigo(bigint) from public, anon;
grant execute on function public.categoria_proximo_codigo(bigint) to authenticated;

create or replace function public.categoria_nova_regras()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;                -- cargas automáticas (Tiny) mantêm o código delas
  if tg_op = 'INSERT' then
    new.codigo := public.categoria_proximo_codigo(new.pai_id);
    if (select public.eh_admin()) then
      new.aprovacao := 'aprovado'; new.aprovacao_por := auth.uid(); new.aprovacao_em := now();
    else
      new.aprovacao := 'pendente'; new.aprovacao_por := null; new.aprovacao_em := null; new.aprovacao_motivo := null;
    end if;
    return new;
  end if;
  -- alteração: código não se digita; muda só se trocar de grupo pai (e se não tiver subcategorias)
  if new.pai_id is distinct from old.pai_id then
    if exists (select 1 from public.categorias_financeiras where pai_id = old.id) then
      raise exception 'Categoria com subcategorias não muda de grupo';
    end if;
    new.codigo := public.categoria_proximo_codigo(new.pai_id);
  else
    new.codigo := old.codigo;
  end if;
  if (new.aprovacao, new.aprovacao_por, new.aprovacao_em, new.aprovacao_motivo) is distinct from (old.aprovacao, old.aprovacao_por, old.aprovacao_em, old.aprovacao_motivo)
     and not (select public.eh_admin()) then
    raise exception 'Só o master aprova ou recusa categoria nova';
  end if;
  return new;
end $$;
revoke execute on function public.categoria_nova_regras() from public, anon, authenticated;
create or replace trigger aprovacao before insert or update on public.categorias_financeiras
  for each row execute function public.categoria_nova_regras();

-- Master aprova/recusa (várias de uma vez)
create or replace function public.categoria_aprovar(p_ids bigint[], p_aprovar boolean, p_motivo text default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not (select public.eh_admin()) then raise exception 'Só o master aprova categoria nova'; end if;
  if not p_aprovar and coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo da recusa'; end if;
  update public.categorias_financeiras set aprovacao = case when p_aprovar then 'aprovado' else 'recusado' end,
         aprovacao_por = auth.uid(), aprovacao_em = now(), aprovacao_motivo = case when p_aprovar then null else upper(p_motivo) end
   where id = any(p_ids);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.categoria_aprovar(bigint[], boolean, text) from public, anon;
grant execute on function public.categoria_aprovar(bigint[], boolean, text) to authenticated;

-- Não deixa usar categoria pendente/recusada (só quando um usuário grava ou troca a categoria)
create or replace function public.exige_categoria_aprovada()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_novo bigint; v_velho bigint; c record;
begin
  if auth.uid() is null then return new; end if;
  v_novo := nullif(to_jsonb(new) ->> tg_argv[0], '')::bigint;
  if v_novo is null then return new; end if;
  if tg_op = 'UPDATE' then
    v_velho := nullif(to_jsonb(old) ->> tg_argv[0], '')::bigint;
    if v_novo is not distinct from v_velho then return new; end if;
  end if;
  select codigo, nome, aprovacao into c from public.categorias_financeiras where id = v_novo;
  if c.aprovacao is distinct from 'aprovado' then
    raise exception 'Categoria % % ainda não foi aprovada pelo master', c.codigo, c.nome;
  end if;
  return new;
end $$;
revoke execute on function public.exige_categoria_aprovada() from public, anon, authenticated;
create or replace trigger categoria_aprovada before insert or update on public.titulos_pagar for each row execute function public.exige_categoria_aprovada('categoria_financeira_id');
create or replace trigger categoria_aprovada before insert or update on public.titulos_receber for each row execute function public.exige_categoria_aprovada('categoria_financeira_id');
create or replace trigger categoria_aprovada before insert or update on public.titulos_pagar_rateio for each row execute function public.exige_categoria_aprovada('categoria_financeira_id');
create or replace trigger categoria_aprovada before insert or update on public.titulos_receber_rateio for each row execute function public.exige_categoria_aprovada('categoria_financeira_id');
create or replace trigger categoria_aprovada before insert or update on public.produtos for each row execute function public.exige_categoria_aprovada('categoria_financeira_id');
create or replace trigger categoria_aprovada before insert or update on public.pedidos_compra_itens for each row execute function public.exige_categoria_aprovada('categoria_financeira_id');
create or replace trigger categoria_aprovada before insert or update on public.pedidos_venda_encargos for each row execute function public.exige_categoria_aprovada('categoria_financeira_id');
create or replace trigger categoria_aprovada before insert or update on public.extrato_lancamentos for each row execute function public.exige_categoria_aprovada('categoria_financeira_id');
create or replace trigger categoria_aprovada before insert or update on public.encargos_tipos for each row execute function public.exige_categoria_aprovada('categoria_financeira_id');
create or replace trigger categoria_aprovada before insert or update on public.canais_venda for each row execute function public.exige_categoria_aprovada('categoria_receita_id');

-- ---------- Pedido de venda: item só com produto cadastrado e aprovado ----------
-- (roda depois do gatilho "produto", que acha o produto pelo anúncio/SKU)
create or replace function public.pv_item_exige_produto()
returns trigger language plpgsql security definer set search_path = public as $$
declare p record; v_tipo text;
begin
  if auth.uid() is null then return new; end if;                -- integrações (Mercado Livre) seguem livres
  if new.produto_id is null then
    if tg_op = 'INSERT' or old.produto_id is not null then
      select tipo into v_tipo from public.pedidos_venda where id = new.pedido_id;
      -- venda de marketplace sem produto ligado ao anúncio ainda: aceita se tem anúncio/SKU (aparece na pendência "Item sem produto")
      if v_tipo = 'marketplace' and (new.anuncio_id is not null or new.sku is not null or new.anuncio_ref is not null) then return new; end if;
      raise exception 'Item sem produto cadastrado: cadastre o produto (vai para aprovação do master) antes de vender';
    end if;
    return new;
  end if;
  if tg_op = 'INSERT' or new.produto_id is distinct from old.produto_id then
    select descricao, coalesce(aprovacao, 'aprovado') aprovacao into p from public.produtos where id = new.produto_id;
    if p.aprovacao <> 'aprovado' then
      raise exception 'Produto "%" ainda não foi aprovado pelo master (cadastro novo)', p.descricao;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.pv_item_exige_produto() from public, anon, authenticated;
create or replace trigger produto_z_obrigatorio before insert or update on public.pedidos_venda_itens
  for each row execute function public.pv_item_exige_produto();

-- Salvar pedido de venda mantendo os itens (id) — entregas ficam ligadas a eles
do $$ declare d text; v_velho text; v_novo text; begin
  d := pg_get_functiondef('public.salvar_pedido_venda(jsonb, jsonb, jsonb)'::regprocedure);
  if position('itens_mantidos' in d) = 0 then
    v_velho := $x$    delete from public.pedidos_venda_itens where pedido_id = v_id;
    insert into public.pedidos_venda_itens (pedido_id, produto_id, anuncio_ref, anuncio_id, variacao_id, sku, descricao, quantidade, valor_unitario, desconto)
    select v_id, nullif(x->>'produto_id', '')::bigint, nullif(x->>'anuncio_ref', '')::bigint, nullif(x->>'anuncio_id', ''), nullif(x->>'variacao_id', ''),
           nullif(x->>'sku', ''), x->>'descricao', (x->>'quantidade')::numeric, coalesce((x->>'valor_unitario')::numeric, 0), coalesce((x->>'desconto')::numeric, 0)
    from jsonb_array_elements(p_itens) x where coalesce((x->>'quantidade')::numeric, 0) > 0;$x$;
    v_novo := $x$    -- itens_mantidos: atualiza os que vieram com id, apaga os retirados e inclui os novos
    if exists (select 1 from public.pedidos_venda_entregas_itens ei join public.pedidos_venda_itens i on i.id = ei.pedido_item_id
                 join public.pedidos_venda_entregas e on e.id = ei.entrega_id
                where i.pedido_id = v_id and e.situacao <> 'cancelada'
                  and i.id <> all (coalesce((select array_agg((x->>'id')::bigint) from jsonb_array_elements(p_itens) x
                                             where nullif(x->>'id', '') is not null and coalesce((x->>'quantidade')::numeric, 0) > 0), '{}'))) then
      raise exception 'Item com entrega não pode ser removido do pedido (cancele a entrega antes)';
    end if;
    delete from public.pedidos_venda_entregas_itens ei using public.pedidos_venda_itens i
     where i.id = ei.pedido_item_id and i.pedido_id = v_id
       and i.id <> all (coalesce((select array_agg((x->>'id')::bigint) from jsonb_array_elements(p_itens) x
                                  where nullif(x->>'id', '') is not null and coalesce((x->>'quantidade')::numeric, 0) > 0), '{}'));
    delete from public.pedidos_venda_itens i where i.pedido_id = v_id
       and i.id <> all (coalesce((select array_agg((x->>'id')::bigint) from jsonb_array_elements(p_itens) x
                                  where nullif(x->>'id', '') is not null and coalesce((x->>'quantidade')::numeric, 0) > 0), '{}'));
    update public.pedidos_venda_itens i set produto_id = nullif(x->>'produto_id', '')::bigint, anuncio_ref = nullif(x->>'anuncio_ref', '')::bigint,
           anuncio_id = nullif(x->>'anuncio_id', ''), variacao_id = nullif(x->>'variacao_id', ''), sku = nullif(x->>'sku', ''), descricao = x->>'descricao',
           quantidade = (x->>'quantidade')::numeric, valor_unitario = coalesce((x->>'valor_unitario')::numeric, 0), desconto = coalesce((x->>'desconto')::numeric, 0)
      from jsonb_array_elements(p_itens) x
     where nullif(x->>'id', '') is not null and i.id = (x->>'id')::bigint and i.pedido_id = v_id and coalesce((x->>'quantidade')::numeric, 0) > 0;
    insert into public.pedidos_venda_itens (pedido_id, produto_id, anuncio_ref, anuncio_id, variacao_id, sku, descricao, quantidade, valor_unitario, desconto)
    select v_id, nullif(x->>'produto_id', '')::bigint, nullif(x->>'anuncio_ref', '')::bigint, nullif(x->>'anuncio_id', ''), nullif(x->>'variacao_id', ''),
           nullif(x->>'sku', ''), x->>'descricao', (x->>'quantidade')::numeric, coalesce((x->>'valor_unitario')::numeric, 0), coalesce((x->>'desconto')::numeric, 0)
    from jsonb_array_elements(p_itens) x
    where coalesce((x->>'quantidade')::numeric, 0) > 0
      and (nullif(x->>'id', '') is null or not exists (select 1 from public.pedidos_venda_itens i where i.id = (x->>'id')::bigint and i.pedido_id = v_id));
    if exists (select 1 from public.pv_item_saldos(v_id) s where s.pendente < -0.0001) then
      raise exception 'Quantidade do item ficou menor que a já separada/entregue nas entregas';
    end if;$x$;
    if position(v_velho in d) = 0 then raise exception 'salvar_pedido_venda mudou: revisar 065'; end if;
    execute replace(d, v_velho, v_novo);
  end if;
end $$;

-- ---------- Aprovações pendentes: categorias novas ----------
do $$ declare d text; begin
  d := pg_get_functiondef('public.minhas_aprovacoes()'::regprocedure);
  if position('categoria_nova' in d) = 0 then
    d := replace(d, $x$    v := v || jsonb_build_object('tipo', 'produto_novo', 'titulo', 'Produtos novos para aprovar', 'itens', v_itens, 'aprovar_aqui', true);$x$,
      $x$    v := v || jsonb_build_object('tipo', 'produto_novo', 'titulo', 'Produtos novos para aprovar', 'itens', v_itens, 'aprovar_aqui', true);
    select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'texto', c.codigo || ' · ' || c.nome || ' · cadastrada por ' || coalesce(u.nome, '?'),
             'data', c.criado_em, 'link', 'pages/cadastros/categorias-financeiras.html?abrir=' || c.id)), '[]') into v_itens
      from public.categorias_financeiras c left join public.usuarios u on u.id = c.criado_por where c.aprovacao = 'pendente';
    v := v || jsonb_build_object('tipo', 'categoria_nova', 'titulo', 'Categorias financeiras novas para aprovar', 'itens', v_itens, 'aprovar_aqui', true);$x$);
    if position('categoria_nova' in d) = 0 then raise exception 'minhas_aprovacoes mudou: revisar 065'; end if;
    execute d;
  end if;
end $$;

-- Salvar pedido de venda grava a opção "entrega parcial" (pedido novo nasce sem)
do $$ declare d text; begin
  d := pg_get_functiondef('public.salvar_pedido_venda(jsonb, jsonb, jsonb)'::regprocedure);
  if position('entrega_parcial' in d) = 0 then
    d := replace(d, $x$'valor_produtos', 0, 'valor_total', 0, 'encargos', 0, 'valor_liquido', 0))$x$,
                    $x$'valor_produtos', 0, 'valor_total', 0, 'encargos', 0, 'valor_liquido', 0, 'entrega_parcial', coalesce(v_dados->'entrega_parcial', 'false')))$x$);
    d := replace(d, $x$observacoes, observacoes_internas) =$x$, $x$observacoes, observacoes_internas, entrega_parcial) =$x$);
    d := replace(d, $x$r.observacoes, r.observacoes_internas
$x$, $x$r.observacoes, r.observacoes_internas, coalesce(r.entrega_parcial, false)
$x$);
    if (length(d) - length(replace(d, 'entrega_parcial', ''))) / length('entrega_parcial') <> 4 then raise exception 'salvar_pedido_venda: troca incompleta'; end if;
    execute d;
  end if;
end $$;
