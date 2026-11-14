-- =====================================================================
-- 117 · Entrada da NF: conversão de unidade (ex.: mangueira comprada em M, estoque em MM)
--  · Uma regra só para as duas entradas no estoque (recebimento no pedido e NF sem pedido):
--      1) se a NF/pedido já vier na unidade do estoque (ex.: MM), não converte (fator 1);
--      2) senão usa o fator do vínculo produto × fornecedor (cadastro do produto › Fornecedores);
--      3) senão o fator padrão do produto; 4) senão 1.
--    Quantidade no estoque = quantidade da NF × fator; custo unitário = valor ÷ (quantidade × fator).
--  · Antes, o recebimento pelo pedido usava só o fator padrão do produto e ignorava o do fornecedor,
--    e nenhuma das duas entradas percebia quando o documento já vinha em MM (multiplicaria por 1000 de novo).
--  · Só troca funções; não mexe em dados nem em movimentos já lançados.
-- =====================================================================

-- Fator de conversão da unidade do documento (NF/pedido) para a unidade de estoque do produto
create or replace function public.fator_entrada(p_produto bigint, p_fornecedor bigint, p_unidade_doc text)
returns numeric language sql stable security invoker set search_path = public as $$
  select case when nullif(upper(trim(p_unidade_doc)), '') = upper(trim(pr.unidade)) then 1
              else coalesce(nullif((select pf.fator_compra from public.produto_fornecedores pf
                                     where pf.produto_id = pr.id and pf.fornecedor_id = p_fornecedor
                                     order by pf.fator_compra is null, pf.id limit 1), 0),
                            nullif(pr.fator_compra, 0), 1) end
    from public.produtos pr where pr.id = p_produto
$$;
revoke execute on function public.fator_entrada(bigint, bigint, text) from public, anon;
grant execute on function public.fator_entrada(bigint, bigint, text) to authenticated;

-- Recebimento no pedido de compra → estoque (mesma função do 060/063, agora com o fator do fornecedor do pedido)
create or replace function public.pc_recebimento_estoque()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_sit text; v_forn bigint; v_ped text;
begin
  if new.nf_chave is not null then
    select situacao into v_sit from public.nfe_entrada where chave = new.nf_chave;
    if v_sit is not null and v_sit not in ('conferida','aprovada','lancada') then
      raise exception 'A NF % ainda não foi conferida na tela de Notas fiscais (antifraude)', new.nf_numero;
    end if;
  end if;
  select fornecedor_id, numero into v_forn, v_ped from public.pedidos_compra where id = new.pedido_id;
  insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, quantidade_compra, unidade_compra, fator, custo_unitario,
    pedido_compra_id, recebimento_id, nfe_entrada_id, observacao, data)
  select x.produto_id, 'entrada_compra', x.qtd * x.fator, x.unidade, x.qtd, x.un_doc, x.fator,
         round(x.valor_total / x.qtd_pedido / x.fator, 6),
         new.pedido_id, new.id, (select id from public.nfe_entrada where chave = new.nf_chave),
         'NF ' || new.nf_numero || ' · ' || v_ped, new.data_recebimento
    from (select i.produto_id, r.quantidade qtd, i.quantidade qtd_pedido, i.valor_total, pr.unidade,
                 coalesce(i.unidade, pr.unidade_compra, pr.unidade) un_doc,
                 public.fator_entrada(i.produto_id, v_forn, coalesce(i.unidade, pr.unidade_compra, pr.unidade)) fator
            from jsonb_to_recordset(coalesce(new.itens, '[]')) r(item_id bigint, quantidade numeric)
            join public.pedidos_compra_itens i on i.id = r.item_id
            join public.produtos pr on pr.id = i.produto_id
           where r.quantidade > 0 and pr.controla_estoque and not i.uso_consumo) x;
  return new;
end $$;
revoke execute on function public.pc_recebimento_estoque() from public, anon, authenticated;

-- NF sem pedido (aprovada pelo master) → contas a pagar + estoque (itens ligados pelo código do fornecedor)
create or replace function public.nfe_lancar_cp(p_id bigint, p_categoria bigint, p_conta bigint default null, p_parcelas jsonb default null)
returns int language plpgsql security definer set search_path = public as $$
declare r public.nfe_entrada; v_parc jsonb; x jsonb; v_n int; v_i int := 0; v_soma numeric;
begin
  if not (select public.pode('pagar', 'criar')) then raise exception 'Sem permissão no contas a pagar'; end if;
  select * into r from public.nfe_entrada where id = p_id for update;
  if r.situacao <> 'aprovada' then raise exception 'Só NF aprovada pelo master (sem pedido) é lançada por aqui; com pedido, registre o recebimento no pedido de compra'; end if;
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
  update public.nfe_entrada set situacao = 'lancada' where id = r.id;
  return v_n;
end $$;
revoke execute on function public.nfe_lancar_cp(bigint, bigint, bigint, jsonb) from public, anon;
grant execute on function public.nfe_lancar_cp(bigint, bigint, bigint, jsonb) to authenticated;

-- Conferência: mangueiras em MM devem mostrar 1000 para NF em M e 1 para NF em MM
select pr.codigo, pr.descricao, pr.unidade, f.nome fornecedor,
       public.fator_entrada(pr.id, pf.fornecedor_id, 'M') fator_nf_em_m,
       public.fator_entrada(pr.id, pf.fornecedor_id, 'MM') fator_nf_em_mm,
       pf.codigo_fornecedor
  from public.produtos pr
  join public.produto_fornecedores pf on pf.produto_id = pr.id
  join public.fornecedores f on f.id = pf.fornecedor_id
 where pr.unidade = 'MM' and pr.situacao = 'ativo'
 order by pr.descricao;
