-- =====================================================================
-- ERP NOX · 032_rh.sql
-- Módulo de RH: eventos da folha, lançamentos do mês e holerite de conferência
-- (contábil e não contábil), adiantamento salarial, férias, vale-transporte, 13º,
-- escala, ponto (leitura do relógio), faltas e documentos (atestados, advertências…).
--
--  - Evento = linha do holerite (código da contabilidade: 8781 dias normais, 998 INSS…).
--    Natureza CONTÁBIL (vai para a folha da contabilidade) ou NÃO CONTÁBIL (pago por fora,
--    sai num holerite separado). Códigos novos podem ser abertos na tela Eventos da folha.
--  - Lançamento = evento + funcionário + competência (mês). O holerite é a soma dos lançamentos.
--  - Evento com "tela exclusiva" só entra pela tela dele (ex.: 981 desconto do adiantamento
--    só pela tela Adiantamento salarial). Na tela Lançamentos ele aparece travado.
--  - Adiantamento, férias, VT, 13º, faltas e fechamento do ponto gravam o próprio registro e o
--    banco gera/atualiza os lançamentos dele (cancelou → lançamentos saem).
--  - Competência fechada: nada muda nos lançamentos daquele mês (reabrir é ação do gestor).
--  - Anexos ficam no Storage do Supabase, pasta privada "rh-documentos".
-- Rodar DEPOIS do 031_funcionarios_custos.sql. Pode rodar mais de uma vez. Sem comandos destrutivos.
-- =====================================================================

-- ---------- Módulos (telas) do RH ----------
insert into public.modulos (id, grupo, nome, ordem) values
  ('rh_eventos', 'rh', 'Eventos da folha', 70),
  ('adiantamento', 'rh', 'Adiantamento salarial', 78),
  ('vale_transporte', 'rh', 'Vale-transporte', 79),
  ('decimo_terceiro', 'rh', '13º salário', 80),
  ('faltas', 'rh', 'Faltas', 81)
on conflict (id) do nothing;
update public.modulos set nome = 'Documentos e advertências' where id = 'advertencias';
update public.modulos set nome = 'Ponto (relógio)' where id = 'ponto';
insert into public.permissoes (perfil_id, modulo_id, nivel)
select 'rh', id, 'editar' from public.modulos where grupo = 'rh'
on conflict do nothing;

-- Pode ver alguma tela do RH? (as telas do RH precisam ler o cadastro de funcionários)
create or replace function public.pode_rh(p_nivel text default 'ver')
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from modulos where grupo = 'rh' and public.pode(id, p_nivel))
$$;
revoke execute on function public.pode_rh(text) from public, anon;
grant execute on function public.pode_rh(text) to authenticated;

drop policy if exists "ver funcionarios" on public.funcionarios;
create policy "ver funcionarios" on public.funcionarios for select to authenticated
  using (public.pode('funcionarios') or public.pode_rh());

-- Ação sensível: fechar/reabrir a competência (por padrão só o gestor; libere ao RH em Usuários e acessos)
insert into public.acoes (id, modulo_id, nome, descricao, ordem) values
  ('lancamentos.fechar', 'lancamentos', 'Fechar / reabrir competência', 'Trava os lançamentos do mês depois de conferidos com a contabilidade.', 1)
on conflict (id) do update set nome = excluded.nome, descricao = excluded.descricao;

-- ---------- Funcionário: dados usados pelo RH ----------
alter table public.funcionarios
  add column if not exists codigo_ponto    text,           -- código/crachá no relógio (se não usar PIS/CPF)
  add column if not exists vt_valor_dia    numeric(12,2),  -- valor do VT por dia (ida + volta)
  add column if not exists escala_id       bigint;

-- ---------- EVENTOS DA FOLHA ----------
create table if not exists public.rh_eventos (
  id              bigserial primary key,
  codigo          text not null,
  descricao       text not null,
  tipo            text not null default 'provento' check (tipo in ('provento','desconto','informativo')),
  natureza        text not null default 'contabil' check (natureza in ('contabil','nao_contabil')),
  referencia_tipo text not null default 'valor' check (referencia_tipo in ('dias','horas','percentual','valor','quantidade')),
  incide_inss     boolean not null default false,
  incide_fgts     boolean not null default false,
  incide_irrf     boolean not null default false,
  tela_exclusiva  text references public.modulos(id),       -- só entra por esta tela
  valor_cadastro  text check (valor_cadastro in ('salario_base','insalubridade','gratificacao_confianca')),
  fixo            boolean not null default false,           -- repete todo mês (copiado do mês anterior)
  ordem           int not null default 0,
  situacao        text not null default 'ativo' check (situacao in ('ativo','inativo')),
  observacoes     text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists rh_eventos_codigo_uk on public.rh_eventos (upper(codigo));

-- Eventos dos recibos de 09/2026 (contábeis) + eventos das telas novas (códigos 91xx: ajuste para o
-- código da contabilidade na tela Eventos da folha) + alguns não contábeis de exemplo.
insert into public.rh_eventos (codigo, descricao, tipo, natureza, referencia_tipo, incide_inss, incide_fgts, incide_irrf, tela_exclusiva, valor_cadastro, fixo, ordem) values
  ('8781', 'DIAS NORMAIS',                     'provento', 'contabil', 'dias',       true,  true,  true,  null, 'salario_base', false, 10),
  ('16',   'INSALUBRIDADE 20%',                'provento', 'contabil', 'percentual', true,  true,  true,  null, 'insalubridade', false, 20),
  ('280',  'ADC CARGO CONFIANÇA',              'provento', 'contabil', 'percentual', true,  true,  true,  null, 'gratificacao_confianca', false, 30),
  ('150',  'HORAS EXTRAS 50%',                 'provento', 'contabil', 'horas',      true,  true,  true,  null, null, false, 40),
  ('9161', 'HORAS EXTRAS 100%',                'provento', 'contabil', 'horas',      true,  true,  true,  null, null, false, 41),
  ('8125', 'REFLEXO HORAS EXTRAS DSR',         'provento', 'contabil', 'horas',      true,  true,  true,  null, null, false, 42),
  ('306',  'ADICIONAL NOTURNO 35%',            'provento', 'contabil', 'horas',      true,  true,  true,  null, null, false, 45),
  ('854',  'REFLEXO ADIC. NOTURNO DSR',        'provento', 'contabil', 'valor',      true,  true,  true,  null, null, false, 46),
  ('8785', 'DIAS AFAST.INSS (P/DOENCA)',       'provento', 'contabil', 'dias',       false, false, false, null, null, false, 50),
  ('307',  'REEMBOLSO VALE TRANSPORTE',        'provento', 'contabil', 'valor',      false, false, false, 'vale_transporte', null, false, 60),
  ('8833', '13 ADIANTAMENTO MENSAL',           'provento', 'contabil', 'quantidade', false, true,  false, 'decimo_terceiro', null, false, 70),
  ('9131', '13º SALÁRIO 2ª PARCELA',           'provento', 'contabil', 'quantidade', true,  true,  true,  'decimo_terceiro', null, false, 71),
  ('9101', 'FÉRIAS',                           'provento', 'contabil', 'dias',       true,  true,  true,  'ferias', null, false, 80),
  ('9102', '1/3 FÉRIAS',                       'provento', 'contabil', 'valor',      true,  true,  true,  'ferias', null, false, 81),
  ('9103', 'ABONO PECUNIÁRIO',                 'provento', 'contabil', 'dias',       false, false, false, 'ferias', null, false, 82),
  ('9104', '1/3 ABONO PECUNIÁRIO',             'provento', 'contabil', 'valor',      false, false, false, 'ferias', null, false, 83),
  ('998',  'I.N.S.S.',                         'desconto', 'contabil', 'percentual', false, false, false, null, null, false, 100),
  ('999',  'IMPOSTO DE RENDA',                 'desconto', 'contabil', 'percentual', false, false, false, null, null, false, 101),
  ('981',  'DESC.ADIANT.SALARIAL',             'desconto', 'contabil', 'valor',      false, false, false, 'adiantamento', null, false, 110),
  ('9132', 'DESC. ADIANTAMENTO 13º',           'desconto', 'contabil', 'valor',      false, false, false, 'decimo_terceiro', null, false, 111),
  ('217',  'VALE TRANSPORTE 6%',               'desconto', 'contabil', 'percentual', false, false, false, 'vale_transporte', null, false, 120),
  ('308',  'VALE TRANSPORTE REF. MÊS ANTERIOR','desconto', 'contabil', 'valor',      false, false, false, 'vale_transporte', null, false, 121),
  ('9151', 'FALTAS',                           'desconto', 'contabil', 'dias',       true,  true,  true,  'faltas', null, false, 130),
  ('9152', 'DSR SOBRE FALTAS',                 'desconto', 'contabil', 'dias',       true,  true,  true,  'faltas', null, false, 131),
  ('8069', 'ATRASOS / SAIDAS ANTECIPADAS',     'desconto', 'contabil', 'horas',      true,  true,  true,  null, null, false, 132),
  ('8801', 'DESCONTO DIAS AFASTADOS',          'desconto', 'contabil', 'dias',       false, false, false, null, null, false, 135),
  ('276',  'OUTROS DESCONTOS',                 'desconto', 'contabil', 'valor',      false, false, false, null, null, false, 140),
  ('292',  'DESC. EMP. CRED. TRAB (1)',        'desconto', 'contabil', 'valor',      false, false, false, null, null, true, 150),
  ('294',  'DESC. EMP. CRED. TRAB (2)',        'desconto', 'contabil', 'valor',      false, false, false, null, null, true, 151),
  ('296',  'DESC. EMP. CRED. TRAB (3)',        'desconto', 'contabil', 'valor',      false, false, false, null, null, true, 152),
  ('9750', 'DESC. EMP. CRED. TRAB (4)',        'desconto', 'contabil', 'valor',      false, false, false, null, null, true, 153),
  ('N001', 'PRÊMIO ASSIDUIDADE',               'provento', 'nao_contabil', 'valor',  false, false, false, null, null, false, 500),
  ('N002', 'HORAS EXTRAS (NÃO CONTÁBIL)',      'provento', 'nao_contabil', 'horas',  false, false, false, null, null, false, 510),
  ('N003', 'GRATIFICAÇÃO (NÃO CONTÁBIL)',      'provento', 'nao_contabil', 'valor',  false, false, false, null, null, false, 520),
  ('N101', 'DESCONTOS DIVERSOS (NÃO CONTÁBIL)','desconto', 'nao_contabil', 'valor',  false, false, false, null, null, false, 600)
on conflict ((upper(codigo))) do nothing;

-- ---------- COMPETÊNCIAS (fechamento do mês por empresa) ----------
create table if not exists public.rh_competencias (
  empresa_id   int  not null references public.empresas(id),
  competencia  date not null check (extract(day from competencia) = 1),
  situacao     text not null default 'aberta' check (situacao in ('aberta','fechada')),
  fechado_em   timestamptz,
  fechado_por  uuid references public.usuarios(id),
  primary key (empresa_id, competencia)
);

create or replace function public.rh_competencia_fechada(p_funcionario bigint, p_competencia date)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from rh_competencias c join funcionarios f on f.empresa_id = c.empresa_id
                 where f.id = p_funcionario and c.competencia = p_competencia and c.situacao = 'fechada')
$$;

create or replace function public.rh_fechar_competencia(p_empresa int, p_competencia date, p_fechar boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.pode_acao('lancamentos.fechar') then raise exception 'Sem permissão para fechar/reabrir a competência'; end if;
  insert into rh_competencias (empresa_id, competencia, situacao, fechado_em, fechado_por)
  values (p_empresa, date_trunc('month', p_competencia)::date, case when p_fechar then 'fechada' else 'aberta' end, now(), auth.uid())
  on conflict (empresa_id, competencia) do update
    set situacao = excluded.situacao, fechado_em = excluded.fechado_em, fechado_por = excluded.fechado_por;
end $$;

-- ---------- LANÇAMENTOS ----------
create table if not exists public.rh_lancamentos (
  id             bigserial primary key,
  funcionario_id bigint not null references public.funcionarios(id),
  empresa_id     int references public.empresas(id),          -- copiado do funcionário
  competencia    date not null check (extract(day from competencia) = 1),
  evento_id      bigint not null references public.rh_eventos(id),
  referencia     numeric(12,2),
  valor          numeric(12,2) not null check (valor >= 0),
  origem         text not null default 'lancamentos',         -- tela que gerou: lancamentos, adiantamento, ferias…
  origem_id      bigint,                                      -- registro da tela de origem
  observacao     text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create index if not exists rh_lancamentos_comp_idx on public.rh_lancamentos (competencia, funcionario_id);
create index if not exists rh_lancamentos_origem_idx on public.rh_lancamentos (origem, origem_id);

-- Copia a empresa do funcionário (para o seletor de empresa e o fechamento)
create or replace function public.rh_empresa_do_funcionario()
returns trigger language plpgsql set search_path = public as $$
begin
  new.empresa_id := (select empresa_id from funcionarios where id = new.funcionario_id);
  return new;
end $$;

-- Regras do lançamento: competência fechada e evento de tela exclusiva
create or replace function public.rh_lancamento_regras()
returns trigger language plpgsql set search_path = public as $$
declare ev record; v_tela text;
begin
  if tg_op in ('UPDATE','DELETE') and public.rh_competencia_fechada(old.funcionario_id, old.competencia) then
    raise exception 'Competência %/% fechada: reabra para alterar', to_char(old.competencia, 'MM'), to_char(old.competencia, 'YYYY');
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if public.rh_competencia_fechada(new.funcionario_id, new.competencia) then
    raise exception 'Competência %/% fechada: reabra para lançar', to_char(new.competencia, 'MM'), to_char(new.competencia, 'YYYY');
  end if;
  select * into ev from rh_eventos where id = new.evento_id;
  if ev.tela_exclusiva is not null and new.origem is distinct from ev.tela_exclusiva then
    select nome into v_tela from modulos where id = ev.tela_exclusiva;
    raise exception 'O evento % - % só é lançado na tela %', ev.codigo, ev.descricao, coalesce(v_tela, ev.tela_exclusiva);
  end if;
  if tg_op = 'INSERT' and ev.situacao = 'inativo' then
    raise exception 'Evento % está inativo', ev.codigo;
  end if;
  return new;
end $$;

-- Gera (ou refaz) os lançamentos de um registro de outra tela.
-- p_itens: [{"codigo":"981","referencia":1400,"valor":1400,"observacao":"…"}] — valor zero/vazio não entra.
create or replace function public.rh_gerar_lancamentos(p_origem text, p_origem_id bigint, p_funcionario bigint, p_competencia date, p_itens jsonb)
returns void language plpgsql set search_path = public as $$
declare it jsonb; v_ev bigint;
begin
  delete from rh_lancamentos where origem = p_origem and origem_id = p_origem_id;
  if p_competencia is null or p_itens is null then return; end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    if coalesce((it->>'valor')::numeric, 0) <= 0 then continue; end if;
    select id into v_ev from rh_eventos where upper(codigo) = upper(it->>'codigo');
    if v_ev is null then raise exception 'Evento % não cadastrado (tela Eventos da folha)', it->>'codigo'; end if;
    insert into rh_lancamentos (funcionario_id, competencia, evento_id, referencia, valor, origem, origem_id, observacao)
    values (p_funcionario, date_trunc('month', p_competencia)::date, v_ev, (it->>'referencia')::numeric,
            round((it->>'valor')::numeric, 2), p_origem, p_origem_id, it->>'observacao');
  end loop;
end $$;

-- Salário/hora e salário/dia do funcionário (base dos descontos e horas extras)
create or replace function public.rh_valor_hora(p_funcionario bigint)
returns numeric language sql stable set search_path = public as $$
  select coalesce(salario_base, 0) / nullif(coalesce(horas_mensais, 220), 0) from funcionarios where id = p_funcionario
$$;
create or replace function public.rh_valor_dia(p_funcionario bigint)
returns numeric language sql stable set search_path = public as $$
  select coalesce(salario_base, 0) / 30 from funcionarios where id = p_funcionario
$$;

-- ---------- CONFERÊNCIA DO HOLERITE COM A CONTABILIDADE ----------
create table if not exists public.rh_holerite_conferencia (
  funcionario_id        bigint not null references public.funcionarios(id),
  competencia           date not null check (extract(day from competencia) = 1),
  liquido_contabilidade numeric(12,2),
  conferido             boolean not null default false,
  observacao            text,
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id) default auth.uid(),
  primary key (funcionario_id, competencia)
);

-- ---------- ADIANTAMENTO SALARIAL ----------
create table if not exists public.rh_adiantamentos (
  id             bigserial primary key,
  funcionario_id bigint not null references public.funcionarios(id),
  empresa_id     int references public.empresas(id),
  competencia    date not null check (extract(day from competencia) = 1),
  percentual     numeric(5,2),                                  -- % do salário (informativo)
  valor          numeric(12,2) not null check (valor >= 0),
  data_pagamento date,
  situacao       text not null default 'previsto' check (situacao in ('previsto','pago','cancelado')),
  observacao     text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists rh_adiantamentos_uk on public.rh_adiantamentos (funcionario_id, competencia) where situacao <> 'cancelado';

create or replace function public.rh_adiantamento_lancar()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then perform public.rh_gerar_lancamentos('adiantamento', old.id, old.funcionario_id, null, null); return old; end if;
  perform public.rh_gerar_lancamentos('adiantamento', new.id, new.funcionario_id,
    case when new.situacao <> 'cancelado' then new.competencia end,
    jsonb_build_array(jsonb_build_object('codigo', '981', 'referencia', new.valor, 'valor', new.valor)));
  return new;
end $$;

-- ---------- FÉRIAS ----------
create table if not exists public.rh_ferias (
  id                 bigserial primary key,
  funcionario_id     bigint not null references public.funcionarios(id),
  empresa_id         int references public.empresas(id),
  aquisitivo_inicio  date,
  aquisitivo_fim     date,
  gozo_inicio        date not null,
  dias               int  not null default 30 check (dias between 1 and 30),
  gozo_fim           date,                                       -- calculado
  abono_dias         int  not null default 0 check (abono_dias between 0 and 10),
  data_pagamento     date,
  competencia        date check (competencia is null or extract(day from competencia) = 1),  -- folha onde entra
  valor_ferias       numeric(12,2),
  valor_terco        numeric(12,2),
  valor_abono        numeric(12,2),
  valor_terco_abono  numeric(12,2),
  situacao           text not null default 'programada' check (situacao in ('programada','confirmada','cancelada','historico')),  -- histórico = tiradas antes do sistema (sem folha)
  observacao         text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);

create or replace function public.rh_ferias_calcular()
returns trigger language plpgsql set search_path = public as $$
declare v_dia numeric := public.rh_valor_dia(new.funcionario_id);
begin
  new.gozo_fim := new.gozo_inicio + new.dias - 1;
  -- Valores em branco: calculados pelo salário base (salário/30 por dia + 1/3). Digitados: ficam.
  new.valor_ferias      := coalesce(new.valor_ferias, round(v_dia * new.dias, 2));
  new.valor_terco       := coalesce(new.valor_terco, round(new.valor_ferias / 3, 2));
  new.valor_abono       := coalesce(new.valor_abono, round(v_dia * new.abono_dias, 2));
  new.valor_terco_abono := coalesce(new.valor_terco_abono, round(new.valor_abono / 3, 2));
  if new.competencia is null then new.competencia := date_trunc('month', new.gozo_inicio)::date; end if;
  return new;
end $$;

create or replace function public.rh_ferias_lancar()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then perform public.rh_gerar_lancamentos('ferias', old.id, old.funcionario_id, null, null); return old; end if;
  perform public.rh_gerar_lancamentos('ferias', new.id, new.funcionario_id,
    case when new.situacao in ('programada','confirmada') then new.competencia end,
    jsonb_build_array(
      jsonb_build_object('codigo', '9101', 'referencia', new.dias, 'valor', new.valor_ferias),
      jsonb_build_object('codigo', '9102', 'valor', new.valor_terco),
      jsonb_build_object('codigo', '9103', 'referencia', new.abono_dias, 'valor', new.valor_abono),
      jsonb_build_object('codigo', '9104', 'valor', new.valor_terco_abono)));
  return new;
end $$;

-- ---------- VALE-TRANSPORTE ----------
create table if not exists public.rh_vale_transporte (
  id               bigserial primary key,
  funcionario_id   bigint not null references public.funcionarios(id),
  empresa_id       int references public.empresas(id),
  competencia      date not null check (extract(day from competencia) = 1),
  dias             int not null default 0 check (dias >= 0),
  faltas           int not null default 0 check (faltas >= 0),
  valor_dia        numeric(12,2) not null default 0,
  valor_total      numeric(12,2),                               -- (dias - faltas) × valor/dia
  desconto         numeric(12,2),                               -- 6% do salário, limitado ao total
  reembolso        numeric(12,2),                               -- devolução ao funcionário (evento 307)
  desconto_anterior numeric(12,2),                              -- acerto do mês anterior (evento 308)
  situacao         text not null default 'previsto' check (situacao in ('previsto','entregue','cancelado')),
  observacao       text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists rh_vale_transporte_uk on public.rh_vale_transporte (funcionario_id, competencia) where situacao <> 'cancelado';

create or replace function public.rh_vt_calcular()
returns trigger language plpgsql set search_path = public as $$
declare v_sal numeric := (select coalesce(salario_base, 0) from funcionarios where id = new.funcionario_id);
begin
  new.valor_total := round(greatest(new.dias - new.faltas, 0) * new.valor_dia, 2);
  if new.desconto is null or tg_op = 'UPDATE' and (new.valor_total, new.funcionario_id) is distinct from (old.valor_total, old.funcionario_id) and new.desconto is not distinct from old.desconto then
    new.desconto := round(least(v_sal * 0.06, new.valor_total), 2);
  end if;
  return new;
end $$;

create or replace function public.rh_vt_lancar()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then perform public.rh_gerar_lancamentos('vale_transporte', old.id, old.funcionario_id, null, null); return old; end if;
  perform public.rh_gerar_lancamentos('vale_transporte', new.id, new.funcionario_id,
    case when new.situacao <> 'cancelado' then new.competencia end,
    jsonb_build_array(
      jsonb_build_object('codigo', '217', 'referencia', 6, 'valor', new.desconto),
      jsonb_build_object('codigo', '307', 'referencia', new.reembolso, 'valor', new.reembolso),
      jsonb_build_object('codigo', '308', 'referencia', new.desconto_anterior, 'valor', new.desconto_anterior)));
  return new;
end $$;

-- ---------- 13º SALÁRIO ----------
create table if not exists public.rh_decimo_terceiro (
  id             bigserial primary key,
  funcionario_id bigint not null references public.funcionarios(id),
  empresa_id     int references public.empresas(id),
  ano            int  not null,
  parcela        text not null check (parcela in ('1','2')),       -- 1 = adiantamento (pode ser mensal); 2 = parcela final
  avos           int  not null default 12 check (avos between 0 and 12),
  base           numeric(12,2),                                    -- salário + médias usado no cálculo
  valor          numeric(12,2),                                    -- 1ª: valor pago · 2ª: 13º integral (bruto)
  desconto_adiantado numeric(12,2),                                -- 2ª: soma das 1ªs do ano (calculado)
  competencia    date not null check (extract(day from competencia) = 1),
  data_pagamento date,
  situacao       text not null default 'previsto' check (situacao in ('previsto','pago','cancelado')),
  observacao     text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);

create or replace function public.rh_13_calcular()
returns trigger language plpgsql set search_path = public as $$
begin
  new.base := coalesce(new.base, (select salario_base from funcionarios where id = new.funcionario_id));
  if new.valor is null then
    new.valor := round(coalesce(new.base, 0) * new.avos / 12 * case when new.parcela = '1' then 0.5 else 1 end, 2);
  end if;
  if new.parcela = '2' then
    new.desconto_adiantado := (select coalesce(sum(valor), 0) from rh_decimo_terceiro
      where funcionario_id = new.funcionario_id and ano = new.ano and parcela = '1' and situacao <> 'cancelado' and id is distinct from new.id);
  else
    new.desconto_adiantado := null;
  end if;
  return new;
end $$;

create or replace function public.rh_13_lancar()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then perform public.rh_gerar_lancamentos('decimo_terceiro', old.id, old.funcionario_id, null, null); return old; end if;
  perform public.rh_gerar_lancamentos('decimo_terceiro', new.id, new.funcionario_id,
    case when new.situacao <> 'cancelado' then new.competencia end,
    case when new.parcela = '1' then jsonb_build_array(jsonb_build_object('codigo', '8833', 'referencia', new.avos, 'valor', new.valor))
    else jsonb_build_array(jsonb_build_object('codigo', '9131', 'referencia', new.avos, 'valor', new.valor),
                           jsonb_build_object('codigo', '9132', 'valor', new.desconto_adiantado)) end);
  return new;
end $$;

-- ---------- DOCUMENTOS (atestados, advertências, suspensões e outros) ----------
create table if not exists public.rh_documentos (
  id             bigserial primary key,
  funcionario_id bigint not null references public.funcionarios(id),
  empresa_id     int references public.empresas(id),
  tipo           text not null default 'atestado'
                 check (tipo in ('atestado','advertencia','suspensao','exame','declaracao','contrato','outro')),
  data           date not null default current_date,
  data_fim       date,
  dias           int,
  descricao      text,
  arquivo_path   text,                                   -- caminho no Storage (pasta rh-documentos)
  arquivo_nome   text,
  arquivo_tipo   text,
  situacao       text not null default 'ativo' check (situacao in ('ativo','cancelado')),
  observacao     text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);

-- ---------- FALTAS ----------
create table if not exists public.rh_faltas (
  id             bigserial primary key,
  funcionario_id bigint not null references public.funcionarios(id),
  empresa_id     int references public.empresas(id),
  data           date not null,
  tipo           text not null default 'injustificada'
                 check (tipo in ('injustificada','justificada','atestado','atraso','saida_antecipada','suspensao')),
  horas          numeric(5,2),                           -- vazio = dia inteiro
  desconta       boolean not null default true,          -- entra como desconto na folha
  desconta_dsr   boolean not null default false,         -- perde o DSR da semana (falta injustificada)
  documento_id   bigint references public.rh_documentos(id),
  competencia    date check (competencia is null or extract(day from competencia) = 1),
  situacao       text not null default 'ativo' check (situacao in ('ativo','cancelado')),
  observacao     text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create index if not exists rh_faltas_func_idx on public.rh_faltas (funcionario_id, data);

create or replace function public.rh_faltas_lancar()
returns trigger language plpgsql set search_path = public as $$
declare v_itens jsonb := '[]'; v_dia numeric; v_hora numeric;
begin
  if tg_op = 'DELETE' then perform public.rh_gerar_lancamentos('faltas', old.id, old.funcionario_id, null, null); return old; end if;
  v_dia := public.rh_valor_dia(new.funcionario_id); v_hora := public.rh_valor_hora(new.funcionario_id);
  if new.desconta then
    if new.horas is null then
      v_itens := v_itens || jsonb_build_object('codigo', '9151', 'referencia', 1, 'valor', round(v_dia, 2), 'observacao', to_char(new.data, 'DD/MM'));
    else
      v_itens := v_itens || jsonb_build_object('codigo', '8069', 'referencia', new.horas, 'valor', round(v_hora * new.horas, 2), 'observacao', to_char(new.data, 'DD/MM'));
    end if;
  end if;
  if new.desconta_dsr then
    v_itens := v_itens || jsonb_build_object('codigo', '9152', 'referencia', 1, 'valor', round(v_dia, 2), 'observacao', 'DSR ' || to_char(new.data, 'DD/MM'));
  end if;
  -- 8069 não é exclusivo da tela Faltas, então o lançamento sai com origem "faltas" do mesmo jeito
  perform public.rh_gerar_lancamentos('faltas', new.id, new.funcionario_id,
    case when new.situacao <> 'cancelado' then coalesce(new.competencia, date_trunc('month', new.data)::date) end, v_itens);
  return new;
end $$;

-- ---------- ESCALA ----------
-- dias: {"1": {"e":"07:00","si":"11:00","vi":"12:00","s":"17:00"}, …} (1 = segunda … 7 = domingo; dia ausente = folga)
create table if not exists public.rh_escalas (
  id              bigserial primary key,
  nome            text not null,
  descricao       text,
  dias            jsonb not null default '{}',
  tolerancia_min  int not null default 10,                -- minutos por dia sem contar atraso/hora extra
  situacao        text not null default 'ativo' check (situacao in ('ativo','inativo')),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists rh_escalas_nome_uk on public.rh_escalas (upper(nome));
insert into public.rh_escalas (nome, descricao, dias)
select 'Seg a sex 07h-17h', 'Intervalo 11h-12h · 44h com sábado compensado',
  '{"1":{"e":"07:00","si":"11:00","vi":"12:00","s":"17:00"},"2":{"e":"07:00","si":"11:00","vi":"12:00","s":"17:00"},"3":{"e":"07:00","si":"11:00","vi":"12:00","s":"17:00"},"4":{"e":"07:00","si":"11:00","vi":"12:00","s":"17:00"},"5":{"e":"07:00","si":"11:00","vi":"12:00","s":"16:00"}}'::jsonb
where not exists (select 1 from public.rh_escalas);

do $$ begin
  alter table public.funcionarios add constraint funcionarios_escala_fk foreign key (escala_id) references public.rh_escalas(id);
exception when duplicate_object then null; end $$;

-- Dia diferente da escala: folga, dia trabalhado extra, feriado (funcionário vazio = todos da empresa)
create table if not exists public.rh_escala_excecoes (
  id             bigserial primary key,
  empresa_id     int references public.empresas(id),
  funcionario_id bigint references public.funcionarios(id),
  data           date not null,
  tipo           text not null check (tipo in ('folga','trabalho','feriado','compensacao')),
  entrada        time, saida_intervalo time, volta_intervalo time, saida time,
  observacao     text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists rh_escala_excecoes_uk on public.rh_escala_excecoes (coalesce(funcionario_id, 0), coalesce(empresa_id, 0), data);

create or replace function public.rh_excecao_empresa()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.funcionario_id is not null then new.empresa_id := (select empresa_id from funcionarios where id = new.funcionario_id); end if;
  return new;
end $$;

-- ---------- PONTO ----------
create table if not exists public.rh_marcacoes (
  id             bigserial primary key,
  funcionario_id bigint not null references public.funcionarios(id),
  empresa_id     int references public.empresas(id),
  data           date not null,                           -- dia de trabalho (horário de Brasília)
  hora           time not null,
  origem         text not null default 'relogio' check (origem in ('relogio','manual')),
  nsr            text,                                    -- nº sequencial do registro no relógio
  arquivo        text,
  desconsiderada boolean not null default false,
  motivo         text,                                    -- obrigatório para marcação manual/desconsiderada
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists rh_marcacoes_uk on public.rh_marcacoes (funcionario_id, data, hora);

-- Fechamento do ponto no mês: o que vai para a folha
create table if not exists public.rh_ponto_fechamentos (
  id               bigserial primary key,
  funcionario_id   bigint not null references public.funcionarios(id),
  empresa_id       int references public.empresas(id),
  competencia      date not null check (extract(day from competencia) = 1),
  horas_trabalhadas numeric(7,2),
  horas_previstas  numeric(7,2),
  he50_horas       numeric(7,2) not null default 0,
  he100_horas      numeric(7,2) not null default 0,
  atraso_horas     numeric(7,2) not null default 0,
  faltas_dias      int not null default 0,                 -- informativo: faltas vão pela tela Faltas
  observacao       text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id),
  unique (funcionario_id, competencia)
);

create or replace function public.rh_ponto_lancar()
returns trigger language plpgsql set search_path = public as $$
declare v_hora numeric;
begin
  if tg_op = 'DELETE' then perform public.rh_gerar_lancamentos('ponto', old.id, old.funcionario_id, null, null); return old; end if;
  v_hora := public.rh_valor_hora(new.funcionario_id);
  perform public.rh_gerar_lancamentos('ponto', new.id, new.funcionario_id, new.competencia, jsonb_build_array(
    jsonb_build_object('codigo', '150',  'referencia', new.he50_horas,   'valor', round(v_hora * 1.5 * new.he50_horas, 2)),
    jsonb_build_object('codigo', '9161', 'referencia', new.he100_horas,  'valor', round(v_hora * 2 * new.he100_horas, 2)),
    jsonb_build_object('codigo', '8069', 'referencia', new.atraso_horas, 'valor', round(v_hora * new.atraso_horas, 2))));
  return new;
end $$;

-- ---------- Gatilhos ----------
do $$ declare t text; begin
  foreach t in array array['rh_eventos','rh_lancamentos','rh_adiantamentos','rh_ferias','rh_vale_transporte','rh_decimo_terceiro',
                           'rh_documentos','rh_faltas','rh_escalas','rh_escala_excecoes','rh_marcacoes','rh_ponto_fechamentos'] loop
    execute format('create or replace trigger carimbo before insert or update on public.%I for each row execute function public.carimbo_cadastro()', t);
  end loop;
  foreach t in array array['rh_lancamentos','rh_adiantamentos','rh_ferias','rh_vale_transporte','rh_decimo_terceiro',
                           'rh_documentos','rh_faltas','rh_marcacoes','rh_ponto_fechamentos'] loop
    execute format('create or replace trigger empresa before insert or update of funcionario_id on public.%I for each row execute function public.rh_empresa_do_funcionario()', t);
  end loop;
end $$;
create or replace trigger empresa before insert or update of funcionario_id on public.rh_escala_excecoes for each row execute function public.rh_excecao_empresa();
create or replace trigger regras before insert or update or delete on public.rh_lancamentos for each row execute function public.rh_lancamento_regras();
create or replace trigger calcular before insert or update on public.rh_ferias for each row execute function public.rh_ferias_calcular();
create or replace trigger calcular before insert or update on public.rh_vale_transporte for each row execute function public.rh_vt_calcular();
create or replace trigger calcular before insert or update on public.rh_decimo_terceiro for each row execute function public.rh_13_calcular();
create or replace trigger lancar after insert or update or delete on public.rh_adiantamentos for each row execute function public.rh_adiantamento_lancar();
create or replace trigger lancar after insert or update or delete on public.rh_ferias for each row execute function public.rh_ferias_lancar();
create or replace trigger lancar after insert or update or delete on public.rh_vale_transporte for each row execute function public.rh_vt_lancar();
create or replace trigger lancar after insert or update or delete on public.rh_decimo_terceiro for each row execute function public.rh_13_lancar();
create or replace trigger lancar after insert or update or delete on public.rh_faltas for each row execute function public.rh_faltas_lancar();
create or replace trigger lancar after insert or update or delete on public.rh_ponto_fechamentos for each row execute function public.rh_ponto_lancar();

-- ---------- SEGURANÇA ----------
do $$ declare r record; begin
  for r in select * from (values
    ('rh_eventos', 'public.pode_rh()', 'public.pode(''rh_eventos'',''editar'')'),
    ('rh_competencias', 'public.pode_rh()', 'false'),                         -- só pela função de fechar
    ('rh_lancamentos', 'public.pode(''lancamentos'') or public.pode(''holerites'') or public.pode(origem)',
                       'public.pode(''lancamentos'',''editar'') and origem = ''lancamentos'' or public.pode(origem,''editar'')'),
    ('rh_holerite_conferencia', 'public.pode(''holerites'') or public.pode(''lancamentos'')', 'public.pode(''holerites'',''editar'')'),
    ('rh_adiantamentos', 'public.pode(''adiantamento'')', 'public.pode(''adiantamento'',''editar'')'),
    ('rh_ferias', 'public.pode(''ferias'')', 'public.pode(''ferias'',''editar'')'),
    ('rh_vale_transporte', 'public.pode(''vale_transporte'')', 'public.pode(''vale_transporte'',''editar'')'),
    ('rh_decimo_terceiro', 'public.pode(''decimo_terceiro'')', 'public.pode(''decimo_terceiro'',''editar'')'),
    ('rh_documentos', 'public.pode(''advertencias'') or public.pode(''faltas'')', 'public.pode(''advertencias'',''editar'') or public.pode(''faltas'',''editar'')'),
    ('rh_faltas', 'public.pode(''faltas'') or public.pode(''ponto'')', 'public.pode(''faltas'',''editar'') or public.pode(''ponto'',''editar'')'),
    ('rh_escalas', 'public.pode_rh()', 'public.pode(''escala'',''editar'')'),
    ('rh_escala_excecoes', 'public.pode_rh()', 'public.pode(''escala'',''editar'')'),
    ('rh_marcacoes', 'public.pode(''ponto'')', 'public.pode(''ponto'',''editar'')'),
    ('rh_ponto_fechamentos', 'public.pode(''ponto'') or public.pode(''lancamentos'')', 'public.pode(''ponto'',''editar'')')
  ) v(tabela, ver, editar) loop
    execute format('alter table public.%I enable row level security', r.tabela);
    if not exists (select 1 from pg_policies where tablename = r.tabela and policyname = 'ver ' || r.tabela) then
      execute format('create policy %I on public.%I for select to authenticated using (%s)', 'ver ' || r.tabela, r.tabela, r.ver);
    end if;
    if not exists (select 1 from pg_policies where tablename = r.tabela and policyname = 'incluir ' || r.tabela) then
      execute format('create policy %I on public.%I for insert to authenticated with check (%s)', 'incluir ' || r.tabela, r.tabela, r.editar);
    end if;
    if not exists (select 1 from pg_policies where tablename = r.tabela and policyname = 'alterar ' || r.tabela) then
      execute format('create policy %I on public.%I for update to authenticated using (%s) with check (%s)', 'alterar ' || r.tabela, r.tabela, r.editar, r.editar);
    end if;
  end loop;
end $$;
-- Lançamentos, marcações, exceções da escala e fechamentos do ponto podem ser apagados (fica na auditoria).
-- Os demais (adiantamento, férias, VT, 13º, faltas, documentos) se cancelam.
do $$ declare r record; begin
  for r in select * from (values
    ('rh_lancamentos', 'public.pode(''lancamentos'',''editar'') and origem = ''lancamentos'' or public.pode(origem,''editar'')'),
    ('rh_marcacoes', 'public.pode(''ponto'',''editar'')'),
    ('rh_ponto_fechamentos', 'public.pode(''ponto'',''editar'')'),
    ('rh_escala_excecoes', 'public.pode(''escala'',''editar'')')
  ) v(tabela, regra) loop
    if not exists (select 1 from pg_policies where tablename = r.tabela and policyname = 'apagar ' || r.tabela) then
      execute format('create policy %I on public.%I for delete to authenticated using (%s)', 'apagar ' || r.tabela, r.tabela, r.regra);
    end if;
  end loop;
end $$;

grant select, insert, update on public.rh_eventos, public.rh_adiantamentos, public.rh_ferias, public.rh_vale_transporte,
  public.rh_decimo_terceiro, public.rh_documentos, public.rh_faltas, public.rh_escalas, public.rh_holerite_conferencia to authenticated;
grant select on public.rh_competencias to authenticated;
grant select, insert, update, delete on public.rh_lancamentos, public.rh_marcacoes, public.rh_ponto_fechamentos, public.rh_escala_excecoes to authenticated;
grant usage, select on all sequences in schema public to authenticated;

revoke execute on function public.rh_empresa_do_funcionario(), public.rh_lancamento_regras(), public.rh_adiantamento_lancar(),
  public.rh_ferias_calcular(), public.rh_ferias_lancar(), public.rh_vt_calcular(), public.rh_vt_lancar(), public.rh_13_calcular(),
  public.rh_13_lancar(), public.rh_faltas_lancar(), public.rh_excecao_empresa(), public.rh_ponto_lancar() from public, anon, authenticated;
-- rh_gerar_lancamentos roda com o usuário logado (as regras de acesso valem): os gatilhos das telas a chamam
revoke execute on function public.rh_competencia_fechada(bigint, date), public.rh_fechar_competencia(int, date, boolean),
  public.rh_valor_hora(bigint), public.rh_valor_dia(bigint), public.rh_gerar_lancamentos(text, bigint, bigint, date, jsonb) from public, anon;
grant execute on function public.rh_competencia_fechada(bigint, date), public.rh_fechar_competencia(int, date, boolean),
  public.rh_valor_hora(bigint), public.rh_valor_dia(bigint), public.rh_gerar_lancamentos(text, bigint, bigint, date, jsonb) to authenticated;

-- ---------- ANEXOS (Storage privado) ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('rh-documentos', 'rh-documentos', false, 10485760)
on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'rh documentos ver') then
    create policy "rh documentos ver" on storage.objects for select to authenticated
      using (bucket_id = 'rh-documentos' and (public.pode('advertencias') or public.pode('faltas')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'rh documentos enviar') then
    create policy "rh documentos enviar" on storage.objects for insert to authenticated
      with check (bucket_id = 'rh-documentos' and (public.pode('advertencias','editar') or public.pode('faltas','editar')));
  end if;
end $$;

-- ---------- AUDITORIA ----------
select public.ligar_auditoria(t) from unnest(array['rh_eventos','rh_competencias','rh_lancamentos','rh_holerite_conferencia',
  'rh_adiantamentos','rh_ferias','rh_vale_transporte','rh_decimo_terceiro','rh_documentos','rh_faltas','rh_escalas',
  'rh_escala_excecoes','rh_marcacoes','rh_ponto_fechamentos']) t;
