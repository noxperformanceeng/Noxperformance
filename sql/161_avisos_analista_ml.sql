-- =====================================================================
-- 161 · Avisos do analista do Mercado Livre (em tempo real para o analista)
--  · Todo dia de manhã, depois da leitura do ML, o sistema confere os anúncios com as regras do
--    analista (sempre olhando 8 semanas, nunca uma semana só) e cria um AVISO para cada caso:
--      - ADS caro: ACOS de 8 semanas acima de 8% com cliques suficientes → baixar a meta de ACOS ou o lance;
--      - muita visita e pouca venda → revisar preço, fotos, título, vídeo e parcelamento;
--      - queda forte de visitas → ver se está pausado, sem estoque ou fora da campanha;
--      - qualidade baixa em anúncio que vende → fazer o que o ML pede;
--      - vende bem e quase sem ADS → subir o ADS aos poucos;
--      - convite de promoção em anúncio que vende → levar para o Paulo decidir (com quanto a NOX paga).
--  · O aviso aparece na hora numa faixa amarela no topo de qualquer tela (como a das perguntas), com
--    som e aviso do computador, e na aba "Avisos" do Painel do Mercado Livre, com a orientação do que fazer.
--  · O analista marca "Feito" ou "Ignorar" (com um comentário). O mesmo caso não volta antes de 3 semanas.
--  · Quem vê: quem já vê o Painel do ML (Paulo, Leila, Alexandre e Caio). A faixa amarela aparece para o Caio.
--  · Tabela nova; nada existente muda. Para desfazer: pausar o agendamento 'nox-ml-avisos'.
-- =====================================================================

create table if not exists public.ml_avisos (
  id             bigint generated always as identity primary key,
  item_id        text not null,
  canal_id       bigint not null references public.canais_venda(id),
  tipo           text not null check (tipo in ('ads_caro', 'visita_sem_venda', 'queda_visitas', 'qualidade', 'ads_oportunidade', 'promocao')),
  semana         date not null,                   -- semana em que o caso foi visto
  titulo         text not null,                   -- ex.: "ADS caro: Intake Onix Turbo"
  orientacao     text not null,                   -- o que fazer, em linguagem simples
  numeros        jsonb,                           -- números que motivaram (8 semanas)
  situacao       text not null default 'aberto' check (situacao in ('aberto', 'feito', 'ignorado')),
  obs            text,                            -- comentário de quem resolveu
  resolvido_por  uuid references auth.users(id),
  resolvido_em   timestamptz,
  criado_em      timestamptz not null default now(),
  unique (item_id, tipo, semana)
);
create index if not exists ml_avisos_abertos on public.ml_avisos (situacao, criado_em);

alter table public.ml_avisos enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ml_avisos' and policyname = 'ver avisos ml') then
    create policy "ver avisos ml" on public.ml_avisos for select to authenticated using ((select public.pode('painel_ml')));
  end if;
end $$;
-- cria quem é o servidor; resolver só pela função abaixo
revoke insert, update, delete on public.ml_avisos from anon, authenticated;

-- Marcar o aviso como feito ou ignorado (quem vê o painel pode: o trabalho é feito no próprio ML)
create or replace function public.ml_aviso_resolver(p_id bigint, p_situacao text, p_obs text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.pode('painel_ml') then raise exception 'Sem permissão'; end if;
  if p_situacao not in ('aberto', 'feito', 'ignorado') then raise exception 'Situação inválida'; end if;
  update public.ml_avisos set situacao = p_situacao, obs = nullif(trim(coalesce(p_obs, '')), ''),
    resolvido_por = case when p_situacao = 'aberto' then null else auth.uid() end,
    resolvido_em  = case when p_situacao = 'aberto' then null else now() end
  where id = p_id;
end $$;
revoke execute on function public.ml_aviso_resolver(bigint, text, text) from public, anon;
grant execute on function public.ml_aviso_resolver(bigint, text, text) to authenticated;

-- Conferência diária às 6h30 (Brasília) = 9h30 UTC, depois da leitura do ML (que começa às 4h)
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'nox-ml-avisos') then
    perform cron.schedule('nox-ml-avisos', '30 9 * * *', $c$select public.integracao_disparar('ml-analista', '{"acao":"avisos"}'::jsonb)$c$);
  end if;
end $$;

select public.ligar_auditoria('ml_avisos');
select public.ligar_tempo_real('ml_avisos');
