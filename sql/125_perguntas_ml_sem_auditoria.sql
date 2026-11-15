-- =====================================================================
-- 125 · Perguntas do Mercado Livre sem histórico de alterações (auditoria)
--  · Em 15/11 a importação das perguntas regravou as mesmas perguntas centenas de vezes, cada vez com uma
--    anotação na auditoria (≈ 409 mil linhas, 668 MB), e o banco encheu e ficou só de leitura (ninguém entrava).
--  · As anotações repetidas foram apagadas e a importação foi corrigida (só grava pergunta nova ou alterada).
--  · A tabela de perguntas deixa de ir para a auditoria: quem respondeu e quando já fica na própria pergunta
--    (respondida_por, respondida_em), e as perguntas vêm do ML, não são digitadas no sistema.
--  · A busca automática (cron) foi pausada durante o problema e é religada aqui.
--  · Para voltar a auditar: alter table public.ml_perguntas enable trigger auditoria;
-- =====================================================================

alter table public.ml_perguntas disable trigger auditoria;

select cron.alter_job(jobid, active := true) from cron.job where jobname in ('nox-ml-perguntas', 'nox-ml-itens');
