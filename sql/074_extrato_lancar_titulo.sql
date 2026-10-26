-- =====================================================================
-- 074 · Extrato: lançar o título direto da linha do extrato (atalho da conciliação)
--  · Saída do extrato (ex.: transferência do Mercado Pago para outro banco, tarifa, antecipação) →
--    cria o título no contas a pagar com fornecedor e categoria, já pago na data do extrato e conciliado.
--  · Entrada do extrato (ex.: crédito de frete, ressarcimento) → título no contas a receber, já recebido.
--  · Uma ou várias linhas de uma vez (um título por linha, com o ID da operação no histórico).
-- =====================================================================
create or replace function public.extrato_lancar_titulo(p_ids bigint[], p_pessoa bigint, p_categoria bigint, p_documento text default null, p_descricao text default null)
returns int language plpgsql security definer set search_path = public as $$
declare l record; v_emp int; v_tit bigint; v_baixa bigint; n int := 0; v_val numeric; v_desc text;
begin
  if not (select public.pode('conciliacao', 'alterar')) then raise exception 'Sem permissão na conciliação'; end if;
  if p_categoria is null then raise exception 'Escolha a categoria financeira'; end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 then raise exception 'Escolha as linhas do extrato'; end if;
  for l in select * from public.extrato_lancamentos where id = any(p_ids) order by data, id for update loop
    if l.conciliacao <> 'pendente' then raise exception 'Linha de % (% %) já está %', to_char(l.data, 'DD/MM/YYYY'), l.tipo, l.valor, l.conciliacao; end if;
    select empresa_id into v_emp from public.contas_bancarias where id = l.conta_bancaria_id;
    v_val := abs(l.valor);
    v_desc := upper(coalesce(nullif(trim(p_descricao), ''), concat_ws(' · ', l.tipo, l.descricao)));
    if l.valor < 0 then
      if not (select public.pode('pagar', 'criar')) then raise exception 'Sem permissão no contas a pagar'; end if;
      if p_pessoa is null then raise exception 'Escolha o fornecedor'; end if;
      insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento, data_programada,
          conta_bancaria_id, origem, origem_ref, projecao, situacao, valor_pago, saldo)
      values (v_emp, p_pessoa, coalesce(nullif(upper(trim(p_documento)), ''), 'EXTRATO ' || coalesce(l.id_operacao, l.id::text)), v_desc, p_categoria, v_val, l.data, l.data, l.data,
          l.conta_bancaria_id, 'manual', jsonb_build_object('extrato_id', l.id, 'id_operacao', l.id_operacao, 'tipo_extrato', l.tipo), false, 'aberto', 0, v_val)
      returning id into v_tit;
      insert into public.pagamentos (titulo_id, data_pagamento, valor, conta_bancaria_id, identificador, conciliado, conciliado_em, conciliado_por, observacoes)
      values (v_tit, l.data, v_val, l.conta_bancaria_id, coalesce(l.id_operacao, 'extrato:' || l.id), true, now(), auth.uid(), 'Lançado e baixado pela linha do extrato #' || l.id)
      returning id into v_baixa;
      update public.extrato_lancamentos set conciliacao = 'conciliado', pagamento_id = v_baixa, categoria_financeira_id = p_categoria,
             conciliado_em = now(), conciliado_por = auth.uid(), observacoes = concat_ws(' · ', observacoes, 'Título a pagar #' || v_tit || ' lançado pelo extrato')
       where id = l.id;
    else
      if not (select public.pode('receber', 'criar')) then raise exception 'Sem permissão no contas a receber'; end if;
      insert into public.titulos_receber (empresa_id, cliente_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento,
          conta_bancaria_id, origem, origem_ref, projecao, situacao, valor_recebido, saldo)
      values (v_emp, p_pessoa, coalesce(nullif(upper(trim(p_documento)), ''), 'EXTRATO ' || coalesce(l.id_operacao, l.id::text)), v_desc, p_categoria, v_val, l.data, l.data,
          l.conta_bancaria_id, 'manual', jsonb_build_object('extrato_id', l.id, 'id_operacao', l.id_operacao, 'tipo_extrato', l.tipo), false, 'aberto', 0, v_val)
      returning id into v_tit;
      insert into public.recebimentos (titulo_id, data_recebimento, valor, conta_bancaria_id, identificador, conciliado, conciliado_em, conciliado_por, observacoes)
      values (v_tit, l.data, v_val, l.conta_bancaria_id, coalesce(l.id_operacao, 'extrato:' || l.id), true, now(), auth.uid(), 'Lançado e baixado pela linha do extrato #' || l.id)
      returning id into v_baixa;
      update public.extrato_lancamentos set conciliacao = 'conciliado', titulo_receber_id = v_tit, recebimento_id = v_baixa, categoria_financeira_id = p_categoria,
             conciliado_em = now(), conciliado_por = auth.uid(), observacoes = concat_ws(' · ', observacoes, 'Título a receber #' || v_tit || ' lançado pelo extrato')
       where id = l.id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.extrato_lancar_titulo(bigint[], bigint, bigint, text, text) from public, anon;
grant execute on function public.extrato_lancar_titulo(bigint[], bigint, bigint, text, text) to authenticated;
