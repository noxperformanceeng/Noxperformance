-- =====================================================================
-- 127 · Varredura diária das vendas do Mercado Livre
-- Regra: toda venda do e-commerce precisa ter título no contas a receber, e o título precisa ter a entrada
-- no extrato. Até aqui as vendas do ML só entravam pelo aviso (notificação) do ML. Quando um aviso se perde,
-- a venda some do sistema: sem venda, sem título, e o dinheiro aparece no extrato do Mercado Pago como
-- "recebimento sem venda". Foi o que aconteceu no ML 37 entre 27 e 30/09 (21 vendas, cerca de R$ 18 mil).
-- O que muda:
--   1. Todo dia às 08:20, cada conta do ML busca as vendas dos últimos 10 dias e grava as que faltarem
--      (as que já estão no sistema e não mudaram são puladas). A venda nova gera o título como hoje.
--   2. Uma vez, agora: busca de 01/06/2026 até hoje nas duas contas, para recuperar as que se perderam.
--      Na próxima importação do extrato, os recebimentos dessas vendas dão baixa no título sozinhos.
-- Não apaga nada. Para desfazer a rotina: select cron.unschedule('nox-ml-varrer-30'), cron.unschedule('nox-ml-varrer-37').
-- =====================================================================

do $$ declare c record; begin
  for c in select canal_id, case when canal_id = 1 then '30' else '37' end as nome
           from public.ml_contas where situacao = 'ativo' loop
    if not exists (select 1 from cron.job where jobname = 'nox-ml-varrer-' || c.nome) then
      perform cron.schedule('nox-ml-varrer-' || c.nome, '20 8 * * *', format(
        $c$select public.integracao_disparar('ml-sync', jsonb_build_object('acao', 'buscar_periodo', 'canal_id', %s,
           'de', to_char(current_date - 10, 'YYYY-MM-DD'), 'ate', to_char(current_date, 'YYYY-MM-DD')))$c$, c.canal_id));
    end if;
    -- recuperação única: desde o início das vendas do ML no sistema
    perform public.integracao_disparar('ml-sync', jsonb_build_object('acao', 'buscar_periodo', 'canal_id', c.canal_id,
      'de', '2026-06-01', 'ate', to_char(current_date, 'YYYY-MM-DD')));
  end loop;
end $$;
