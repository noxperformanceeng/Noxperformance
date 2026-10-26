-- =====================================================================
-- 082 · Produto: lead time e estoque máximo
--  · Lead time (dias): prazo entre pedir a compra e a peça chegar. Base para a sugestão de compra.
--  · Estoque máximo, ao lado do mínimo: a compra sugerida repõe até o máximo.
--  · O máximo não pode ser menor que o mínimo.
-- =====================================================================
alter table public.produtos add column if not exists lead_time_dias int;
alter table public.produtos add column if not exists estoque_maximo numeric;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'produtos_lead_time_pos') then
    alter table public.produtos add constraint produtos_lead_time_pos check (lead_time_dias is null or lead_time_dias >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'produtos_estoque_max_min') then
    alter table public.produtos add constraint produtos_estoque_max_min
      check (estoque_maximo is null or estoque_maximo >= 0 and (estoque_minimo is null or estoque_maximo >= estoque_minimo));
  end if;
end $$;
comment on column public.produtos.lead_time_dias is 'Prazo de reposição em dias corridos (pedido de compra até a chegada)';
comment on column public.produtos.estoque_maximo is 'Estoque máximo: a sugestão de compra repõe até este valor';
