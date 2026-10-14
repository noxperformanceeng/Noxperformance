-- =====================================================================
-- ERP NOX · 015_seguranca.sql
-- Ajustes apontados pelo verificador de segurança do Supabase (14/10/2026):
--  1) search_path fixo nas funções (evita sequestro de nomes por outro schema)
--  2) Ninguém sem login executa funções do sistema (anon/public)
--  3) Funções internas (gatilhos) não podem ser chamadas pela API
-- Pode rodar mais de uma vez.
-- =====================================================================

-- 1) search_path fixo
alter function public.texto_norm(text)                          set search_path = public, extensions;
alter function public.produto_tokens(text)                      set search_path = public, extensions;
alter function public.produto_numeros(text)                     set search_path = public, extensions;
alter function public.produto_nivel_duplicado(text, text)       set search_path = public, extensions;
alter function public.produtos_duplicados()                     set search_path = public, extensions;
alter function public.produtos_parecidos(text, text, bigint)    set search_path = public, extensions;
alter function public.produtos_proximo_codigo(text)             set search_path = public, extensions;
alter function public.produtos_marcar_revisado(bigint[])        set search_path = public, extensions;
alter function public.produtos_carimbo()                        set search_path = public, extensions;
alter function public.ligar_auditoria(text)                     set search_path = public, extensions;

-- 2) Sem login, nenhuma função do sistema
revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public, anon;

-- Usuário logado: só o que as telas e as regras de acesso usam
grant execute on function
  public.meu_perfil(), public.eh_admin(), public.meu_nivel(text), public.pode(text, text), public.minhas_permissoes(),
  public.usuarios_nomes(), public.texto_norm(text), public.produto_tokens(text), public.produto_numeros(text),
  public.produto_nivel_duplicado(text, text), public.produtos_duplicados(), public.produtos_parecidos(text, text, bigint),
  public.produtos_proximo_codigo(text), public.produtos_marcar_revisado(bigint[])
to authenticated;

-- 3) Gatilhos e funções administrativas: fora da API
revoke execute on function public.auditar(), public.novo_usuario(), public.produtos_carimbo(), public.ligar_auditoria(text)
  from authenticated;
