-- =====================================================================
-- 040 · Fechamento da folha → contas a pagar · quarentena · fluxo pelo saldo da conta
--  1) Fechar a competência (tela Lançamentos) gera 1 título por colaborador com o líquido do
--     5º dia útil (proventos − descontos, sem férias e 13º, que têm título próprio).
--     Reabrir tira os títulos ainda não pagos; com título pago, reabrir é bloqueado.
--  2) 13º: título próprio; 1ª parcela vence no 5º dia útil (paga junto com o salário, controlada à parte).
--  3) Contas a pagar: só o perfil Financeiro (e administradores).
--  4) Quarentena: ajustes em lote dos títulos importados (categoria, fornecedor, conta do pagamento,
--     data) e "revisado" para tirar da lista. Tudo fica na auditoria.
--  5) Fluxo de caixa: saldo inicial de cada conta vale a partir da data do saldo (movimentos antes dela
--     já estão dentro do saldo informado).
--  6) Rastreio: títulos do RH visíveis para o RH (sem abrir o contas a pagar).
-- =====================================================================

-- ---------- 5º dia útil (segunda a sábado, sem feriados nacionais fixos) ----------
create or replace function public.rh_quinto_dia_util(p_competencia date)
returns date language plpgsql immutable as $$
declare d date := (date_trunc('month', p_competencia) + interval '1 month')::date; n int := 0;
begin
  loop
    if extract(isodow from d) <> 7 and to_char(d, 'MM-DD') not in ('01-01','04-21','05-01','09-07','10-12','11-02','11-15','11-20','12-25') then
      n := n + 1;
      if n = 5 then return d; end if;
    end if;
    d := d + 1;
  end loop;
end $$;

-- ---------- Líquido do 5º dia útil de um colaborador numa competência ----------
create or replace function public.rh_liquido_quinto_dia(p_funcionario bigint, p_competencia date)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(case e.tipo when 'provento' then l.valor when 'desconto' then -l.valor else 0 end), 0)
    from rh_lancamentos l join rh_eventos e on e.id = l.evento_id
   where l.funcionario_id = p_funcionario and l.competencia = date_trunc('month', p_competencia)::date
     and l.origem not in ('ferias', 'decimo_terceiro')
$$;

-- ---------- Fechar / reabrir a competência ----------
-- Folhas antes de 'folha_titulos_desde' (integracao_config, padrão 10/2026) já foram pagas pelo Tiny:
-- fechar só trava, não gera título (evita duplicar o histórico importado).
insert into public.integracao_config (chave, valor) values ('folha_titulos_desde', '2026-10-01') on conflict (chave) do nothing;
drop function if exists public.rh_fechar_competencia(int, date, boolean);
create or replace function public.rh_fechar_competencia(p_empresa int, p_competencia date, p_fechar boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_comp date := date_trunc('month', p_competencia)::date; f record; v_liq numeric; n int := 0; v_total numeric := 0;
        negativos text[] := '{}'; v_pagos int;
        v_desde date := coalesce((select valor::date from integracao_config where chave = 'folha_titulos_desde'), '2026-10-01');
begin
  if not public.pode_acao('lancamentos.fechar') then raise exception 'Sem permissão para fechar/reabrir a competência'; end if;
  if not p_fechar then
    select count(*) into v_pagos from titulos_pagar t
     where t.origem = 'rh' and t.origem_ref->>'origem' = 'folha' and t.empresa_id = p_empresa
       and (t.origem_ref->>'competencia')::date = v_comp and t.valor_pago > 0;
    if v_pagos > 0 then
      raise exception 'A folha de % já tem % salário(s) pago(s) no financeiro. Estorne o pagamento lá antes de reabrir.', to_char(v_comp, 'MM/YYYY'), v_pagos;
    end if;
    for f in select (t.origem_ref->>'origem_id')::bigint oid, t.funcionario_id fid from titulos_pagar t
              where t.origem = 'rh' and t.origem_ref->>'origem' = 'folha' and t.empresa_id = p_empresa
                and (t.origem_ref->>'competencia')::date = v_comp loop
      perform rh_titulo_sincronizar('folha', f.oid, false, f.fid, 0, null, v_comp, '5.01.008', '');
      n := n + 1;
    end loop;
  end if;
  insert into rh_competencias (empresa_id, competencia, situacao, fechado_em, fechado_por)
  values (p_empresa, v_comp, case when p_fechar then 'fechada' else 'aberta' end, now(), auth.uid())
  on conflict (empresa_id, competencia) do update
    set situacao = excluded.situacao, fechado_em = excluded.fechado_em, fechado_por = excluded.fechado_por;
  if p_fechar and v_comp >= v_desde then
    for f in select distinct l.funcionario_id fid, fu.nome from rh_lancamentos l join funcionarios fu on fu.id = l.funcionario_id
              where l.empresa_id = p_empresa and l.competencia = v_comp loop
      v_liq := rh_liquido_quinto_dia(f.fid, v_comp);
      if v_liq < 0 then negativos := negativos || (f.nome || ' (' || v_liq || ')'); continue; end if;
      perform rh_titulo_sincronizar('folha', f.fid * 1000000 + to_char(v_comp, 'YYYYMM')::bigint, v_liq > 0, f.fid, v_liq,
        rh_quinto_dia_util(v_comp), v_comp, '5.01.008', 'Salário (líquido 5º dia útil) ' || to_char(v_comp, 'MM/YYYY'));
      if v_liq > 0 then n := n + 1; v_total := v_total + v_liq; end if;
    end loop;
  end if;
  return jsonb_build_object('fechada', p_fechar, 'titulos', n, 'total', v_total, 'vencimento', rh_quinto_dia_util(v_comp),
                            'negativos', to_jsonb(negativos), 'sem_titulos', p_fechar and v_comp < v_desde);
end $$;
revoke execute on function public.rh_fechar_competencia(int, date, boolean) from public, anon;
grant execute on function public.rh_fechar_competencia(int, date, boolean) to authenticated;

-- ---------- 13º: 1ª parcela vence com o salário (5º dia útil), 2ª em 20/12 ----------
create or replace function public.rh_13_lancar()
returns trigger language plpgsql set search_path = public as $$
declare v_ok boolean; v_mesmo boolean;
begin
  if tg_op = 'DELETE' then
    perform public.rh_titulo_sincronizar('decimo_terceiro', old.id, false, old.funcionario_id, 0, null, old.competencia, '5.01.001', '');
    perform public.rh_gerar_lancamentos('decimo_terceiro', old.id, old.funcionario_id, null, null); return old;
  end if;
  v_ok := new.situacao in ('confirmado', 'pago');
  v_mesmo := tg_op = 'UPDATE' and v_ok and old.situacao in ('confirmado', 'pago') and (new.valor, new.desconto_adiantado, new.avos, new.parcela, new.competencia, new.funcionario_id) is not distinct from (old.valor, old.desconto_adiantado, old.avos, old.parcela, old.competencia, old.funcionario_id);
  if not v_mesmo then perform public.rh_gerar_lancamentos('decimo_terceiro', new.id, new.funcionario_id,
    case when v_ok then new.competencia end,
    case when new.parcela = '1' then jsonb_build_array(jsonb_build_object('codigo', '8833', 'referencia', new.avos, 'valor', new.valor))
    else jsonb_build_array(jsonb_build_object('codigo', '9131', 'referencia', new.avos, 'valor', new.valor),
                           jsonb_build_object('codigo', '9132', 'valor', new.desconto_adiantado)) end); end if;
  perform public.rh_titulo_sincronizar('decimo_terceiro', new.id, v_ok, new.funcionario_id,
    coalesce(new.valor, 0) - coalesce(new.desconto_adiantado, 0),
    coalesce(new.data_pagamento, case when new.parcela = '1' then public.rh_quinto_dia_util(new.competencia) else make_date(new.ano, 12, 20) end),
    new.competencia, '5.01.001', '13º salário ' || new.parcela || 'ª parcela ' || new.ano);
  return new;
end $$;

-- ---------- RH vê os próprios títulos (rastreio), sem acesso ao contas a pagar ----------
create or replace function public.rh_titulos(p_competencia date default null, p_funcionario bigint default null)
returns table (titulo_id bigint, funcionario_id bigint, origem text, origem_id bigint, competencia date, descricao text,
               valor numeric, data_vencimento date, situacao text, valor_pago numeric, data_pagamento date, conciliado boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.funcionario_id, t.origem_ref->>'origem', (t.origem_ref->>'origem_id')::bigint, (t.origem_ref->>'competencia')::date,
         t.descricao, t.valor, t.data_vencimento, t.situacao, t.valor_pago, t.data_pagamento,
         coalesce((select bool_and(p.conciliado) from pagamentos p where p.titulo_id = t.id and not p.estornado), false)
    from titulos_pagar t
   where t.origem = 'rh' and (public.pode_rh() or public.pode('pagar'))
     and (p_competencia is null or (t.origem_ref->>'competencia')::date = date_trunc('month', p_competencia)::date)
     and (p_funcionario is null or t.funcionario_id = p_funcionario)
$$;
revoke execute on function public.rh_titulos(date, bigint) from public, anon;
grant execute on function public.rh_titulos(date, bigint) to authenticated;

-- ---------- Contas a pagar: só financeiro (e administradores) ----------
delete from public.permissoes where modulo_id = 'pagar' and perfil_id not in ('financeiro', 'admin');
delete from public.permissoes_usuario where modulo_id = 'pagar' and nivel <> 'nenhum';

-- ---------- Quarentena ----------
-- Alteração de título já pago vinda da quarentena (reclassificação de histórico importado)
create or replace function public.titulos_acoes()
returns trigger language plpgsql set search_path = public as $$
begin
  if (new.situacao = 'cancelado') <> (old.situacao = 'cancelado') then
    if not public.pode_acao('pagar.cancelar') then raise exception 'Sem permissão para cancelar/reabrir título (peça ao gestor)'; end if;
    if new.situacao = 'cancelado' and old.valor_pago > 0 then raise exception 'Título com pagamento não pode ser cancelado: estorne o pagamento antes'; end if;
    if new.situacao = 'cancelado' and coalesce(new.motivo_cancelamento, '') = '' then raise exception 'Informe o motivo do cancelamento'; end if;
  end if;
  if old.valor_pago > 0 and (new.empresa_id, new.fornecedor_id, new.valor, new.data_emissao, new.data_vencimento, new.categoria_financeira_id, new.documento)
     is distinct from (old.empresa_id, old.fornecedor_id, old.valor, old.data_emissao, old.data_vencimento, old.categoria_financeira_id, old.documento)
     and not public.pode_acao('pagar.editar_pago')
     and not (current_setting('nox.quarentena', true) = 'sim'
              and (new.empresa_id, new.valor, new.data_emissao, new.data_vencimento, new.documento)
                  is not distinct from (old.empresa_id, old.valor, old.data_emissao, old.data_vencimento, old.documento)) then
    raise exception 'Título já tem pagamento: alteração só com permissão do gestor';
  end if;
  return new;
end $$;

-- Lista: títulos importados com algo a revisar
create or replace view public.quarentena_pagar with (security_invoker = true) as
select t.id, t.empresa_id, t.descricao, t.documento, t.valor, t.data_vencimento, t.situacao, t.valor_pago, t.data_pagamento,
       t.categoria_financeira_id, t.fornecedor_id,
       t.origem_ref->>'fornecedor_tiny' fornecedor_tiny, t.origem_ref->>'categoria_tiny' categoria_tiny, t.origem_ref->>'tiny_id' tiny_id,
       t.categoria_financeira_id is null sem_categoria,
       t.fornecedor_id is null sem_fornecedor,
       exists (select 1 from pagamentos p join contas_bancarias c on c.id = p.conta_bancaria_id
                where p.titulo_id = t.id and not p.estornado and c.descricao like 'Pagamentos Tiny a conferir%') conta_a_conferir,
       exists (select 1 from pagamentos p where p.titulo_id = t.id and not p.estornado
                and (p.data_pagamento < date '2024-01-01' or p.data_pagamento > current_date)) data_suspeita,
       exists (select 1 from categorias_financeiras c where c.id = t.categoria_financeira_id and c.codigo like '99%') categoria_antiga,
       coalesce(t.origem_ref->'quarentena_ok', '[]'::jsonb) revisado
  from titulos_pagar t
 where t.origem = 'importacao';
grant select on public.quarentena_pagar to authenticated;

-- Ajuste em lote. p_campo: categoria | fornecedor | conta | data_pagamento | revisado
create or replace function public.quarentena_ajustar(p_titulos bigint[], p_campo text, p_valor text)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if not public.pode('pagar', 'editar') then raise exception 'Sem permissão'; end if;
  perform set_config('nox.quarentena', 'sim', true);
  if p_campo = 'categoria' then
    if not exists (select 1 from categorias_financeiras where id = p_valor::bigint and aceita_lancamento) then raise exception 'Categoria inválida'; end if;
    update titulos_pagar set categoria_financeira_id = p_valor::bigint where id = any (p_titulos) and origem = 'importacao';
  elsif p_campo = 'fornecedor' then
    update titulos_pagar set fornecedor_id = p_valor::bigint where id = any (p_titulos) and origem = 'importacao';
  elsif p_campo = 'conta' then
    update pagamentos p set conta_bancaria_id = p_valor::bigint,
           observacoes = concat_ws(' · ', p.observacoes, 'Conta ajustada na quarentena')
      from titulos_pagar t
     where p.titulo_id = t.id and t.id = any (p_titulos) and t.origem = 'importacao' and not p.estornado and not p.conciliado;
  elsif p_campo = 'data_pagamento' then
    update pagamentos p set data_pagamento = p_valor::date,
           observacoes = concat_ws(' · ', p.observacoes, 'Data ajustada na quarentena')
      from titulos_pagar t
     where p.titulo_id = t.id and t.id = any (p_titulos) and t.origem = 'importacao' and not p.estornado and not p.conciliado;
  elsif p_campo = 'revisado' then
    -- marca o motivo (sem_fornecedor, conta_a_conferir…) como revisado: sai da lista sem mudar o título
    update titulos_pagar set origem_ref = jsonb_set(coalesce(origem_ref, '{}'), '{quarentena_ok}',
           coalesce(origem_ref->'quarentena_ok', '[]'::jsonb) || to_jsonb(p_valor))
     where id = any (p_titulos) and origem = 'importacao' and not (coalesce(origem_ref->'quarentena_ok', '[]'::jsonb) ? p_valor);
  else
    raise exception 'Ajuste desconhecido: %', p_campo;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.quarentena_ajustar(bigint[], text, text) from public, anon;
grant execute on function public.quarentena_ajustar(bigint[], text, text) to authenticated;

insert into public.modulos (id, grupo, nome, ordem) values ('quarentena', 'financeiro', 'Quarentena das importações', 65)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('financeiro', 'quarentena', 'editar')
on conflict (perfil_id, modulo_id) do nothing;

-- ---------- Fluxo de caixa: saldo inicial pela data do saldo de cada conta ----------
create or replace function public.fluxo_caixa(p_de date, p_ate date, p_empresa integer default null, p_conta bigint default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_juros bigint; v_res jsonb;
begin
  if not (public.pode('fluxo') or public.pode('pagar') and public.pode('receber')) then raise exception 'Sem acesso ao fluxo de caixa'; end if;
  select id into v_juros from public.categorias_financeiras where codigo = '7.02.006';
  with
  cb as (select id, empresa_id, saldo_inicial, data_saldo_inicial from public.contas_bancarias where (p_empresa is null or empresa_id = p_empresa) and (p_conta is null or id = p_conta)),
  rec as (
    select r.id rid, r.data_recebimento d, r.conta_bancaria_id conta, r.valor, r.ajuste, r.ajuste_categoria_id, t.id tid, t.valor tval, t.categoria_financeira_id tcat, t.pedido_venda_id ped
    from public.recebimentos r join public.titulos_receber t on t.id = r.titulo_id
    where not r.estornado and r.conta_bancaria_id in (select id from cb) and r.data_recebimento <= p_ate),
  rec_l as (
    select rec.d, coalesce(tr.categoria_financeira_id, rec.tcat) cat, round(coalesce(tr.valor, rec.tval) * rec.valor / nullif(rec.tval, 0), 2) v,
           'rec' o, rec.rid ref, rec.tid tit, rec.ped, rec.conta
    from rec left join public.titulos_receber_rateio tr on tr.titulo_id = rec.tid
    union all
    select d, ajuste_categoria_id, ajuste, 'rec_ajuste', rid, tid, ped, conta from rec where ajuste <> 0),
  pag as (
    select p.id pid, p.data_pagamento d, p.conta_bancaria_id conta, p.valor, p.juros + p.multa jm, p.desconto, t.id tid, t.valor tval, t.categoria_financeira_id tcat
    from public.pagamentos p join public.titulos_pagar t on t.id = p.titulo_id
    where not p.estornado and p.conta_bancaria_id in (select id from cb) and p.data_pagamento <= p_ate),
  pag_l as (
    select pag.d, coalesce(tr.categoria_financeira_id, pag.tcat) cat, -round(coalesce(tr.valor, pag.tval) * (pag.valor - pag.desconto) / nullif(pag.tval, 0), 2) v,
           'pag' o, pag.pid ref, pag.tid tit, null::bigint ped, pag.conta
    from pag left join public.titulos_pagar_rateio tr on tr.titulo_id = pag.tid
    union all
    select d, v_juros, -jm, 'pag_juros', pid, tid, null, conta from pag where jm <> 0),
  ext_l as (
    select l.data d, l.categoria_financeira_id cat, l.valor v, 'extrato' o, l.id ref, null::bigint tit, l.pedido_venda_id ped, l.conta_bancaria_id conta
    from public.extrato_lancamentos l
    where l.conciliacao = 'classificado' and l.categoria_financeira_id is not null and l.conta_bancaria_id in (select id from cb) and l.data <= p_ate),
  prev_r as (
    select t.data_vencimento d, coalesce(tr.categoria_financeira_id, t.categoria_financeira_id) cat,
           round(coalesce(tr.valor, t.valor) * t.saldo / nullif(t.valor, 0), 2) v, 'prev_rec' o, t.id ref, t.id tit, t.pedido_venda_id ped, t.conta_bancaria_id conta
    from public.titulos_receber t left join public.titulos_receber_rateio tr on tr.titulo_id = t.id
    where t.situacao in ('aberto','parcial') and t.saldo > 0 and (p_empresa is null or t.empresa_id = p_empresa)
      and (p_conta is null or t.conta_bancaria_id = p_conta) and t.data_vencimento <= p_ate),
  prev_p as (
    select coalesce(t.data_programada, t.data_vencimento) d, coalesce(tr.categoria_financeira_id, t.categoria_financeira_id) cat,
           -round(coalesce(tr.valor, t.valor) * t.saldo / nullif(t.valor, 0), 2) v, 'prev_pag' o, t.id ref, t.id tit, null::bigint ped, t.conta_bancaria_id conta
    from public.titulos_pagar t left join public.titulos_pagar_rateio tr on tr.titulo_id = t.id
    where t.situacao in ('aberto','programado','parcial') and t.saldo > 0 and (p_empresa is null or t.empresa_id = p_empresa)
      and (p_conta is null or t.conta_bancaria_id = p_conta) and coalesce(t.data_programada, t.data_vencimento) <= p_ate),
  tudo as (select * from rec_l union all select * from pag_l union all select * from ext_l union all select * from prev_r union all select * from prev_p)
  select jsonb_build_object(
    'linhas', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'c', cat, 'v', v, 'o', o, 'r', ref, 't', tit, 'p', ped, 'b', conta)) from tudo where d >= p_de and v <> 0), '[]'),
    'atrasado', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'c', cat, 'v', v, 'o', o, 'r', ref, 't', tit, 'p', ped, 'b', conta)) from tudo where d < p_de and o like 'prev%' and v <> 0), '[]'),
    -- saldo de cada conta: o informado na data do saldo + o que entrou/saiu desde então até o dia anterior ao período
    'saldo_inicial', (select coalesce(sum(c.saldo_inicial), 0) from cb c)
                   + coalesce((select sum(tu.v) from tudo tu join cb c on c.id = tu.conta
                                where tu.d < p_de and tu.o not like 'prev%' and (c.data_saldo_inicial is null or tu.d >= c.data_saldo_inicial)), 0),
    'contas', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.descricao, 'empresa', c.empresa_id, 'saldo_inicial', c.saldo_inicial, 'data_saldo', c.data_saldo_inicial)), '[]')
               from public.contas_bancarias c where c.id in (select id from cb))
  ) into v_res;
  return v_res;
end $$;
