-- =====================================================================
-- 083 · Pintura não é produto: os SKUs "...P" (PINTURA - ...) ficam inativos
--  · Serviço não tem SKU próprio (mesma regra da usinagem): a pintura será lançada como serviço
--    sobre a peça/defletor no pedido de compra.
--  · Os 78 cadastros "PINTURA - ..." (vindos do Tiny) são inativados — nada é apagado; nenhum
--    está em pedido de compra ou de venda.
--  · A leitura diária do Tiny deixa de trazer cadastros de pintura.
-- =====================================================================
update public.produtos
   set situacao = 'inativo',
       observacoes = 'Inativado em 26/10/2026: pintura é serviço (sem SKU), lançada sobre a peça no pedido de compra.'
 where codigo ~ 'P$' and descricao ilike 'PINTURA%' and situacao = 'ativo';

do $$ declare d text;
begin
  d := pg_get_functiondef('public.tiny_carregar_produtos_novos()'::regprocedure);
  if position('PINTURA%' in d) = 0 then
    d := replace(d, $q$where b.recurso = 'produtos' and coalesce(trim(b.resumo->>'codigo'), '') <> ''$q$,
                    $q$where b.recurso = 'produtos' and coalesce(trim(b.resumo->>'codigo'), '') <> ''
       and not (upper(trim(b.resumo->>'nome')) like 'PINTURA%')$q$);
    execute d;
  end if;
end $$;
