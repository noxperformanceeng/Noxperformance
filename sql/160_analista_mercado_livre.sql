-- =====================================================================
-- 160 · Painel do Mercado Livre (analista de marketplace)
--  · Nova tela Vendas › Painel do Mercado Livre: ML 30 e ML 37 separados e somados, com
--    vendas, visitas, conversão, ADS (gasto, vendas pelo ADS, ACOS), qualidade dos anúncios,
--    promoções abertas e reputação. Cada anúncio com o funil visita → venda e o resultado do ADS.
--  · Os números vêm sozinhos do Mercado Livre: uma leitura por dia (madrugada), guardando UMA linha
--    por anúncio por semana (o histórico cresce pouco: ~1.500 anúncios × 52 semanas por ano).
--  · Curva ABC dos produtos: A = os que somam 80% do faturamento, B = os próximos 15%, C = o resto (5%).
--    Calculada na hora, pelo período escolhido na tela (padrão: últimos 90 dias), por conta ou todas juntas.
--  · Toda segunda a IA lê esses números e escreve um relatório curto com o que fazer
--    (ex.: "campanha X com ACOS acima da margem", "anúncio Y perdeu visitas"). Só sugere: nada muda no ML.
--  · Quem vê: Paulo, Leila e Alexandre (administradores) e o Caio (liberado só para ele: o resto do Comercial não vê).
--    Só leitura; quem grava é o servidor.
--  · Tabelas novas; nada existente muda. Para desfazer: pausar o agendamento 'nox-ml-analista'.
-- =====================================================================

insert into public.modulos (id, grupo, nome, ordem) values ('painel_ml', 'comercial', 'Painel do Mercado Livre', 15)
on conflict (id) do nothing;
-- administradores já veem tudo; o Caio recebe acesso individual (não o perfil Comercial inteiro)
insert into public.permissoes_usuario (usuario_id, modulo_id, nivel)
values ('58170d96-5b55-43c5-a2ee-6d9f77797406', 'painel_ml', 'ver')
on conflict do nothing;

-- Uma linha por anúncio por semana (segunda-feira da semana). A leitura diária atualiza a semana corrente.
create table if not exists public.ml_anuncio_semana (
  item_id          text not null,
  semana           date not null,                 -- segunda-feira da semana
  canal_id         bigint not null references public.canais_venda(id),
  titulo           text,
  preco            numeric(12,2),
  no_full          boolean,                       -- anúncio no Full
  situacao         text,
  visitas          integer not null default 0,
  vendas_qtd       numeric(12,3) not null default 0,
  vendas_valor     numeric(14,2) not null default 0,
  ads_custo        numeric(12,2) not null default 0,
  ads_receita      numeric(14,2) not null default 0,
  ads_cliques      integer not null default 0,
  ads_impressoes   integer not null default 0,
  qualidade        integer,                       -- nota do ML (0 a 100)
  qualidade_nivel  text,
  qualidade_falta  text,                          -- o que o ML diz que falta melhorar
  promocoes        jsonb,                         -- promoções abertas para o anúncio (tipo, desconto sugerido)
  atualizado_em    timestamptz not null default now(),
  primary key (item_id, semana)
);
create index if not exists ml_anuncio_semana_semana on public.ml_anuncio_semana (semana, canal_id);

-- Resumo diário da conta: reputação, visitas, campanhas de ADS
create table if not exists public.ml_conta_dia (
  canal_id        bigint not null references public.canais_venda(id),
  dia             date not null,
  reputacao       text,                           -- cor/nível (ex.: 5_green)
  medalha         text,                           -- MercadoLíder
  reclamacoes     numeric(8,4),                   -- taxas dos últimos 60 dias
  atrasos         numeric(8,4),
  cancelamentos   numeric(8,4),
  visitas         integer,
  campanhas       jsonb,                          -- campanhas de ADS: nome, status, orçamento, gasto, vendas, ACOS
  atualizado_em   timestamptz not null default now(),
  primary key (canal_id, dia)
);

-- Relatório semanal da IA (o "analista")
create table if not exists public.ml_relatorios (
  id          bigint generated always as identity primary key,
  semana      date not null unique,
  texto       text not null,
  criado_em   timestamptz not null default now()
);

alter table public.ml_anuncio_semana enable row level security;
alter table public.ml_conta_dia enable row level security;
alter table public.ml_relatorios enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ml_anuncio_semana' and policyname = 'ver painel ml anuncios') then
    create policy "ver painel ml anuncios" on public.ml_anuncio_semana for select to authenticated using ((select public.pode('painel_ml')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ml_conta_dia' and policyname = 'ver painel ml contas') then
    create policy "ver painel ml contas" on public.ml_conta_dia for select to authenticated using ((select public.pode('painel_ml')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ml_relatorios' and policyname = 'ver relatorios ml') then
    create policy "ver relatorios ml" on public.ml_relatorios for select to authenticated using ((select public.pode('painel_ml')));
  end if;
end $$;
-- escrita só pelo servidor
revoke insert, update, delete on public.ml_anuncio_semana, public.ml_conta_dia, public.ml_relatorios from anon, authenticated;

-- Curva ABC: faturamento por produto no período (pedidos não cancelados), do maior para o menor
create or replace function public.painel_ml_curva_abc(p_dias integer default 90, p_canal bigint default null)
returns table (produto_id bigint, codigo text, descricao text, quantidade numeric, faturamento numeric, participacao numeric, acumulado numeric, curva text)
language sql stable security definer set search_path = public as $$
  with v as (
    select i.produto_id, sum(i.quantidade) q, sum(i.valor_total) f
      from public.pedidos_venda_itens i join public.pedidos_venda p on p.id = i.pedido_id
     where (select public.pode('painel_ml')) and i.produto_id is not null
       and p.data_pedido >= current_date - greatest(coalesce(p_dias, 90), 1) and p.situacao::text <> 'cancelado'
       and (p_canal is null or p.canal_id = p_canal)
     group by 1 having sum(i.valor_total) > 0),
  t as (select sum(f) tot from v),
  r as (select v.*, v.f / t.tot * 100 part, sum(v.f) over (order by v.f desc, v.produto_id rows unbounded preceding) / t.tot * 100 acum from v, t)
  select r.produto_id, pr.codigo, pr.descricao, r.q, round(r.f, 2), round(r.part, 2), round(r.acum, 2),
         case when r.acum - r.part < 80 then 'A' when r.acum - r.part < 95 then 'B' else 'C' end
    from r join public.produtos pr on pr.id = r.produto_id
   order by r.f desc
$$;
revoke execute on function public.painel_ml_curva_abc(integer, bigint) from public, anon;
grant execute on function public.painel_ml_curva_abc(integer, bigint) to authenticated;

-- Leitura diária às 4h (horário de Brasília = 7h UTC) e relatório toda segunda às 7h (10h UTC)
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'nox-ml-analista') then
    perform cron.schedule('nox-ml-analista', '0 7 * * *', $c$select public.integracao_disparar('ml-analista', '{"acao":"coletar"}'::jsonb)$c$);
  end if;
  if not exists (select 1 from cron.job where jobname = 'nox-ml-relatorio') then
    perform cron.schedule('nox-ml-relatorio', '0 10 * * 1', $c$select public.integracao_disparar('ml-analista', '{"acao":"relatorio"}'::jsonb)$c$);
  end if;
end $$;

-- Números de leitura (não são dados de pessoas): tempo real só no relatório; auditoria desligada como nas tabelas
-- de marketplace (SQL 125), para não encher o banco com a regravação diária.
select public.ligar_tempo_real('ml_relatorios');
