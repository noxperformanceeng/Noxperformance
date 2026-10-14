-- =====================================================================
-- ERP NOX · 029_service_role_integracao.sql
-- Funções do servidor (Edge Functions) usam a service_role: precisa ler e gravar nas tabelas da integração.
-- Usuários (anon/authenticated) continuam sem acesso às tabelas ml_*.
-- =====================================================================
grant select, insert, update on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
alter default privileges in schema public grant select, insert, update on tables to service_role;
alter default privileges in schema public grant usage, select on sequences to service_role;
