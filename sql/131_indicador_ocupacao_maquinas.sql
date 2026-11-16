-- =====================================================================
-- 131 · Indicadores › Produção: ocupação das máquinas (começando pela solda a laser)
--  · Substitui a planilha "Indicador Eficiência Solda Laser" por uma tela do ERP.
--  · Máquinas: nome, meta de ocupação (verde), faixa de atenção (amarelo) e horas disponíveis
--    por dia da semana. Exceções por dia (feriado, meio período, máquina parada).
--  · Registro de uso: data, hora de início e de fim, quantidade, peça/item, operador e observação.
--    As horas trabalhadas e a ocupação (horas trabalhadas ÷ horas disponíveis) são calculadas na tela.
--  · Quem vê a tela Indicadores de produção vê o painel; quem tem "ver e incluir" lança registros;
--    quem tem "ver, incluir e alterar" corrige/exclui registros e mexe na configuração.
--  · Já cadastra a máquina "Solda a laser" (meta 70%, atenção 40%, 9,5 h de segunda a sexta),
--    valores iniciais para ajustar na própria tela.
-- =====================================================================

-- ---------- Máquinas e parâmetros do indicador ----------
create table if not exists public.maquinas (
  id             bigserial primary key,
  nome           text not null unique,
  meta           numeric(5,4) not null default 0.70 check (meta between 0 and 1),
  atencao        numeric(5,4) not null default 0.40 check (atencao between 0 and 1),
  -- horas disponíveis por dia da semana: posição 1 = segunda ... 7 = domingo
  horas_dia      numeric(4,2)[] not null default '{9.5,9.5,9.5,9.5,9.5,0,0}'
                 check (array_length(horas_dia, 1) = 7 and 0 <= all(horas_dia) and 24 >= all(horas_dia)),
  ativa          boolean not null default true,
  criado_em      timestamptz not null default now(),
  criado_por     uuid default auth.uid(),
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid,
  check (atencao <= meta)
);

create table if not exists public.maquinas_excecoes (
  id             bigserial primary key,
  maquina_id     bigint not null references public.maquinas(id),
  data           date not null,
  horas          numeric(4,2) not null check (horas between 0 and 24),
  motivo         text,
  criado_em      timestamptz not null default now(),
  criado_por     uuid default auth.uid(),
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid,
  unique (maquina_id, data)
);

create table if not exists public.maquinas_uso (
  id             bigserial primary key,
  maquina_id     bigint not null references public.maquinas(id),
  data           date not null,
  inicio         time not null,
  fim            time not null,
  quantidade     numeric(12,2) not null default 0 check (quantidade >= 0),
  item           text,
  operador       text,
  observacao     text,
  check (fim <> inicio),   -- fim antes do início = passou da meia-noite
  criado_em      timestamptz not null default now(),
  criado_por     uuid default auth.uid(),
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid
);
create index if not exists maquinas_uso_maquina_data on public.maquinas_uso (maquina_id, data);
create index if not exists maquinas_excecoes_maquina_data on public.maquinas_excecoes (maquina_id, data);

create or replace trigger carimbo before insert or update on public.maquinas for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.maquinas_excecoes for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.maquinas_uso for each row execute function public.carimbo_cadastro();

-- ---------- Segurança ----------
alter table public.maquinas          enable row level security;
alter table public.maquinas_excecoes enable row level security;
alter table public.maquinas_uso      enable row level security;

do $$ begin
  -- ver: quem abre a tela Indicadores de produção
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'maquinas' and policyname = 'ver maquinas') then
    create policy "ver maquinas" on public.maquinas for select to authenticated using ((select public.pode('ind_producao')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'maquinas_excecoes' and policyname = 'ver excecoes maquina') then
    create policy "ver excecoes maquina" on public.maquinas_excecoes for select to authenticated using ((select public.pode('ind_producao')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'maquinas_uso' and policyname = 'ver uso maquina') then
    create policy "ver uso maquina" on public.maquinas_uso for select to authenticated using ((select public.pode('ind_producao')));
  end if;
  -- configuração (máquina e exceções): "ver, incluir e alterar"
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'maquinas' and policyname = 'configurar maquinas') then
    create policy "configurar maquinas" on public.maquinas for all to authenticated
      using ((select public.pode('ind_producao', 'alterar'))) with check ((select public.pode('ind_producao', 'alterar')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'maquinas_excecoes' and policyname = 'configurar excecoes maquina') then
    create policy "configurar excecoes maquina" on public.maquinas_excecoes for all to authenticated
      using ((select public.pode('ind_producao', 'alterar'))) with check ((select public.pode('ind_producao', 'alterar')));
  end if;
  -- registro de uso: incluir com "ver e incluir"; corrigir/excluir com "ver, incluir e alterar"
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'maquinas_uso' and policyname = 'lancar uso maquina') then
    create policy "lancar uso maquina" on public.maquinas_uso for insert to authenticated
      with check ((select public.pode('ind_producao', 'criar')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'maquinas_uso' and policyname = 'corrigir uso maquina') then
    create policy "corrigir uso maquina" on public.maquinas_uso for update to authenticated
      using ((select public.pode('ind_producao', 'alterar'))) with check ((select public.pode('ind_producao', 'alterar')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'maquinas_uso' and policyname = 'excluir uso maquina') then
    create policy "excluir uso maquina" on public.maquinas_uso for delete to authenticated
      using ((select public.pode('ind_producao', 'alterar')));
  end if;
end $$;

revoke all on public.maquinas, public.maquinas_excecoes, public.maquinas_uso from anon;

-- ---------- Máquina inicial ----------
insert into public.maquinas (nome, meta, atencao, horas_dia)
values ('Solda a laser', 0.70, 0.40, '{9.5,9.5,9.5,9.5,9.5,0,0}')
on conflict (nome) do nothing;

select public.ligar_auditoria('maquinas');
select public.ligar_auditoria('maquinas_excecoes');
select public.ligar_auditoria('maquinas_uso');
select public.ligar_tempo_real('maquinas');
select public.ligar_tempo_real('maquinas_excecoes');
select public.ligar_tempo_real('maquinas_uso');
