-- =====================================================================
-- 067 · Histórico de pedidos de venda do Tiny (distribuidores e venda direta)
--  · A leitura do Tiny marca e pula os pedidos de e-commerce (Mercado Livre, Shopee…), que já vêm
--    pela integração direta. Só os pedidos sem origem de e-commerce são detalhados e carregados.
--  · Limite do plano do Tiny: a API só devolve os últimos 2 anos.
-- =====================================================================
create or replace function public.tiny_pedidos_pular_ecommerce(p_empresa int)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.tiny_brutos set detalhe = jsonb_build_object('pulado', 'ecommerce'), detalhado_em = now()
   where empresa_id = p_empresa and recurso = 'pedidos' and detalhe is null
     and coalesce(nullif(trim(resumo->>'numero_ecommerce'), ''), nullif(trim(resumo->>'numeroPedidoEcommerce'), '')) is not null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.tiny_pedidos_pular_ecommerce(int) from public, anon, authenticated;
