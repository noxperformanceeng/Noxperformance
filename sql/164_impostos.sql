-- =====================================================================
-- 164 · Impostos (Financeiro): quanto cada empresa paga de imposto sobre o faturamento
--  · Nova tela Financeiro › Impostos, mês a mês, NOX 30 (Lucro Presumido) e NOX 37 (Simples):
--    faturamento declarado pelo contador, cada imposto (ICMS, PIS, COFINS, IRPJ, CSLL, DAS),
--    o % sobre o faturamento (o número que vai para a precificação) e as vendas que o sistema
--    registrou no mesmo mês, para conferir a apuração do contador.
--  · Os números vêm dos documentos que a contabilidade manda (pasta IMPOSTOS NOX PEÇAS no Google
--    Drive): o Claude lê a pasta todo mês e grava aqui; a tela mostra o que falta mandar.
--  · IRPJ e CSLL do Presumido são trimestrais: a tela reparte o valor do trimestre pelos meses,
--    na proporção do faturamento de cada mês.
--  · Quem vê: administradores (Paulo, Leila, Alexandre). Só leitura na tela.
--  · Tabela nova; nada existente muda. Para desfazer: basta não usar a tela.
-- =====================================================================

insert into public.modulos (id, grupo, nome, ordem) values ('impostos', 'financeiro', 'Impostos', 66)
on conflict (id) do nothing;

create table if not exists public.impostos_mes (
  empresa_id     integer not null references public.empresas(id),
  competencia    date not null,                 -- 1º dia do mês
  faturamento    numeric(14,2),                 -- receita da apuração (PIS/COFINS no Presumido; receita bruta do PGDAS no Simples)
  icms           numeric(14,2),                 -- ICMS a recolher (apuração normal)
  icms_difal_st  numeric(14,2),                 -- ICMS-ST / DIFAL em guia separada (GNRE/GARE)
  pis            numeric(14,2),
  cofins         numeric(14,2),
  irpj           numeric(14,2),                 -- valor do trimestre, gravado no mês de fechamento (mar/jun/set/dez)
  csll           numeric(14,2),
  irpj_csll_base numeric(14,2),                 -- receita do trimestre usada no IRPJ/CSLL
  das            numeric(14,2),                 -- Simples Nacional (total do DAS)
  outros         jsonb,                         -- retenções e guias que não entram no % (IRRF de terceiros, ISS retido...)
  documentos     jsonb,                         -- [{tipo, nome, link}] lidos na pasta
  faltando       text[],                        -- documentos que a contabilidade ainda não mandou
  observacao     text,
  atualizado_em  timestamptz not null default now(),
  primary key (empresa_id, competencia)
);

alter table public.impostos_mes enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'impostos_mes' and policyname = 'ver impostos') then
    create policy "ver impostos" on public.impostos_mes for select to authenticated using ((select public.pode('impostos')));
  end if;
end $$;
-- quem grava é o servidor (leitura mensal da pasta)
revoke insert, update, delete on public.impostos_mes from anon, authenticated;

-- Painel: impostos + % sobre o faturamento + vendas registradas no sistema no mesmo mês
create or replace function public.impostos_painel(p_desde date default (date_trunc('year', current_date))::date)
returns table (empresa_id integer, competencia date, faturamento numeric, icms numeric, icms_difal_st numeric, pis numeric, cofins numeric,
               irpj numeric, csll numeric, das numeric, total numeric, percentual numeric, vendas_sistema numeric,
               faltando text[], documentos jsonb, observacao text, atualizado_em timestamptz)
language sql stable security definer set search_path = public as $$
  with m as (
    select i.*, date_trunc('quarter', i.competencia)::date tri from public.impostos_mes i
     where (select public.pode('impostos')) and i.competencia >= p_desde
  ),
  t as (   -- IRPJ/CSLL do trimestre (gravado no mês de fechamento) e faturamento do trimestre
    select empresa_id, tri, sum(coalesce(irpj, 0)) irpj_t, sum(coalesce(csll, 0)) csll_t, sum(coalesce(faturamento, 0)) fat_t
      from m group by 1, 2
  ),
  v as (   -- vendas registradas no sistema (pedidos não cancelados), pela empresa do pedido ou do canal
    select coalesce(p.empresa_id, c.empresa_id) empresa_id, date_trunc('month', p.data_pedido)::date mes, sum(p.valor_total) total
      from public.pedidos_venda p join public.canais_venda c on c.id = p.canal_id
     where (select public.pode('impostos')) and p.data_pedido >= p_desde and p.situacao::text <> 'cancelado'
     group by 1, 2
  )
  select m.empresa_id, m.competencia, m.faturamento, m.icms, m.icms_difal_st, m.pis, m.cofins,
         round(case when t.fat_t > 0 then t.irpj_t * coalesce(m.faturamento, 0) / t.fat_t end, 2),
         round(case when t.fat_t > 0 then t.csll_t * coalesce(m.faturamento, 0) / t.fat_t end, 2),
         m.das,
         x.total, round(case when m.faturamento > 0 then x.total / m.faturamento * 100 end, 2),
         v.total, m.faltando, m.documentos, m.observacao, m.atualizado_em
    from m
    join t on t.empresa_id = m.empresa_id and t.tri = m.tri
    left join v on v.empresa_id = m.empresa_id and v.mes = m.competencia
    cross join lateral (select coalesce(m.icms, 0) + coalesce(m.icms_difal_st, 0) + coalesce(m.pis, 0) + coalesce(m.cofins, 0) + coalesce(m.das, 0)
                             + case when t.fat_t > 0 then (t.irpj_t + t.csll_t) * coalesce(m.faturamento, 0) / t.fat_t else 0 end total) x
   order by m.competencia desc, m.empresa_id
$$;
revoke execute on function public.impostos_painel(date) from public, anon;
grant execute on function public.impostos_painel(date) to authenticated;

select public.ligar_auditoria('impostos_mes');
select public.ligar_tempo_real('impostos_mes');
