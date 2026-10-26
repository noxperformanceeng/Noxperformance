-- 053 · Vale-transporte: dias de trabalho e faltas aceitam fração (ex.: 16,5 dias)
alter table public.rh_vale_transporte alter column dias type numeric(6,2), alter column faltas type numeric(6,2);
