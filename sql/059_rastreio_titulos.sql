-- =====================================================================
-- 059 · Rastreio completo de títulos (contas a pagar e a receber)
--  · Uma linha do tempo por título, igual em todas as telas (fluxo de caixa, contas a pagar/receber, conciliação):
--    origem (pedido de compra com aprovações, folha do RH, importação do Tiny, pedido de venda),
--    quem lançou e quando, alterações (auditoria), revisão, pagamentos/recebimentos, conciliação com o extrato.
--  · Só leitura; respeita o acesso: pagar → contas a pagar ou fluxo; receber → contas a receber, fluxo ou conciliação.
-- =====================================================================
-- valor em reais no formato brasileiro (R$ 1.234,56)
create or replace function public.fmt_brl(v numeric)
returns text language sql immutable set search_path = public as $$
  select 'R$ ' || translate(to_char(coalesce(v, 0), 'FM999G999G990D00'), ',.', '.,')
$$;

create or replace function public.rastreio_titulo(p_tipo text, p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb := '[]'; t record; r record; v_tit jsonb; v_hist text; v_oc text;
begin
  if p_tipo = 'pagar' then
    if not ((select public.pode('pagar')) or (select public.pode('fluxo'))) then raise exception 'Sem acesso ao contas a pagar'; end if;
    select tp.*, f.nome fornecedor into t from public.titulos_pagar tp left join public.fornecedores f on f.id = tp.fornecedor_id where tp.id = p_id;
  elsif p_tipo = 'receber' then
    if not ((select public.pode('receber')) or (select public.pode('fluxo')) or (select public.pode('conciliacao'))) then raise exception 'Sem acesso ao contas a receber'; end if;
    select tr.*, c.nome fornecedor into t from public.titulos_receber tr left join public.clientes c on c.id = tr.cliente_id where tr.id = p_id;
  else raise exception 'Tipo inválido'; end if;
  if t.id is null then raise exception 'Título não encontrado'; end if;

  v_tit := jsonb_build_object('id', t.id, 'tipo', p_tipo, 'documento', t.documento, 'descricao', t.descricao, 'pessoa', t.fornecedor,
    'valor', t.valor, 'situacao', t.situacao, 'emissao', t.data_emissao, 'vencimento', t.data_vencimento, 'competencia', t.data_competencia,
    'empresa', (select nome from public.empresas where id = t.empresa_id), 'origem', t.origem, 'projecao', t.projecao);

  -- 1) ORIGEM -------------------------------------------------------------
  if p_tipo = 'pagar' and t.pedido_compra_id is not null then
    for r in select e.em, e.acao, e.detalhe, coalesce(u.nome, 'sistema') quem, p.numero
               from public.pedidos_compra_eventos e join public.pedidos_compra p on p.id = e.pedido_id left join public.usuarios u on u.id = e.por
              where e.pedido_id = t.pedido_compra_id order by e.em, e.id loop
      v := v || jsonb_build_object('grupo', 'Pedido de compra ' || r.numero, 'quando', r.em, 'quem', r.quem,
        'etapa', case r.acao when 'criado' then 'Pedido criado' when 'enviado_aprovacao' then 'Enviado para aprovação'
          when 'aprovado_nivel' then 'Aprovação' when 'aprovado' then 'Pedido aprovado' when 'recusado' then 'Recusado'
          when 'reaberto' then 'Reaberto' when 'enviado_fornecedor' then 'Enviado ao fornecedor' when 'recebido' then 'NF recebida'
          when 'liberado_avulso' then 'Item sem cadastro liberado' when 'cancelado' then 'Pedido cancelado' when 'encerrado' then 'Saldo encerrado'
          when 'pdf' then 'PDF gerado' when 'comentario' then 'Comentário' else r.acao end,
        'detalhe', r.detalhe, 'link', 'pages/compras/pedidos.html?abrir=' || t.pedido_compra_id,
        'cor', case when r.acao in ('recusado','cancelado') then 'erro' when r.acao in ('aprovado','aprovado_nivel','recebido') then 'ok' else '' end);
    end loop;
  elsif p_tipo = 'pagar' and t.origem = 'rh' then
    v := v || jsonb_build_object('grupo', 'Folha / RH', 'etapa', 'Lançado pelo RH', 'quando', t.criado_em,
      'quem', coalesce((select nome from public.usuarios where id = t.criado_por), 'RH'),
      'detalhe', coalesce(t.origem_ref->>'origem', '') || ' · competência ' || to_char(t.data_competencia, 'MM/YYYY'), 'cor', 'ok');
    select c.fechado_em, u.nome into r from public.rh_competencias c left join public.usuarios u on u.id = c.fechado_por
     where c.empresa_id = t.empresa_id and c.competencia = date_trunc('month', t.data_competencia)::date and c.situacao = 'fechada';
    if found then v := v || jsonb_build_object('grupo', 'Folha / RH', 'etapa', 'Folha fechada e enviada ao financeiro', 'quando', r.fechado_em, 'quem', coalesce(r.nome, 'RH'), 'cor', 'ok'); end if;
  elsif t.origem_ref->>'sistema' = 'tiny' then
    select b.detalhe->>'historico' into v_hist from public.tiny_brutos b
     where b.recurso = case p_tipo when 'pagar' then 'contas_pagar' else 'contas_receber' end and b.tiny_id = t.origem_ref->>'tiny_id' and b.empresa_id = t.empresa_id;
    v_oc := substring(coalesce(v_hist, t.descricao, '') from '(?i)ordem de compra n[ºo°.]*\s*(\d+)');
    if v_oc is not null then
      v := v || jsonb_build_object('grupo', 'Origem no Tiny', 'etapa', 'Ordem de compra Tiny nº ' || v_oc,
        'detalhe', 'Compra feita e aprovada no Tiny (antes do sistema) — aprovação não registrada aqui', 'quem', 'Tiny');
    end if;
    v := v || jsonb_build_object('grupo', 'Origem no Tiny', 'etapa', 'Importado do Tiny', 'quando', t.criado_em, 'quem', 'integração Tiny',
      'detalhe', concat_ws(' · ', 'Tiny #' || (t.origem_ref->>'tiny_id'), nullif(t.origem_ref->>'fornecedor_tiny', ''), nullif(t.origem_ref->>'categoria_tiny', '')));
  elsif p_tipo = 'receber' and t.pedido_venda_id is not null then
    select pv.*, cv.nome canal into r from public.pedidos_venda pv left join public.canais_venda cv on cv.id = pv.canal_id where pv.id = t.pedido_venda_id;
    v := v || jsonb_build_object('grupo', 'Pedido de venda', 'etapa', 'Venda ' || coalesce(r.numero_externo, '#' || r.id), 'quando', r.data_pedido,
      'quem', coalesce((select nome from public.usuarios where id = r.criado_por), case when r.origem in ('api','tiny') then 'integração ' || r.origem else coalesce(r.origem, 'integração') end),
      'detalhe', concat_ws(' · ', r.canal, case when r.valor_total is not null then 'total ' || public.fmt_brl(r.valor_total) end),
      'link', 'pages/comercial/pedidos-venda.html?abrir=' || r.id);
    if r.nf_numero is not null then v := v || jsonb_build_object('grupo', 'Pedido de venda', 'etapa', 'NF ' || r.nf_numero, 'quando', r.nf_data, 'quem', 'Tiny'); end if;
    if r.data_envio is not null then v := v || jsonb_build_object('grupo', 'Pedido de venda', 'etapa', 'Enviado', 'quando', r.data_envio); end if;
    if r.data_entrega is not null then v := v || jsonb_build_object('grupo', 'Pedido de venda', 'etapa', 'Entregue', 'quando', r.data_entrega, 'cor', 'ok'); end if;
  end if;

  -- 2) TÍTULO -------------------------------------------------------------
  v := v || jsonb_build_object('grupo', 'Título', 'etapa', case when t.projecao then 'Previsão lançada' else 'Título lançado' end, 'quando', t.criado_em,
    'quem', coalesce((select nome from public.usuarios where id = t.criado_por), case when t.origem_ref->>'sistema' = 'tiny' then 'integração Tiny' else 'sistema' end),
    'detalhe', concat_ws(' · ', t.documento, '' || public.fmt_brl(t.valor), 'vence ' || to_char(t.data_vencimento, 'DD/MM/YYYY')));
  for r in select a.em, coalesce(a.usuario_nome, u.nome, 'sistema') quem, a.campos
             from public.auditoria a left join public.usuarios u on u.id = a.usuario_id
            where a.tabela = case p_tipo when 'pagar' then 'titulos_pagar' else 'titulos_receber' end and a.registro = t.id::text and a.acao = 'alterou'
              and a.campos is not null and not (a.campos <@ array['atualizado_em','atualizado_por','saldo','valor_pago','valor_recebido','situacao','data_pagamento','data_recebimento']::text[])
            order by a.em desc limit 15 loop
    v := v || jsonb_build_object('grupo', 'Título', 'etapa', 'Alterado', 'quando', r.em, 'quem', r.quem,
      'detalhe', 'campos: ' || array_to_string(array(select x from unnest(r.campos) x where x not in ('atualizado_em','atualizado_por')), ', '));
  end loop;
  if t.revisado_em is not null then
    v := v || jsonb_build_object('grupo', 'Título', 'etapa', 'Revisado', 'quando', t.revisado_em, 'quem', (select nome from public.usuarios where id = t.revisado_por), 'cor', 'ok');
  end if;
  if t.situacao = 'cancelado' then v := v || jsonb_build_object('grupo', 'Título', 'etapa', 'Cancelado', 'quando', t.atualizado_em,
    'quem', (select nome from public.usuarios where id = t.atualizado_por), 'detalhe', t.motivo_cancelamento, 'cor', 'erro'); end if;

  -- 3) BAIXAS E CONCILIAÇÃO ---------------------------------------------
  if p_tipo = 'pagar' then
    for r in select p.*, cb.descricao conta, uc.nome quem_lanc, uk.nome quem_conc,
                    (select string_agg('linha #' || l.id || ' (' || to_char(l.data, 'DD/MM') || ')', ', ') from public.extrato_lancamentos l where l.pagamento_id = p.id) linhas
               from public.pagamentos p left join public.contas_bancarias cb on cb.id = p.conta_bancaria_id
               left join public.usuarios uc on uc.id = p.criado_por left join public.usuarios uk on uk.id = p.conciliado_por
              where p.titulo_id = t.id order by p.data_pagamento, p.id loop
      v := v || jsonb_build_object('grupo', 'Pagamento', 'etapa', case when r.estornado then 'Pagamento estornado' else 'Pago' end, 'quando', r.data_pagamento,
        'quem', coalesce(r.quem_lanc, case when r.identificador like 'tiny:%' then 'baixa importada do Tiny' else 'sistema' end),
        'detalhe', concat_ws(' · ', '' || public.fmt_brl(r.valor), r.conta, 'lançado em ' || to_char(r.criado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'), r.observacoes),
        'cor', case when r.estornado then 'erro' else 'ok' end);
      if r.conciliado then
        v := v || jsonb_build_object('grupo', 'Pagamento', 'etapa', 'Conciliado com o extrato', 'quando', r.conciliado_em, 'quem', coalesce(r.quem_conc, 'conciliação automática'),
          'detalhe', r.linhas, 'cor', 'ok');
      elsif not r.estornado then
        v := v || jsonb_build_object('grupo', 'Pagamento', 'etapa', 'Aguardando conciliação com o extrato', 'cor', 'alerta');
      end if;
    end loop;
  else
    for r in select x.*, cb.descricao conta, uc.nome quem_lanc, uk.nome quem_conc,
                    (select string_agg('linha #' || l.id || ' (' || to_char(l.data, 'DD/MM') || ')', ', ') from public.extrato_lancamentos l where l.recebimento_id = x.id) linhas
               from public.recebimentos x left join public.contas_bancarias cb on cb.id = x.conta_bancaria_id
               left join public.usuarios uc on uc.id = x.criado_por left join public.usuarios uk on uk.id = x.conciliado_por
              where x.titulo_id = t.id order by x.data_recebimento, x.id loop
      v := v || jsonb_build_object('grupo', 'Recebimento', 'etapa', case when r.estornado then 'Recebimento estornado' else 'Recebido' end, 'quando', r.data_recebimento,
        'quem', coalesce(r.quem_lanc, case when r.identificador like 'mp:%' then 'baixa automática pelo extrato do Mercado Pago' else 'sistema' end),
        'detalhe', concat_ws(' · ', '' || public.fmt_brl(r.valor), r.conta,
          case when r.ajuste <> 0 then 'ajuste ' || public.fmt_brl(r.ajuste) end, r.observacoes),
        'cor', case when r.estornado then 'erro' else 'ok' end);
      if r.conciliado then
        v := v || jsonb_build_object('grupo', 'Recebimento', 'etapa', 'Conciliado com o extrato', 'quando', r.conciliado_em, 'quem', coalesce(r.quem_conc, 'conciliação automática'),
          'detalhe', r.linhas, 'cor', 'ok');
      elsif not r.estornado then
        v := v || jsonb_build_object('grupo', 'Recebimento', 'etapa', 'Aguardando conciliação com o extrato', 'cor', 'alerta');
      end if;
    end loop;
  end if;

  return jsonb_build_object('titulo', v_tit, 'passos', v);
end $$;
revoke execute on function public.rastreio_titulo(text, bigint) from public, anon;
grant execute on function public.rastreio_titulo(text, bigint) to authenticated;
