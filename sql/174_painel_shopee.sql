-- =====================================================================
-- 174 · Painel da Shopee
--  · Tela nova "Painel da Shopee" (Marketplaces), no mesmo formato do painel do Mercado Livre:
--    vendas, unidades, pedidos e ticket médio por semana, mês ou período personalizado, evolução e ranking
--    dos anúncios. Quem vê: os mesmos do painel do ML (administradores e quem tiver a permissão).
--  · Duas tabelas novas, gravadas só pelo servidor, uma vez por dia:
--      shopee_item_dia: foto do dia de cada anúncio (título, preço, visitas e vendas ACUMULADAS que a Shopee
--                       informa). A diferença entre dois dias dá as visitas do período (só daqui para frente:
--                       a Shopee não informa visitas antigas).
--      shopee_ads_dia:  desempenho do ADS da Shopee por dia (gasto, cliques, vendas pelo ADS).
--  · Função painel_shopee(de, até): devolve os números do período para a tela (só para quem pode ver).
--  · Agendamento: todo dia às 6h40 a função shopee-sync tira a foto dos anúncios e lê o ADS.
--  · Nada existente muda. Para desfazer: tirar a tela do menu e o agendamento.
-- =====================================================================

insert into public.modulos (id, grupo, nome, ordem) values ('painel_shopee', 'comercial', 'Painel da Shopee', 16)
on conflict (id) do nothing;
insert into public.permissoes_usuario (usuario_id, modulo_id, nivel)
select usuario_id, 'painel_shopee', nivel from public.permissoes_usuario where modulo_id = 'painel_ml'
on conflict do nothing;

create table if not exists public.shopee_item_dia (
  item_id      text not null,
  dia          date not null,
  canal_id     bigint not null references public.canais_venda(id),
  titulo       text,
  preco        numeric(12,2),
  situacao     text,
  visitas_total integer,          -- acumulado desde a criação do anúncio (o que a Shopee informa)
  vendas_total integer,
  curtidas     integer,
  nota         numeric(4,2),
  avaliacoes   integer,
  atualizado_em timestamptz not null default now(),
  primary key (item_id, dia)
);
create index if not exists shopee_item_dia_dia_idx on public.shopee_item_dia (dia);

create table if not exists public.shopee_ads_dia (
  canal_id     bigint not null references public.canais_venda(id),
  dia          date not null,
  impressoes   integer not null default 0,
  cliques      integer not null default 0,
  gasto        numeric(12,2) not null default 0,
  pedidos      integer not null default 0,
  itens        integer not null default 0,
  vendas       numeric(12,2) not null default 0,   -- vendas atribuídas ao ADS (direct_gmv)
  atualizado_em timestamptz not null default now(),
  primary key (canal_id, dia)
);

alter table public.shopee_item_dia enable row level security;
alter table public.shopee_ads_dia enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'shopee_item_dia' and policyname = 'ver painel shopee itens') then
    create policy "ver painel shopee itens" on public.shopee_item_dia for select to authenticated using ((select public.pode('painel_shopee')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'shopee_ads_dia' and policyname = 'ver painel shopee ads') then
    create policy "ver painel shopee ads" on public.shopee_ads_dia for select to authenticated using ((select public.pode('painel_shopee')));
  end if;
end $$;
revoke all on public.shopee_item_dia, public.shopee_ads_dia from anon;
revoke insert, update, delete on public.shopee_item_dia, public.shopee_ads_dia from authenticated;

-- Números do período para a tela: vendas por dia, por anúncio (com visitas, quando houver foto) e ADS por dia
create or replace function public.painel_shopee(p_de date, p_ate date)
returns jsonb language sql stable security definer set search_path = public as $$
  with ped as (
    select p.id, p.data_pedido::date dia, p.valor_produtos, p.valor_liquido
      from public.pedidos_venda p join public.canais_venda c on c.id = p.canal_id
     where c.plataforma = 'shopee' and p.situacao not in ('cancelado', 'orcamento')
       and p.data_pedido::date between p_de and p_ate
  ), it as (
    select i.anuncio_id, max(i.descricao) descricao, sum(i.quantidade) un, sum(i.valor_total) valor, count(distinct i.pedido_id) pedidos
      from public.pedidos_venda_itens i join ped on ped.id = i.pedido_id group by i.anuncio_id
  ), fot as (
    select item_id,
           (array_agg(visitas_total order by dia desc))[1] - (array_agg(visitas_total order by dia))[1] visitas,
           count(*) dias,
           (array_agg(titulo order by dia desc))[1] titulo, (array_agg(preco order by dia desc))[1] preco,
           (array_agg(nota order by dia desc))[1] nota, (array_agg(avaliacoes order by dia desc))[1] avaliacoes
      from public.shopee_item_dia where dia between p_de - 1 and p_ate group by item_id
  )
  select jsonb_build_object(
    'dias', coalesce((select jsonb_agg(jsonb_build_object('dia', d.dia, 'pedidos', d.n, 'unidades', d.un, 'vendas', d.v, 'liquido', d.l) order by d.dia)
        from (select ped.dia, count(distinct ped.id) n, sum(ped.valor_produtos) v, sum(ped.valor_liquido) l,
                     (select sum(i.quantidade) from public.pedidos_venda_itens i join ped p2 on p2.id = i.pedido_id where p2.dia = ped.dia) un
                from ped group by ped.dia) d), '[]'),
    'anuncios', coalesce((select jsonb_agg(jsonb_build_object('item_id', coalesce(it.anuncio_id, fot.item_id), 'titulo', coalesce(fot.titulo, it.descricao),
          'preco', fot.preco, 'unidades', coalesce(it.un, 0), 'vendas', coalesce(it.valor, 0), 'pedidos', coalesce(it.pedidos, 0),
          'visitas', case when fot.dias > 1 then fot.visitas end, 'nota', fot.nota, 'avaliacoes', fot.avaliacoes))
        from it full join fot on fot.item_id = it.anuncio_id), '[]'),
    'ads', coalesce((select jsonb_agg(jsonb_build_object('dia', a.dia, 'gasto', a.gasto, 'vendas', a.vendas, 'cliques', a.cliques, 'impressoes', a.impressoes) order by a.dia)
        from public.shopee_ads_dia a where a.dia between p_de and p_ate), '[]'),
    'fotos_desde', (select min(dia) from public.shopee_item_dia),
    'vendas_desde', (select min(p.data_pedido)::date from public.pedidos_venda p join public.canais_venda c on c.id = p.canal_id where c.plataforma = 'shopee')
  ) where (select public.pode('painel_shopee'))
$$;
revoke execute on function public.painel_shopee(date, date) from public, anon;
grant execute on function public.painel_shopee(date, date) to authenticated;

select public.ligar_auditoria('shopee_item_dia');
select public.ligar_tempo_real('shopee_item_dia');
select public.ligar_auditoria('shopee_ads_dia');
select public.ligar_tempo_real('shopee_ads_dia');

-- foto diária dos anúncios e ADS (6h40, antes do expediente)
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'nox-shopee-diario') then
    perform cron.schedule('nox-shopee-diario', '40 9 * * *', $c$select public.integracao_disparar('shopee-sync', '{"acao":"diario"}'::jsonb)$c$);
  end if;
end $$;
