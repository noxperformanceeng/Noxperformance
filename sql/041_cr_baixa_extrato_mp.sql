-- =====================================================================
-- 041 · Contas a receber: baixa das vendas do Mercado Livre pelo extrato do Mercado Pago
--  Regra (siga o extrato): a venda só é dada como recebida quando o dinheiro é liberado na conta MP.
--  · Título aberto de marketplace + linhas "payment" do extrato ligadas ao mesmo pedido
--  · Soma das linhas = saldo do título (pagamento dividido em 2 cartões também fecha)
--    → 1 recebimento por linha, na data da liberação, na conta MP, já conciliado com a linha
--  · Qualquer diferença (pedido cancelado, devolução, disputa, valor diferente) fica pendente
--    na conciliação para revisão — nada é lançado no chute.
--  A rotina roda pela tela Contas a receber (botão) e depois de cada importação do extrato MP.
-- =====================================================================
create or replace function public.cr_baixar_extrato_mp(p_conta bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t record; l record; v_rec bigint; n_tit int := 0; n_lin int := 0; v_total numeric := 0;
begin
  if auth.uid() is not null and not (public.pode('receber', 'editar') and public.pode_acao('receber.conciliar')) then
    raise exception 'Sem permissão para baixar e conciliar recebimentos';
  end if;
  perform set_config('nox.baixa_extrato', 'sim', true);   -- a baixa vem do próprio extrato: já nasce conciliada
  for t in
    select tr.id, tr.saldo, tr.conta_bancaria_id, x.n, x.soma
      from titulos_receber tr
      join lateral (select count(*) n, sum(e.valor) soma from extrato_lancamentos e
                     where e.pedido_venda_id = tr.pedido_venda_id and e.tipo = 'payment' and e.valor > 0
                       and e.conciliacao = 'pendente' and e.conta_bancaria_id = tr.conta_bancaria_id) x on x.n > 0
     where tr.origem = 'marketplace' and tr.situacao = 'aberto' and tr.pedido_venda_id is not null
       and (p_conta is null or tr.conta_bancaria_id = p_conta)
       and abs(x.soma - tr.saldo) < 0.005
  loop
    for l in select * from extrato_lancamentos e
              where e.pedido_venda_id = (select pedido_venda_id from titulos_receber where id = t.id) and e.tipo = 'payment' and e.valor > 0
                and e.conciliacao = 'pendente' and e.conta_bancaria_id = t.conta_bancaria_id order by e.data, e.id loop
      insert into recebimentos (titulo_id, data_recebimento, valor, conta_bancaria_id, identificador, conciliado, observacoes)
      values (t.id, l.data, l.valor, l.conta_bancaria_id, 'mp:' || l.id_operacao, true,
              'Baixa pelo extrato do Mercado Pago (liberação ' || to_char(l.data, 'DD/MM/YYYY') || ', linha #' || l.id || ')')
      returning id into v_rec;
      update extrato_lancamentos set titulo_receber_id = t.id, recebimento_id = v_rec, conciliacao = 'conciliado',
             conciliado_em = now(), conciliado_por = auth.uid()
       where id = l.id;
      n_lin := n_lin + 1; v_total := v_total + l.valor;
    end loop;
    n_tit := n_tit + 1;
  end loop;
  return jsonb_build_object('titulos', n_tit, 'linhas', n_lin, 'total', v_total,
    'pendentes', (select jsonb_build_object(
        'linhas_payment_sem_pedido', count(*) filter (where e.pedido_venda_id is null),
        'pedido_sem_titulo_aberto', count(*) filter (where e.pedido_venda_id is not null and not exists (select 1 from titulos_receber x where x.pedido_venda_id = e.pedido_venda_id and x.situacao = 'aberto')),
        'valor_diferente', count(*) filter (where exists (select 1 from titulos_receber x where x.pedido_venda_id = e.pedido_venda_id and x.situacao = 'aberto')))
      from extrato_lancamentos e where e.tipo = 'payment' and e.valor > 0 and e.conciliacao = 'pendente' and (p_conta is null or e.conta_bancaria_id = p_conta)));
end $$;
revoke execute on function public.cr_baixar_extrato_mp(bigint) from public, anon;
grant execute on function public.cr_baixar_extrato_mp(bigint) to authenticated;

-- Recebimento conciliado criado pela rotina do extrato (inclusive pela importação automática, sem usuário)
create or replace function public.recebimentos_validar()
returns trigger language plpgsql set search_path = public as $$
declare t record; v_outros numeric(14,2);
begin
  select * into t from public.titulos_receber where id = new.titulo_id;
  if t.situacao = 'cancelado' and not new.estornado then raise exception 'Título cancelado não recebe baixa'; end if;
  select coalesce(sum(valor), 0) into v_outros from public.recebimentos where titulo_id = new.titulo_id and not estornado and id is distinct from new.id;
  if not new.estornado and v_outros + new.valor > t.valor + 0.005 then
    raise exception 'Recebimento maior que o saldo do título (saldo %)', t.valor - v_outros;
  end if;
  if tg_op = 'UPDATE' and new.estornado and not old.estornado and not public.pode_acao('receber.estornar') then
    raise exception 'Sem permissão para estornar recebimento (peça ao gestor)';
  end if;
  if tg_op = 'UPDATE' and old.estornado and not new.estornado then raise exception 'Recebimento estornado não volta; registre uma nova baixa'; end if;
  if (tg_op = 'INSERT' and new.conciliado or tg_op = 'UPDATE' and new.conciliado is distinct from old.conciliado)
     and not public.pode_acao('receber.conciliar') and coalesce(current_setting('nox.baixa_extrato', true), '') <> 'sim' then
    raise exception 'Sem permissão para conciliar';
  end if;
  if new.conciliado and new.conciliado_em is null then new.conciliado_em := now(); new.conciliado_por := auth.uid(); end if;
  if not new.conciliado then new.conciliado_em := null; new.conciliado_por := null; end if;
  return new;
end $$;
grant execute on function public.cr_baixar_extrato_mp(bigint) to service_role;   -- chamada pela importação automática (mp-extrato)
