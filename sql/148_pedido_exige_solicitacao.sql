-- =====================================================================
-- 148 · Pedido de compra só avança com a solicitação de compra vinculada
--  · Regra do Paulo (18/11/2026): o comprador só manda o pedido para aprovação se ele estiver ligado a uma
--    solicitação de compra APROVADA. Sem solicitação vinculada, o botão "Enviar para aprovação" é recusado
--    e o pedido mostra a pendência "Vincule a solicitação de compra".
--  · Pedido gerado pela própria solicitação ou pela cotação já nasce vinculado (nada muda para eles).
--  · Pedido feito à mão: no pedido, "Vincular solicitação…" → escolhe a solicitação aprovada e marca os itens
--    que este pedido atende (esses itens saem da fila "sem pedido" da solicitação, evitando compra em dobro).
--    A mesma solicitação pode ser vinculada a mais de um pedido (ex.: peças num fornecedor e pintura em outro).
--  · Pedidos importados do Tiny e pedidos que já passaram da aprovação não são afetados.
--  · Nova tabela: pedidos_compra_solicitacoes (vínculo pedido × solicitação). Para desfazer a exigência:
--    tirar o bloco 'sem_solicitacao' de pc_pendencias.
-- =====================================================================

create table if not exists public.pedidos_compra_solicitacoes (
  id              bigint generated always as identity primary key,
  pedido_id       bigint not null references public.pedidos_compra(id) on delete cascade,
  solicitacao_id  bigint not null references public.solicitacoes_compra(id),
  criado_em       timestamptz not null default now(),
  criado_por      uuid default auth.uid(),
  unique (pedido_id, solicitacao_id)
);
create index if not exists pc_solicitacoes_sol_idx on public.pedidos_compra_solicitacoes (solicitacao_id);

alter table public.pedidos_compra_solicitacoes enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'pedidos_compra_solicitacoes' and policyname = 'ver vinculo pedido solicitacao') then
    create policy "ver vinculo pedido solicitacao" on public.pedidos_compra_solicitacoes for select to authenticated
      using ((select public.pode('compras')) or (select public.pode('solicitacoes_compra')));
  end if;
end $$;
-- gravação só pelas funções abaixo (sem política de insert/update/delete)

-- vínculo existe? (tabela de vínculo ou item da solicitação já apontando para o pedido)
create or replace function public.pc_tem_solicitacao(p_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pedidos_compra_solicitacoes where pedido_id = p_id)
      or exists (select 1 from public.solicitacoes_compra_itens where pedido_id = p_id)
$$;
revoke execute on function public.pc_tem_solicitacao(bigint) from public, anon;
grant execute on function public.pc_tem_solicitacao(bigint) to authenticated;

-- ---------- Solicitações do pedido: as vinculadas e as aprovadas que podem ser vinculadas ----------
create or replace function public.pc_solicitacoes(p_pedido bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_vinc bigint[];
begin
  if not (select public.pode('compras')) then return '{}'::jsonb; end if;
  select coalesce(array_agg(distinct x), '{}') into v_vinc from (
    select solicitacao_id x from public.pedidos_compra_solicitacoes where pedido_id = p_pedido
    union select solicitacao_id from public.solicitacoes_compra_itens where pedido_id = p_pedido) z;
  return jsonb_build_object(
    'vinculadas', v_vinc,
    'solicitacoes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'numero', s.numero, 'data', s.data_solicitacao, 'necessidade', s.data_necessidade, 'justificativa', s.justificativa,
        'solicitante', coalesce(u.nome, ''), 'situacao', s.situacao, 'vinculada', s.id = any(v_vinc),
        'itens', (select jsonb_agg(jsonb_build_object(
                    'id', i.id, 'descricao', i.descricao, 'quantidade', i.quantidade, 'unidade', i.unidade, 'urgencia', i.urgencia,
                    'deste', i.pedido_id = p_pedido,
                    'pedido', case when i.pedido_id is not null and i.pedido_id <> p_pedido and p.situacao <> 'cancelado' then p.numero end,
                    'em_cotacao', case when c.situacao = 'aberta' then c.numero end) order by i.id)
                    from public.solicitacoes_compra_itens i
                    left join public.pedidos_compra p on p.id = i.pedido_id
                    left join public.cotacoes_compra c on c.id = i.cotacao_id
                   where i.solicitacao_id = s.id)) order by s.id = any(v_vinc) desc, s.id desc)
      from public.solicitacoes_compra s left join public.usuarios u on u.id = s.solicitante_id
     where s.id = any(v_vinc) or (s.situacao = 'aprovado' and s.data_solicitacao >= current_date - 180)), '[]'::jsonb));
end $$;
revoke execute on function public.pc_solicitacoes(bigint) from public, anon;
grant execute on function public.pc_solicitacoes(bigint) to authenticated;

-- ---------- Vincular / desvincular ----------
create or replace function public.pedido_compra_vincular_solicitacao(p_pedido bigint, p_solicitacao bigint, p_itens bigint[] default '{}')
returns int language plpgsql security definer set search_path = public as $$
declare p public.pedidos_compra; s public.solicitacoes_compra; n int := 0; v_its text;
begin
  if not public.pode('compras', 'criar') then raise exception 'Sem permissão para alterar pedido de compra'; end if;
  select * into p from public.pedidos_compra where id = p_pedido for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if p.situacao not in ('rascunho', 'recusado') then raise exception 'Só dá para vincular solicitação com o pedido em rascunho ou recusado'; end if;
  select * into s from public.solicitacoes_compra where id = p_solicitacao for update;
  if s.id is null then raise exception 'Solicitação não encontrada'; end if;
  if s.situacao <> 'aprovado' then raise exception 'A solicitação % não está aprovada (%)', s.numero, s.situacao; end if;
  -- itens marcados: precisam ser desta solicitação, sem pedido ativo e fora de cotação aberta
  if exists (select 1 from unnest(coalesce(p_itens, '{}')) x
              left join public.solicitacoes_compra_itens i on i.id = x and i.solicitacao_id = s.id
              left join public.pedidos_compra pp on pp.id = i.pedido_id
              left join public.cotacoes_compra c on c.id = i.cotacao_id
             where i.id is null or (i.pedido_id is not null and i.pedido_id <> p_pedido and pp.situacao <> 'cancelado') or c.situacao = 'aberta') then
    raise exception 'Algum item marcado já está em outro pedido ou em cotação aberta. Atualize a tela.';
  end if;
  insert into public.pedidos_compra_solicitacoes (pedido_id, solicitacao_id) values (p_pedido, s.id) on conflict do nothing;
  update public.solicitacoes_compra_itens set pedido_id = p_pedido where id = any(coalesce(p_itens, '{}')) and pedido_id is distinct from p_pedido;
  get diagnostics n = row_count;
  select string_agg(descricao, ', ' order by id) into v_its from public.solicitacoes_compra_itens where id = any(coalesce(p_itens, '{}'));
  perform public.pc_evento(p_pedido, 'solicitacao_vinculada', 'Solicitação ' || s.numero || ' vinculada' || coalesce(' · atende: ' || v_its, ''),
    jsonb_build_object('solicitacao_id', s.id, 'itens', p_itens));
  return n;
end $$;
revoke execute on function public.pedido_compra_vincular_solicitacao(bigint, bigint, bigint[]) from public, anon;
grant execute on function public.pedido_compra_vincular_solicitacao(bigint, bigint, bigint[]) to authenticated;

create or replace function public.pedido_compra_desvincular_solicitacao(p_pedido bigint, p_solicitacao bigint)
returns int language plpgsql security definer set search_path = public as $$
declare p public.pedidos_compra; v_num text;
begin
  if not public.pode('compras', 'criar') then raise exception 'Sem permissão para alterar pedido de compra'; end if;
  select * into p from public.pedidos_compra where id = p_pedido for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if p.situacao not in ('rascunho', 'recusado') then raise exception 'Só dá para desvincular com o pedido em rascunho ou recusado'; end if;
  select numero into v_num from public.solicitacoes_compra where id = p_solicitacao;
  delete from public.pedidos_compra_solicitacoes where pedido_id = p_pedido and solicitacao_id = p_solicitacao;
  update public.solicitacoes_compra_itens set pedido_id = null where solicitacao_id = p_solicitacao and pedido_id = p_pedido;
  perform public.pc_evento(p_pedido, 'solicitacao_desvinculada', 'Solicitação ' || coalesce(v_num, '?') || ' desvinculada', jsonb_build_object('solicitacao_id', p_solicitacao));
  return 1;
end $$;
revoke execute on function public.pedido_compra_desvincular_solicitacao(bigint, bigint) from public, anon;
grant execute on function public.pedido_compra_desvincular_solicitacao(bigint, bigint) to authenticated;

-- ---------- Pendência que bloqueia o envio para aprovação ----------
do $$
declare d text; n text;
begin
  d := replace(pg_get_functiondef('public.pc_pendencias(bigint)'::regprocedure), E'\r\n', E'\n');
  if position('sem_solicitacao' in d) = 0 then
    n := replace(d, '    union all
    select jsonb_build_object(''id'', ''sem_forma''',
'    union all
    select jsonb_build_object(''id'', ''sem_solicitacao'', ''bloqueia'', true, ''texto'', ''Vincule a solicitação de compra aprovada (botão "Vincular solicitação…")'')
      from public.pedidos_compra p where p.id = p_id and p.origem <> ''tiny'' and not public.pc_tem_solicitacao(p_id)
    union all
    select jsonb_build_object(''id'', ''sem_forma''');
    if n = d then raise exception 'pc_pendencias: trecho não encontrado'; end if;
    execute n;
  end if;
end $$;

select public.ligar_auditoria('pedidos_compra_solicitacoes');
select public.ligar_tempo_real('pedidos_compra_solicitacoes');
