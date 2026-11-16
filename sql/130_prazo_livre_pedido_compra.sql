-- =====================================================================
-- 130 · Pedido de compra: prazo de pagamento digitado só no pedido
-- O que muda:
--   1. No pedido de compra, a caixa "ou digite os prazos: 30/60/90" passa a gravar o prazo só naquele
--      pedido (coluna nova pedidos_compra.prazo_livre_dias), sem cadastrar condição de pagamento nova.
--      Com o prazo digitado, a condição de pagamento não precisa ser escolhida.
--   2. As parcelas previstas no contas a pagar (pedido aprovado) usam esse prazo quando não há condição.
--   3. A pendência "Sem condição de pagamento" só aparece se não houver condição nem prazo digitado.
--   4. Cadastrar condição nova volta a ser só de quem tem acesso à tela Formas e condições de pagamento
--      (antes o perfil Compras também conseguia, pela caixa de prazos).
-- Não apaga nada.
-- =====================================================================

alter table public.pedidos_compra add column if not exists prazo_livre_dias int[];
comment on column public.pedidos_compra.prazo_livre_dias is 'Prazos em dias combinados só neste pedido (ex.: {30,60,90}), quando não há condição de pagamento cadastrada';

-- 1. Salvar o pedido grava o prazo digitado (escolher uma condição zera o prazo)
create or replace function public.pedido_compra_salvar(p_pedido jsonb, p_itens jsonb)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id bigint := nullif(p_pedido->>'id', '')::bigint; d public.pedidos_compra; v_sit text; v_cat_usi bigint; v_prazo int[];
begin
  d := jsonb_populate_record(null::public.pedidos_compra, p_pedido - 'id' - 'numero');
  if d.condicao_pagamento_id is null and cardinality(d.prazo_livre_dias) > 0 then
    select array_agg(distinct x order by x) into v_prazo from unnest(d.prazo_livre_dias) x where x is not null;
    if cardinality(v_prazo) > 24 then raise exception 'Prazos de pagamento: no máximo 24 parcelas'; end if;
    if v_prazo[1] < 0 or v_prazo[cardinality(v_prazo)] > 720 then raise exception 'Prazos de pagamento entre 0 e 720 dias'; end if;
  end if;
  if v_id is null then
    if not public.pode('compras', 'criar') then raise exception 'Sem permissão para incluir pedidos de compra'; end if;
    insert into public.pedidos_compra (empresa_id, fornecedor_id, comprador_id, data_pedido, data_entrega_prevista, condicao_pagamento_id, prazo_livre_dias, forma_pagamento_id,
      conta_bancaria_id, frete, outras_despesas, desconto, contato_fornecedor, email_fornecedor, whatsapp_fornecedor, observacoes, observacoes_internas)
    values (d.empresa_id, d.fornecedor_id, coalesce(d.comprador_id, auth.uid()), coalesce(d.data_pedido, current_date), d.data_entrega_prevista, d.condicao_pagamento_id, v_prazo,
      d.forma_pagamento_id, d.conta_bancaria_id, coalesce(d.frete, 0), coalesce(d.outras_despesas, 0), coalesce(d.desconto, 0), d.contato_fornecedor,
      d.email_fornecedor, d.whatsapp_fornecedor, d.observacoes, d.observacoes_internas)
    returning id into v_id;
    perform public.pc_evento(v_id, 'criado', 'Pedido criado (rascunho)');
  else
    select situacao into v_sit from public.pedidos_compra where id = v_id for update;
    if v_sit is null then raise exception 'Pedido não encontrado'; end if;
    if not public.pode('compras', 'alterar') then raise exception 'Sem permissão para alterar pedidos de compra'; end if;
    if v_sit not in ('rascunho','recusado') then
      update public.pedidos_compra set contato_fornecedor = d.contato_fornecedor, email_fornecedor = d.email_fornecedor,
        whatsapp_fornecedor = d.whatsapp_fornecedor, observacoes_internas = d.observacoes_internas, data_entrega_prevista = d.data_entrega_prevista
      where id = v_id;
      perform public.pc_projetar(v_id);
      return v_id;
    end if;
    update public.pedidos_compra set empresa_id = d.empresa_id, fornecedor_id = d.fornecedor_id, data_pedido = coalesce(d.data_pedido, data_pedido),
      data_entrega_prevista = d.data_entrega_prevista, condicao_pagamento_id = d.condicao_pagamento_id, prazo_livre_dias = v_prazo, forma_pagamento_id = d.forma_pagamento_id,
      conta_bancaria_id = d.conta_bancaria_id, frete = coalesce(d.frete, 0), outras_despesas = coalesce(d.outras_despesas, 0), desconto = coalesce(d.desconto, 0),
      contato_fornecedor = d.contato_fornecedor, email_fornecedor = d.email_fornecedor, whatsapp_fornecedor = d.whatsapp_fornecedor,
      observacoes = d.observacoes, observacoes_internas = d.observacoes_internas
    where id = v_id;
    perform public.pc_evento(v_id, 'alterado', 'Pedido alterado');
  end if;
  if p_itens is not null then
    if exists (select 1 from jsonb_array_elements(p_itens) x where x->>'tipo_item' = 'servico_usinagem' and nullif(x->>'produto_id', '') is null) then
      raise exception 'Serviço de usinagem precisa da peça (produto) que volta usinada';
    end if;
    if exists (select 1 from jsonb_array_elements(p_itens) x left join public.servicos s on s.id = nullif(x->>'servico_id', '')::bigint
                where nullif(x->>'servico_id', '') is not null and s.id is null) then
      raise exception 'Serviço não encontrado no cadastro';
    end if;
    select id into v_cat_usi from public.categorias_financeiras where codigo = '3.05.005' limit 1;
    delete from public.pedidos_compra_itens where pedido_id = v_id;
    insert into public.pedidos_compra_itens (pedido_id, produto_id, servico_id, descricao, unidade, codigo_fornecedor, quantidade, valor_unitario, desconto, categoria_financeira_id, observacao,
      tipo_item, material, comprimento_mm, perda_mm, barra_mm, pecas_por_barra, barras_enviar, uso_consumo)
    select v_id, case when s.sv is not null and not s.srv then null else nullif(s.x->>'produto_id', '')::bigint end, s.sv,
           coalesce(nullif(s.x->>'descricao', ''),
                    case when s.srv then coalesce(sv.nome, 'USINAGEM') || ' · ' || (select descricao from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint) end,
                    sv.nome, (select descricao from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint), 'Item'),
           coalesce(nullif(s.x->>'unidade', ''), sv.unidade, case when s.srv then 'PÇ' end), nullif(s.x->>'codigo_fornecedor', ''), (s.x->>'quantidade')::numeric,
           coalesce((s.x->>'valor_unitario')::numeric, 0), coalesce((s.x->>'desconto')::numeric, 0),
           case when s.sv is not null then coalesce(sv.categoria_financeira_id, nullif(s.x->>'categoria_financeira_id', '')::bigint)
                else coalesce(nullif(s.x->>'categoria_financeira_id', '')::bigint, case when s.srv then v_cat_usi end,
                              (select categoria_financeira_id from public.produtos where id = nullif(s.x->>'produto_id', '')::bigint)) end,
           nullif(s.x->>'observacao', ''),
           case when s.srv then 'servico_usinagem' else 'normal' end,
           case when s.srv then coalesce(nullif(s.x->>'material', ''), u.material) end,
           case when s.srv then coalesce(nullif(s.x->>'comprimento_mm', '')::numeric, u.comprimento_mm) end,
           case when s.srv then coalesce(nullif(s.x->>'perda_mm', '')::numeric, u.perda_mm) end,
           case when s.srv then nullif(s.x->>'barra_mm', '')::numeric end,
           case when s.srv then s.pb end,
           case when s.srv and s.pb > 0 then ceil((s.x->>'quantidade')::numeric / s.pb) end,
           case when s.sv is not null then false else coalesce((s.x->>'uso_consumo')::boolean, false) end
    from (select x, coalesce((x->>'tipo_item') = 'servico_usinagem', false) as srv, nullif(x->>'servico_id', '')::bigint as sv,
                 floor(nullif(x->>'barra_mm', '')::numeric / nullif(coalesce(nullif(x->>'comprimento_mm', '')::numeric, u2.comprimento_mm) + coalesce(nullif(x->>'perda_mm', '')::numeric, u2.perda_mm, 0), 0)) as pb
          from jsonb_array_elements(p_itens) x
          left join public.produto_usinagem u2 on u2.produto_id = nullif(x->>'produto_id', '')::bigint
          where coalesce((x->>'quantidade')::numeric, 0) > 0) s
    left join public.servicos sv on sv.id = s.sv
    left join public.produto_usinagem u on u.produto_id = nullif(s.x->>'produto_id', '')::bigint;
  end if;
  perform public.pc_recalcular(v_id);
  return v_id;
end $function$;

-- 2. Parcelas previstas: condição cadastrada → prazo digitado no pedido → prazo padrão do fornecedor
create or replace function public.pc_projetar(p_id bigint)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare p public.pedidos_compra; v_pend numeric; v_dias int[]; v_n int; v_base date; v_cat bigint; v_i int; v_v numeric; v_acum numeric := 0;
begin
  select * into p from public.pedidos_compra where id = p_id;
  delete from public.titulos_pagar where pedido_compra_id = p_id and projecao and coalesce(valor_pago, 0) = 0 and origem = 'pedido_compra';
  if p.situacao not in ('aprovado','enviado','recebido_parcial') or p.origem = 'tiny' then return 0; end if;
  v_pend := round(p.valor_total - p.valor_recebido, 2);
  if v_pend <= 0.009 then return 0; end if;
  select dias into v_dias from public.condicoes_pagamento where id = p.condicao_pagamento_id;
  if v_dias is null or cardinality(v_dias) = 0 then v_dias := p.prazo_livre_dias; end if;
  if v_dias is null or cardinality(v_dias) = 0 then v_dias := array[coalesce(public.p_dias_padrao_fornecedor(p.fornecedor_id), 0)]; end if;
  v_n := cardinality(v_dias);
  v_base := greatest(coalesce(p.data_entrega_prevista, p.data_pedido), current_date);
  select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) into v_cat
  from public.pedidos_compra_itens i left join public.produtos pr on pr.id = i.produto_id
  where i.pedido_id = p_id group by 1 order by sum(i.valor_total) desc nulls last limit 1;
  for v_i in 1..v_n loop
    v_v := case when v_i = v_n then v_pend - v_acum else round(v_pend / v_n, 2) end; v_acum := v_acum + v_v;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao,
      data_vencimento, data_programada, conta_bancaria_id, forma_pagamento_id, parcela, parcelas, origem, origem_ref, projecao,
      pedido_compra_id, situacao, valor_pago, saldo, observacoes)
    values (p.empresa_id, p.fornecedor_id, p.numero, 'Pedido de compra ' || p.numero || ' · aguardando NF', v_cat, v_v, p.data_pedido,
      v_base + v_dias[v_i], v_base + v_dias[v_i], p.conta_bancaria_id, p.forma_pagamento_id, v_i, v_n, 'pedido_compra',
      jsonb_build_object('pedido_compra', p.numero, 'aguardando_nf', true), true, p_id, 'aberto', 0, v_v,
      'Projeção automática do pedido aprovado. Vira título real no recebimento da NF (tela de Pedidos de compra).');
  end loop;
  return v_n;
end $function$;

-- 3. Pendência "Sem condição de pagamento" só sem condição e sem prazo digitado
create or replace function public.pc_pendencias(p_id bigint)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(x), '[]') from (
    select jsonb_build_object('id', 'sem_categoria', 'bloqueia', true, 'texto', count(*) || ' item(ns) sem categoria financeira') x
      from public.pedidos_compra_itens i where i.pedido_id = p_id and i.categoria_financeira_id is null having count(*) > 0
    union all
    select jsonb_build_object('id', 'avulso', 'bloqueia', true, 'texto', 'Item sem cadastro aguardando liberação: ' || array_to_string(public.pc_avulsos_pendentes(p_id), ', '))
     where cardinality(public.pc_avulsos_pendentes(p_id)) > 0
    union all
    select jsonb_build_object('id', 'sem_forma', 'bloqueia', true, 'texto', 'Sem forma de pagamento (combine com o fornecedor: Pix, boleto…)')
      from public.pedidos_compra p where p.id = p_id and p.forma_pagamento_id is null
    union all
    select jsonb_build_object('id', 'produto_sem_categoria', 'bloqueia', false, 'texto', 'Produto sem categoria no cadastro: ' || string_agg(distinct coalesce(pr.codigo, pr.descricao), ', '))
      from public.pedidos_compra_itens i join public.produtos pr on pr.id = i.produto_id
     where i.pedido_id = p_id and pr.categoria_financeira_id is null and not i.uso_consumo and i.servico_id is null having count(*) > 0
    union all
    select jsonb_build_object('id', 'aumento_preco', 'bloqueia', false, 'texto', 'Preço acima da última compra: ' ||
           string_agg((a->>'descricao') || ' R$ ' || replace(to_char((a->>'ultimo')::numeric, 'FM999999990.00'), '.', ',') || ' → R$ ' || replace(to_char((a->>'atual')::numeric, 'FM999999990.00'), '.', ',')
                      || ' (+' || replace(a->>'pct', '.', ',') || '%)', '; '))
      from jsonb_array_elements(public.pc_aumentos(p_id)) a having count(*) > 0
    union all
    select jsonb_build_object('id', 'sem_condicao', 'bloqueia', false, 'texto', 'Sem condição de pagamento')
      from public.pedidos_compra p where p.id = p_id and p.condicao_pagamento_id is null and coalesce(cardinality(p.prazo_livre_dias), 0) = 0
    union all
    select jsonb_build_object('id', 'sem_entrega', 'bloqueia', false, 'texto', 'Sem previsão de entrega')
      from public.pedidos_compra p where p.id = p_id and p.data_entrega_prevista is null
    union all
    select jsonb_build_object('id', 'sem_contato', 'bloqueia', false, 'texto', 'Fornecedor sem e-mail e sem WhatsApp para envio')
      from public.pedidos_compra p join public.fornecedores f on f.id = p.fornecedor_id
     where p.id = p_id and coalesce(nullif(p.email_fornecedor, ''), nullif(f.email, ''), nullif(p.whatsapp_fornecedor, ''), nullif(f.telefone, '')) is null
  ) z where (select public.pode('compras'))
$function$;

-- 4. Cadastrar condição nova (atalho 30/60/90): só quem pode gravar em Formas e condições de pagamento
create or replace function public.condicao_pagamento_garantir(p_dias integer[])
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v int[]; v_id bigint;
begin
  if not public.pode('condicoes_pagamento', 'editar') then
    raise exception 'Sem permissão para criar condição de pagamento';
  end if;
  select array_agg(distinct d order by d) into v from unnest(p_dias) d where d is not null;
  if v is null or cardinality(v) = 0 then raise exception 'Informe os prazos em dias (ex.: 30/60/90)'; end if;
  if cardinality(v) > 24 then raise exception 'No máximo 24 parcelas'; end if;
  if v[1] < 0 or v[cardinality(v)] > 720 then raise exception 'Prazos entre 0 e 720 dias'; end if;

  select id into v_id from public.condicoes_pagamento where dias = v order by (situacao = 'ativo') desc, id limit 1;
  if v_id is not null then
    update public.condicoes_pagamento set situacao = 'ativo', atualizado_em = now(), atualizado_por = auth.uid()
     where id = v_id and situacao <> 'ativo';
    return v_id;
  end if;
  insert into public.condicoes_pagamento (nome, dias, situacao, criado_por, atualizado_por)
  values (case when v = array[0] then 'À vista' else array_to_string(v, '/') || case when cardinality(v) = 1 then ' dias' else '' end end,
          v, 'ativo', auth.uid(), auth.uid())
  returning id into v_id;
  return v_id;
end $function$;

-- Conferência: deve mostrar 1
select count(*) as coluna_nova from information_schema.columns where table_name = 'pedidos_compra' and column_name = 'prazo_livre_dias';
