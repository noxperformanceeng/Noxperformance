-- =====================================================================
-- ERP NOX · 031_funcionarios_custos.sql
-- Custos mensais por funcionário, além do salário base, para a precificação (mão de obra):
--  - Adicionais e benefícios: insalubridade, gratificação de cargo de confiança, vale-transporte,
--    prêmio assiduidade, cesta básica
--  - Rateios mensais: EPI, uniforme, exames, contabilidade, outros custos
--  - Base do custo por hora: horas mensais e eficiência (% das horas que são produtivas)
-- Encargos (FGTS, INSS, RAT, 13º e férias) não são guardados: serão calculados sobre esses valores.
-- Pode rodar mais de uma vez.
-- =====================================================================
alter table public.funcionarios
  add column if not exists insalubridade          numeric(12,2),
  add column if not exists gratificacao_confianca numeric(12,2),
  add column if not exists vale_transporte        numeric(12,2),
  add column if not exists premio_assiduidade     numeric(12,2),
  add column if not exists cesta_basica           numeric(12,2),
  add column if not exists epi_mensal             numeric(12,2),
  add column if not exists uniforme_mensal        numeric(12,2),
  add column if not exists exames_mensal          numeric(12,2),
  add column if not exists contabilidade_mensal   numeric(12,2),
  add column if not exists outros_custos          numeric(12,2),
  add column if not exists horas_mensais          numeric(6,2) default 220,
  add column if not exists eficiencia_pct         numeric(5,2) default 85;

do $$ begin
  alter table public.funcionarios add constraint funcionarios_eficiencia_pct check (eficiencia_pct is null or eficiencia_pct between 0 and 100);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.funcionarios add constraint funcionarios_horas_mensais check (horas_mensais is null or horas_mensais > 0);
exception when duplicate_object then null; end $$;
