-- =====================================================================
-- ERP NOX · 002_auditoria.sql
-- Rastreia TODA alteração de dados: usuário, data/hora, tela, tabela,
-- ação (incluiu / alterou / excluiu), valor anterior e valor novo.
-- Como usar: Supabase → SQL Editor → New → colar tudo → Run
-- (rodar DEPOIS do 001_base.sql). Pode rodar mais de uma vez.
-- =====================================================================

create table if not exists public.auditoria (
  id            bigserial primary key,
  em            timestamptz not null default now(),
  usuario_id    uuid,
  usuario_nome  text,
  tela          text,
  tabela        text not null,
  acao          text not null check (acao in ('incluiu','alterou','excluiu')),
  registro      text,
  antes         jsonb,
  depois        jsonb,
  campos        text[]          -- campos que mudaram (só em "alterou")
);
create index if not exists auditoria_em_idx      on public.auditoria (em desc);
create index if not exists auditoria_usuario_idx on public.auditoria (usuario_id);
create index if not exists auditoria_tabela_idx  on public.auditoria (tabela);

-- Função que grava o registro. A tela vem do cabeçalho "x-tela" (id da tela,
-- ex.: "usuarios") que o sistema envia automaticamente (assets/js/supabase.js).
create or replace function public.auditar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_antes  jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_depois jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  v_campos text[];
  v_tela   text;
  v_reg    jsonb := coalesce(v_depois, v_antes);
begin
  if tg_op = 'UPDATE' then
    select array_agg(k) into v_campos
    from jsonb_object_keys(v_depois) k
    where v_depois->k is distinct from v_antes->k;
    if v_campos is null then return new; end if;     -- nada mudou de fato
  end if;

  begin
    v_tela := current_setting('request.headers', true)::json->>'x-tela';
    v_tela := coalesce((select nome from modulos where id = v_tela), v_tela);
  exception when others then v_tela := null;
  end;

  insert into auditoria (usuario_id, usuario_nome, tela, tabela, acao, registro, antes, depois, campos)
  values (
    auth.uid(),
    coalesce((select nome from usuarios where id = auth.uid()), case when auth.uid() is null then 'Sistema / Supabase' end),
    coalesce(v_tela, case when auth.uid() is null then 'Painel Supabase' end),
    tg_table_name,
    case tg_op when 'INSERT' then 'incluiu' when 'UPDATE' then 'alterou' else 'excluiu' end,
    coalesce(v_reg->>'id', v_reg->>'usuario_id', v_reg->>'perfil_id') ||
      coalesce(' · ' || (v_reg->>'modulo_id'), ''),
    v_antes, v_depois, v_campos
  );
  return coalesce(new, old);
end $$;

-- Liga a auditoria numa tabela. Toda tabela nova do ERP chama isto no seu SQL:
--   select public.ligar_auditoria('produtos');
create or replace function public.ligar_auditoria(p_tabela text)
returns void language plpgsql as $$
begin
  execute format('drop trigger if exists auditoria on public.%I', p_tabela);
  execute format('create trigger auditoria after insert or update or delete on public.%I
                  for each row execute function public.auditar()', p_tabela);
end $$;

select public.ligar_auditoria(t) from unnest(array[
  'empresas','perfis','modulos','permissoes','permissoes_usuario','usuarios'
]) t;

-- Ninguém altera nem apaga o histórico; só quem tem a tela "auditoria" consulta.
alter table public.auditoria enable row level security;
drop policy if exists "ler auditoria" on public.auditoria;
create policy "ler auditoria" on public.auditoria for select to authenticated using (public.pode('auditoria'));
revoke insert, update, delete on public.auditoria from authenticated, anon;

-- Tela no menu (Configurações → Auditoria). Só o Administrador vê, até ser liberada a alguém.
insert into public.modulos (id, grupo, nome, ordem) values ('auditoria','config','Auditoria',93)
on conflict (id) do update set grupo = excluded.grupo, nome = excluded.nome, ordem = excluded.ordem;
