-- =====================================================================
-- 064 · Pedido de venda: entregas parciais, expedição e faturamento por entrega
--  · "Habilitar entrega parcial" no pedido: o comercial cria entregas com parte dos itens
--    (ex.: pedido de 51 itens, 1 sai na hora e 50 depois). Sem a opção, a entrega leva tudo o que falta.
--  · Expedição: separar → expedir (quem retirou / transportadora / rastreio) → entregue. Sem valores.
--    A saída baixa o estoque dos produtos controlados.
--  · Faturamento por entrega: com NF (número, série, chave) ou sem NF (fica pendência "NF pendente").
--    Gera o título a receber da parte entregue, pela condição de pagamento do pedido.
--  · Pedido faturado inteiro (botão antigo) e faturamento por entrega não se misturam.
--  · Produção, expedição e almoxarifado deixam de ver pedidos de venda com valores (usam a tela de Expedição).
-- =====================================================================
alter table public.pedidos_venda add column if not exists entrega_parcial boolean not null default false;

create table if not exists public.pedidos_venda_entregas (
  id                  bigserial primary key,
  pedido_id           bigint not null references public.pedidos_venda(id),
  numero              int not null,                         -- 1, 2, 3… dentro do pedido
  tipo                text not null default 'retirada' check (tipo in ('retirada','envio')),
  situacao            text not null default 'separar' check (situacao in ('separar','separado','expedido','entregue','cancelada')),
  faturamento         text not null default 'pendente' check (faturamento in ('pendente','com_nf','sem_nf')),
  nf_numero           text, nf_serie text, nf_chave text, nf_data date,
  previsao            date,
  observacao          text,                                 -- do comercial para a expedição
  observacao_expedicao text,
  recebido_por        text,                                 -- quem retirou / transportadora
  codigo_rastreio     text,
  separado_por uuid, separado_em timestamptz, expedido_por uuid, expedido_em timestamptz, entregue_em timestamptz,
  faturado_por uuid, faturado_em timestamptz,
  motivo_cancelamento text,
  criado_em timestamptz not null default now(), criado_por uuid default auth.uid(),
  atualizado_em timestamptz not null default now(), atualizado_por uuid,
  unique (pedido_id, numero)
);
create table if not exists public.pedidos_venda_entregas_itens (
  id               bigserial primary key,
  entrega_id       bigint not null references public.pedidos_venda_entregas(id) on delete cascade,
  pedido_item_id   bigint not null references public.pedidos_venda_itens(id),
  quantidade       numeric(14,4) not null check (quantidade > 0)
);
create index if not exists pv_entregas_ped_idx on public.pedidos_venda_entregas (pedido_id);
create index if not exists pv_entregas_itens_idx on public.pedidos_venda_entregas_itens (entrega_id);
alter table public.estoque_movimentos add column if not exists pedido_venda_entrega_id bigint references public.pedidos_venda_entregas(id);
alter table public.titulos_receber add column if not exists pedido_venda_entrega_id bigint references public.pedidos_venda_entregas(id);

create or replace trigger carimbo before insert or update on public.pedidos_venda_entregas for each row execute function public.carimbo_cadastro();
alter table public.pedidos_venda_entregas enable row level security;
alter table public.pedidos_venda_entregas_itens enable row level security;
drop policy if exists "ver entregas" on public.pedidos_venda_entregas;
create policy "ver entregas" on public.pedidos_venda_entregas for select to authenticated using ((select public.pode('pedidos')) or (select public.pode('separacao')));
drop policy if exists "ver entregas itens" on public.pedidos_venda_entregas_itens;
create policy "ver entregas itens" on public.pedidos_venda_entregas_itens for select to authenticated using ((select public.pode('pedidos')) or (select public.pode('separacao')));

-- Quanto de cada item já está comprometido (entregas não canceladas)
create or replace function public.pv_item_saldos(p_pedido bigint)
returns table (pedido_item_id bigint, quantidade numeric, em_entregas numeric, entregue numeric, pendente numeric)
language sql stable security definer set search_path = public as $$
  select i.id, i.quantidade,
         coalesce(sum(ei.quantidade) filter (where e.situacao not in ('cancelada')), 0),
         coalesce(sum(ei.quantidade) filter (where e.situacao in ('expedido','entregue')), 0),
         i.quantidade - coalesce(sum(ei.quantidade) filter (where e.situacao not in ('cancelada')), 0)
    from public.pedidos_venda_itens i
    left join public.pedidos_venda_entregas_itens ei on ei.pedido_item_id = i.id
    left join public.pedidos_venda_entregas e on e.id = ei.entrega_id
   where i.pedido_id = p_pedido and ((select public.pode('pedidos')) or (select public.pode('separacao')))
   group by i.id, i.quantidade
$$;
revoke execute on function public.pv_item_saldos(bigint) from public, anon;
grant execute on function public.pv_item_saldos(bigint) to authenticated;

-- Criar entrega (comercial)
create or replace function public.entrega_criar(p_pedido bigint, p_itens jsonb, p_tipo text default 'retirada', p_obs text default null, p_previsao date default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare p public.pedidos_venda; v_id bigint; v_n int; x record; v_pend numeric; v_total_pend numeric; v_total_ent numeric;
begin
  if not (select public.pode('pedidos', 'alterar')) then raise exception 'Sem permissão para criar entrega'; end if;
  select * into p from public.pedidos_venda where id = p_pedido for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if p.situacao in ('orcamento','cancelado') then raise exception 'Pedido em orçamento ou cancelado'; end if;
  if exists (select 1 from public.titulos_receber where pedido_venda_id = p.id and pedido_venda_entrega_id is null and origem_ref->'entregas' is null and situacao <> 'cancelado') then
    raise exception 'Este pedido já foi faturado inteiro (título do pedido todo): entrega parcial não se aplica';
  end if;
  select coalesce(sum(pendente), 0) into v_total_pend from public.pv_item_saldos(p.id);
  select coalesce(sum((y->>'quantidade')::numeric), 0) into v_total_ent from jsonb_array_elements(p_itens) y where coalesce((y->>'quantidade')::numeric, 0) > 0;
  if v_total_ent <= 0 then raise exception 'Informe a quantidade de pelo menos um item'; end if;
  for x in select (y->>'pedido_item_id')::bigint item, (y->>'quantidade')::numeric q from jsonb_array_elements(p_itens) y where coalesce((y->>'quantidade')::numeric, 0) > 0 loop
    select pendente into v_pend from public.pv_item_saldos(p.id) s where s.pedido_item_id = x.item;
    if v_pend is null then raise exception 'Item % não é deste pedido', x.item; end if;
    if x.q > v_pend + 0.0001 then raise exception 'Quantidade maior que o pendente do item (pendente %)', v_pend; end if;
  end loop;
  if not p.entrega_parcial and abs(v_total_ent - v_total_pend) > 0.0001 then
    raise exception 'Entrega parcial não habilitada neste pedido: a entrega precisa levar tudo o que falta (habilite "entrega parcial")';
  end if;
  select coalesce(max(numero), 0) + 1 into v_n from public.pedidos_venda_entregas where pedido_id = p.id;
  insert into public.pedidos_venda_entregas (pedido_id, numero, tipo, observacao, previsao)
  values (p.id, v_n, coalesce(nullif(p_tipo, ''), 'retirada'), nullif(p_obs, ''), p_previsao) returning id into v_id;
  insert into public.pedidos_venda_entregas_itens (entrega_id, pedido_item_id, quantidade)
  select v_id, (y->>'pedido_item_id')::bigint, (y->>'quantidade')::numeric from jsonb_array_elements(p_itens) y where coalesce((y->>'quantidade')::numeric, 0) > 0;
  return v_id;
end $$;
revoke execute on function public.entrega_criar(bigint, jsonb, text, text, date) from public, anon;
grant execute on function public.entrega_criar(bigint, jsonb, text, text, date) to authenticated;

-- Expedição: separar, expedir (baixa estoque), entregue; comercial: cancelar (antes de expedir)
create or replace function public.entrega_acao(p_id bigint, p_acao text, p_dados jsonb default '{}')
returns text language plpgsql security definer set search_path = public as $$
declare e public.pedidos_venda_entregas;
begin
  select * into e from public.pedidos_venda_entregas where id = p_id for update;
  if e.id is null then raise exception 'Entrega não encontrada'; end if;
  if p_acao in ('separado','expedido','entregue','voltar') then
    if not ((select public.pode('separacao', 'alterar')) or (select public.pode('pedidos', 'alterar'))) then raise exception 'Sem permissão na expedição'; end if;
  end if;
  if p_acao = 'separado' then
    if e.situacao <> 'separar' then raise exception 'Entrega não está para separar'; end if;
    update public.pedidos_venda_entregas set situacao = 'separado', separado_por = auth.uid(), separado_em = now(),
      observacao_expedicao = coalesce(nullif(p_dados->>'obs', ''), observacao_expedicao) where id = p_id;
  elsif p_acao = 'expedido' then
    if e.situacao not in ('separar','separado') then raise exception 'Entrega já expedida ou cancelada'; end if;
    if coalesce(trim(p_dados->>'recebido_por'), '') = '' then raise exception 'Informe quem retirou ou a transportadora'; end if;
    update public.pedidos_venda_entregas set situacao = 'expedido', expedido_por = auth.uid(), expedido_em = now(),
      separado_por = coalesce(separado_por, auth.uid()), separado_em = coalesce(separado_em, now()),
      recebido_por = p_dados->>'recebido_por', codigo_rastreio = nullif(p_dados->>'rastreio', ''),
      observacao_expedicao = coalesce(nullif(p_dados->>'obs', ''), observacao_expedicao) where id = p_id;
    insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, observacao, pedido_venda_entrega_id)
    select i.produto_id, 'saida', -ei.quantidade, pr.unidade,
           'Entrega ' || e.numero || ' · pedido ' || coalesce(pv.numero_externo, pv.id::text), e.id
      from public.pedidos_venda_entregas_itens ei join public.pedidos_venda_itens i on i.id = ei.pedido_item_id
      join public.pedidos_venda pv on pv.id = i.pedido_id join public.produtos pr on pr.id = i.produto_id
     where ei.entrega_id = e.id and pr.controla_estoque;
  elsif p_acao = 'entregue' then
    if e.situacao <> 'expedido' then raise exception 'Expeça a entrega antes'; end if;
    update public.pedidos_venda_entregas set situacao = 'entregue', entregue_em = now() where id = p_id;
  elsif p_acao = 'voltar' then
    if e.situacao <> 'separado' then raise exception 'Só volta para separar uma entrega separada'; end if;
    update public.pedidos_venda_entregas set situacao = 'separar', separado_por = null, separado_em = null where id = p_id;
  elsif p_acao = 'cancelar' then
    if not (select public.pode('pedidos', 'alterar')) then raise exception 'Sem permissão'; end if;
    if e.situacao in ('expedido','entregue') then raise exception 'Entrega já saiu: não dá para cancelar'; end if;
    if e.faturamento <> 'pendente' then raise exception 'Entrega já faturada'; end if;
    if coalesce(trim(p_dados->>'motivo'), '') = '' then raise exception 'Informe o motivo'; end if;
    update public.pedidos_venda_entregas set situacao = 'cancelada', motivo_cancelamento = p_dados->>'motivo' where id = p_id;
  else raise exception 'Ação desconhecida'; end if;
  -- pedido: entregue quando todas as quantidades saíram
  update public.pedidos_venda pv set situacao = 'entregue', data_entrega = coalesce(pv.data_entrega, current_date)
   where pv.id = e.pedido_id and pv.situacao not in ('cancelado','devolvido','entregue')
     and not exists (select 1 from public.pv_item_saldos(pv.id) s where s.quantidade - s.entregue > 0.0001);
  return (select situacao from public.pedidos_venda_entregas where id = p_id);
end $$;
revoke execute on function public.entrega_acao(bigint, text, jsonb) from public, anon;
grant execute on function public.entrega_acao(bigint, text, jsonb) to authenticated;

-- Faturamento: uma ou várias entregas JÁ RETIRADAS do mesmo cliente e empresa numa cobrança só
--   (o cliente retira e a cobrança sai depois, ex.: quando acumular um valor). Com NF ou sem NF (NF pendente).
alter table public.pedidos_venda_entregas add column if not exists faturamento_grupo uuid;
create or replace function public.entregas_faturar(p_ids bigint[], p_com_nf boolean, p_nf jsonb default '{}', p_condicao bigint default null)
returns int language plpgsql security definer set search_path = public as $$
declare p public.pedidos_venda; c record; v_cat bigint; v_valor numeric := 0; v_dias int[]; v_n int; i int; v_cli bigint; v_emp int; v_qt int;
        v_parc numeric; v_acum numeric := 0; v_grupo uuid := gen_random_uuid(); v_data date; v_peds bigint[]; v_nums text; v_ent record;
begin
  if not ((select public.pode('pedidos', 'alterar')) or (select public.pode('receber', 'criar'))) then raise exception 'Sem permissão para faturar'; end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 then raise exception 'Escolha as entregas'; end if;
  -- só registrar a NF de entregas já faturadas sem NF
  if p_com_nf and not exists (select 1 from public.pedidos_venda_entregas where id = any(p_ids) and faturamento = 'pendente') then
    if exists (select 1 from public.pedidos_venda_entregas where id = any(p_ids) and faturamento <> 'sem_nf') then raise exception 'Há entrega já faturada com NF'; end if;
    if coalesce(trim(p_nf->>'numero'), '') = '' then raise exception 'Informe o número da NF'; end if;
    update public.pedidos_venda_entregas set faturamento = 'com_nf', nf_numero = p_nf->>'numero', nf_serie = nullif(p_nf->>'serie', ''),
      nf_chave = nullif(p_nf->>'chave', ''), nf_data = coalesce(nullif(p_nf->>'data', '')::date, current_date) where id = any(p_ids);
    update public.titulos_receber t set documento = 'NF ' || (p_nf->>'numero') || case when t.parcelas > 1 then ' ' || t.parcela || '/' || t.parcelas else '' end,
      descricao = replace(t.descricao, ' (SEM NF — NF PENDENTE)', '')
     where t.situacao <> 'cancelado' and t.grupo_parcelas in (select faturamento_grupo from public.pedidos_venda_entregas where id = any(p_ids));
    return 0;
  end if;
  select count(*), count(distinct coalesce(pv.cliente_id, -pv.id)), count(distinct pv.empresa_id), min(pv.cliente_id), min(pv.empresa_id), array_agg(distinct pv.id),
         string_agg('entrega ' || e.numero || ' do pedido ' || coalesce(pv.numero_externo, pv.id::text), ', ')
    into v_qt, i, v_n, v_cli, v_emp, v_peds, v_nums
    from public.pedidos_venda_entregas e join public.pedidos_venda pv on pv.id = e.pedido_id
   where e.id = any(p_ids) and e.situacao <> 'cancelada' and e.faturamento = 'pendente';
  if v_qt <> array_length(p_ids, 1) then raise exception 'Há entrega cancelada ou já faturada na seleção'; end if;
  if i > 1 or v_n > 1 then raise exception 'Fature juntas só entregas do mesmo cliente e da mesma empresa'; end if;
  if p_com_nf and coalesce(trim(p_nf->>'numero'), '') = '' then raise exception 'Informe o número da NF'; end if;
  if exists (select 1 from public.titulos_receber where pedido_venda_id = any(v_peds) and pedido_venda_entrega_id is null and origem_ref->'entregas' is null
             and situacao <> 'cancelado') then
    raise exception 'Pedido já faturado inteiro: não fatura por entrega';
  end if;
  for v_ent in select e.id, pv.valor_liquido, pv.valor_produtos from public.pedidos_venda_entregas e join public.pedidos_venda pv on pv.id = e.pedido_id where e.id = any(p_ids) loop
    v_valor := v_valor + coalesce((select round(sum(ei.quantidade * (it.valor_total / nullif(it.quantidade, 0))) *
                  case when coalesce(v_ent.valor_produtos, 0) > 0 then v_ent.valor_liquido / v_ent.valor_produtos else 1 end, 2)
                from public.pedidos_venda_entregas_itens ei join public.pedidos_venda_itens it on it.id = ei.pedido_item_id where ei.entrega_id = v_ent.id), 0);
  end loop;
  if v_valor <= 0 then raise exception 'Entregas sem valor'; end if;
  select * into p from public.pedidos_venda where id = v_peds[1];
  select * into c from public.canais_venda where id = p.canal_id;
  v_cat := coalesce(c.categoria_receita_id, (select id from public.categorias_financeiras where codigo = '1.01.002'));
  v_data := case when p_com_nf then coalesce(nullif(p_nf->>'data', '')::date, current_date) else current_date end;
  select dias into v_dias from public.condicoes_pagamento where id = coalesce(p_condicao, p.condicao_pagamento_id);
  v_dias := coalesce(v_dias, '{0}'); v_n := array_length(v_dias, 1);
  for i in 1..v_n loop
    v_parc := case when i = v_n then v_valor - v_acum else round(v_valor / v_n, 2) end; v_acum := v_acum + v_parc;
    insert into public.titulos_receber (empresa_id, cliente_id, canal_id, pedido_venda_id, pedido_venda_entrega_id, numero_externo, documento, descricao,
      categoria_financeira_id, valor, data_emissao, data_vencimento, conta_bancaria_id, forma_pagamento_id, parcela, parcelas, grupo_parcelas, origem, origem_ref)
    values (v_emp, v_cli, p.canal_id, case when array_length(v_peds, 1) = 1 then v_peds[1] end, case when array_length(p_ids, 1) = 1 then p_ids[1] end, p.numero_externo,
      case when p_com_nf then 'NF ' || (p_nf->>'numero') else 'Retiradas ' || to_char(v_data, 'DD/MM/YYYY') end || case when v_n > 1 then ' ' || i || '/' || v_n else '' end,
      upper(v_nums) || case when p_com_nf then '' else ' (SEM NF — NF PENDENTE)' end,
      v_cat, v_parc, v_data, v_data + v_dias[i],
      case when (select empresa_id from public.contas_bancarias where id = c.conta_bancaria_id) = v_emp then c.conta_bancaria_id end,
      p.forma_pagamento_id, i, v_n, v_grupo, 'pedido_venda', jsonb_build_object('entregas', to_jsonb(p_ids), 'pedidos', to_jsonb(v_peds)));
  end loop;
  update public.pedidos_venda_entregas set faturamento = case when p_com_nf then 'com_nf' else 'sem_nf' end, faturado_por = auth.uid(), faturado_em = now(),
    faturamento_grupo = v_grupo, nf_numero = case when p_com_nf then p_nf->>'numero' end, nf_serie = case when p_com_nf then nullif(p_nf->>'serie', '') end,
    nf_chave = case when p_com_nf then nullif(p_nf->>'chave', '') end, nf_data = case when p_com_nf then v_data end
   where id = any(p_ids);
  return v_n;
end $$;
revoke execute on function public.entregas_faturar(bigint[], boolean, jsonb, bigint) from public, anon;
grant execute on function public.entregas_faturar(bigint[], boolean, jsonb, bigint) to authenticated;

-- Entregas a faturar por cliente (acumulado das retiradas ainda sem cobrança)
create or replace function public.entregas_a_faturar()
returns table (cliente_id bigint, cliente text, empresa_id int, entregas int, valor numeric, desde date, ids bigint[])
language sql stable security definer set search_path = public as $$
  select pv.cliente_id, coalesce(cl.nome, max(pv.cliente_nome)), pv.empresa_id, count(*)::int,
         sum((select round(sum(ei.quantidade * (it.valor_total / nullif(it.quantidade, 0))) *
              case when coalesce(pv.valor_produtos, 0) > 0 then pv.valor_liquido / pv.valor_produtos else 1 end, 2)
              from public.pedidos_venda_entregas_itens ei join public.pedidos_venda_itens it on it.id = ei.pedido_item_id where ei.entrega_id = e.id)),
         min(coalesce(e.expedido_em, e.criado_em))::date, array_agg(e.id order by e.id)
    from public.pedidos_venda_entregas e join public.pedidos_venda pv on pv.id = e.pedido_id left join public.clientes cl on cl.id = pv.cliente_id
   where (select public.pode('pedidos')) and e.situacao in ('expedido','entregue') and e.faturamento = 'pendente'
   group by pv.cliente_id, cl.nome, pv.empresa_id
   order by 5 desc
$$;
revoke execute on function public.entregas_a_faturar() from public, anon;
grant execute on function public.entregas_a_faturar() to authenticated;

-- Faturar o pedido inteiro (botão antigo) não pode misturar com faturamento por entrega
do $$ declare d text; begin
  d := pg_get_functiondef('public.gerar_titulos_pedido(bigint)'::regprocedure);
  if position('pedidos_venda_entregas' in d) = 0 then
    d := replace(d, $x$if not exists (select 1 from public.pedidos_venda_itens where pedido_id = p.id) then raise exception 'Pedido sem itens'; end if;$x$,
      $x$if not exists (select 1 from public.pedidos_venda_itens where pedido_id = p.id) then raise exception 'Pedido sem itens'; end if;
  if exists (select 1 from public.pedidos_venda_entregas where pedido_id = p.id and situacao <> 'cancelada') then
    raise exception 'Este pedido tem entregas: fature por entrega (seção Entregas do pedido)';
  end if;$x$);
    execute d;
  end if;
end $$;

-- Tela de Expedição (sem valores): entregas com cliente e itens/quantidades
create or replace function public.expedicao_lista()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'numero', e.numero, 'pedido_id', pv.id, 'pedido', coalesce(pv.numero_externo, pv.id::text), 'empresa_id', pv.empresa_id,
      'cliente', coalesce(cl.nome, pv.cliente_nome), 'tipo', e.tipo, 'situacao', e.situacao, 'previsao', e.previsao, 'observacao', e.observacao,
      'observacao_expedicao', e.observacao_expedicao, 'recebido_por', e.recebido_por, 'codigo_rastreio', e.codigo_rastreio,
      'criado_em', e.criado_em, 'separado_em', e.separado_em, 'expedido_em', e.expedido_em, 'entregue_em', e.entregue_em,
      'separado_por', (select nome from public.usuarios where id = e.separado_por), 'expedido_por', (select nome from public.usuarios where id = e.expedido_por),
      'parcial', pv.entrega_parcial,
      'itens', (select jsonb_agg(jsonb_build_object('codigo', pr.codigo, 'descricao', coalesce(pr.descricao, i.descricao, i.sku), 'unidade', pr.unidade,
                  'quantidade', ei.quantidade, 'pedido', i.quantidade) order by i.id)
                from public.pedidos_venda_entregas_itens ei join public.pedidos_venda_itens i on i.id = ei.pedido_item_id
                left join public.produtos pr on pr.id = i.produto_id where ei.entrega_id = e.id)
    ) order by e.situacao, coalesce(e.previsao, e.criado_em::date), e.id), '[]')
    from public.pedidos_venda_entregas e join public.pedidos_venda pv on pv.id = e.pedido_id left join public.clientes cl on cl.id = pv.cliente_id
   where ((select public.pode('separacao')) or (select public.pode('pedidos')))
     and (e.situacao in ('separar','separado','expedido') or e.atualizado_em > now() - interval '30 days')
$$;
revoke execute on function public.expedicao_lista() from public, anon;
grant execute on function public.expedicao_lista() to authenticated;

-- Produção, expedição e almoxarifado sem valores: deixam de ver pedidos de venda (usam a Expedição)
delete from public.permissoes where modulo_id = 'pedidos' and perfil_id in ('expedicao','estoque','producao_lider','producao_operador');
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('estoque', 'separacao', 'alterar'), ('comercial', 'separacao', 'ver')
on conflict (perfil_id, modulo_id) do nothing;
update public.permissoes set nivel = 'alterar' where perfil_id = 'estoque' and modulo_id = 'separacao' and nivel = 'ver';

select public.ligar_auditoria('pedidos_venda_entregas');
