-- =====================================================================
-- 151 · Pedido de compra com PAGAMENTO ANTECIPADO (Mercado Livre, Pix na hora, compra urgente)
--  · No pedido, o comprador marca "Pagamento antecipado" e informa: pagar até (data), Pix (chave ou copia e cola),
--    código de barras do boleto ou link de pagamento, e se é URGENTE.
--  · Quando o pedido é APROVADO, o sistema cria na hora o título no Contas a pagar — já liberado para pagar
--    (não é projeção esperando NF), com a data, o Pix/boleto/link e a marca de urgente. A Leila/financeiro paga
--    e dá baixa como sempre; o menu Contas a pagar mostra quantos antecipados estão em aberto (vermelho = urgente).
--  · Na entrada da mercadoria (com ou sem NF), o estoque entra normal, mas NÃO nasce outra conta a pagar: a entrada
--    fica ligada ao título que já foi pago (evita pagar duas vezes).
--  · Se o pedido voltar para rascunho ou for cancelado antes de pagar, o título antecipado em aberto sai.
--  · Sem a data e sem uma forma de pagar (Pix, boleto ou link), o pedido antecipado não vai para aprovação.
--  · Pedidos e títulos que já existem não mudam.
-- =====================================================================

alter table public.pedidos_compra add column if not exists pagamento_antecipado boolean not null default false;
alter table public.pedidos_compra add column if not exists pagamento_urgente boolean not null default false;
alter table public.pedidos_compra add column if not exists pagamento_data date;
alter table public.pedidos_compra add column if not exists pagamento_pix text;
alter table public.pedidos_compra add column if not exists pagamento_codigo_barras text;
alter table public.pedidos_compra add column if not exists pagamento_link text;

alter table public.titulos_pagar add column if not exists urgente boolean not null default false;
alter table public.titulos_pagar add column if not exists pix text;
alter table public.titulos_pagar add column if not exists link_pagamento text;

do $$
declare d text; n text;
begin
  -- 1) salvar pedido: grava os campos do pagamento antecipado (só em rascunho/recusado)
  d := replace(pg_get_functiondef('public.pedido_compra_salvar(jsonb, jsonb)'::regprocedure), E'\r\n', E'\n');
  if position('pagamento_antecipado' in d) = 0 then
    n := replace(d, '  if p_itens is not null then
    if exists (select 1 from jsonb_array_elements(p_itens) x where x->>''tipo_item'' = ''servico_usinagem''',
'  if p_pedido ? ''pagamento_antecipado'' and (select situacao from public.pedidos_compra where id = v_id) in (''rascunho'', ''recusado'') then
    update public.pedidos_compra set pagamento_antecipado = coalesce(d.pagamento_antecipado, false),
      pagamento_urgente = coalesce(d.pagamento_antecipado, false) and coalesce(d.pagamento_urgente, false),
      pagamento_data = case when d.pagamento_antecipado then d.pagamento_data end,
      pagamento_pix = case when d.pagamento_antecipado then nullif(trim(d.pagamento_pix), '''') end,
      pagamento_codigo_barras = case when d.pagamento_antecipado then nullif(trim(d.pagamento_codigo_barras), '''') end,
      pagamento_link = case when d.pagamento_antecipado then nullif(trim(d.pagamento_link), '''') end
    where id = v_id;
  end if;
  if p_itens is not null then
    if exists (select 1 from jsonb_array_elements(p_itens) x where x->>''tipo_item'' = ''servico_usinagem''');
    if n = d then raise exception 'pedido_compra_salvar: trecho não encontrado'; end if;
    execute n;
  end if;

  -- 2) projeção do contas a pagar: pedido antecipado vira título REAL na aprovação (uma vez só)
  d := replace(pg_get_functiondef('public.pc_projetar(bigint)'::regprocedure), E'\r\n', E'\n');
  if position('pagamento_antecipado' in d) = 0 then
    n := replace(d, '  if p.situacao not in (''aprovado'',''enviado'',''recebido_parcial'') or p.origem = ''tiny'' then return 0; end if;',
'  if p.pagamento_antecipado then
    if p.situacao not in (''aprovado'',''enviado'',''recebido_parcial'',''recebido'') then
      delete from public.titulos_pagar where pedido_compra_id = p_id and origem = ''pedido_compra'' and origem_ref->>''antecipado'' = ''true''
         and coalesce(valor_pago, 0) = 0 and situacao in (''aberto'', ''programado'');
      return 0;
    end if;
    if exists (select 1 from public.titulos_pagar where pedido_compra_id = p_id and origem_ref->>''antecipado'' = ''true'' and situacao <> ''cancelado'') then return 0; end if;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao,
      data_vencimento, data_programada, conta_bancaria_id, forma_pagamento_id, codigo_barras, pix, link_pagamento, urgente, parcela, parcelas,
      origem, origem_ref, projecao, pedido_compra_id, situacao, valor_pago, saldo, observacoes)
    values (p.empresa_id, p.fornecedor_id, p.numero,
      ''Pedido '' || p.numero || '' · PAGAMENTO ANTECIPADO'' || case when p.pagamento_urgente then '' · URGENTE'' else '''' end,
      (select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) from public.pedidos_compra_itens i left join public.produtos pr on pr.id = i.produto_id
        where i.pedido_id = p_id group by 1 order by sum(i.valor_total) desc nulls last limit 1),
      p.valor_total, current_date, coalesce(p.pagamento_data, current_date), coalesce(p.pagamento_data, current_date), p.conta_bancaria_id, p.forma_pagamento_id,
      p.pagamento_codigo_barras, p.pagamento_pix, p.pagamento_link, p.pagamento_urgente, 1, 1, ''pedido_compra'',
      jsonb_build_object(''pedido_compra'', p.numero, ''antecipado'', true), false, p_id, ''aberto'', 0, p.valor_total,
      ''Pagamento antecipado do pedido aprovado (pagar antes de receber). Na entrada da mercadoria não nasce outro título.'');
    return 1;
  end if;
  if p.situacao not in (''aprovado'',''enviado'',''recebido_parcial'') or p.origem = ''tiny'' then return 0; end if;');
    if n = d then raise exception 'pc_projetar: trecho não encontrado'; end if;
    execute n;
  end if;

  -- 3) entrada da mercadoria de pedido antecipado: não gera outra conta a pagar
  d := replace(pg_get_functiondef('public.pedido_compra_receber(bigint, jsonb, jsonb, jsonb)'::regprocedure), E'\r\n', E'\n');
  if position('pagamento_antecipado' in d) = 0 then
    n := replace(d, '  perform public.pc_projetar_recebimento(v_rec);',
'  if p.pagamento_antecipado then
    update public.pedidos_compra_recebimentos set situacao_financeiro = ''lancado'', lancado_em = now(), lancado_por = auth.uid(),
      observacao = concat_ws('' · '', observacao, ''PAGAMENTO ANTECIPADO: já está no contas a pagar pelo pedido'') where id = v_rec;
  else
    perform public.pc_projetar_recebimento(v_rec);
  end if;');
    if n = d then raise exception 'pedido_compra_receber: trecho não encontrado'; end if;
    execute n;
  end if;

  -- 4) pendência: antecipado sem data ou sem forma de pagar não vai para aprovação
  d := replace(pg_get_functiondef('public.pc_pendencias(bigint)'::regprocedure), E'\r\n', E'\n');
  if position('antecipado_incompleto' in d) = 0 then
    n := replace(d, '    union all
    select jsonb_build_object(''id'', ''sem_forma''',
'    union all
    select jsonb_build_object(''id'', ''antecipado_incompleto'', ''bloqueia'', true, ''texto'', ''Pagamento antecipado: informe "Pagar até" e o Pix, o código de barras ou o link de pagamento'')
      from public.pedidos_compra p where p.id = p_id and p.pagamento_antecipado
       and (p.pagamento_data is null or coalesce(p.pagamento_pix, p.pagamento_codigo_barras, p.pagamento_link) is null)
    union all
    select jsonb_build_object(''id'', ''sem_forma''');
    if n = d then raise exception 'pc_pendencias: trecho não encontrado'; end if;
    execute n;
  end if;

  -- 5) menu Contas a pagar: antecipados em aberto (amarelo) e urgentes (vermelho)
  d := replace(pg_get_functiondef('public.menu_contadores()'::regprocedure), E'\r\n', E'\n');
  if position('antecipado' in d) = 0 then
    n := replace(d, '    v := v || jsonb_build_object(''pagar'', jsonb_build_object(''amarelo'', 0, ''vermelho'', r));',
'    select r + count(*) filter (where urgente), count(*) filter (where not urgente) into r, a from public.titulos_pagar
     where origem_ref->>''antecipado'' = ''true'' and situacao in (''aberto'', ''programado'', ''parcial'');
    v := v || jsonb_build_object(''pagar'', jsonb_build_object(''amarelo'', a, ''vermelho'', r));');
    if n = d then raise exception 'menu_contadores: trecho não encontrado'; end if;
    execute n;
  end if;
end $$;
