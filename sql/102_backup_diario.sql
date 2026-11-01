-- =====================================================================
-- 102 · Backup diário do sistema
--  · Toda madrugada (03:15) o sistema copia todas as tabelas do banco para arquivos compactados numa pasta
--    privada ("backups"), uma pasta por dia (AAAA-MM-DD). Junto vai a estrutura (funções e regras de acesso).
--  · A auditoria (rastreio de alterações) é muito grande: vai só a parte dos últimos 2 dias em cada backup;
--    somando os dias guardados, nada se perde.
--  · Ficam guardados os últimos 14 dias e, além deles, o backup de domingo das últimas 8 semanas.
--  · Só administradores veem e baixam os backups (tela Configurações › Backups).
--  · Cada execução fica registrada (quando rodou, quantas tabelas, tamanho, erro se houver).
-- =====================================================================

insert into storage.buckets (id, name, public) values ('backups', 'backups', false) on conflict (id) do nothing;

drop policy if exists "admin baixa backups" on storage.objects;
create policy "admin baixa backups" on storage.objects for select to authenticated
  using (bucket_id = 'backups' and (select public.eh_admin()));

create table if not exists public.backup_execucoes (
  id          bigint generated always as identity primary key,
  dia         date not null,
  situacao    text not null default 'rodando' check (situacao in ('rodando', 'ok', 'erro')),
  feitas      text[] not null default '{}',
  tabelas     int,
  linhas      bigint not null default 0,
  bytes       bigint not null default 0,
  mensagem    text,
  iniciado_em timestamptz not null default now(),
  concluido_em timestamptz
);
create index if not exists backup_execucoes_dia on public.backup_execucoes (dia desc);
alter table public.backup_execucoes enable row level security;
drop policy if exists "admin ve backups" on public.backup_execucoes;
create policy "admin ve backups" on public.backup_execucoes for select to authenticated using ((select public.eh_admin()));

-- tabelas a copiar (todas as do esquema public), com a coluna de ordenação
create or replace function public.backup_tabelas()
returns table (nome text, ordem text, linhas_estimadas bigint)
language sql stable security definer set search_path = public as $$
  select c.relname::text,
         (select a.attname::text from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
           where i.indrelid = c.oid and i.indisprimary limit 1),
         greatest(c.reltuples, 0)::bigint
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
   order by c.relname
$$;
revoke execute on function public.backup_tabelas() from public, anon, authenticated;
grant execute on function public.backup_tabelas() to service_role;   -- só a função de backup (servidor) usa

-- estrutura: funções, regras de acesso (RLS) e colunas, em texto
create or replace function public.backup_estrutura()
returns text language sql stable security definer set search_path = public as $$
  select '-- ERP NOX · estrutura em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || E'\n\n'
    || '-- ===== COLUNAS =====' || E'\n'
    || coalesce((select string_agg('-- ' || table_name || ': ' || cols, E'\n' order by table_name) from (
         select table_name, string_agg(column_name || ' ' || data_type || case when is_nullable = 'NO' then ' not null' else '' end, ', ' order by ordinal_position) cols
           from information_schema.columns where table_schema = 'public' group by table_name) t), '') || E'\n\n'
    || '-- ===== REGRAS DE ACESSO (RLS) =====' || E'\n'
    || coalesce((select string_agg(format('create policy %I on public.%I for %s to %s using (%s)%s;', policyname, tablename, cmd,
              array_to_string(roles, ','), coalesce(qual, 'true'), coalesce(' with check (' || with_check || ')', '')), E'\n' order by tablename, policyname)
           from pg_policies where schemaname = 'public'), '') || E'\n\n'
    || '-- ===== FUNÇÕES =====' || E'\n'
    || coalesce((select string_agg(pg_get_functiondef(p.oid) || ';', E'\n\n' order by p.proname)
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.prokind in ('f', 'p')
            and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')), '')
$$;
revoke execute on function public.backup_estrutura() from public, anon, authenticated;
grant execute on function public.backup_estrutura() to service_role;

-- agenda: todo dia 03:15 (horário de Brasília = 06:15 UTC), com nova tentativa a cada 30 min até 04:45
-- (se o backup do dia já terminou, a nova tentativa não faz nada; se parou no meio, continua de onde parou)
select cron.schedule('nox-backup-diario', '15,45 6-7 * * *', $$select public.integracao_disparar('backup-diario', '{"acao":"rodar"}'::jsonb)$$)
 where not exists (select 1 from cron.job where jobname = 'nox-backup-diario');

select public.ligar_auditoria('backup_execucoes');

-- tela Backups (só administrador) e botão "Fazer backup agora"
insert into public.modulos (id, grupo, nome, ordem) values ('backups', 'config', 'Backups', 96) on conflict do nothing;
create or replace function public.backup_agora()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'Só administrador'; end if;
  if exists (select 1 from public.backup_execucoes where situacao = 'rodando' and iniciado_em > now() - interval '30 minutes') then
    raise exception 'Já existe um backup em andamento';
  end if;
  update public.backup_execucoes set situacao = 'erro', mensagem = 'Substituído: backup refeito manualmente'
   where dia = (now() at time zone 'America/Sao_Paulo')::date and situacao = 'ok';
  perform public.integracao_disparar('backup-diario', '{"acao":"rodar"}'::jsonb);
end $$;
revoke execute on function public.backup_agora() from public, anon;
grant execute on function public.backup_agora() to authenticated;
