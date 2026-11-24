-- =====================================================================
-- 162 · RH: DSR e INSS automáticos, insalubridade nas extras, descontos nas férias
--  · Horas extras de quem recebe insalubridade (produção, polimento, montagem/solda) passam a
--    ser calculadas sobre salário + insalubridade. Vale para o fechamento do ponto daqui em diante
--    (atrasos continuam descontados só sobre o salário).
--  · DSR sobre horas extras (evento 8125) sai sozinho: total das extras (150 e 9161) ÷ dias úteis
--    do mês × domingos e feriados. Feriados: nacionais (inclusive Sexta-feira Santa) + os
--    cadastrados como "feriado" na tela Escala (municipais/estaduais).
--  · INSS (evento 998) sai sozinho pela tabela progressiva (faixas em rh_inss_faixas, 2025 e
--    2026 já carregadas), do mesmo jeito que a contabilidade: base × alíquota − parcela a deduzir.
--    Conferido com a folha de outubro/2026: 14 de 19 batem no centavo (os outros têm base diferente
--    no sistema). Estagiário, PJ e autônomo ficam sem INSS.
--  · Os dois são refeitos sempre que um lançamento do colaborador muda no mês (tempo real) e
--    aparecem com a origem "Cálculo automático". Se o RH lançar o 998 ou o 8125 à mão (valor da
--    contabilidade), o lançamento manual vale e o cálculo automático daquele evento sai.
--  · Só a partir da competência 11/2026 (setembro e outubro, que vieram da contabilidade, não mudam).
--  · Férias ganham "Descontos nas férias" (empréstimo consignado, INSS/previdência, IR, outros): cada
--    desconto vira lançamento da férias na competência dela. INSS descontado nas férias é abatido
--    do INSS calculado do mês (a soma do mês segue a tabela progressiva).
--  · Corrige o evento N004 ABONO ESPECIAL: estava ligado ao salário base, e o "Gerar fixos do mês"
--    lançaria um abono igual ao salário para todos. Passa a ser digitado (ou % do salário).
--  · Não apaga tabela nem coluna. Para desfazer: remover o gatilho "recalcular" de rh_lancamentos
--    e voltar rh_ponto_lancar do 032.
-- =====================================================================

-- ---------- 1. Tabela do INSS (faixas por vigência) ----------
create table if not exists public.rh_inss_faixas (
  id          bigint generated always as identity primary key,
  vigencia    date not null,                 -- vale a partir desta competência
  ate         numeric(12,2) not null,        -- limite da faixa (a última é o teto)
  aliquota    numeric(5,2) not null,         -- %
  deduzir     numeric(12,2) not null default 0,   -- parcela a deduzir da faixa
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id),
  unique (vigencia, ate)
);
create or replace trigger carimbo before insert or update on public.rh_inss_faixas for each row execute function public.carimbo_cadastro();
alter table public.rh_inss_faixas enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'rh_inss_faixas' and policyname = 'ver rh_inss_faixas') then
    create policy "ver rh_inss_faixas" on public.rh_inss_faixas for select to authenticated using ((select public.pode_rh()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'rh_inss_faixas' and policyname = 'incluir rh_inss_faixas') then
    create policy "incluir rh_inss_faixas" on public.rh_inss_faixas for insert to authenticated with check ((select public.pode('rh_eventos', 'editar')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'rh_inss_faixas' and policyname = 'alterar rh_inss_faixas') then
    create policy "alterar rh_inss_faixas" on public.rh_inss_faixas for update to authenticated
      using ((select public.pode('rh_eventos', 'editar'))) with check ((select public.pode('rh_eventos', 'editar')));
  end if;
end $$;

-- 2025: Portaria MPS/MF 6/2025 · 2026: Portaria MPS/MF 13/2026 (teto R$ 8.475,55).
-- Parcela a deduzir de 2026 como a contabilidade usa (24,32 · 111,41 · 198,50), conferida com o holerite de 10/2026.
-- Ano novo: cadastrar as faixas com a vigência 01/01 do ano.
insert into public.rh_inss_faixas (vigencia, ate, aliquota, deduzir) values
  ('2025-01-01', 1518.00, 7.5, 0), ('2025-01-01', 2793.88, 9, 22.77), ('2025-01-01', 4190.83, 12, 106.59), ('2025-01-01', 8157.41, 14, 190.40),
  ('2026-01-01', 1621.00, 7.5, 0), ('2026-01-01', 2902.84, 9, 24.32), ('2026-01-01', 4354.27, 12, 111.41), ('2026-01-01', 8475.55, 14, 198.50)
on conflict (vigencia, ate) do nothing;

-- INSS do empregado: base (limitada ao teto) × alíquota da faixa − parcela a deduzir, truncado no centavo
create or replace function public.rh_inss_calcular(p_base numeric, p_competencia date)
returns numeric language sql stable set search_path = public as $$
  with tab as (select * from rh_inss_faixas
                where vigencia = (select max(vigencia) from rh_inss_faixas where vigencia <= p_competencia)),
       b as (select least(greatest(coalesce(p_base, 0), 0), (select max(ate) from tab)) v)
  select coalesce(trunc((select b.v * t.aliquota / 100 - t.deduzir from tab t where t.ate >= b.v order by t.ate limit 1), 2), 0)
    from b
$$;

-- ---------- 2. Feriados e hora da extra ----------
-- Feriado nacional (fixos + Sexta-feira Santa) ou cadastrado na Escala para todos (da empresa ou geral)
create or replace function public.rh_feriado(p_data date, p_empresa int)
returns boolean language plpgsql stable set search_path = public as $$
declare a int := extract(year from p_data); b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int; v_pascoa date;
begin
  if to_char(p_data, 'MM-DD') in ('01-01','04-21','05-01','09-07','10-12','11-02','11-15','11-20','12-25') then return true; end if;
  -- Páscoa (algoritmo de Meeus) → Sexta-feira Santa = Páscoa − 2
  b := a / 100; c := a % 100; d := b / 4; e := b % 4; f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19 * (a % 19) + b - d - g + 15) % 30; i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7;
  m := ((a % 19) + 11 * h + 22 * l) / 451;
  v_pascoa := make_date(a, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
  if p_data = v_pascoa - 2 then return true; end if;
  return exists (select 1 from rh_escala_excecoes x where x.data = p_data and x.tipo = 'feriado' and x.funcionario_id is null
                   and (x.empresa_id is null or x.empresa_id = p_empresa));
end $$;

-- Valor da hora para horas extras: (salário + insalubridade) ÷ horas do mês
create or replace function public.rh_valor_hora_extra(p_funcionario bigint)
returns numeric language sql stable set search_path = public as $$
  select (coalesce(salario_base, 0) + coalesce(insalubridade, 0)) / nullif(coalesce(horas_mensais, 220), 0) from funcionarios where id = p_funcionario
$$;

-- Fechamento do ponto: HE 50% e 100% sobre salário + insalubridade; atraso só sobre o salário
create or replace function public.rh_ponto_lancar()
returns trigger language plpgsql set search_path = public as $$
declare v_hora numeric; v_he numeric;
begin
  if tg_op = 'DELETE' then perform public.rh_gerar_lancamentos('ponto', old.id, old.funcionario_id, null, null); return old; end if;
  v_hora := public.rh_valor_hora(new.funcionario_id);
  v_he := public.rh_valor_hora_extra(new.funcionario_id);
  perform public.rh_gerar_lancamentos('ponto', new.id, new.funcionario_id, new.competencia, jsonb_build_array(
    jsonb_build_object('codigo', '150',  'referencia', new.he50_horas,   'valor', round(v_he * 1.5 * new.he50_horas, 2)),
    jsonb_build_object('codigo', '9161', 'referencia', new.he100_horas,  'valor', round(v_he * 2 * new.he100_horas, 2)),
    jsonb_build_object('codigo', '8069', 'referencia', new.atraso_horas, 'valor', round(v_hora * new.atraso_horas, 2))));
  return new;
end $$;

-- ---------- 3. Cálculo automático: DSR sobre extras (8125) e INSS (998) ----------
insert into public.integracao_config (chave, valor) values ('folha_calculo_desde', '2026-11-01') on conflict (chave) do nothing;

create or replace function public.rh_folha_recalcular(p_funcionario bigint, p_competencia date)
returns void language plpgsql security definer set search_path = public as $$
declare v_comp date := date_trunc('month', p_competencia)::date; v_emp int; v_he numeric; v_uteis int := 0; v_dsr int := 0;
        v_val_dsr numeric := 0; v_base numeric; v_inss numeric := 0; v_aliq numeric; d date;
        v_ev_dsr bigint; v_ev_inss bigint; v_manual_dsr boolean; v_manual_inss boolean; v_inss_ferias numeric; v_atual jsonb; v_novo jsonb;
begin
  if v_comp < coalesce((select valor::date from integracao_config where chave = 'folha_calculo_desde'), '2026-11-01') then return; end if;
  if exists (select 1 from rh_competencias c join funcionarios f on f.empresa_id = c.empresa_id
              where f.id = p_funcionario and c.competencia = v_comp and c.situacao = 'fechada') then return; end if;
  select empresa_id into v_emp from funcionarios where id = p_funcionario;
  select id into v_ev_dsr from rh_eventos where codigo = '8125';
  select id into v_ev_inss from rh_eventos where codigo = '998';
  select bool_or(evento_id = v_ev_dsr), bool_or(evento_id = v_ev_inss and origem <> 'ferias'),
         coalesce(sum(valor) filter (where evento_id = v_ev_inss and origem = 'ferias'), 0)
    into v_manual_dsr, v_manual_inss, v_inss_ferias
    from rh_lancamentos where funcionario_id = p_funcionario and competencia = v_comp and origem <> 'calculo';

  -- DSR: extras ÷ dias úteis × (domingos + feriados)
  select coalesce(sum(l.valor), 0) into v_he from rh_lancamentos l join rh_eventos e on e.id = l.evento_id
   where l.funcionario_id = p_funcionario and l.competencia = v_comp and e.codigo in ('150', '9161');
  if v_he > 0 and not coalesce(v_manual_dsr, false) then
    for d in select generate_series(v_comp, (v_comp + interval '1 month - 1 day')::date, '1 day')::date loop
      if extract(isodow from d) = 7 or public.rh_feriado(d, v_emp) then v_dsr := v_dsr + 1; else v_uteis := v_uteis + 1; end if;
    end loop;
    v_val_dsr := round(v_he / nullif(v_uteis, 0) * v_dsr, 2);
  end if;

  -- INSS: base = proventos − descontos que incidem INSS (folha contábil, sem o 13º, que tem INSS próprio) + DSR novo
  if not coalesce(v_manual_inss, false)
     and coalesce((select tipo_contrato from funcionarios where id = p_funcionario), 'clt') not in ('estagio', 'pj', 'autonomo') then
    select coalesce(sum(case e.tipo when 'provento' then l.valor when 'desconto' then -l.valor else 0 end), 0) into v_base
      from rh_lancamentos l join rh_eventos e on e.id = l.evento_id
     where l.funcionario_id = p_funcionario and l.competencia = v_comp and l.origem not in ('calculo', 'decimo_terceiro')
       and e.incide_inss and e.natureza = 'contabil';
    v_base := v_base + case when (select incide_inss from rh_eventos where id = v_ev_dsr) then v_val_dsr else 0 end;
    if v_base > 0 then
      v_inss := public.rh_inss_calcular(v_base, v_comp);
      v_aliq := round(v_inss / v_base * 100, 2);
      v_inss := greatest(v_inss - v_inss_ferias, 0);            -- parte já descontada no recibo de férias
    end if;
  end if;

  -- Só regrava se mudou (não enche a auditoria nem dispara tempo real à toa)
  select coalesce(jsonb_object_agg(evento_id::text, valor), '{}') into v_atual from rh_lancamentos
   where funcionario_id = p_funcionario and competencia = v_comp and origem = 'calculo';
  v_novo := jsonb_strip_nulls(jsonb_build_object(v_ev_dsr::text, case when v_val_dsr > 0 then round(v_val_dsr, 2) end,
                                                v_ev_inss::text, case when v_inss > 0 then round(v_inss, 2) end));
  if v_atual = v_novo then return; end if;

  delete from rh_lancamentos where funcionario_id = p_funcionario and competencia = v_comp and origem = 'calculo';
  if v_val_dsr > 0 then
    insert into rh_lancamentos (funcionario_id, competencia, evento_id, referencia, valor, origem, observacao)
    values (p_funcionario, v_comp, v_ev_dsr, null, v_val_dsr, 'calculo',
            'Extras ' || to_char(v_he, 'FM999G990D00') || ' ÷ ' || v_uteis || ' dias úteis × ' || v_dsr || ' domingos/feriados');
  end if;
  if v_inss > 0 then
    insert into rh_lancamentos (funcionario_id, competencia, evento_id, referencia, valor, origem, observacao)
    values (p_funcionario, v_comp, v_ev_inss, v_aliq, v_inss, 'calculo',
            'Tabela progressiva sobre ' || to_char(v_base, 'FM999G990D00')
            || case when v_inss_ferias > 0 then ' − ' || to_char(v_inss_ferias, 'FM999G990D00') || ' já descontado nas férias' else '' end);
  end if;
end $$;
revoke execute on function public.rh_folha_recalcular(bigint, date) from public, anon, authenticated;

-- Qualquer lançamento do colaborador mudou no mês → refaz DSR e INSS dele
create or replace function public.rh_folha_recalcular_gatilho()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.origem, old.origem) = 'calculo' and (tg_op <> 'UPDATE' or old.origem = 'calculo') then return null; end if;
  if auth.uid() is not null and not public.pode_rh() then return null; end if;
  if tg_op <> 'INSERT' then perform public.rh_folha_recalcular(old.funcionario_id, old.competencia); end if;
  if tg_op <> 'DELETE' and (tg_op = 'INSERT' or (new.funcionario_id, new.competencia) is distinct from (old.funcionario_id, old.competencia)) then
    perform public.rh_folha_recalcular(new.funcionario_id, new.competencia);
  end if;
  return null;
end $$;
revoke execute on function public.rh_folha_recalcular_gatilho() from public, anon, authenticated;
create or replace trigger recalcular after insert or update or delete on public.rh_lancamentos
  for each row execute function public.rh_folha_recalcular_gatilho();

-- Botão "Recalcular DSR e INSS" na tela Lançamentos (mês inteiro de uma empresa)
create or replace function public.rh_folha_recalcular_mes(p_empresa int, p_competencia date)
returns int language plpgsql security definer set search_path = public as $$
declare f record; n int := 0;
begin
  if not public.pode('lancamentos', 'editar') then raise exception 'Sem permissão para alterar os lançamentos'; end if;
  for f in select distinct funcionario_id from rh_lancamentos
            where competencia = date_trunc('month', p_competencia)::date and (p_empresa is null or empresa_id = p_empresa) loop
    perform public.rh_folha_recalcular(f.funcionario_id, p_competencia); n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.rh_folha_recalcular_mes(int, date) from public, anon;
grant execute on function public.rh_folha_recalcular_mes(int, date) to authenticated;

-- ---------- 4. Descontos nas férias ----------
-- [{"codigo": "292", "valor": 150.00, "observacao": "parcela 3/10"}, …]
alter table public.rh_ferias add column if not exists descontos jsonb not null default '[]';

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
      jsonb_build_object('codigo', '9104', 'valor', new.valor_terco_abono))
    || coalesce((select jsonb_agg(jsonb_build_object('codigo', d->>'codigo', 'valor', (d->>'valor')::numeric, 'observacao', nullif(d->>'observacao', '')))
                   from jsonb_array_elements(coalesce(new.descontos, '[]')) d), '[]'));
  return new;
end $$;

-- ---------- 5. Abono especial (N004): não é mais o salário base ----------
update public.rh_eventos set valor_cadastro = null where codigo = 'N004' and valor_cadastro = 'salario_base';

-- ---------- 6. Auditoria e tempo real ----------
select public.ligar_auditoria('rh_inss_faixas');
select public.ligar_tempo_real('rh_inss_faixas');
