-- =====================================================================
-- 168 · Recados entre a equipe (na Minha mesa)
--  · Qualquer pessoa pode mandar um recado/pedido para outra pelo sistema (ex.: "Danielle, sobe os
--    extratos do Itaú de novembro"), com prazo opcional e link para a tela certa.
--  · Quem recebe vê o recado no topo da Minha mesa, pode responder e marcar como feito.
--    Quem mandou acompanha: pendente, visto (e quando) e feito.
--  · Cada pessoa só enxerga os recados que mandou ou recebeu. Nada é apagado (fica o histórico).
--  · Nada existente muda. Para desfazer: tirar o bloco da Minha mesa (a tabela fica sem uso).
-- =====================================================================

create table if not exists public.recados (
  id         bigint generated always as identity primary key,
  de_id      uuid not null default auth.uid() references auth.users(id),
  para_id    uuid not null references auth.users(id),
  texto      text not null check (length(btrim(texto)) between 1 and 2000),
  link       text,                                   -- tela do sistema, ex.: pages/financeiro/conciliacao.html
  prazo      date,
  criado_em  timestamptz not null default now(),
  visto_em   timestamptz,
  feito_em   timestamptz,
  resposta   text check (resposta is null or length(resposta) <= 2000)
);
create index if not exists recados_para_idx on public.recados (para_id) where feito_em is null;
create index if not exists recados_de_idx on public.recados (de_id, criado_em desc);

alter table public.recados enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'recados' and policyname = 'ver meus recados') then
    create policy "ver meus recados" on public.recados for select to authenticated
      using (de_id = (select auth.uid()) or para_id = (select auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'recados' and policyname = 'mandar recado') then
    create policy "mandar recado" on public.recados for insert to authenticated
      with check (de_id = (select auth.uid()) and para_id <> (select auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'recados' and policyname = 'marcar recado') then
    create policy "marcar recado" on public.recados for update to authenticated
      using (de_id = (select auth.uid()) or para_id = (select auth.uid()))
      with check (de_id = (select auth.uid()) or para_id = (select auth.uid()));
  end if;
end $$;
-- só dá para mudar visto, feito e resposta (o texto, o remetente e o destinatário não mudam)
revoke all on public.recados from anon;
revoke update on public.recados from authenticated;
grant select, insert on public.recados to authenticated;
grant update (visto_em, feito_em, resposta) on public.recados to authenticated;

-- Lista de pessoas para escolher o destinatário (só nome; a tabela usuarios só o administrador lê)
create or replace function public.recados_pessoas()
returns table (id uuid, nome text)
language sql stable security definer
set search_path = public
as $$
  select u.id, u.nome from public.usuarios u
   where u.ativo and exists (select 1 from public.usuarios e where e.id = (select auth.uid()) and e.ativo)
   order by u.nome;
$$;
revoke execute on function public.recados_pessoas() from public, anon;
grant execute on function public.recados_pessoas() to authenticated;

select public.ligar_auditoria('recados');
select public.ligar_tempo_real('recados');
