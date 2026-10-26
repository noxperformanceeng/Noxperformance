-- =====================================================================
-- 053 · Vale-transporte com dias quebrados
--   Dias de trabalho e faltas do VT aceitam fração (ex.: 16,5 dias). Antes eram número inteiro
--   e o 16,5 dava erro ao salvar. O cálculo do VT segue igual: (dias − faltas) × valor por dia.
-- =====================================================================
alter table public.rh_vale_transporte alter column dias type numeric(6,2), alter column faltas type numeric(6,2);
