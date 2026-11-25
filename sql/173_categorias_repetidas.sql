-- =====================================================================
-- 173 · Categorias repetidas: junta os lançamentos e inativa as sobras
--  · Pedido do Paulo (25/11/2026).
--  · "Flauta de bico injetor" existia 3 vezes. Fica a de Componentes e itens de revenda (3.02.021).
--    Os 5 títulos a pagar das outras duas (3.08 e a que estava em Receitas, 1.01.004) passam para ela.
--  · "Freelancer de almoxarifado" existia 2 vezes. Fica a 5.05.002; a 5.05.003 não tinha lançamento.
--  · As repetidas ficam inativas (não somem: o histórico continua na auditoria).
-- =====================================================================
update public.titulos_pagar set categoria_financeira_id = 346 where categoria_financeira_id in (341, 342);
update public.titulos_pagar set categoria_financeira_id = 340 where categoria_financeira_id = 344;
update public.categorias_financeiras set situacao = 'inativo' where id in (341, 342, 344) and situacao <> 'inativo';
