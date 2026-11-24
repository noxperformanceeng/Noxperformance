-- =====================================================================
-- 162 · Saldo da solicitação de compra quando o pedido compra menos
--  · Antes: o pedido de compra prendia o item da solicitação inteiro. Ex.: a SC-00022 pediu 120 válvulas,
--    o PC-00049 comprou 53, e as outras 67 sumiam (não voltavam para "aguardando compra").
--  · Agora: quando o pedido sai do rascunho (vai para aprovação), o sistema compara a quantidade do pedido
--    com a da solicitação. Se o pedido tem menos, o item da solicitação se divide em dois:
--      - a parte comprada fica presa a este pedido (ex.: 53);
--      - o saldo volta para a fila do comprador / "aguardando compra" (ex.: 67), na mesma solicitação,
--        com a mesma urgência e observação, pronto para outro pedido ou outra cotação.
--  · Só divide quando é o mesmo item (produto, serviço ou descrição) e a mesma unidade. Se a unidade do pedido
--    for outra (ex.: compra em barra e a solicitação em metro), não mexe.
--  · Pedido com quantidade igual ou maior que a solicitação: nada muda.
--  · Acerta agora o único caso que já existe: PC-00049 (53 de 120) → 67 válvulas voltam para aguardando compra.
--  · A linha do tempo do pedido registra a divisão. Tempo real: a fila e as telas se atualizam sozinhas.
--  · Desfazer: dá para juntar as linhas de volta pela própria solicitação; nenhum dado é apagado.
-- =====================================================================

-- 1) divide os itens da solicitação presos ao pedido conforme a quantidade que o pedido compra
create or replace function public.pc_dividir_saldo_solicitacao(p_pedido bigint)
returns int language plpgsql security definer set search_path = public as $$
declare i record; v_saldo jsonb; v_resta numeric; v_usa numeric; v_sobra numeric; n int := 0; v_txt text := '';
begin
  -- quanto o pedido compra de cada item (mesmo produto/serviço/descrição e mesma unidade)
  select coalesce(jsonb_object_agg(chave, q), '{}') into v_saldo from (
    select coalesce(produto_id::text, '') || '|' || coalesce(servico_id::text, '') || '|'
           || case when produto_id is null and servico_id is null then upper(btrim(coalesce(descricao, ''))) else '' end
           || '|' || upper(btrim(coalesce(unidade, ''))) as chave, sum(quantidade) as q
      from public.pedidos_compra_itens where pedido_id = p_pedido group by 1) z;
  -- distribui na ordem dos itens da solicitação; o que não couber vira uma linha nova sem pedido
  for i in select si.*, s.numero as sc_numero,
                  coalesce(coalesce(si.produto_id, si.peca_id)::text, '') || '|' || coalesce(si.servico_id::text, '') || '|'
                  || case when coalesce(si.produto_id, si.peca_id) is null and si.servico_id is null then upper(btrim(coalesce(si.descricao, ''))) else '' end
                  || '|' || upper(btrim(coalesce(si.unidade, ''))) as chave
             from public.solicitacoes_compra_itens si join public.solicitacoes_compra s on s.id = si.solicitacao_id
            where si.pedido_id = p_pedido order by si.id for update of si loop
    v_resta := (v_saldo ->> i.chave)::numeric;
    continue when v_resta is null;                       -- item ou unidade diferente: não mexe
    v_usa := least(i.quantidade, greatest(v_resta, 0));
    v_saldo := jsonb_set(v_saldo, array[i.chave], to_jsonb(v_resta - v_usa));
    continue when v_usa >= i.quantidade or v_usa <= 0;   -- comprou tudo (ou nada deste item): não divide
    v_sobra := i.quantidade - v_usa;
    update public.solicitacoes_compra_itens set quantidade = v_usa where id = i.id;
    insert into public.solicitacoes_compra_itens (solicitacao_id, produto_id, servico_id, descricao, unidade, quantidade, urgencia, observacao, peca_id)
    values (i.solicitacao_id, i.produto_id, i.servico_id, i.descricao, i.unidade, v_sobra, i.urgencia, i.observacao, i.peca_id);
    n := n + 1;
    v_txt := v_txt || case when v_txt = '' then '' else ' · ' end || i.sc_numero || ': '
             || case when v_sobra = trunc(v_sobra) then trunc(v_sobra)::text else rtrim(v_sobra::text, '0') end
             || ' ' || coalesce(i.unidade, '') || ' ' || coalesce(i.descricao, '') || ' voltam para aguardando compra';
  end loop;
  if n > 0 then
    perform public.pc_evento(p_pedido, 'solicitacao_saldo', 'Pedido compra menos que a solicitação · ' || v_txt, jsonb_build_object('itens_divididos', n));
  end if;
  return n;
end $$;
revoke execute on function public.pc_dividir_saldo_solicitacao(bigint) from public, anon, authenticated;

-- 2) dispara quando o pedido sai do rascunho/recusado (vai para aprovação ou é aprovado direto)
create or replace function public.pc_saldo_solicitacao_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.situacao is distinct from old.situacao and old.situacao in ('rascunho', 'recusado') and new.situacao not in ('rascunho', 'recusado', 'cancelado') then
    perform public.pc_dividir_saldo_solicitacao(new.id);
  end if;
  return new;
end $$;
revoke execute on function public.pc_saldo_solicitacao_trg() from public, anon, authenticated;

create or replace trigger pc_saldo_solicitacao
  after update of situacao on public.pedidos_compra
  for each row execute function public.pc_saldo_solicitacao_trg();

-- 3) acerta os pedidos que já saíram do rascunho com quantidade menor (hoje: só o PC-00049)
select p.numero, public.pc_dividir_saldo_solicitacao(p.id) as itens_divididos
  from public.pedidos_compra p
 where p.situacao not in ('rascunho', 'recusado', 'cancelado')
   and exists (select 1 from public.solicitacoes_compra_itens si where si.pedido_id = p.id);

-- Resultado esperado: PC-00049 → 1 (SC-00022 fica com 53 no pedido e uma linha nova de 67 aguardando compra).
-- Conferir: select id, quantidade, pedido_id from solicitacoes_compra_itens where solicitacao_id = (select id from solicitacoes_compra where numero = 'SC-00022');
