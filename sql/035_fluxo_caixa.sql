-- =====================================================================
-- 035 · Fluxo de caixa
-- Linhas do fluxo por data e categoria, com a origem de cada valor:
--  · realizado: baixas do contas a receber e a pagar (as baixas nascem da
--    conciliação com o extrato); a venda de marketplace entra pelo BRUTO e
--    cada tarifa sai na própria categoria (composição do título);
--  · previsto: saldo em aberto dos títulos, no vencimento (ou data programada).
-- Juros e multa pagos vão para 7.02.006 (pendência antiga do relatório).
-- =====================================================================
insert into public.categorias_financeiras (codigo, nome, pai_id, tipo, grupo_dre, natureza, aceita_lancamento, descricao)
select '7.02.006', 'JUROS E MULTAS POR ATRASO', id, 'financeiro', grupo_dre, 'variavel', true, 'Juros e multa pagos em títulos do contas a pagar (lançado automaticamente na baixa).'
from public.categorias_financeiras where codigo = '7.02'
on conflict (codigo) do nothing;

create or replace function public.fluxo_caixa(p_de date, p_ate date, p_empresa int default null, p_conta bigint default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_juros bigint; v_res jsonb;
begin
  if not (public.pode('fluxo') or public.pode('pagar') and public.pode('receber')) then raise exception 'Sem acesso ao fluxo de caixa'; end if;
  select id into v_juros from public.categorias_financeiras where codigo = '7.02.006';
  with
  cb as (select id, empresa_id from public.contas_bancarias where (p_empresa is null or empresa_id = p_empresa) and (p_conta is null or id = p_conta)),
  -- recebimentos: bruto/tarifas pela composição do título, proporcional ao valor baixado
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
  -- linhas do extrato já classificadas direto numa categoria (rotina antiga; some quando virar título)
  ext_l as (
    select l.data d, l.categoria_financeira_id cat, l.valor v, 'extrato' o, l.id ref, null::bigint tit, l.pedido_venda_id ped, l.conta_bancaria_id conta
    from public.extrato_lancamentos l
    where l.conciliacao = 'classificado' and l.categoria_financeira_id is not null and l.conta_bancaria_id in (select id from cb) and l.data <= p_ate),
  -- previsto: saldo aberto dos títulos
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
    -- antes do período: o realizado vira saldo inicial; o previsto em atraso aparece no primeiro dia
    'atrasado', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'c', cat, 'v', v, 'o', o, 'r', ref, 't', tit, 'p', ped, 'b', conta)) from tudo where d < p_de and o like 'prev%' and v <> 0), '[]'),
    'saldo_inicial', (select coalesce(sum(c.saldo_inicial), 0) from public.contas_bancarias c where c.id in (select id from cb))
                   + coalesce((select sum(v) from tudo where d < p_de and o not like 'prev%'), 0),
    'contas', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.descricao, 'empresa', c.empresa_id, 'saldo_inicial', c.saldo_inicial, 'data_saldo', c.data_saldo_inicial)), '[]')
               from public.contas_bancarias c where c.id in (select id from cb))
  ) into v_res;
  return v_res;
end $$;
revoke execute on function public.fluxo_caixa(date, date, int, bigint) from public, anon;
grant execute on function public.fluxo_caixa(date, date, int, bigint) to authenticated;
