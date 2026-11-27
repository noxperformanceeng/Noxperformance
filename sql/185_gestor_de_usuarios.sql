-- =====================================================================
-- 185 · Usuários e acessos: quem tem a tela no nível "Tudo" também cuida dos usuários
-- O que muda:
--  · Quem tiver a tela "Usuários e acessos" liberada no nível "Tudo (inclusive inativar)" passa a ver a
--    lista de usuários, criar usuário novo, gerar o link de senha, trocar o perfil, ativar/inativar e
--    liberar/bloquear telas de cada pessoa (antes era só o administrador).
--  · Travas: essa pessoa NÃO mexe em administradores, NÃO dá perfil de administrador a ninguém e NÃO
--    altera o próprio acesso. Perfis (aba Perfis), empresas e ações sensíveis continuam só com o administrador.
-- =====================================================================

-- Gestor de usuários: administrador ou nível "Tudo" na tela Usuários e acessos
create or replace function public.gere_usuarios()
returns boolean language sql stable security definer set search_path = public as $$
  select public.eh_admin() or public.nivel_rank(public.meu_nivel('usuarios')) >= 4
$$;
revoke execute on function public.gere_usuarios() from public, anon;
grant execute on function public.gere_usuarios() to authenticated;

-- Pode mexer NESTE usuário? Administrador: qualquer um. Gestor: só quem não é administrador e não é ele mesmo.
create or replace function public.pode_gerir_usuario(p_usuario uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.eh_admin()
      or (public.gere_usuarios()
          and p_usuario is distinct from auth.uid()
          and coalesce((select perfil_id from usuarios where id = p_usuario), '') <> 'admin')
$$;
revoke execute on function public.pode_gerir_usuario(uuid) from public, anon;
grant execute on function public.pode_gerir_usuario(uuid) to authenticated;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'usuarios' and policyname = 'gestor ve usuarios') then
    create policy "gestor ve usuarios" on public.usuarios for select to authenticated
      using ((select public.gere_usuarios()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'usuarios' and policyname = 'gestor altera usuarios') then
    create policy "gestor altera usuarios" on public.usuarios for update to authenticated
      using (public.pode_gerir_usuario(id))
      with check (public.pode_gerir_usuario(id) and ((select public.eh_admin()) or perfil_id is distinct from 'admin'));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'permissoes_usuario' and policyname = 'gestor ajustes') then
    create policy "gestor ajustes" on public.permissoes_usuario for all to authenticated
      using (public.pode_gerir_usuario(usuario_id))
      with check (public.pode_gerir_usuario(usuario_id));
  end if;
end $$;
