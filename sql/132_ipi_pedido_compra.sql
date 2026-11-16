-- =====================================================================
-- 132 · Pedido de compra: IPI por item
--  · Cada item do pedido ganha o campo "IPI %". O valor do IPI é calculado sozinho
--    (total do item × IPI %) e entra no total do pedido: Itens + IPI + frete + outras − desconto.
--  · Com o total já com IPI, a aprovação (escala por valor), as parcelas previstas no contas a
--    pagar e o PDF que vai ao fornecedor passam a considerar o IPI.
--  · No recebimento da NF, o rateio por categoria financeira usa o valor do item com IPI.
--  · Pedido gerado pela cotação já vem com o IPI cotado; pedido gerado pela solicitação vem com o
--    IPI do cadastro produto × fornecedor (quando houver).
--  · Pedidos que já existem ficam com IPI 0 % (nada muda neles). Não apaga nada.
-- =====================================================================

alter table public.pedidos_compra_itens add column if not exists ipi_pct numeric(6,2) not null default 0;
alter table public.pedidos_compra_itens add column if not exists valor_ipi numeric
  generated always as (round(((quantidade * valor_unitario) - desconto) * ipi_pct / 100, 2)) stored;
alter table public.pedidos_compra add column if not exists valor_ipi numeric not null default 0;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pedidos_compra_itens_ipi_pct_faixa') then
    alter table public.pedidos_compra_itens add constraint pedidos_compra_itens_ipi_pct_faixa check (ipi_pct between 0 and 100);
  end if;
end $$;
comment on column public.pedidos_compra_itens.ipi_pct is 'IPI % do item (sobre quantidade × unitário − desconto)';
comment on column public.pedidos_compra_itens.valor_ipi is 'Valor do IPI do item (calculado)';
comment on column public.pedidos_compra.valor_ipi is 'Soma do IPI dos itens (já incluída em valor_total)';

-- 1. Total do pedido: itens + IPI + frete + outras despesas − desconto
create or replace function public.pc_recalcular(p_id bigint)
returns void language sql security definer set search_path = public as $$
  update public.pedidos_compra p set
    valor_produtos = s.prod, valor_ipi = s.ipi,
    valor_total = s.prod + s.ipi + p.frete + p.outras_despesas - p.desconto
  from (select coalesce(sum(valor_total), 0) prod, coalesce(sum(valor_ipi), 0) ipi
          from public.pedidos_compra_itens where pedido_id = p_id) s
  where p.id = p_id;
$$;
revoke execute on function public.pc_recalcular(bigint) from public, anon, authenticated;

-- 2. Ajustes pontuais nas funções que já existem (mesmo padrão do 050: troca só o trecho)
do $$
declare d text; n text;
begin
  -- 2a. Salvar o pedido grava o IPI % de cada item (limitado a 0–100)
  d := pg_get_functiondef('public.pedido_compra_salvar(jsonb,jsonb)'::regprocedure);
  if position('ipi_pct' in d) = 0 then
    n := replace(d, 'valor_unitario, desconto, categoria_financeira_id, observacao,', 'valor_unitario, desconto, ipi_pct, categoria_financeira_id, observacao,');
    n := replace(n, 'coalesce((s.x->>''desconto'')::numeric, 0),', 'coalesce((s.x->>''desconto'')::numeric, 0), least(greatest(coalesce(nullif(s.x->>''ipi_pct'', '''')::numeric, 0), 0), 100),');
    if n = d or (length(n) - length(d)) < 80 then raise exception '132: trecho de pedido_compra_salvar não encontrado'; end if;
    execute n;
  end if;

  -- 2b. Recebimento da NF: rateio por categoria com o IPI do item
  d := pg_get_functiondef('public.pedido_compra_receber(bigint,jsonb,jsonb,jsonb)'::regprocedure);
  if position('valor_ipi' in d) = 0 then
    n := replace(d, 'sum(round(i.valor_total * (r.quantidade / i.quantidade), 2))', 'sum(round((i.valor_total + i.valor_ipi) * (r.quantidade / i.quantidade), 2))');
    if n = d then raise exception '132: trecho de pedido_compra_receber não encontrado'; end if;
    execute n;
  end if;

  -- 2c. Cotação → pedido leva o IPI cotado do vencedor
  d := pg_get_functiondef('public.cotacao_gerar_pedidos(bigint)'::regprocedure);
  if position('''ipi_pct'', pr.ipi_pct' in d) = 0 then
    n := replace(d, '''valor_unitario'', pr.valor_unitario, ''codigo_fornecedor''', '''valor_unitario'', pr.valor_unitario, ''ipi_pct'', pr.ipi_pct, ''codigo_fornecedor''');
    if n = d then raise exception '132: trecho de cotacao_gerar_pedidos não encontrado'; end if;
    execute n;
  end if;

  -- 2d. Solicitação → pedido leva o IPI do cadastro produto × fornecedor
  d := pg_get_functiondef('public.solicitacao_compra_gerar_pedido'::regproc);
  if position('pf.ipi_pct' in d) = 0 then
    n := replace(d, 'select x.preco, x.codigo_fornecedor from public.produto_fornecedores x', 'select x.preco, x.ipi_pct, x.codigo_fornecedor from public.produto_fornecedores x');
    n := replace(n, '''valor_unitario'', coalesce(case when i.produto_id is not null then pf.preco end, 0),',
                    '''valor_unitario'', coalesce(case when i.produto_id is not null then pf.preco end, 0), ''ipi_pct'', case when i.produto_id is not null then pf.ipi_pct end,');
    if (length(n) - length(d)) < 60 then raise exception '132: trecho de solicitacao_compra_gerar_pedido não encontrado'; end if;
    execute n;
  end if;
end $$;
