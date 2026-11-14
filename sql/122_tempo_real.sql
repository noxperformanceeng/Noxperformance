-- =====================================================================
-- 122 · Telas em tempo real (sem botão de atualizar)
--  · Toda inclusão, alteração ou exclusão, feita por qualquer usuário, tela ou integração (Tiny, ML,
--    Mercado Pago), passa a aparecer sozinha em todas as telas abertas, de todos os usuários.
--  · Como: cada tabela ganha um gatilho por comando (não por linha) que avisa no canal privado
--    "nox:mudancas" só QUAL tabela e QUAIS ids mudaram (até 50; acima disso, "muitos").
--    Nenhum dado vai no aviso: a tela busca de novo pelas consultas normais, então o RLS continua
--    decidindo o que cada um vê. Um comando que não mexeu em nenhuma linha não avisa nada.
--  · Só usuário logado e ativo no ERP escuta o canal; ninguém consegue publicar nele pelo navegador.
--  · Se o aviso falhar, a gravação segue normalmente (o aviso nunca bloqueia o trabalho).
--  · Ficam de fora tabelas brutas de integração, cópias, backup e a própria auditoria (volume alto,
--    nenhuma tela as lista linha a linha): auditoria, tiny_brutos, tiny_cp_conta, tiny_produtos_ignorados,
--    ml_eventos, ml_pedidos_brutos, ml_autorizacoes, integracao_config, usuarios_convites, _import_*, bkp_*.
--  · O aviso não diz quem alterou (só tabela, ids e quantidade). Quem for inativado ainda recebe avisos
--    (sem dados) até a sessão renovar, em no máximo ~1 h.
--  · Recomendado no painel do Supabase: Realtime › Settings › desligar "Allow public access", para só
--    existirem canais privados (as telas já usam canal privado).
--  · Tabela nova daqui em diante: além de ligar_auditoria, chamar  select public.ligar_tempo_real('tabela');
-- =====================================================================

-- ---------- Quem pode escutar: usuário ativo do ERP ----------
create or replace function public.sou_usuario_ativo()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select ativo from public.usuarios where id = auth.uid()), false)
$$;
revoke execute on function public.sou_usuario_ativo() from public, anon;
grant execute on function public.sou_usuario_ativo() to authenticated;

-- ---------- Aviso de mudança (gatilho por comando) ----------
create or replace function public.avisar_mudanca()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_n int; v_ids jsonb;
begin
  -- conta tudo, mas só monta o id das 50 primeiras linhas (importação grande não pesa)
  if tg_op = 'DELETE' then
    select count(*)::int into v_n from antigas;
    if v_n = 0 then return null; end if;
    select jsonb_agg(x.id) filter (where x.id is not null) into v_ids from (select to_jsonb(o) -> 'id' as id from (select * from antigas limit 50) o) x;
  else
    select count(*)::int into v_n from novas;
    if v_n = 0 then return null; end if;
    select jsonb_agg(x.id) filter (where x.id is not null) into v_ids from (select to_jsonb(r) -> 'id' as id from (select * from novas limit 50) r) x;
  end if;
  perform realtime.send(
    jsonb_build_object('t', tg_table_name, 'o', lower(tg_op), 'ids', coalesce(v_ids, '[]'::jsonb), 'n', v_n),
    'mudanca', 'nox:mudancas', true);
  return null;
exception when others then
  raise warning 'tempo real: aviso de % em % falhou: %', tg_op, tg_table_name, sqlerrm;
  return null;
end $$;
revoke execute on function public.avisar_mudanca() from public, anon, authenticated;

-- ---------- Liga o aviso numa tabela (uso interno, como ligar_auditoria) ----------
create or replace function public.ligar_tempo_real(p_tabela text)
returns void language plpgsql security definer set search_path = public as $$
begin
  execute format('create or replace trigger tempo_real_ins after insert on public.%I referencing new table as novas
                  for each statement execute function public.avisar_mudanca()', p_tabela);
  execute format('create or replace trigger tempo_real_upd after update on public.%I referencing new table as novas
                  for each statement execute function public.avisar_mudanca()', p_tabela);
  execute format('create or replace trigger tempo_real_del after delete on public.%I referencing old table as antigas
                  for each statement execute function public.avisar_mudanca()', p_tabela);
end $$;
revoke execute on function public.ligar_tempo_real(text) from public, anon, authenticated;

-- ---------- Canal privado: só usuário ativo escuta; ninguém publica pelo navegador ----------
-- (sem "drop": cria só se ainda não existe, para o arquivo poder rodar de novo)
do $$
begin
  if not exists (select 1 from pg_policy where polrelid = 'realtime.messages'::regclass and polname = 'nox_tempo_real_escutar') then
    create policy "nox_tempo_real_escutar" on realtime.messages
      for select to authenticated
      using (realtime.topic() = 'nox:mudancas' and extension = 'broadcast' and (select public.sou_usuario_ativo()));
  end if;
end $$;

-- ---------- Liga em todas as tabelas das telas ----------
-- Cada gatilho novo pede um bloqueio rápido na tabela. Se alguma estiver ocupada (backup, importação do Tiny),
-- desiste em 3 s em vez de segurar as gravações do ERP: é só rodar o arquivo de novo depois.
set lock_timeout = '3s';
do $$
declare t text;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relispartition
       and c.relname not in ('auditoria', 'tiny_brutos', 'tiny_cp_conta', 'tiny_produtos_ignorados', 'ml_eventos',
                             'ml_pedidos_brutos', 'ml_autorizacoes', 'integracao_config', 'usuarios_convites')
       and c.relname not like '\_%' and c.relname not like 'bkp\_%'
     order by 1
  loop
    perform public.ligar_tempo_real(t);
  end loop;
end $$;
reset lock_timeout;

-- Conferência: deve listar só as tabelas que ficam de fora de propósito (auditoria, brutos de integração, cópias)
select c.relname as sem_tempo_real
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relispartition
   and not exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'tempo_real_ins')
 order by 1;
