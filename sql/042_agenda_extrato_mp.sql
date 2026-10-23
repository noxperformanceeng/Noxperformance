-- =====================================================================
-- 042 · Agenda do extrato Mercado Pago (pg_cron)
--  06:10 (Brasília) todo dia: pede o relatório de liberações dos últimos 3 dias das duas contas
--  de hora em hora (:35): importa os relatórios prontos e dá baixa nas vendas liberadas (cr_baixar_extrato_mp)
-- =====================================================================
create extension if not exists pg_cron;
select cron.schedule('nox-mp-gerar', '10 9 * * *', $$select public.integracao_disparar('mp-extrato', jsonb_build_object('acao', 'gerar', 'de', to_char(current_date - 3, 'YYYY-MM-DD'), 'ate', to_char(current_date - 1, 'YYYY-MM-DD')))$$);
select cron.schedule('nox-mp-importar', '35 * * * *', $$select public.integracao_disparar('mp-extrato', '{"acao":"importar_prontos"}'::jsonb)$$);
