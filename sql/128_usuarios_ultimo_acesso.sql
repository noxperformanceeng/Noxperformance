-- =====================================================================
-- 128 · Usuários: mostrar quem ainda não entrou no sistema
--  · Na tela Configurações › Usuários e acessos, quem foi cadastrado mas ainda não criou a senha nem entrou
--    aparece como "Aguardando 1º acesso" (amarelo). "Ativo" só depois do primeiro login.
--  · Função só de leitura: devolve, para cada usuário, a data do último acesso. Só quem pode ver a tela de
--    usuários consegue usar.
-- =====================================================================

create or replace function public.usuarios_ultimo_acesso()
returns table (id uuid, ultimo_acesso timestamptz)
language sql stable security definer set search_path = public as $$
  select u.id, au.last_sign_in_at
    from public.usuarios u join auth.users au on au.id = u.id
   where (select public.pode('usuarios'))
$$;
revoke execute on function public.usuarios_ultimo_acesso() from public, anon;
grant execute on function public.usuarios_ultimo_acesso() to authenticated;
