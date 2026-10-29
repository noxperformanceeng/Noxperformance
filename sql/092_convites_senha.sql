-- =====================================================================
-- 092 · Convite para criar senha (vale 48 horas)
--  · O link que o administrador manda por WhatsApp/e-mail abre uma página com o botão "Criar minha senha".
--    Abrir o link (ou a prévia do WhatsApp) não gasta o convite: ele só é usado quando a pessoa grava a senha.
--  · Vale por 48 horas e uma vez só; gerar um convite novo cancela os anteriores daquela pessoa.
--  · Só a função do sistema (usuarios-admin) lê e grava esta tabela; o código do convite fica guardado
--    apenas como "impressão digital" (hash), nunca o código em si.
-- =====================================================================
create table if not exists public.usuarios_convites (
  id          bigserial primary key,
  usuario_id  uuid not null references public.usuarios(id) on delete cascade,
  token_hash  text not null unique,
  criado_por  uuid references public.usuarios(id),
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz not null default now() + interval '48 hours',
  usado_em    timestamptz,
  cancelado_em timestamptz
);
create index if not exists usuarios_convites_usuario_idx on public.usuarios_convites (usuario_id);
alter table public.usuarios_convites enable row level security;
-- leitura só para quem administra usuários (a tela pode mostrar "convite pendente"); gravação só pela função do sistema
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'usuarios_convites' and policyname = 'ver convites') then
    create policy "ver convites" on public.usuarios_convites for select to authenticated using ((select public.eh_admin()));
  end if;
end $$;
revoke insert, update on public.usuarios_convites from anon, authenticated;

select public.ligar_auditoria('usuarios_convites');
