-- =====================================================================
-- 166 · Compras em linha reta: solicitação → cotação → pedido (uma aprovação só)
--  · Pedido do Paulo (24/11/2026): menos burocracia em compras.
--  · Solicitação de QUALQUER pessoa vai direto para a fila do comprador (não passa mais por aprovação).
--    A aprovação única da diretoria acontece no pedido de compra.
--  · O comprador (ou a diretoria) pode RECUSAR, com motivo, uma solicitação que está na fila e ainda não
--    entrou em cotação/pedido; quem pediu pode alterar a solicitação enquanto ela está só na fila.
--  · Cotação obrigatória a partir de R$500,00 (parâmetro em compras_config): pedido acima disso sem cotação
--    não vai para aprovação. Dispensado em: recompra do mesmo fornecedor com preço até 5% acima da última
--    compra, pagamento antecipado/urgente, pedido vindo do Tiny ou liberação da diretoria com motivo
--    (pedido_compra_dispensar_cotacao). Pedido montado pela diretoria: o aviso aparece, mas não trava.
--  · Orçamentos dos fornecedores (PDF, planilha, print do WhatsApp) anexados na cotação, por fornecedor
--    (cotacoes_compra_anexos, arquivos no bucket "compras"). Fornecedor vencedor com compra a partir de
--    R$500,00 precisa ter o orçamento anexado para gerar o pedido.
--  · Pode rodar de novo sem estragar nada.
-- =====================================================================

-- ---------- Parâmetros de compras (linha única; só o administrador altera) ----------
create table if not exists public.compras_config (
  id int primary key default 1 check (id = 1),
  cotacao_valor_minimo numeric(14,2) not null default 500,
  recompra_tolerancia_pct numeric(6,2) not null default 5,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
comment on table public.compras_config is 'Regras de compras: valor a partir do qual a cotação é obrigatória e tolerância de preço para recompra sem cotação';
insert into public.compras_config (id) values (1) on conflict do nothing;
alter table public.compras_config enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'compras_config' and policyname = 'ver config compras') then
    create policy "ver config compras" on public.compras_config for select
      using ((select public.pode('compras')) or (select public.pode('cotacoes_compra')) or (select public.pode('solicitacoes_compra')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'compras_config' and policyname = 'admin altera config compras') then
    create policy "admin altera config compras" on public.compras_config for update using ((select public.eh_admin())) with check ((select public.eh_admin()));
  end if;
end $$;
revoke all on table public.compras_config from anon;

-- ---------- Dispensa de cotação dada pela diretoria ----------
alter table public.pedidos_compra add column if not exists cotacao_dispensa jsonb;

-- Por que o pedido pode seguir sem cotação (null = precisa de cotação)
create or replace function public.pc_dispensa_cotacao(p_id bigint)
returns text language sql stable security definer set search_path to 'public' as $$
  select case
    when p.id is null then null
    when p.origem = 'tiny' then 'tiny'
    when p.valor_total < cfg.minimo then 'abaixo_limite'
    when exists (select 1 from public.cotacoes_compra_fornecedores cf where cf.pedido_id = p.id) then 'cotacao'
    when p.cotacao_dispensa is not null then 'dispensa_diretoria'
    when coalesce(p.pagamento_antecipado, false) or coalesce(p.pagamento_urgente, false) then 'urgente'
    when exists (select 1 from public.pedidos_compra_itens i where i.pedido_id = p.id)
     and not exists (
       select 1 from public.pedidos_compra_itens i
        where i.pedido_id = p.id
          and not coalesce((
            select i.valor_unitario <= u.valor_unitario * (1 + cfg.tol / 100)
              from public.pedidos_compra_itens u join public.pedidos_compra q on q.id = u.pedido_id
             where q.id <> p.id and q.fornecedor_id = p.fornecedor_id
               and q.situacao in ('aprovado','enviado','recebido_parcial','recebido')
               and (i.produto_id is not null or i.servico_id is not null)
               and u.produto_id is not distinct from i.produto_id and u.servico_id is not distinct from i.servico_id
               and u.valor_unitario > 0
             order by q.data_pedido desc, u.id desc limit 1), false))
    then 'recompra'
  end
  from (select 1) d
  left join public.pedidos_compra p on p.id = p_id
  cross join lateral (select coalesce(max(cotacao_valor_minimo), 500) minimo, coalesce(max(recompra_tolerancia_pct), 5) tol from public.compras_config) cfg
  where (select public.pode('compras'))
$$;
revoke all on function public.pc_dispensa_cotacao(bigint) from public, anon;
grant execute on function public.pc_dispensa_cotacao(bigint) to authenticated;

-- Nova pendência no pedido: acima do limite sem cotação bloqueia o envio para aprovação (diretoria só vê o aviso)
do $do$
declare d text := pg_get_functiondef('public.pc_pendencias'::regproc); n text;
begin
  if position('cotacao_obrigatoria' in d) = 0 then
    n := replace(d, $x$  ) z where (select public.pode('compras'))$x$,
$x$    union all
    select jsonb_build_object('id', 'cotacao_obrigatoria', 'bloqueia', not public.eh_admin(), 'texto',
           'Compra de R$' || replace(replace(replace(to_char(p.valor_total, 'FM999,999,990.00'), ',', '#'), '.', ','), '#', '.')
           || ' (a partir de R$' || replace(replace(replace(to_char(cfg.minimo, 'FM999,999,990.00'), ',', '#'), '.', ','), '#', '.')
           || ') precisa passar pela COTAÇÃO, com os orçamentos dos fornecedores anexados. Dispensa só em recompra do mesmo fornecedor sem aumento de preço, pagamento antecipado/urgente ou liberação da diretoria')
      from public.pedidos_compra p
      cross join lateral (select coalesce(max(cotacao_valor_minimo), 500) minimo from public.compras_config) cfg
     where p.id = p_id and public.pc_dispensa_cotacao(p_id) is null
  ) z where (select public.pode('compras'))$x$);
    if n = d then raise exception 'pc_pendencias: ponto de inserção não encontrado'; end if;
    execute n;
  end if;
end $do$;

-- Diretoria libera pedido sem cotação (ex.: assinatura, fornecedor único)
create or replace function public.pedido_compra_dispensar_cotacao(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare p public.pedidos_compra; v_mot text := upper(nullif(trim(coalesce(p_motivo, '')), ''));
begin
  if not (public.eh_admin() or public.pode_acao('compras.aprovar')) then raise exception 'Só a diretoria dispensa a cotação'; end if;
  if v_mot is null then raise exception 'Informe o motivo da dispensa (ex.: fornecedor único, assinatura)'; end if;
  select * into p from public.pedidos_compra where id = p_id for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if p.situacao not in ('rascunho','recusado','em_aprovacao') then raise exception 'Pedido % já foi aprovado', p.numero; end if;
  update public.pedidos_compra set cotacao_dispensa = jsonb_build_object('por', auth.uid(), 'em', now(), 'motivo', v_mot) where id = p_id;
  perform public.pc_evento(p_id, 'cotacao_dispensada', 'Cotação dispensada pela diretoria: ' || v_mot);
end $$;
revoke all on function public.pedido_compra_dispensar_cotacao(bigint, text) from public, anon;
grant execute on function public.pedido_compra_dispensar_cotacao(bigint, text) to authenticated;

-- ---------- Solicitação vai direto para a fila do comprador ----------
do $do$
declare d text := pg_get_functiondef('public.solicitacao_compra_salvar(jsonb,jsonb)'::regprocedure); n text;
begin
  if position('aprovação única acontece no pedido' in d) = 0 then
    n := replace(d,
      $x$if s.situacao not in ('em_aprovacao', 'recusado') then raise exception 'Solicitação % já foi % e não pode mais ser alterada', s.numero, s.situacao; end if;$x$,
      $x$if s.situacao not in ('em_aprovacao', 'recusado', 'aprovado') then raise exception 'Solicitação % já foi % e não pode mais ser alterada', s.numero, s.situacao; end if;
    if exists (select 1 from public.solicitacoes_compra_itens i left join public.pedidos_compra p on p.id = i.pedido_id left join public.cotacoes_compra c on c.id = i.cotacao_id
                where i.solicitacao_id = v_id and ((i.pedido_id is not null and p.situacao <> 'cancelado') or (i.cotacao_id is not null and c.situacao <> 'cancelada'))) then
      raise exception 'Solicitação % já está com o comprador (em cotação ou pedido) e não pode mais ser alterada', s.numero;
    end if;$x$);
    if n = d then raise exception 'solicitacao_compra_salvar: trecho 1 não encontrado'; end if;
    d := n;
    n := replace(d,
      $x$  -- administrador: a solicitação dele JÁ NASCE APROVADA (vai direto para o comprador)
  if public.eh_admin() then
    update public.solicitacoes_compra set situacao = 'aprovado', motivo_recusa = null, decidido_por = auth.uid(), decidido_em = now()
     where id = v_id and solicitante_id = auth.uid() and situacao = 'em_aprovacao';
  end if;$x$,
      $x$  -- toda solicitação vai direto para a fila do comprador; a aprovação única acontece no pedido de compra
  update public.solicitacoes_compra set situacao = 'aprovado', motivo_recusa = null,
         decidido_por = case when public.eh_admin() then auth.uid() end, decidido_em = now()
   where id = v_id and situacao = 'em_aprovacao';$x$);
    if n = d then raise exception 'solicitacao_compra_salvar: trecho 2 não encontrado'; end if;
    execute n;
  end if;
end $do$;

-- Comprador (ou diretoria) recusa, com motivo, solicitação que está na fila e ainda não entrou em cotação/pedido
create or replace function public.solicitacao_compra_decidir(p_id bigint, p_aprovar boolean, p_motivo text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_sit text; v_sol uuid; v_num text; v_mot text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  select situacao, solicitante_id, numero into v_sit, v_sol, v_num from public.solicitacoes_compra where id = p_id for update;
  if v_sit is null then raise exception 'Solicitação não encontrada'; end if;
  if not p_aprovar and v_mot is null then raise exception 'Informe o motivo da recusa'; end if;
  if v_sit = 'aprovado' and not p_aprovar then
    if not (public.pode('cotacoes_compra', 'criar') or public.pode('compras', 'criar') or public.pode_acao('compras.aprovar_solicitacao')) then
      raise exception 'Só Compras ou a diretoria recusam solicitação de compra'; end if;
    if exists (select 1 from public.solicitacoes_compra_itens i left join public.pedidos_compra p on p.id = i.pedido_id left join public.cotacoes_compra c on c.id = i.cotacao_id
                where i.solicitacao_id = p_id and ((i.pedido_id is not null and p.situacao <> 'cancelado') or (i.cotacao_id is not null and c.situacao <> 'cancelada'))) then
      raise exception 'Solicitação % já está em cotação ou pedido: retire o item de lá antes de recusar', v_num; end if;
  else
    if not public.pode_acao('compras.aprovar_solicitacao') then raise exception 'Sem permissão para aprovar solicitações de compra'; end if;
    if p_aprovar and v_sol = auth.uid() and not public.eh_admin() then raise exception 'A própria solicitação precisa ser aprovada por outra pessoa da diretoria'; end if;
    if v_sit is distinct from 'em_aprovacao' then raise exception 'Solicitação % não está aguardando aprovação', v_num; end if;
  end if;
  update public.solicitacoes_compra set situacao = case when p_aprovar then 'aprovado' else 'recusado' end,
    motivo_recusa = case when p_aprovar then null else upper(v_mot) end, decidido_por = auth.uid(), decidido_em = now()
  where id = p_id;
end $$;
revoke all on function public.solicitacao_compra_decidir(bigint, boolean, text) from public, anon;
grant execute on function public.solicitacao_compra_decidir(bigint, boolean, text) to authenticated;

-- ---------- Orçamentos dos fornecedores anexados na cotação ----------
create table if not exists public.cotacoes_compra_anexos (
  id bigint generated by default as identity primary key,
  cotacao_id bigint not null references public.cotacoes_compra(id) on delete cascade,
  cotacao_forn_id bigint references public.cotacoes_compra_fornecedores(id) on delete set null,
  tipo text not null default 'outro' check (tipo in ('pdf','planilha','print','outro')),
  nome text not null,
  caminho text not null,          -- arquivo no bucket "compras" (cotacoes/<cotacao_id>/...)
  mime text,
  tamanho bigint,
  leitura jsonb,                  -- preços/prazos lidos automaticamente do orçamento (o comprador confere)
  lido_em timestamptz,
  criado_em timestamptz not null default now(),
  criado_por uuid default auth.uid()
);
create index if not exists cotacoes_compra_anexos_cotacao on public.cotacoes_compra_anexos (cotacao_id);
create index if not exists cotacoes_compra_anexos_forn on public.cotacoes_compra_anexos (cotacao_forn_id);
alter table public.cotacoes_compra_anexos enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'cotacoes_compra_anexos' and policyname = 'ver anexos cotacao') then
    create policy "ver anexos cotacao" on public.cotacoes_compra_anexos for select using ((select public.pode('cotacoes_compra')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'cotacoes_compra_anexos' and policyname = 'incluir anexos cotacao') then
    create policy "incluir anexos cotacao" on public.cotacoes_compra_anexos for insert
      with check ((select public.pode('cotacoes_compra', 'criar')) and criado_por = (select auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'cotacoes_compra_anexos' and policyname = 'excluir anexos cotacao') then
    create policy "excluir anexos cotacao" on public.cotacoes_compra_anexos for delete
      using ((select public.eh_admin()) or (criado_por = (select auth.uid()) and (select public.pode('cotacoes_compra', 'criar'))
             and exists (select 1 from public.cotacoes_compra c where c.id = cotacao_id and c.situacao = 'aberta')));
  end if;
end $$;
revoke all on table public.cotacoes_compra_anexos from anon;

-- Gerar pedidos: fornecedor vencedor com compra a partir do valor mínimo precisa do orçamento anexado
do $do$
declare d text := pg_get_functiondef('public.cotacao_gerar_pedidos(bigint)'::regprocedure); n text;
begin
  if position('orçamento anexado' in d) = 0 then
    n := replace(d, $x$  -- frete: cotado para todos os itens do fornecedor$x$,
$x$  -- orçamento anexado: vencedor com compra a partir do valor mínimo precisa do orçamento (PDF, planilha ou print)
  select string_agg(fo.nome_curto, ', ') into v_scs from (
    select coalesce(nullif(f2.nome_fantasia, ''), f2.nome) nome_curto
      from public.cotacoes_compra_fornecedores cf2 join public.fornecedores f2 on f2.id = cf2.fornecedor_id
     where cf2.cotacao_id = p_id
       and (select coalesce(sum(pr.valor_unitario * (1 + coalesce(pr.ipi_pct, 0) / 100) * ci.quantidade), 0)
              from public.cotacoes_compra_itens ci join public.cotacoes_compra_precos pr on pr.cotacao_item_id = ci.id and pr.cotacao_forn_id = cf2.id
             where ci.vencedor_id = cf2.id) >= (select coalesce(max(cotacao_valor_minimo), 500) from public.compras_config)
       and not exists (select 1 from public.cotacoes_compra_anexos an where an.cotacao_forn_id = cf2.id)) fo;
  if v_scs is not null then
    raise exception 'Anexe o orçamento recebido (PDF, planilha ou print do WhatsApp) de: %', v_scs;
  end if;
  v_scs := null;
  -- frete: cotado para todos os itens do fornecedor$x$);
    if n = d then raise exception 'cotacao_gerar_pedidos: ponto de inserção não encontrado'; end if;
    execute n;
  end if;
end $do$;

select public.ligar_auditoria('compras_config');
select public.ligar_auditoria('cotacoes_compra_anexos');
select public.ligar_tempo_real('compras_config');
select public.ligar_tempo_real('cotacoes_compra_anexos');
