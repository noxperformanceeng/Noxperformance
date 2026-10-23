-- =====================================================================
-- 039 · RH → Financeiro
--  Adiantamento salarial, vale-transporte e 13º seguem o mesmo caminho:
--   previsto  → só na tela (não vai para lançamentos nem para o financeiro)
--   confirmado→ gera os eventos na tela Lançamentos e o título no Contas a pagar
--   pago      → marcado sozinho quando o financeiro paga o título
--   cancelado → eventos saem; título sai se ainda não foi pago (pago: estornar no financeiro antes)
--  Vale-transporte: o valor da compra do VT vai para o financeiro; na folha entra só o desconto
--  (6% / acerto do mês anterior) e o reembolso, como já era.
--  Projeções do Tiny (salário, adiantamento, prêmio… em aberto para os próximos meses) ficam
--  marcadas como projeção e saem quando o RH gera o título real daquela categoria/mês.
-- =====================================================================

-- ---------- Contas a pagar: título vindo do RH ----------
alter table public.titulos_pagar add column if not exists funcionario_id bigint references public.funcionarios(id);
create index if not exists titulos_pagar_func_idx on public.titulos_pagar (funcionario_id) where funcionario_id is not null;
create unique index if not exists titulos_pagar_rh_uk on public.titulos_pagar ((origem_ref->>'origem'), ((origem_ref->>'origem_id')::bigint))
  where origem = 'rh';
alter table public.titulos_pagar drop constraint if exists titulos_pagar_origem_check;
alter table public.titulos_pagar add constraint titulos_pagar_origem_check
  check (origem in ('manual','recorrente','nf_entrada','pedido_compra','importacao','rh'));

-- RH: o "fornecedor" é o colaborador
create or replace function public.rateio_conferir_titulo(v_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_valor numeric(14,2); v_soma numeric(14,2); v_n int; t record;
begin
  select * into t from public.titulos_pagar where id = v_id;
  if not found then return; end if;
  v_valor := t.valor;
  select count(*), coalesce(sum(valor), 0) into v_n, v_soma from public.titulos_pagar_rateio where titulo_id = v_id;
  if v_n > 0 and abs(v_soma - v_valor) > 0.005 then
    raise exception 'Rateio (R$ %) não fecha com o valor do título (R$ %)', v_soma, v_valor;
  end if;
  if t.origem not in ('importacao', 'rh') and t.situacao <> 'cancelado' then
    if t.fornecedor_id is null then raise exception 'Informe o fornecedor'; end if;
    if t.data_emissao is null then raise exception 'Informe a data de emissão'; end if;
    if t.categoria_financeira_id is null and v_n = 0 then raise exception 'Informe a categoria financeira (ou o rateio)'; end if;
  end if;
end $$;

-- ---------- Situações: entra "confirmado" ----------
alter table public.rh_adiantamentos drop constraint if exists rh_adiantamentos_situacao_check;
alter table public.rh_adiantamentos add constraint rh_adiantamentos_situacao_check check (situacao in ('previsto','confirmado','pago','cancelado'));

alter table public.rh_vale_transporte add column if not exists data_pagamento date;
alter table public.rh_vale_transporte drop constraint if exists rh_vale_transporte_situacao_check;
alter table public.rh_vale_transporte add constraint rh_vale_transporte_situacao_check check (situacao in ('previsto','confirmado','entregue','cancelado'));

alter table public.rh_decimo_terceiro drop constraint if exists rh_decimo_terceiro_situacao_check;
alter table public.rh_decimo_terceiro add constraint rh_decimo_terceiro_situacao_check check (situacao in ('previsto','confirmado','pago','cancelado'));

-- ---------- Título do RH no contas a pagar (cria, atualiza ou tira) ----------
create or replace function public.rh_titulo_sincronizar(p_origem text, p_origem_id bigint, p_ativo boolean, p_funcionario bigint,
  p_valor numeric, p_vencimento date, p_competencia date, p_categoria_codigo text, p_descricao text)
returns void language plpgsql security definer set search_path = public as $$
declare t record; f record; v_cat bigint; v_pago numeric;
begin
  -- chamada pelas telas do RH (gatilhos); direto só quem edita alguma tela do RH
  if pg_trigger_depth() = 0 and auth.uid() is not null and not public.pode_rh('editar') then raise exception 'Sem permissão'; end if;
  select * into t from titulos_pagar where origem = 'rh' and origem_ref->>'origem' = p_origem and (origem_ref->>'origem_id')::bigint = p_origem_id;
  if found then
    select coalesce(sum(valor), 0) into v_pago from pagamentos where titulo_id = t.id and not estornado;
  end if;

  if not p_ativo or coalesce(p_valor, 0) <= 0 then
    if t.id is null then return; end if;
    if v_pago > 0 then raise exception 'O título deste lançamento já foi pago no financeiro (Contas a pagar #%). Estorne o pagamento lá antes de mudar aqui.', t.id; end if;
    delete from titulos_pagar_rateio where titulo_id = t.id;
    delete from titulos_pagar where id = t.id;
    return;
  end if;

  select id, nome, empresa_id into f from funcionarios where id = p_funcionario;
  select id into v_cat from categorias_financeiras where codigo = p_categoria_codigo;

  if t.id is null then
    insert into titulos_pagar (empresa_id, funcionario_id, descricao, documento, categoria_financeira_id, valor, data_emissao,
                               data_vencimento, origem, origem_ref, observacoes)
    values (f.empresa_id, f.id, p_descricao || ' · ' || f.nome, 'RH ' || to_char(p_competencia, 'MM/YYYY'), v_cat, round(p_valor, 2),
            p_competencia, coalesce(p_vencimento, p_competencia), 'rh',
            jsonb_build_object('sistema', 'rh', 'origem', p_origem, 'origem_id', p_origem_id, 'competencia', p_competencia),
            'Gerado pelo RH (' || p_descricao || '). Para mudar valor ou data, altere na tela do RH.');
    -- a projeção do Tiny desta categoria/mês sai: agora existe o lançamento real
    with proj as (
      delete from titulos_pagar p
       where p.projecao and p.situacao = 'aberto' and p.empresa_id = f.empresa_id and p.categoria_financeira_id = v_cat
         and p.origem_ref->>'sistema' = 'tiny'
         and date_trunc('month', p.data_vencimento) = date_trunc('month', coalesce(p_vencimento, p_competencia))
         and not exists (select 1 from pagamentos g where g.titulo_id = p.id)
      returning p.origem_ref->>'bruto_id' bruto)
    update tiny_brutos b set resultado = 'projecao_substituida_pelo_rh' from proj where b.id = proj.bruto::bigint;
  elsif v_pago > 0 then
    -- já pago: só o valor importa (a data de pagamento vem do financeiro)
    if t.valor <> round(p_valor, 2) then
      raise exception 'O título deste lançamento já foi pago no financeiro (Contas a pagar #%). Estorne o pagamento lá antes de mudar aqui.', t.id;
    end if;
  elsif (t.valor, t.data_vencimento, t.empresa_id) is distinct from (round(p_valor, 2), coalesce(p_vencimento, p_competencia), f.empresa_id) then
    update titulos_pagar set valor = round(p_valor, 2), data_vencimento = coalesce(p_vencimento, p_competencia), empresa_id = f.empresa_id,
           funcionario_id = f.id, descricao = p_descricao || ' · ' || f.nome, data_emissao = p_competencia
     where id = t.id;
  end if;
end $$;
revoke execute on function public.rh_titulo_sincronizar(text, bigint, boolean, bigint, numeric, date, date, text, text) from public, anon;
grant execute on function public.rh_titulo_sincronizar(text, bigint, boolean, bigint, numeric, date, date, text, text) to authenticated;

-- ---------- Adiantamento ----------
create or replace function public.rh_adiantamento_lancar()
returns trigger language plpgsql set search_path = public as $$
declare v_ok boolean; v_mesmo boolean;
begin
  if tg_op = 'DELETE' then
    perform public.rh_titulo_sincronizar('adiantamento', old.id, false, old.funcionario_id, 0, null, old.competencia, '5.01.002', '');
    perform public.rh_gerar_lancamentos('adiantamento', old.id, old.funcionario_id, null, null); return old;
  end if;
  v_ok := new.situacao in ('confirmado', 'pago');
  -- só mudou de confirmado para pago (financeiro pagou): eventos continuam iguais
  v_mesmo := tg_op = 'UPDATE' and v_ok and old.situacao in ('confirmado', 'pago') and (new.valor, new.competencia, new.funcionario_id) is not distinct from (old.valor, old.competencia, old.funcionario_id);
  if not v_mesmo then perform public.rh_gerar_lancamentos('adiantamento', new.id, new.funcionario_id,
    case when v_ok then new.competencia end,
    jsonb_build_array(jsonb_build_object('codigo', '981', 'referencia', new.valor, 'valor', new.valor))); end if;
  perform public.rh_titulo_sincronizar('adiantamento', new.id, v_ok, new.funcionario_id, new.valor,
    coalesce(new.data_pagamento, new.competencia + 19), new.competencia, '5.01.002',
    'Adiantamento salarial ' || to_char(new.competencia, 'MM/YYYY'));
  return new;
end $$;

-- ---------- Vale-transporte ----------
create or replace function public.rh_vt_lancar()
returns trigger language plpgsql set search_path = public as $$
declare v_ok boolean; v_mesmo boolean;
begin
  if tg_op = 'DELETE' then
    perform public.rh_titulo_sincronizar('vale_transporte', old.id, false, old.funcionario_id, 0, null, old.competencia, '5.02.005', '');
    perform public.rh_gerar_lancamentos('vale_transporte', old.id, old.funcionario_id, null, null); return old;
  end if;
  v_ok := new.situacao in ('confirmado', 'entregue');
  -- só mudou de confirmado para pago (financeiro pagou): eventos continuam iguais
  v_mesmo := tg_op = 'UPDATE' and v_ok and old.situacao in ('confirmado', 'entregue') and (new.desconto, new.reembolso, new.desconto_anterior, new.competencia, new.funcionario_id) is not distinct from (old.desconto, old.reembolso, old.desconto_anterior, old.competencia, old.funcionario_id);
  if not v_mesmo then perform public.rh_gerar_lancamentos('vale_transporte', new.id, new.funcionario_id,
    case when v_ok then new.competencia end,
    jsonb_build_array(
      jsonb_build_object('codigo', '217', 'referencia', 6, 'valor', new.desconto),
      jsonb_build_object('codigo', '307', 'referencia', new.reembolso, 'valor', new.reembolso),
      jsonb_build_object('codigo', '308', 'referencia', new.desconto_anterior, 'valor', new.desconto_anterior))); end if;
  perform public.rh_titulo_sincronizar('vale_transporte', new.id, v_ok, new.funcionario_id, new.valor_total,
    coalesce(new.data_pagamento, new.competencia), new.competencia, '5.02.005',
    'Vale-transporte ' || to_char(new.competencia, 'MM/YYYY'));
  return new;
end $$;

-- ---------- 13º ----------
create or replace function public.rh_13_lancar()
returns trigger language plpgsql set search_path = public as $$
declare v_ok boolean; v_mesmo boolean;
begin
  if tg_op = 'DELETE' then
    perform public.rh_titulo_sincronizar('decimo_terceiro', old.id, false, old.funcionario_id, 0, null, old.competencia, '5.01.001', '');
    perform public.rh_gerar_lancamentos('decimo_terceiro', old.id, old.funcionario_id, null, null); return old;
  end if;
  v_ok := new.situacao in ('confirmado', 'pago');
  -- só mudou de confirmado para pago (financeiro pagou): eventos continuam iguais
  v_mesmo := tg_op = 'UPDATE' and v_ok and old.situacao in ('confirmado', 'pago') and (new.valor, new.desconto_adiantado, new.avos, new.parcela, new.competencia, new.funcionario_id) is not distinct from (old.valor, old.desconto_adiantado, old.avos, old.parcela, old.competencia, old.funcionario_id);
  if not v_mesmo then perform public.rh_gerar_lancamentos('decimo_terceiro', new.id, new.funcionario_id,
    case when v_ok then new.competencia end,
    case when new.parcela = '1' then jsonb_build_array(jsonb_build_object('codigo', '8833', 'referencia', new.avos, 'valor', new.valor))
    else jsonb_build_array(jsonb_build_object('codigo', '9131', 'referencia', new.avos, 'valor', new.valor),
                           jsonb_build_object('codigo', '9132', 'valor', new.desconto_adiantado)) end); end if;
  -- 2ª parcela: vai para o financeiro o valor menos o que já foi adiantado (INSS/IR do 13º entram nos lançamentos/guia)
  perform public.rh_titulo_sincronizar('decimo_terceiro', new.id, v_ok, new.funcionario_id,
    coalesce(new.valor, 0) - coalesce(new.desconto_adiantado, 0),
    coalesce(new.data_pagamento, case when new.parcela = '1' then make_date(new.ano, 11, 30) else make_date(new.ano, 12, 20) end),
    new.competencia, '5.01.001', '13º salário ' || new.parcela || 'ª parcela ' || new.ano);
  return new;
end $$;

-- ---------- Financeiro pagou → a tela do RH fica "pago" ----------
create or replace function public.rh_titulo_pago()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_pago boolean := new.situacao = 'pago'; v_id bigint := (new.origem_ref->>'origem_id')::bigint;
begin
  if new.origem <> 'rh' or new.situacao is not distinct from old.situacao then return null; end if;
  case new.origem_ref->>'origem'
    when 'adiantamento' then
      update rh_adiantamentos set situacao = case when v_pago then 'pago' else 'confirmado' end,
             data_pagamento = case when v_pago then new.data_pagamento else data_pagamento end
       where id = v_id and situacao in ('confirmado', 'pago') and situacao <> case when v_pago then 'pago' else 'confirmado' end;
    when 'vale_transporte' then
      update rh_vale_transporte set situacao = case when v_pago then 'entregue' else 'confirmado' end,
             data_pagamento = case when v_pago then new.data_pagamento else data_pagamento end
       where id = v_id and situacao in ('confirmado', 'entregue') and situacao <> case when v_pago then 'entregue' else 'confirmado' end;
    when 'decimo_terceiro' then
      update rh_decimo_terceiro set situacao = case when v_pago then 'pago' else 'confirmado' end,
             data_pagamento = case when v_pago then new.data_pagamento else data_pagamento end
       where id = v_id and situacao in ('confirmado', 'pago') and situacao <> case when v_pago then 'pago' else 'confirmado' end;
    else null;
  end case;
  return null;
end $$;
drop trigger if exists rh_pago on public.titulos_pagar;
create trigger rh_pago after update of situacao on public.titulos_pagar
  for each row when (new.origem = 'rh') execute function public.rh_titulo_pago();

-- ---------- Projeções do Tiny (folha dos próximos meses) ----------
update public.titulos_pagar set projecao = true
 where origem = 'importacao' and origem_ref->>'sistema' = 'tiny' and situacao = 'aberto' and not projecao
   and data_vencimento >= date_trunc('month', current_date)
   and upper(origem_ref->>'categoria_tiny') in ('SALARIO', 'ADIANTAMENTO SALARIAL', 'PRÊMIO POR ASSIDUIDADE', 'VALE TRANSPORTE', 'FERIAS',
                                                '13° SALARIO', 'FGTS', 'INSS', 'CESTA BASICA');

-- ---------- Relatórios do RH (tela nova) ----------
insert into public.modulos (id, grupo, nome, ordem) values ('rh_relatorios', 'rh', 'Relatórios do RH', 82)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('rh', 'rh_relatorios', 'editar')
on conflict (perfil_id, modulo_id) do nothing;
