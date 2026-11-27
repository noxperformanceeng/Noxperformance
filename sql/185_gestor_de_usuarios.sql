-- =====================================================================
-- 185 · Usuários e acessos: cadastro de usuários fora do administrador + perfil Pós-venda
-- O que muda:
--  · Quem tiver a tela "Usuários e perfis" no nível "Ver, incluir e alterar" passa a ver a lista de usuários,
--    criar usuário novo, gerar o link de senha, trocar o perfil e liberar/bloquear telas de cada pessoa.
--  · INATIVAR usuário: só o administrador ou quem tiver a tela no nível "Tudo (inclusive inativar)".
--  · Travas: quem não é administrador NÃO mexe em administradores, NÃO dá perfil de administrador a ninguém
--    e NÃO altera o próprio acesso. Perfis, empresas e ações sensíveis continuam só com o administrador.
--  · Perfil novo "Pós-venda": mensagens pós-venda do Mercado Livre, reclamações (ML e Shopee) e devoluções
--    (ver, incluir e alterar) e clientes (só ver). As telas de mensagens, reclamações e devoluções entram no
--    menu como "em breve" até ficarem prontas.
-- Nada é apagado; dá para desfazer.
-- =====================================================================

-- Gestor de usuários: administrador ou "Usuários e perfis" no nível "Ver, incluir e alterar" (ou acima)
create or replace function public.gere_usuarios()
returns boolean language sql stable security definer set search_path = public as $$
  select public.eh_admin() or public.nivel_rank(public.meu_nivel('usuarios')) >= 3
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

-- Inativar usuário: só administrador ou nível "Tudo" na tela (rotinas internas, sem login, passam)
create or replace function public.trava_inativar_usuario()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.ativo and not new.ativo and auth.uid() is not null
     and not (public.eh_admin() or public.nivel_rank(public.meu_nivel('usuarios')) >= 4) then
    raise exception 'Inativar usuário: só o administrador (ou quem tem Usuários e perfis no nível Tudo)';
  end if;
  return new;
end $$;
revoke execute on function public.trava_inativar_usuario() from public, anon, authenticated;
create or replace trigger trava_inativar_usuario before update on public.usuarios
  for each row execute function public.trava_inativar_usuario();

-- Telas novas do pós-venda (no menu como "em breve" até ficarem prontas)
insert into public.modulos (id, grupo, nome, ordem) values
  ('mensagens_ml', 'comercial', 'Mensagens pós-venda do Mercado Livre', 23),
  ('reclamacoes',  'comercial', 'Reclamações (Mercado Livre e Shopee)', 23)
on conflict (id) do nothing;

-- Perfil Pós-venda
insert into public.perfis (id, nome, descricao) values
  ('pos_venda', 'Pós-venda', 'Mensagens e reclamações do Mercado Livre e da Shopee, devoluções e clientes')
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values
  ('pos_venda', 'mensagens_ml', 'alterar'),
  ('pos_venda', 'reclamacoes',  'alterar'),
  ('pos_venda', 'devolucoes',   'alterar'),
  ('pos_venda', 'clientes',     'ver')
on conflict do nothing;
