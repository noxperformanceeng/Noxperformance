-- =====================================================================
-- 089 · Preço e impostos do fornecedor no cadastro do produto
--  · No vínculo produto × fornecedor passam a ficar: preço cotado (por unidade de compra), IPI %, ICMS %,
--    data e número do orçamento. Aparecem no cadastro do produto (seção Fornecedores).
--  · No pedido de compra, quando o item nunca foi comprado, o preço sugerido vem dessa cotação.
-- =====================================================================
alter table public.produto_fornecedores add column if not exists preco        numeric(14,4);
alter table public.produto_fornecedores add column if not exists ipi_pct      numeric(6,2);
alter table public.produto_fornecedores add column if not exists icms_pct     numeric(6,2);
alter table public.produto_fornecedores add column if not exists cotacao_data date;
alter table public.produto_fornecedores add column if not exists cotacao_ref  text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'prodforn_preco_chk') then
    alter table public.produto_fornecedores add constraint prodforn_preco_chk check (
      (preco is null or preco >= 0) and (ipi_pct is null or ipi_pct between 0 and 100) and (icms_pct is null or icms_pct between 0 and 100));
  end if;
end $$;
