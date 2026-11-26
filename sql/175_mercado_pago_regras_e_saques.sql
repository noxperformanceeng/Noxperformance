-- =====================================================================
-- 175 · Mercado Pago: saques viram transferência e cada tipo de movimento
--       vira título no contas a pagar/receber, já baixado e conciliado
-- O que muda (aprovado pelo Paulo em 25/11/2026):
--  1. Saques do Mercado Pago (payout) passam a ser lançados sozinhos como
--     transferência entre contas: MP 30 → Itaú 30 e MP 37 → Itaú 37.
--     A entrada no Itaú fica esperando o extrato do Itaú para conferir.
--  2. Regra por tipo de movimento (linha do extrato → título baixado):
--     · taxa de antecipação (fee-release_in_advance) → a pagar, "Taxa de antecipação…", fornecedor Mercado Pago
--       (só de mar/2026 em diante: jan/fev e anteriores já foram lançados no Tiny)
--     · devolução ao comprador (mediation, depois de 15 dias) → a pagar, "Estorno de vendas", fornecedor Mercado Livre
--     · saldo usado para pagar dívida (reserve_for_debt_payment) → a pagar, "Empréstimo Mercado Pago", fornecedor Mercado Crédito
--     · crédito de frete (shipping, valor positivo) → a receber, "Créditos de frete - plataformas"
--     · bonificação/ressarcimento (cashback, valor positivo) → a receber, "Reembolsos e ressarcimentos de marketplace"
--     Vale para as linhas pendentes e para as que estavam só "classificadas".
--     Roda sozinho a cada importação do extrato (dentro de extrato_compensar).
-- Para desfazer: tela de conciliação › "Desfazer conciliação" nas linhas (o título volta a ser apagado pelo desfazer).
-- =====================================================================

-- baixa conciliada feita pelo próprio sistema (rotina do extrato, sem usuário logado): mesma liberação que o
-- contas a receber já tem (nox.baixa_extrato), agora também no contas a pagar
create or replace function public.pagamentos_validar()
returns trigger language plpgsql set search_path = public as $$
declare t record; v_outros numeric(14,2);
begin
  select * into t from public.titulos_pagar where id = new.titulo_id;
  if t.situacao = 'cancelado' and not new.estornado then raise exception 'Título cancelado não recebe pagamento'; end if;
  select coalesce(sum(valor), 0) into v_outros from public.pagamentos
   where titulo_id = new.titulo_id and not estornado and id is distinct from new.id;
  if not new.estornado and v_outros + new.valor > t.valor + 0.005 then
    raise exception 'Pagamento maior que o saldo do título (saldo %)', t.valor - v_outros;
  end if;
  if tg_op = 'UPDATE' and new.estornado and not old.estornado and not public.pode_acao('pagar.estornar') then
    raise exception 'Sem permissão para estornar pagamento (peça ao gestor)';
  end if;
  if tg_op = 'UPDATE' and old.estornado and not new.estornado then raise exception 'Pagamento estornado não volta; registre um novo pagamento'; end if;
  if (tg_op = 'INSERT' and new.conciliado or tg_op = 'UPDATE' and new.conciliado is distinct from old.conciliado)
     and not public.pode_acao('pagar.conciliar')
     and not (auth.uid() is null and coalesce(current_setting('nox.baixa_extrato', true), '') = 'sim') then
    raise exception 'Sem permissão para conciliar';
  end if;
  if new.conciliado and new.conciliado_em is null then new.conciliado_em := now(); new.conciliado_por := auth.uid(); end if;
  if not new.conciliado then new.conciliado_em := null; new.conciliado_por := null; end if;
  return new;
end $$;

create or replace function public.transferencias_automaticas()
returns integer language plpgsql security definer set search_path = public as $$
declare l record; n int := 0;
begin
  perform set_config('nox.transf_auto', '1', true);
  perform set_config('nox.baixa_extrato', 'sim', true);
  for l in select x.id, c.conta_transferencia_padrao destino from public.extrato_lancamentos x join public.contas_bancarias c on c.id = x.conta_bancaria_id
            where x.conciliacao = 'pendente' and x.tipo = 'payout' and x.valor < 0 and c.conta_transferencia_padrao is not null loop
    n := n + public.extrato_transferencia(array[l.id], l.destino, false, true);
  end loop;
  perform set_config('nox.transf_auto', '', true);
  perform set_config('nox.baixa_extrato', '', true);
  return n + public.transferencias_confrontar(null);
end $$;

-- transferência entre contas: o título de saída precisa de fornecedor; passa a ser a própria empresa de destino
-- (fornecedores já cadastrados: 174 = NOX 30, 164 = NOX 37), como nas transferências lançadas à mão
create or replace function public.extrato_transferencia(p_ids bigint[], p_conta_destino bigint, p_padrao boolean default false, p_auto boolean default false)
returns integer language plpgsql security definer set search_path = public as $$
declare l record; o record; d record; v_val numeric; v_tp bigint; v_pg bigint; v_tr bigint; v_rec bigint; v_cs bigint; v_ce bigint; n int := 0; v_tx bigint;
begin
  if not (p_auto and current_setting('nox.transf_auto', true) = '1')
     and not ((select public.pode('conciliacao', 'alterar')) and (select public.pode('pagar', 'criar'))) then raise exception 'Sem permissão'; end if;
  select * into d from public.contas_bancarias where id = p_conta_destino;
  if d.id is null then raise exception 'Escolha a conta que recebe'; end if;
  for l in select * from public.extrato_lancamentos where id = any(p_ids) order by data, id for update loop
    if l.conciliacao <> 'pendente' then raise exception 'Linha de % já está %', to_char(l.data, 'DD/MM/YYYY'), l.conciliacao; end if;
    if l.valor >= 0 then raise exception 'Use a linha de SAÍDA (valor negativo) da conta de origem'; end if;
    if l.conta_bancaria_id = d.id then raise exception 'A conta de destino é a mesma da origem'; end if;
    select * into o from public.contas_bancarias where id = l.conta_bancaria_id;
    v_val := abs(l.valor);
    if o.empresa_id = d.empresa_id then
      select id into v_cs from public.categorias_financeiras where codigo = '10.05.001';
      select id into v_ce from public.categorias_financeiras where codigo = '10.05.002';
    else
      select id into v_cs from public.categorias_financeiras where codigo = '10.01.001';
      select id into v_ce from public.categorias_financeiras where codigo = '10.01.002';
    end if;
    insert into public.transferencias_contas (data, valor, conta_origem_id, conta_destino_id, extrato_saida_id, automatica, observacao)
    values (l.data, v_val, o.id, d.id, l.id, p_auto, concat_ws(' · ', l.tipo, l.id_operacao)) returning id into v_tx;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento, data_programada,
        conta_bancaria_id, origem, origem_ref, projecao, situacao, valor_pago, saldo)
    values (o.empresa_id, case d.empresa_id when 1 then 174 when 2 then 164 end, 'TRANSF ' || v_tx, upper('Transferência ' || o.descricao || ' → ' || d.descricao), v_cs, v_val, l.data, l.data, l.data,
        o.id, 'manual', jsonb_build_object('transferencia_id', v_tx, 'extrato_id', l.id, 'id_operacao', l.id_operacao), false, 'aberto', 0, v_val)
    returning id into v_tp;
    insert into public.pagamentos (titulo_id, data_pagamento, valor, conta_bancaria_id, identificador, conciliado, conciliado_em, conciliado_por, observacoes)
    values (v_tp, l.data, v_val, o.id, coalesce(l.id_operacao, 'transf:' || v_tx), true, now(), auth.uid(), 'Transferência #' || v_tx || ' (saída)')
    returning id into v_pg;
    update public.extrato_lancamentos set conciliacao = 'conciliado', pagamento_id = v_pg, categoria_financeira_id = v_cs, conciliado_em = now(), conciliado_por = auth.uid(),
           observacoes = concat_ws(' · ', observacoes, 'Transferência #' || v_tx || ' para ' || d.descricao) where id = l.id;
    insert into public.titulos_receber (empresa_id, cliente_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento,
        conta_bancaria_id, origem, origem_ref, projecao, situacao, valor_recebido, saldo)
    values (d.empresa_id, (select c.id from public.clientes c join public.empresas e on c.cpf_cnpj = regexp_replace(e.cnpj, '\D', '', 'g') where e.id = o.empresa_id order by c.id limit 1),
        'TRANSF ' || v_tx, upper('Transferência ' || o.descricao || ' → ' || d.descricao), v_ce, v_val, l.data, l.data,
        d.id, 'manual', jsonb_build_object('transferencia_id', v_tx, 'extrato_saida_id', l.id), false, 'aberto', 0, v_val)
    returning id into v_tr;
    insert into public.recebimentos (titulo_id, data_recebimento, valor, conta_bancaria_id, identificador, conciliado, observacoes)
    values (v_tr, l.data, v_val, d.id, 'transf:' || v_tx, false, 'Transferência #' || v_tx || ' (entrada) · aguardando o extrato de ' || d.descricao)
    returning id into v_rec;
    update public.transferencias_contas set titulo_pagar_id = v_tp, titulo_receber_id = v_tr, recebimento_id = v_rec where id = v_tx;
    perform public.transferencias_confrontar(d.id);
    n := n + 1;
  end loop;
  if p_padrao then update public.contas_bancarias set conta_transferencia_padrao = d.id where id = (select conta_bancaria_id from public.extrato_lancamentos where id = p_ids[1]); end if;
  return n;
end $$;

-- a entrada da transferência (contas a receber) precisa de cliente: a própria empresa de origem
insert into public.clientes (tipo_pessoa, nome, cpf_cnpj, tipo_cliente)
select 'J', 'NOX 37  37.360.527/0001-37', '37360527000137', 'consumidor'
 where not exists (select 1 from public.clientes where cpf_cnpj = '37360527000137');

update public.contas_bancarias set conta_transferencia_padrao = 1 where id = 2 and conta_transferencia_padrao is null;   -- MP 30 → Itaú 30
update public.contas_bancarias set conta_transferencia_padrao = 8 where id = 10 and conta_transferencia_padrao is null;  -- MP 37 → Itaú 37

create or replace function public.extrato_lancar_regras_mp(p_conta bigint default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  l record; r record; v_emp int; v_tit bigint; v_baixa bigint; n int := 0; v_val numeric; v_desc text;
begin
  if auth.uid() is not null and not (select public.pode('conciliacao', 'alterar')) then raise exception 'Sem permissão'; end if;
  perform set_config('nox.baixa_extrato', 'sim', true);
  for l in
    select e.*, cb.empresa_id emp
      from public.extrato_lancamentos e join public.contas_bancarias cb on cb.id = e.conta_bancaria_id
     where cb.banco = 'Mercado Pago' and (p_conta is null or e.conta_bancaria_id = p_conta)
       and (e.conciliacao = 'pendente'
            or (e.conciliacao = 'classificado' and e.pagamento_id is null and e.recebimento_id is null and e.titulo_receber_id is null))
       and (   (e.tipo = 'fee-release_in_advance' and e.valor < 0 and e.data >= date '2026-03-01')
            or (e.tipo = 'mediation' and e.valor < 0 and (e.conciliacao = 'classificado' or e.data < current_date - 15))
            or (e.tipo = 'reserve_for_debt_payment' and e.valor < 0 and e.conciliacao = 'pendente')
            or (e.tipo in ('shipping', 'cashback') and e.valor > 0))
     order by e.data, e.id
     for update of e
  loop
    select case l.tipo
             when 'fee-release_in_advance' then 125 when 'mediation' then 66 when 'reserve_for_debt_payment' then 97
             when 'shipping' then 219 else 321 end cat,
           case l.tipo
             when 'fee-release_in_advance' then 216 when 'mediation' then 160 when 'reserve_for_debt_payment' then 260 end forn,
           case l.tipo
             when 'fee-release_in_advance' then 'TAXA DE ANTECIPAÇÃO DO MERCADO PAGO'
             when 'mediation' then 'ESTORNO DE VENDA (DEVOLUÇÃO AO COMPRADOR NO ML)'
             when 'reserve_for_debt_payment' then 'EMPRÉSTIMO MERCADO PAGO (DESCONTADO DO SALDO)'
             when 'shipping' then 'CRÉDITO DE FRETE DO MERCADO LIVRE'
             else 'BONIFICAÇÃO / RESSARCIMENTO DO MERCADO LIVRE' end txt
      into r;
    v_val := abs(l.valor);
    v_desc := r.txt || coalesce(' · VENDA ' || l.pedido_externo, '');
    if l.valor < 0 then
      insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento, data_programada,
          conta_bancaria_id, origem, origem_ref, projecao, situacao, valor_pago, saldo)
      values (l.emp, r.forn, 'EXTRATO ' || coalesce(l.id_operacao, l.id::text), v_desc, r.cat, v_val, l.data, l.data, l.data,
          l.conta_bancaria_id, 'manual', jsonb_build_object('extrato_id', l.id, 'id_operacao', l.id_operacao, 'tipo_extrato', l.tipo, 'regra', '175'), false, 'aberto', 0, v_val)
      returning id into v_tit;
      insert into public.pagamentos (titulo_id, data_pagamento, valor, conta_bancaria_id, identificador, conciliado, conciliado_em, conciliado_por, observacoes)
      values (v_tit, l.data, v_val, l.conta_bancaria_id, coalesce(l.id_operacao, 'extrato:' || l.id), true, now(), auth.uid(), 'Lançado e baixado pela regra do Mercado Pago (175), linha #' || l.id)
      returning id into v_baixa;
      update public.extrato_lancamentos set conciliacao = 'conciliado', pagamento_id = v_baixa, categoria_financeira_id = r.cat, conciliado_em = now(), conciliado_por = auth.uid(),
             observacoes = concat_ws(' · ', observacoes, 'Título a pagar #' || v_tit || ' pela regra 175')
       where id = l.id;
    else
      insert into public.titulos_receber (empresa_id, canal_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento,
          conta_bancaria_id, origem, origem_ref, projecao, situacao, valor_recebido, saldo)
      values (l.emp, (select id from public.canais_venda where empresa_id = l.emp and plataforma = 'mercado_livre' order by id limit 1), 'EXTRATO ' || coalesce(l.id_operacao, l.id::text), v_desc, r.cat, v_val, l.data, l.data,
          l.conta_bancaria_id, 'manual', jsonb_build_object('extrato_id', l.id, 'id_operacao', l.id_operacao, 'tipo_extrato', l.tipo, 'regra', '175'), false, 'aberto', 0, v_val)
      returning id into v_tit;
      insert into public.recebimentos (titulo_id, data_recebimento, valor, conta_bancaria_id, identificador, conciliado, conciliado_em, conciliado_por, observacoes)
      values (v_tit, l.data, v_val, l.conta_bancaria_id, coalesce(l.id_operacao, 'extrato:' || l.id), true, now(), auth.uid(), 'Lançado e baixado pela regra do Mercado Pago (175), linha #' || l.id)
      returning id into v_baixa;
      update public.extrato_lancamentos set conciliacao = 'conciliado', titulo_receber_id = v_tit, recebimento_id = v_baixa, categoria_financeira_id = r.cat,
             conciliado_em = now(), conciliado_por = auth.uid(), observacoes = concat_ws(' · ', observacoes, 'Título a receber #' || v_tit || ' pela regra 175')
       where id = l.id;
    end if;
    n := n + 1;
  end loop;
  perform set_config('nox.baixa_extrato', '', true);
  return n;
end $$;
revoke execute on function public.extrato_lancar_regras_mp(bigint) from public, anon, authenticated;

-- roda junto com a compensação automática que já acontece a cada importação do extrato
create or replace function public.extrato_compensar(p_conta bigint default null)
returns integer language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with op as (
    select conta_bancaria_id c, id_operacao from public.extrato_lancamentos
     where conciliacao = 'pendente' and id_operacao is not null and (p_conta is null or conta_bancaria_id = p_conta)
     group by 1, 2 having count(*) > 1 and abs(sum(valor)) < 0.005 and bool_or(valor > 0) and bool_or(valor < 0)),
  g as (select c, id_operacao, gen_random_uuid() gid from op),
  u as (update public.extrato_lancamentos l set conciliacao = 'compensado', grupo_compensacao = g.gid, conciliado_em = now(), conciliado_por = auth.uid(),
          observacoes = coalesce(l.observacoes || ' · ', '') || 'Compensado: linhas da mesma operação somam zero (disputa/reserva/estorno do ML)'
        from g where l.conta_bancaria_id = g.c and l.id_operacao = g.id_operacao and l.conciliacao = 'pendente' returning 1)
  select count(*) into n from u;
  n := n + public.extrato_compensar_pares(p_conta);
  n := n + public.extrato_classificar_auto(p_conta);
  n := n + public.extrato_lancar_regras_mp(p_conta);
  perform public.transferencias_automaticas();
  return n;
end $$;

-- aplica agora no que já está no extrato
select public.transferencias_automaticas();
select public.extrato_lancar_regras_mp(null);
