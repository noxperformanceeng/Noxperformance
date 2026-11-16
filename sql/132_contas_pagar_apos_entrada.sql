-- =====================================================================
-- 132 · Contas a pagar só depois da entrada no almoxarifado (pedido do Paulo)
-- O que muda:
--   1. "Dar entrada da NF" no pedido de compra (antes "Registrar recebimento") passa a fazer só a parte
--      do almoxarifado: soma o que chegou, dá entrada no estoque (com local por item) e muda o pedido
--      para "Entregue parcial"/"Recebido". NÃO cria mais título real no contas a pagar.
--      Quem pode: Compras e, agora, o perfil Estoque / Almoxarifado. O Financeiro deixa de poder.
--   2. A NF com entrada dada fica no contas a pagar como previsão ("NF recebida · aguardando o financeiro"),
--      com o pagamento bloqueado, e entra na fila "NF recebidas para lançar" do Contas a pagar.
--   3. O financeiro confere e lança (vira título real) ou devolve com o motivo. Devolvida, Compras ou o
--      almoxarifado acerta e reenvia ao financeiro.
--   4. NF sem pedido aprovada pelo master: o almoxarifado dá a entrada no estoque (tela Notas fiscais) e só
--      depois o financeiro lança no contas a pagar.
--   5. Contador vermelho no menu (Contas a pagar: fila do financeiro; Pedidos de compra: NF devolvidas) e
--      avisos em Aprovações pendentes.
--   6. O perfil Estoque / Almoxarifado passa a ver a tela Notas fiscais (só ver).
-- Não apaga nada. Até hoje nenhum recebimento foi registrado, então não há nada no meio do caminho.
-- =====================================================================

-- 1. Situação no financeiro de cada entrada (recebimento) do pedido de compra
alter table public.pedidos_compra_recebimentos add column if not exists situacao_financeiro text not null default 'aguardando';
alter table public.pedidos_compra_recebimentos add column if not exists parcelas jsonb;
alter table public.pedidos_compra_recebimentos add column if not exists lancado_por uuid;
alter table public.pedidos_compra_recebimentos add column if not exists lancado_em timestamptz;
alter table public.pedidos_compra_recebimentos add column if not exists devolvido_motivo text;
alter table public.pedidos_compra_recebimentos add column if not exists devolvido_por uuid;
alter table public.pedidos_compra_recebimentos add column if not exists devolvido_em timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pc_receb_situacao_financeiro_ck') then
    alter table public.pedidos_compra_recebimentos add constraint pc_receb_situacao_financeiro_ck
      check (situacao_financeiro in ('aguardando', 'lancado', 'devolvido'));
  end if;
end $$;
comment on column public.pedidos_compra_recebimentos.situacao_financeiro is 'aguardando = entrada dada, falta o financeiro lançar; lancado = títulos reais criados; devolvido = financeiro devolveu (ver devolvido_motivo)';
comment on column public.pedidos_compra_recebimentos.parcelas is 'Parcelas sugeridas (duplicatas da NF ou condição do pedido): [{vencimento, valor, codigo_barras}]';
-- recebimentos antigos que já tenham título real ficam como lançados
update public.pedidos_compra_recebimentos r set situacao_financeiro = 'lancado'
 where situacao_financeiro = 'aguardando'
   and exists (select 1 from public.titulos_pagar t where t.origem = 'pedido_compra' and not t.projecao and t.origem_ref->>'recebimento_id' = r.id::text);

-- NF sem pedido: quem deu a entrada no estoque
alter table public.nfe_entrada add column if not exists entrada_por uuid;
alter table public.nfe_entrada add column if not exists entrada_em timestamptz;

-- Almoxarifado vê a tela Notas fiscais (para dar entrada da NF sem pedido aprovada pelo master)
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('estoque', 'notas', 'ver') on conflict do nothing;

-- 2. Parcelas sugeridas: duplicatas da NF importada (se somarem o valor) ou condição/prazo do pedido a partir da emissão
create or replace function public.pc_parcelas_sugeridas(p_id bigint, p_valor numeric, p_emissao date, p_chave text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.pedidos_compra; v_dup jsonb; v_dias int[]; v_n int; v_i int; v_v numeric; v_acum numeric := 0; v jsonb := '[]';
begin
  select * into p from public.pedidos_compra where id = p_id;
  if p_chave is not null then
    select duplicatas into v_dup from public.nfe_entrada where chave = p_chave;
    if jsonb_array_length(coalesce(v_dup, '[]')) > 0
       and abs((select sum((d->>'valor')::numeric) from jsonb_array_elements(v_dup) d) - p_valor) <= 0.01 then
      return (select jsonb_agg(jsonb_build_object('vencimento', d->>'vencimento', 'valor', round((d->>'valor')::numeric, 2))) from jsonb_array_elements(v_dup) d);
    end if;
  end if;
  select dias into v_dias from public.condicoes_pagamento where id = p.condicao_pagamento_id;
  if v_dias is null or cardinality(v_dias) = 0 then v_dias := p.prazo_livre_dias; end if;
  if v_dias is null or cardinality(v_dias) = 0 then v_dias := array[coalesce(public.p_dias_padrao_fornecedor(p.fornecedor_id), 0)]; end if;
  v_n := cardinality(v_dias);
  for v_i in 1..v_n loop
    v_v := case when v_i = v_n then round(p_valor - v_acum, 2) else round(p_valor / v_n, 2) end; v_acum := v_acum + v_v;
    v := v || jsonb_build_object('vencimento', coalesce(p_emissao, current_date) + v_dias[v_i], 'valor', v_v);
  end loop;
  return v;
end $$;
revoke execute on function public.pc_parcelas_sugeridas(bigint, numeric, date, text) from public, anon, authenticated;

-- 3. Previsão de cada entrada aguardando o financeiro (sai quando o financeiro lança)
create or replace function public.pc_projetar_recebimento(p_rec bigint)
returns integer language plpgsql security definer set search_path = public as $$
declare r public.pedidos_compra_recebimentos; p public.pedidos_compra; v_cat bigint; x jsonb; v_i int := 0; v_n int;
begin
  select * into r from public.pedidos_compra_recebimentos where id = p_rec;
  delete from public.titulos_pagar where origem = 'pedido_compra' and projecao and coalesce(valor_pago, 0) = 0
     and origem_ref->>'recebimento_id' = p_rec::text;
  if r.id is null or r.situacao_financeiro = 'lancado' then return 0; end if;
  select * into p from public.pedidos_compra where id = r.pedido_id;
  select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) into v_cat
    from jsonb_to_recordset(coalesce(r.itens, '[]')) q(item_id bigint, quantidade numeric)
    join public.pedidos_compra_itens i on i.id = q.item_id left join public.produtos pr on pr.id = i.produto_id
   where q.quantidade > 0 group by 1 order by sum(i.valor_total * q.quantidade / nullif(i.quantidade, 0)) desc nulls last limit 1;
  v_n := jsonb_array_length(coalesce(r.parcelas, '[]'));
  for x in select * from jsonb_array_elements(coalesce(r.parcelas, '[]')) loop
    v_i := v_i + 1;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao,
      data_vencimento, data_programada, conta_bancaria_id, forma_pagamento_id, parcela, parcelas, origem, origem_ref, projecao,
      pedido_compra_id, situacao, valor_pago, saldo, observacoes)
    values (p.empresa_id, p.fornecedor_id, case when r.nf_numero = 'SEM NF' then p.numero else 'NF ' || r.nf_numero end,
      case when r.nf_numero = 'SEM NF' then 'Serviço ' || p.numero else 'NF ' || r.nf_numero || ' · ' || p.numero end
        || case when r.situacao_financeiro = 'devolvido' then ' · devolvida pelo financeiro' else ' · recebida, aguardando o financeiro lançar' end,
      v_cat, round((x->>'valor')::numeric, 2), r.nf_data_emissao, (x->>'vencimento')::date, (x->>'vencimento')::date,
      p.conta_bancaria_id, p.forma_pagamento_id, v_i, v_n, 'pedido_compra',
      jsonb_build_object('pedido_compra', p.numero, 'recebimento_id', r.id, 'nf', r.nf_numero, 'aguardando_financeiro', true), true,
      p.id, 'aberto', 0, round((x->>'valor')::numeric, 2),
      'Entrada dada pelo almoxarifado. Vira título real quando o financeiro lançar (Contas a pagar › NF recebidas para lançar).');
  end loop;
  return v_i;
end $$;
revoke execute on function public.pc_projetar_recebimento(bigint) from public, anon, authenticated;

-- A previsão do saldo do pedido não apaga a previsão das entradas aguardando o financeiro
create or replace function public.pc_projetar(p_id bigint)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare p public.pedidos_compra; v_pend numeric; v_dias int[]; v_n int; v_base date; v_cat bigint; v_i int; v_v numeric; v_acum numeric := 0;
begin
  select * into p from public.pedidos_compra where id = p_id;
  delete from public.titulos_pagar where pedido_compra_id = p_id and projecao and coalesce(valor_pago, 0) = 0 and origem = 'pedido_compra'
     and not (coalesce(origem_ref, '{}') ? 'recebimento_id');
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
      'Projeção automática do pedido aprovado. Vira título real depois da entrada da NF (almoxarifado) e do lançamento pelo financeiro.');
  end loop;
  return v_n;
end $function$;

-- 4. Dar entrada da NF no pedido (almoxarifado / compras): estoque e quantidades, sem título real
create or replace function public.pedido_compra_receber(p_id bigint, p_nf jsonb, p_itens jsonb, p_parcelas jsonb)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare p public.pedidos_compra; v_rec bigint; v_valor numeric; v_soma numeric; x jsonb; v_n int;
        v_nf text; v_servico boolean; v_sem_nf boolean; v_parc jsonb; v_emissao date; v_chave text;
begin
  select * into p from public.pedidos_compra where id = p_id for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if not (public.pode('compras', 'alterar') or public.pode('estoque', 'alterar')) then
    raise exception 'Só o almoxarifado ou compras dá entrada da NF (o financeiro lança depois, pela fila do Contas a pagar)';
  end if;
  if p.situacao not in ('aprovado','enviado','recebido_parcial') then raise exception 'Pedido precisa estar aprovado para receber'; end if;
  select count(*) > 0 and bool_and(i.tipo_item = 'servico_usinagem' or i.servico_id is not null) into v_servico
    from jsonb_to_recordset(coalesce(p_itens, '[]')) r(item_id bigint, quantidade numeric)
    join public.pedidos_compra_itens i on i.id = r.item_id and i.pedido_id = p_id where r.quantidade > 0;
  v_nf := nullif(trim(p_nf->>'numero'), '');
  if v_nf is not null and upper(v_nf) = 'SEM NF' then raise exception 'Informe o número da NF'; end if;
  v_sem_nf := v_nf is null and coalesce(v_servico, false);
  if v_nf is null then
    if v_sem_nf then v_nf := 'SEM NF'; else raise exception 'Informe o número da NF'; end if;
  end if;
  v_valor := round((p_nf->>'valor')::numeric, 2);
  if coalesce(v_valor, 0) <= 0 then raise exception 'Informe o valor %', case when v_sem_nf then 'do serviço' else 'da NF' end; end if;
  v_emissao := coalesce(nullif(p_nf->>'data_emissao', '')::date, current_date);
  v_chave := nullif(p_nf->>'chave', '');
  -- parcelas: as informadas (se vierem) ou sugeridas pelas duplicatas da NF / condição do pedido; o financeiro confirma ao lançar
  if jsonb_array_length(coalesce(p_parcelas, '[]')) > 0 then
    select coalesce(sum(round((y->>'valor')::numeric, 2)), 0), count(*) into v_soma, v_n from jsonb_array_elements(p_parcelas) y;
    if abs(v_soma - v_valor) > 0.01 then raise exception 'Soma das parcelas (%) diferente do valor (%)', v_soma, v_valor; end if;
    v_parc := p_parcelas;
  else
    v_parc := public.pc_parcelas_sugeridas(p_id, v_valor, v_emissao, v_chave);
  end if;
  for x in select * from jsonb_array_elements(coalesce(p_itens, '[]')) loop
    if coalesce((x->>'quantidade')::numeric, 0) > 0 then
      update public.pedidos_compra_itens set quantidade_recebida = quantidade_recebida + (x->>'quantidade')::numeric
       where id = (x->>'item_id')::bigint and pedido_id = p_id;
    end if;
  end loop;
  insert into public.pedidos_compra_recebimentos (pedido_id, nf_numero, nf_serie, nf_chave, nf_data_emissao, data_recebimento, valor_nf, itens, observacao,
    situacao_financeiro, parcelas)
  values (p_id, v_nf, nullif(p_nf->>'serie', ''), v_chave, v_emissao,
          coalesce(nullif(p_nf->>'data_recebimento', '')::date, current_date), v_valor, p_itens, nullif(p_nf->>'observacao', ''),
          'aguardando', v_parc)
  returning id into v_rec;
  update public.pedidos_compra set valor_recebido = valor_recebido + v_valor,
    situacao = case when not exists (select 1 from public.pedidos_compra_itens where pedido_id = p_id and quantidade_recebida < quantidade) then 'recebido' else 'recebido_parcial' end
  where id = p_id;
  perform public.pc_projetar(p_id);
  perform public.pc_projetar_recebimento(v_rec);
  perform public.pc_evento(p_id, 'recebido',
    case when v_sem_nf then 'Serviço recebido sem NF · ' else 'Entrada da NF ' || v_nf || ' · ' end
      || 'R$ ' || to_char(v_valor, 'FM999G999G990D00') || ' · aguardando o financeiro lançar no contas a pagar',
    jsonb_build_object('recebimento_id', v_rec));
  return v_rec;
end $function$;

-- 5. Financeiro: lançar (títulos reais), devolver ou (compras/almoxarifado) reenviar
create or replace function public.pc_recebimento_lancar(p_rec bigint, p_parcelas jsonb default null, p_categoria bigint default null)
returns integer language plpgsql security definer set search_path = public as $$
declare r public.pedidos_compra_recebimentos; p public.pedidos_compra; v_parc jsonb; v_soma numeric; v_n int; v_i int := 0; x jsonb; v_tid bigint;
        v_cats jsonb; v_ncat int; v_item_tot numeric; v_c record; v_acum numeric; v_parte numeric; v_k int; v_sem_nf boolean; v_doc text;
begin
  if not (select public.pode('pagar', 'criar')) then raise exception 'Sem permissão no contas a pagar'; end if;
  select * into r from public.pedidos_compra_recebimentos where id = p_rec for update;
  if r.id is null then raise exception 'Entrada não encontrada'; end if;
  if r.situacao_financeiro = 'lancado' then raise exception 'Esta NF já foi lançada no contas a pagar'; end if;
  if r.situacao_financeiro = 'devolvido' then raise exception 'Esta NF foi devolvida: espere compras/almoxarifado reenviar'; end if;
  select * into p from public.pedidos_compra where id = r.pedido_id;
  v_sem_nf := r.nf_numero = 'SEM NF';
  v_doc := case when v_sem_nf then 'Pedido ' || p.numero else 'NF ' || r.nf_numero end;
  v_parc := case when jsonb_array_length(coalesce(p_parcelas, '[]')) > 0 then p_parcelas else r.parcelas end;
  select coalesce(sum(round((y->>'valor')::numeric, 2)), 0), count(*) into v_soma, v_n from jsonb_array_elements(coalesce(v_parc, '[]')) y;
  if v_n = 0 then raise exception 'Informe as parcelas'; end if;
  if exists (select 1 from jsonb_array_elements(v_parc) y where nullif(y->>'vencimento', '') is null) then raise exception 'Parcela sem vencimento'; end if;
  if abs(v_soma - r.valor_nf) > 0.01 then raise exception 'Soma das parcelas (%) diferente do valor da NF (%)', v_soma, r.valor_nf; end if;
  -- tira a previsão desta entrada
  delete from public.titulos_pagar where origem = 'pedido_compra' and projecao and coalesce(valor_pago, 0) = 0
     and origem_ref->>'recebimento_id' = p_rec::text;
  -- categorias dos itens recebidos (rateio quando houver mais de uma)
  select coalesce(jsonb_agg(jsonb_build_object('c', c, 'v', v)), '[]'), count(*) into v_cats, v_ncat from (
    select coalesce(i.categoria_financeira_id, pr.categoria_financeira_id) c, sum(round(i.valor_total * (q.quantidade / i.quantidade), 2)) v
    from jsonb_to_recordset(coalesce(r.itens, '[]')) q(item_id bigint, quantidade numeric)
    join public.pedidos_compra_itens i on i.id = q.item_id and i.pedido_id = r.pedido_id
    left join public.produtos pr on pr.id = i.produto_id
    where q.quantidade > 0 group by 1) s;
  select coalesce(sum((e->>'v')::numeric), 0) into v_item_tot from jsonb_array_elements(v_cats) e;
  for x in select * from jsonb_array_elements(v_parc) loop
    v_i := v_i + 1;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento,
      data_programada, conta_bancaria_id, forma_pagamento_id, codigo_barras, parcela, parcelas, origem, origem_ref, projecao, pedido_compra_id, situacao, valor_pago, saldo)
    values (p.empresa_id, p.fornecedor_id, v_doc, case when v_sem_nf then v_doc || ' · serviço' else v_doc || ' · ' || p.numero end,
      coalesce(p_categoria, case when v_ncat = 1 then ((v_cats->0)->>'c')::bigint end), round((x->>'valor')::numeric, 2),
      r.nf_data_emissao, (x->>'vencimento')::date, (x->>'vencimento')::date, p.conta_bancaria_id, p.forma_pagamento_id, nullif(x->>'codigo_barras', ''),
      v_i, v_n, 'pedido_compra', jsonb_build_object('pedido_compra', p.numero, 'recebimento_id', r.id, 'nf', r.nf_numero), false, p.id, 'aberto', 0, round((x->>'valor')::numeric, 2))
    returning id into v_tid;
    if p_categoria is null and v_ncat > 1 and v_item_tot > 0 and not exists (select 1 from jsonb_array_elements(v_cats) e where e->>'c' is null) then
      v_acum := 0; v_k := 0;
      for v_c in select (e->>'c')::bigint c, (e->>'v')::numeric v from jsonb_array_elements(v_cats) e order by (e->>'v')::numeric loop
        v_k := v_k + 1;
        v_parte := case when v_k = v_ncat then round((x->>'valor')::numeric, 2) - v_acum else round((x->>'valor')::numeric * v_c.v / v_item_tot, 2) end;
        v_acum := v_acum + v_parte;
        insert into public.titulos_pagar_rateio (titulo_id, categoria_financeira_id, valor, observacao) values (v_tid, v_c.c, v_parte, p.numero);
      end loop;
    end if;
  end loop;
  update public.pedidos_compra_recebimentos set situacao_financeiro = 'lancado', parcelas = v_parc, lancado_por = auth.uid(), lancado_em = now() where id = p_rec;
  perform public.pc_evento(r.pedido_id, 'lancado_cp', v_doc || ' lançada no contas a pagar pelo financeiro · ' || v_n || ' parcela(s)', jsonb_build_object('recebimento_id', p_rec));
  return v_n;
end $$;
revoke execute on function public.pc_recebimento_lancar(bigint, jsonb, bigint) from public, anon;
grant execute on function public.pc_recebimento_lancar(bigint, jsonb, bigint) to authenticated;

create or replace function public.pc_recebimento_acao(p_rec bigint, p_acao text, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r public.pedidos_compra_recebimentos;
begin
  select * into r from public.pedidos_compra_recebimentos where id = p_rec for update;
  if r.id is null then raise exception 'Entrada não encontrada'; end if;
  if p_acao = 'devolver' then
    if not (select public.pode('pagar', 'criar')) then raise exception 'Sem permissão no contas a pagar'; end if;
    if r.situacao_financeiro <> 'aguardando' then raise exception 'Só NF aguardando o financeiro pode ser devolvida'; end if;
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo da devolução'; end if;
    update public.pedidos_compra_recebimentos set situacao_financeiro = 'devolvido', devolvido_motivo = trim(p_motivo), devolvido_por = auth.uid(), devolvido_em = now() where id = p_rec;
    perform public.pc_evento(r.pedido_id, 'devolvido_financeiro', 'NF ' || r.nf_numero || ' devolvida pelo financeiro: ' || trim(p_motivo), jsonb_build_object('recebimento_id', p_rec));
  elsif p_acao = 'reenviar' then
    if not (public.pode('compras', 'alterar') or public.pode('estoque', 'alterar')) then raise exception 'Sem permissão'; end if;
    if r.situacao_financeiro <> 'devolvido' then raise exception 'Só NF devolvida pode ser reenviada'; end if;
    update public.pedidos_compra_recebimentos set situacao_financeiro = 'aguardando',
      observacao = concat_ws(' · ', observacao, 'Devolvida: ' || devolvido_motivo, nullif('Resposta: ' || coalesce(trim(p_motivo), ''), 'Resposta: '))
     where id = p_rec;
    perform public.pc_evento(r.pedido_id, 'reenviado_financeiro', 'NF ' || r.nf_numero || ' reenviada ao financeiro' || coalesce(': ' || nullif(trim(p_motivo), ''), ''), jsonb_build_object('recebimento_id', p_rec));
  else raise exception 'Ação desconhecida'; end if;
  perform public.pc_projetar_recebimento(p_rec);
end $$;
revoke execute on function public.pc_recebimento_acao(bigint, text, text) from public, anon;
grant execute on function public.pc_recebimento_acao(bigint, text, text) to authenticated;

-- 6. NF sem pedido aprovada pelo master: almoxarifado dá entrada no estoque; o financeiro lança depois
create or replace function public.nfe_dar_entrada(p_id bigint, p_destinos jsonb default null)
returns integer language plpgsql security definer set search_path = public as $$
declare r public.nfe_entrada; v_n int;
begin
  if not (public.pode('estoque', 'alterar') or public.pode('compras', 'alterar')) then raise exception 'Só o almoxarifado ou compras dá entrada no estoque'; end if;
  select * into r from public.nfe_entrada where id = p_id for update;
  if r.id is null then raise exception 'NF não encontrada'; end if;
  if r.situacao <> 'aprovada' then raise exception 'Só NF sem pedido aprovada pelo master entra por aqui; com pedido, dê entrada no pedido de compra'; end if;
  if r.entrada_em is not null then raise exception 'A entrada desta NF já foi dada'; end if;
  if r.fornecedor_id is null then raise exception 'Vincule o fornecedor da NF'; end if;
  insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, quantidade_compra, unidade_compra, fator, custo_unitario, nfe_entrada_id, observacao, data)
  select y.produto_id, 'entrada_compra', y.qtd * y.fator, y.unidade, y.qtd, y.un_doc, y.fator,
         round(y.valor / nullif(y.qtd * y.fator, 0), 6), r.id, 'NF ' || r.numero || ' (sem pedido)', r.data_emissao
    from (select distinct on (it.ord) pf.produto_id, pr.unidade, (it.v->>'quantidade')::numeric qtd, (it.v->>'valor')::numeric valor, it.v->>'unidade' un_doc,
                 public.fator_entrada(pf.produto_id, r.fornecedor_id, it.v->>'unidade') fator
            from jsonb_array_elements(coalesce(r.itens, '[]')) with ordinality it(v, ord)
            join public.produto_fornecedores pf on pf.fornecedor_id = r.fornecedor_id and pf.codigo_fornecedor = it.v->>'codigo'
            join public.produtos pr on pr.id = pf.produto_id
           where pr.controla_estoque
           order by it.ord, pf.preferencial desc nulls last, pf.id) y;
  get diagnostics v_n = row_count;
  update public.nfe_entrada set entrada_por = auth.uid(), entrada_em = now() where id = r.id;
  perform public.estoque_aplicar_destinos(null, p_id, p_destinos);
  return v_n;
end $$;
revoke execute on function public.nfe_dar_entrada(bigint, jsonb) from public, anon;
grant execute on function public.nfe_dar_entrada(bigint, jsonb) to authenticated;

create or replace function public.nfe_lancar_cp(p_id bigint, p_categoria bigint, p_conta bigint DEFAULT NULL::bigint, p_parcelas jsonb DEFAULT NULL::jsonb)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare r public.nfe_entrada; v_parc jsonb; x jsonb; v_n int; v_i int := 0; v_soma numeric;
begin
  if not (select public.pode('pagar', 'criar')) then raise exception 'Sem permissão no contas a pagar'; end if;
  select * into r from public.nfe_entrada where id = p_id for update;
  if r.situacao <> 'aprovada' then raise exception 'Só NF aprovada pelo master (sem pedido) é lançada por aqui; com pedido, o financeiro lança pela fila "NF recebidas para lançar"'; end if;
  if r.entrada_em is null then raise exception 'O almoxarifado ainda não deu entrada desta NF (tela Notas fiscais › Dar entrada no estoque)'; end if;
  if r.fornecedor_id is null then raise exception 'Vincule o fornecedor da NF'; end if;
  if p_categoria is null then raise exception 'Escolha a categoria financeira'; end if;
  v_parc := coalesce(p_parcelas, case when jsonb_array_length(coalesce(r.duplicatas, '[]')) > 0
    then (select jsonb_agg(jsonb_build_object('vencimento', d->>'vencimento', 'valor', d->>'valor')) from jsonb_array_elements(r.duplicatas) d)
    else jsonb_build_array(jsonb_build_object('vencimento', (r.data_emissao at time zone 'America/Sao_Paulo')::date, 'valor', r.valor_total)) end);
  select count(*), sum((x2->>'valor')::numeric) into v_n, v_soma from jsonb_array_elements(v_parc) x2;
  if abs(v_soma - r.valor_total) > 0.01 then raise exception 'Parcelas (%) diferentes do valor da NF (%)', v_soma, r.valor_total; end if;
  for x in select * from jsonb_array_elements(v_parc) loop
    v_i := v_i + 1;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento, data_programada,
      conta_bancaria_id, parcela, parcelas, origem, origem_ref, projecao, nf_entrada_id, situacao, valor_pago, saldo)
    values (r.empresa_id, r.fornecedor_id, 'NF ' || r.numero, 'NF ' || r.numero || ' · sem pedido (aprovada pelo master)', p_categoria, (x->>'valor')::numeric,
      (r.data_emissao at time zone 'America/Sao_Paulo')::date, (x->>'vencimento')::date, (x->>'vencimento')::date, p_conta, v_i, v_n, 'nf_entrada',
      jsonb_build_object('nf', r.numero, 'chave', r.chave, 'aprovada_por', r.aprovada_por), false, r.id, 'aberto', 0, (x->>'valor')::numeric);
  end loop;
  update public.nfe_entrada set situacao = 'lancada' where id = r.id;
  return v_n;
end $function$;

-- a versão antiga (com destinos) só lança: o estoque já entrou pelo almoxarifado
create or replace function public.nfe_lancar_cp_destinos(p_id bigint, p_categoria bigint, p_conta bigint DEFAULT NULL::bigint, p_parcelas jsonb DEFAULT NULL::jsonb, p_destinos jsonb DEFAULT NULL::jsonb)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  return public.nfe_lancar_cp(p_id, p_categoria, p_conta, p_parcelas);
end $function$;

-- Pagamento da previsão continua bloqueado (mensagem nova)
create or replace function public.pagamento_projecao_pc()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
begin
  if exists (select 1 from public.titulos_pagar t where t.id = new.titulo_id and t.origem = 'pedido_compra' and t.projecao) then
    raise exception 'Este título é a previsão de um pedido de compra: o almoxarifado dá entrada da NF e o financeiro lança pela fila "NF recebidas para lançar"; pague o título real';
  end if;
  return new;
end $function$;

-- 7. Fila do financeiro (lista para a tela Contas a pagar)
create or replace function public.cp_fila_nf_recebidas()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'recebida_em', x->>'id'), '[]') from (
    select jsonb_build_object('tipo', 'pedido', 'id', r.id, 'situacao', r.situacao_financeiro, 'nf', r.nf_numero, 'serie', r.nf_serie, 'chave', r.nf_chave,
      'emissao', r.nf_data_emissao, 'recebida_em', r.data_recebimento, 'valor', r.valor_nf, 'parcelas', r.parcelas, 'itens', r.itens,
      'devolvido_motivo', r.devolvido_motivo, 'quem', u.nome, 'pedido_id', p.id, 'pedido', p.numero, 'empresa_id', p.empresa_id,
      'fornecedor_id', p.fornecedor_id, 'fornecedor', coalesce(f.nome_fantasia, f.nome), 'valor_pedido', p.valor_total,
      'valor_recebido_pedido', p.valor_recebido, 'conta_bancaria_id', p.conta_bancaria_id) x
      from public.pedidos_compra_recebimentos r join public.pedidos_compra p on p.id = r.pedido_id
      join public.fornecedores f on f.id = p.fornecedor_id left join public.usuarios u on u.id = r.criado_por
     where r.situacao_financeiro in ('aguardando', 'devolvido')
    union all
    select jsonb_build_object('tipo', 'nf_sem_pedido', 'id', n.id, 'situacao', 'aguardando', 'nf', n.numero, 'serie', n.serie, 'chave', n.chave,
      'emissao', (n.data_emissao at time zone 'America/Sao_Paulo')::date, 'recebida_em', n.entrada_em::date, 'valor', n.valor_total,
      'parcelas', n.duplicatas, 'itens', n.itens, 'quem', u.nome, 'empresa_id', n.empresa_id, 'fornecedor_id', n.fornecedor_id,
      'fornecedor', coalesce(f.nome_fantasia, f.nome, n.emitente_nome), 'motivo_sem_pedido', n.motivo_sem_pedido)
      from public.nfe_entrada n left join public.fornecedores f on f.id = n.fornecedor_id left join public.usuarios u on u.id = n.entrada_por
     where n.situacao = 'aprovada' and n.entrada_em is not null
  ) z where (select public.pode('pagar'))
$$;
revoke execute on function public.cp_fila_nf_recebidas() from public, anon;
grant execute on function public.cp_fila_nf_recebidas() to authenticated;

-- 8. Contadores do menu: Contas a pagar (fila do financeiro) e Pedidos de compra (NF devolvidas)
create or replace function public.menu_contadores()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v jsonb := '{}'; v_eu uuid := auth.uid(); a int; r int;
begin
  if (select public.pode('solicitacoes_compra')) then
    select count(*) into a from public.solicitacoes_compra s
     where s.situacao = 'em_aprovacao' and (s.solicitante_id = v_eu or (select public.pode_acao('compras.aprovar_solicitacao')));
    r := 0;
    if (select public.pode('cotacoes_compra', 'criar')) or (select public.pode('compras', 'criar')) then
      select count(distinct s.id) into r from public.solicitacoes_compra s join public.solicitacoes_compra_itens i on i.solicitacao_id = s.id
        left join public.pedidos_compra p on p.id = i.pedido_id left join public.cotacoes_compra c on c.id = i.cotacao_id
       where s.situacao = 'aprovado' and (i.pedido_id is null or p.situacao = 'cancelado') and (i.cotacao_id is null or c.situacao = 'cancelada');
    end if;
    v := v || jsonb_build_object('solicitacoes_compra', jsonb_build_object('amarelo', a, 'vermelho', r));
  end if;
  if (select public.pode('cotacoes_compra')) then
    select count(*) into a from public.cotacoes_compra where situacao = 'aberta';
    v := v || jsonb_build_object('cotacoes_compra', jsonb_build_object('amarelo', a, 'vermelho', 0));
  end if;
  if (select public.pode('pagar', 'criar')) then
    select (select count(*) from public.pedidos_compra_recebimentos where situacao_financeiro = 'aguardando')
         + (select count(*) from public.nfe_entrada where situacao = 'aprovada' and entrada_em is not null) into r;
    v := v || jsonb_build_object('pagar', jsonb_build_object('amarelo', 0, 'vermelho', r));
  end if;
  if (select public.pode('compras', 'alterar')) or (select public.pode('estoque', 'alterar')) then
    select count(*) into r from public.pedidos_compra_recebimentos where situacao_financeiro = 'devolvido';
    select count(*) into a from public.pedidos_compra_recebimentos where situacao_financeiro = 'aguardando';
    v := v || jsonb_build_object('compras', jsonb_build_object('amarelo', a, 'vermelho', r));
  end if;
  return v;
end $function$;

-- 9. Aprovações pendentes › Avisos: fila do financeiro, NF devolvidas e NF sem pedido esperando a entrada
do $$ declare d text; begin
  d := pg_get_functiondef('public.minhas_aprovacoes()'::regprocedure);
  if position('cp_fila_nf_recebidas' in d) = 0 then
    d := replace(d, $x$select jsonb_build_object('id', 0, 'texto', count(*) || ' produto(s) ativo(s) sem categoria$x$,
      $x$select jsonb_build_object('id', 'cpf' || (y->>'id'), 'texto', 'NF ' || (y->>'nf') || ' · ' || coalesce(y->>'fornecedor', '') || coalesce(' · ' || (y->>'pedido'), ' · sem pedido')
             || ' — entrada dada pelo almoxarifado, lançar no contas a pagar', 'valor', (y->>'valor')::numeric, 'data', y->>'recebida_em', 'quem', y->>'quem',
             'link', 'pages/financeiro/contas-pagar.html?fila=1') /* cp_fila_nf_recebidas */
      from jsonb_array_elements(public.cp_fila_nf_recebidas()) y where (select public.pode('pagar', 'criar')) and y->>'situacao' = 'aguardando'
    union all
    select jsonb_build_object('id', 'dev' || r.id, 'texto', 'NF ' || r.nf_numero || ' · ' || p.numero || ' devolvida pelo financeiro: ' || coalesce(r.devolvido_motivo, '') || ' — acerte e reenvie',
             'valor', r.valor_nf, 'data', r.devolvido_em, 'link', 'pages/compras/pedidos.html?abrir=' || p.id)
      from public.pedidos_compra_recebimentos r join public.pedidos_compra p on p.id = r.pedido_id
     where r.situacao_financeiro = 'devolvido' and ((select public.pode('compras', 'alterar')) or (select public.pode('estoque', 'alterar')))
    union all
    select jsonb_build_object('id', 'ent' || n.id, 'texto', 'NF ' || n.numero || ' · ' || coalesce(n.emitente_nome, '') || ' — sem pedido, aprovada pelo master: dar entrada no estoque',
             'valor', n.valor_total, 'data', n.aprovada_em, 'link', 'pages/financeiro/notas-fiscais.html?abrir=' || n.id)
      from public.nfe_entrada n
     where n.situacao = 'aprovada' and n.entrada_em is null and ((select public.pode('estoque', 'alterar')) or (select public.pode('compras', 'alterar')))
    union all
    select jsonb_build_object('id', 0, 'texto', count(*) || ' produto(s) ativo(s) sem categoria$x$);
    if position('cp_fila_nf_recebidas' in d) = 0 then raise exception 'minhas_aprovacoes: trecho dos avisos não encontrado'; end if;
    execute d;
  end if;
end $$;

-- pedidos_compra_recebimentos e nfe_entrada já estão com auditoria/tempo real desde o SQL 122: tabela nova não há.
