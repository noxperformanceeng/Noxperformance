-- =====================================================================
-- ERP NOX · 012_unidades_compra.sql
-- Unidade de compra × unidade de estoque/uso, com fator de conversão.
-- Ex.: tubo comprado em M e consumido em MM → unidade_compra = 'M', fator_compra = 1000
--      (1 M = 1000 MM). Na entrada da NF a quantidade é multiplicada pelo fator
--      e o custo unitário dividido por ele.
-- O fator pode ser diferente por fornecedor (um vende por metro, outro por barra de 6 m).
-- Como usar: Supabase → SQL Editor → New → colar tudo → Run (depois do 010).
-- =====================================================================

alter table public.produtos
  add column if not exists unidade_compra text,
  add column if not exists fator_compra   numeric(14,6);

alter table public.produto_fornecedores
  add column if not exists unidade_compra text,
  add column if not exists fator_compra   numeric(14,6);

do $$ begin
  alter table public.produtos add constraint produtos_fator_pos check (fator_compra is null or fator_compra > 0);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.produto_fornecedores add constraint prodforn_fator_pos check (fator_compra is null or fator_compra > 0);
exception when duplicate_object then null; end $$;

comment on column public.produtos.unidade        is 'Unidade de estoque e de uso na produção (ex.: MM)';
comment on column public.produtos.unidade_compra is 'Unidade em que normalmente se compra (ex.: M). Vazio = igual à de estoque';
comment on column public.produtos.fator_compra   is 'Quantas unidades de estoque há em 1 unidade de compra (ex.: 1000)';
comment on column public.produto_fornecedores.unidade_compra is 'Unidade deste fornecedor na NF, se diferente da padrão do produto';
comment on column public.produto_fornecedores.fator_compra   is 'Fator deste fornecedor, se diferente do padrão do produto';
