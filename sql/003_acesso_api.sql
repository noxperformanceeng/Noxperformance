-- =====================================================================
-- ERP NOX · 003_acesso_api.sql
-- Libera as tabelas para USUÁRIOS LOGADOS acessarem pelo sistema.
-- (Este projeto Supabase não libera tabelas novas automaticamente.)
-- Quem não está logado continua sem acesso a nada.
-- O que cada usuário vê/edita continua controlado pelas regras (RLS).
-- Como usar: Supabase → SQL Editor → New → colar tudo → Run
-- =====================================================================

grant usage on schema public to authenticated;

grant select, insert, update, delete on
  public.empresas, public.perfis, public.modulos,
  public.permissoes, public.permissoes_usuario, public.usuarios
to authenticated;

-- Histórico de auditoria: só leitura (quem grava é o próprio banco)
grant select on public.auditoria to authenticated;

grant usage, select on all sequences in schema public to authenticated;

grant execute on function
  public.meu_perfil(), public.eh_admin(), public.meu_nivel(text),
  public.pode(text, text), public.minhas_permissoes()
to authenticated;

-- Tabelas que forem criadas daqui pra frente já nascem liberadas
-- para usuários logados (sempre protegidas pelas regras RLS de cada uma).
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant usage, select on sequences to authenticated;
