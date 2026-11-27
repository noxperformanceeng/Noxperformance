-- =====================================================================
-- 190 · Anúncios do Mercado Livre: ligar ao produto pelo SKU
-- O que muda:
--   - Função interna usada pela leitura completa dos anúncios (função ml-anuncios): todo anúncio (ou variação)
--     ainda sem produto cujo SKU é exatamente o código de UM produto do cadastro passa a apontar para ele.
--     As vendas antigas desse anúncio são religadas sozinhas (gatilho anuncios_religar, já existente).
--   - Não muda anúncio que já tem produto. Só o servidor chama (não aparece para os usuários).
-- Dá para desfazer: os vínculos ficam no histórico de auditoria de anuncios.
-- =====================================================================
create or replace function public.anuncios_ligar_por_sku()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  with unicos as (
    select upper(trim(codigo)) cod, min(id) id from public.produtos group by 1 having count(*) = 1)
  update public.anuncios a set produto_id = u.id
  from unicos u
  where a.produto_id is null and a.sku is not null and upper(trim(a.sku)) = u.cod;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.anuncios_ligar_por_sku() from public, anon, authenticated;
grant execute on function public.anuncios_ligar_por_sku() to service_role;
