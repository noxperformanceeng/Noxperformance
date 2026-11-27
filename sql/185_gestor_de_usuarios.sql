-- =====================================================================
-- 185 · Usuários e acessos: cadastro de usuários fora do administrador + perfil Pós-venda
-- O que muda:
--  · Quem tiver a tela "Usuários e perfis" no nível "Ver, incluir e alterar" passa a ver a lista de usuários,
--    criar usuário novo, gerar o link de senha, trocar o perfil e liberar/bloquear telas de cada pessoa.
--  · INATIVAR usuário: só o administrador ou quem tiver a tela no nível "Tudo (inclusive inativar)".
--  · Travas: quem não é administrador NÃO mexe em administradores, NÃO dá perfil de administrador a ninguém
--    e NÃO altera o próprio acesso. Perfis, empresas e ações sensíveis continuam só com o administrador.
--  · Perfil novo "Pós-venda": mensagens pós-venda do Mercado Livre, reclamações (ML e Shopee) e devoluções
--    (ver, incluir e alterar), Chat da Shopee só das conversas de quem já comprou (ver e responder),
--    clientes e pedidos de venda (só ver). As telas de mensagens, reclamações e devoluções entram no menu
--    como "em breve" até ficarem prontas.
--  · "Já comprou" na Shopee = a conversa cita um pedido ou o comprador tem pedido na loja (pedidos lidos da API).
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
  ('pos_venda', 'clientes',     'ver'),
  ('pos_venda', 'pedidos',      'ver')
on conflict do nothing;

-- ---------- Chat da Shopee só de quem já comprou (pós-venda) ----------
insert into public.modulos (id, grupo, nome, ordem) values
  ('chat_shopee_pos', 'comercial', 'Chat da Shopee (só quem já comprou)', 16)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('pos_venda', 'chat_shopee_pos', 'alterar')
on conflict do nothing;

-- O comprador da Shopee já fez pedido na loja? (lê os pedidos sem abrir a tabela de pedidos ao pós-venda)
create or replace function public.shopee_comprador_comprou(p_comprador bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select p_comprador is not null
     and exists (select 1 from shopee_pedidos_brutos where detalhe->>'buyer_user_id' = p_comprador::text)
$$;
revoke execute on function public.shopee_comprador_comprou(bigint) from public, anon;
grant execute on function public.shopee_comprador_comprou(bigint) to authenticated;

-- Pode responder ESTA conversa? Chat completo, ou pós-venda se a conversa é de quem já comprou
create or replace function public.shopee_pode_conversa(p_id text, p_nivel text default 'ver')
returns boolean language sql stable security definer set search_path = public as $$
  select public.pode('chat_shopee', p_nivel)
      or (public.pode('chat_shopee_pos', p_nivel)
          and exists (select 1 from shopee_conversas c where c.id = p_id
                       and (c.order_sn is not null or public.shopee_comprador_comprou(c.comprador_id))))
$$;
revoke execute on function public.shopee_pode_conversa(text, text) from public, anon;
grant execute on function public.shopee_pode_conversa(text, text) to authenticated;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'shopee_conversas' and policyname = 'pos venda ve conversas de compradores') then
    create policy "pos venda ve conversas de compradores" on public.shopee_conversas for select to authenticated
      using ((select public.pode('chat_shopee_pos')) and (order_sn is not null or public.shopee_comprador_comprou(comprador_id)));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'shopee_mensagens' and policyname = 'pos venda ve mensagens de compradores') then
    create policy "pos venda ve mensagens de compradores" on public.shopee_mensagens for select to authenticated
      using ((select public.pode('chat_shopee_pos')) and public.shopee_pode_conversa(conversa_id));
  end if;
end $$;

-- Responder e pedir sugestão da IA: mesma regra de antes + pós-venda nas conversas de quem já comprou
create or replace function public.shopee_chat_responder(p_id text, p_texto text)
returns void language plpgsql security definer set search_path = public as $function$
declare v public.shopee_conversas;
begin
  if not public.shopee_pode_conversa(p_id, 'alterar') then raise exception 'Sem permissão para responder o chat da Shopee'; end if;
  p_texto := btrim(coalesce(p_texto, ''));
  if p_texto = '' then raise exception 'Escreva a resposta'; end if;
  if length(p_texto) > 2000 then raise exception 'Resposta muito longa (máximo 2.000 caracteres)'; end if;
  select * into v from public.shopee_conversas where id = p_id for update;
  if not found then raise exception 'Conversa não encontrada'; end if;
  if v.enviando_em is not null and v.enviando_em > now() - interval '1 minute' and v.resposta_erro is null and v.resposta_pendente is not null then
    raise exception 'A resposta desta conversa já está sendo enviada'; end if;
  update public.shopee_conversas set resposta_pendente = p_texto,
    usou_sugestao = case when v.sugestao is null then null else regexp_replace(btrim(v.sugestao), '\s+', ' ', 'g') = regexp_replace(p_texto, '\s+', ' ', 'g') end,
    respondida_por = auth.uid(), enviando_em = now(), resposta_erro = null, atualizado_em = now()
   where id = p_id;
  perform public.integracao_disparar('shopee-chat', jsonb_build_object('acao', 'enviar', 'id', p_id));
end $function$;

create or replace function public.shopee_chat_sugerir(p_id text)
returns void language plpgsql security definer set search_path = public as $function$
begin
  if not public.shopee_pode_conversa(p_id, 'alterar') then raise exception 'Sem permissão'; end if;
  update public.shopee_conversas set sugestao_erro = null where id = p_id;
  perform public.integracao_disparar('shopee-chat', jsonb_build_object('acao', 'sugerir', 'id', p_id));
end $function$;
