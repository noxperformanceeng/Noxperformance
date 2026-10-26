-- =====================================================================
-- 076 · Transferência entre contas: lança a saída e a entrada de uma vez e concilia sozinha
--  · Na linha de saída do extrato (ex.: saque do Mercado Pago), informa-se a conta que recebe o dinheiro.
--    O sistema lança a saída (paga e conciliada na conta de origem) e a entrada (recebida na conta de destino).
--  · Quando o extrato da conta de destino chega com o mesmo valor (até 5 dias depois), a entrada
--    é conciliada automaticamente — o confronto é feito sem ninguém procurar.
--  · Mesma empresa: categoria "transferência entre contas próprias" (fora do resultado).
--    Empresas diferentes (NOX 30 ↔ NOX 37): transferência entre empresas do grupo.
--  · A conta de destino pode ficar como padrão da conta de origem: os próximos saques entram sozinhos.
-- =====================================================================
alter table public.contas_bancarias add column if not exists conta_transferencia_padrao bigint references public.contas_bancarias(id);

create table if not exists public.transferencias_contas (
  id                 bigserial primary key,
  data               date not null,
  valor              numeric(14,2) not null check (valor > 0),
  conta_origem_id    bigint not null references public.contas_bancarias(id),
  conta_destino_id   bigint not null references public.contas_bancarias(id),
  extrato_saida_id   bigint references public.extrato_lancamentos(id),
  extrato_entrada_id bigint references public.extrato_lancamentos(id),
  titulo_pagar_id    bigint references public.titulos_pagar(id),
  titulo_receber_id  bigint references public.titulos_receber(id),
  recebimento_id     bigint references public.recebimentos(id),
  situacao           text not null default 'aguardando_entrada' check (situacao in ('aguardando_entrada','conciliada')),
  automatica         boolean not null default false,
  observacao         text,
  criado_em timestamptz not null default now(), criado_por uuid default auth.uid(),
  atualizado_em timestamptz not null default now(), atualizado_por uuid,
  check (conta_origem_id <> conta_destino_id)
);
create index if not exists transf_destino_idx on public.transferencias_contas (conta_destino_id, situacao);
create or replace trigger carimbo before insert or update on public.transferencias_contas for each row execute function public.carimbo_cadastro();
alter table public.transferencias_contas enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'transferencias_contas' and policyname = 'ver transferencias') then
    create policy "ver transferencias" on public.transferencias_contas for select to authenticated
      using ((select public.pode('conciliacao')) or (select public.pode('pagar')) or (select public.pode('fluxo')));
  end if;
end $$;

-- Categorias de transferência entre contas próprias (fora do resultado)
do $$ declare g bigint; t bigint; begin
  select id into t from public.categorias_financeiras where codigo = '10';
  if not exists (select 1 from public.categorias_financeiras where nome = 'Transferências entre contas próprias') then
    insert into public.categorias_financeiras (codigo, nome, pai_id, tipo, grupo_dre, aceita_lancamento, situacao, aprovacao)
    values (public.categoria_proximo_codigo(t), 'Transferências entre contas próprias', t, 'transferencia', 'Não entra no resultado', false, 'ativo', 'aprovado') returning id into g;
    insert into public.categorias_financeiras (codigo, nome, pai_id, tipo, grupo_dre, aceita_lancamento, situacao, aprovacao)
    values (public.categoria_proximo_codigo(g), 'TRANSFERÊNCIA ENTRE CONTAS - SAÍDA', g, 'transferencia', 'Não entra no resultado', true, 'ativo', 'aprovado');
    insert into public.categorias_financeiras (codigo, nome, pai_id, tipo, grupo_dre, aceita_lancamento, situacao, aprovacao)
    values (public.categoria_proximo_codigo(g), 'TRANSFERÊNCIA ENTRE CONTAS - ENTRADA', g, 'transferencia', 'Não entra no resultado', true, 'ativo', 'aprovado');
  end if;
end $$;

-- Lança a transferência a partir da(s) linha(s) de saída do extrato
create or replace function public.extrato_transferencia(p_ids bigint[], p_conta_destino bigint, p_padrao boolean default false, p_auto boolean default false)
returns int language plpgsql security definer set search_path = public as $$
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
      select id into v_cs from public.categorias_financeiras where nome = 'TRANSFERÊNCIA ENTRE CONTAS - SAÍDA';
      select id into v_ce from public.categorias_financeiras where nome = 'TRANSFERÊNCIA ENTRE CONTAS - ENTRADA';
    else
      select id into v_cs from public.categorias_financeiras where codigo = '10.01.001';
      select id into v_ce from public.categorias_financeiras where codigo = '10.01.002';
    end if;
    insert into public.transferencias_contas (data, valor, conta_origem_id, conta_destino_id, extrato_saida_id, automatica, observacao)
    values (l.data, v_val, o.id, d.id, l.id, p_auto, concat_ws(' · ', l.tipo, l.id_operacao)) returning id into v_tx;
    -- saída: título pago na origem, conciliado com a linha
    insert into public.titulos_pagar (empresa_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento, data_programada,
        conta_bancaria_id, origem, origem_ref, projecao, situacao, valor_pago, saldo)
    values (o.empresa_id, 'TRANSF ' || v_tx, upper('Transferência ' || o.descricao || ' → ' || d.descricao), v_cs, v_val, l.data, l.data, l.data,
        o.id, 'manual', jsonb_build_object('transferencia_id', v_tx, 'extrato_id', l.id, 'id_operacao', l.id_operacao), false, 'aberto', 0, v_val)
    returning id into v_tp;
    insert into public.pagamentos (titulo_id, data_pagamento, valor, conta_bancaria_id, identificador, conciliado, conciliado_em, conciliado_por, observacoes)
    values (v_tp, l.data, v_val, o.id, coalesce(l.id_operacao, 'transf:' || v_tx), true, now(), auth.uid(), 'Transferência #' || v_tx || ' (saída)')
    returning id into v_pg;
    update public.extrato_lancamentos set conciliacao = 'conciliado', pagamento_id = v_pg, categoria_financeira_id = v_cs, conciliado_em = now(), conciliado_por = auth.uid(),
           observacoes = concat_ws(' · ', observacoes, 'Transferência #' || v_tx || ' para ' || d.descricao) where id = l.id;
    -- entrada: título recebido no destino (a conciliação acontece quando o extrato do destino chegar)
    insert into public.titulos_receber (empresa_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento,
        conta_bancaria_id, origem, origem_ref, projecao, situacao, valor_recebido, saldo)
    values (d.empresa_id, 'TRANSF ' || v_tx, upper('Transferência ' || o.descricao || ' → ' || d.descricao), v_ce, v_val, l.data, l.data,
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

-- Confronto: entrada do extrato da conta de destino = transferência aguardando (mesmo valor, até 5 dias depois)
create or replace function public.transferencias_confrontar(p_conta bigint default null)
returns int language plpgsql security definer set search_path = public as $$
declare t record; e bigint; n int := 0;
begin
  for t in select * from public.transferencias_contas where situacao = 'aguardando_entrada' and (p_conta is null or conta_destino_id = p_conta) order by data, id for update loop
    select x.id into e from public.extrato_lancamentos x
     where x.conta_bancaria_id = t.conta_destino_id and x.conciliacao = 'pendente' and abs(x.valor - t.valor) < 0.005
       and x.data between t.data and t.data + 5
     order by x.data, x.id limit 1 for update skip locked;
    if e is null then continue; end if;
    update public.extrato_lancamentos set conciliacao = 'conciliado', titulo_receber_id = t.titulo_receber_id, recebimento_id = t.recebimento_id,
           categoria_financeira_id = (select categoria_financeira_id from public.titulos_receber where id = t.titulo_receber_id),
           conciliado_em = now(), observacoes = concat_ws(' · ', observacoes, 'Entrada da transferência #' || t.id) where id = e;
    update public.recebimentos set conciliado = true, conciliado_em = now(), data_recebimento = (select data from public.extrato_lancamentos where id = e) where id = t.recebimento_id;
    update public.transferencias_contas set situacao = 'conciliada', extrato_entrada_id = e where id = t.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Automático: saques com conta de destino padrão entram sozinhos (roda junto com a compensação do extrato)
create or replace function public.transferencias_automaticas()
returns int language plpgsql security definer set search_path = public as $$
declare l record; n int := 0;
begin
  perform set_config('nox.transf_auto', '1', true);
  for l in select x.id, c.conta_transferencia_padrao destino from public.extrato_lancamentos x join public.contas_bancarias c on c.id = x.conta_bancaria_id
            where x.conciliacao = 'pendente' and x.tipo = 'payout' and x.valor < 0 and c.conta_transferencia_padrao is not null loop
    n := n + public.extrato_transferencia(array[l.id], l.destino, false, true);
  end loop;
  perform set_config('nox.transf_auto', '', true);
  return n + public.transferencias_confrontar(null);
end $$;

-- Extrato novo chegando: tenta o confronto na hora
create or replace function public.extrato_novo_confronto()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.valor > 0 and new.conciliacao = 'pendente' then perform public.transferencias_confrontar(new.conta_bancaria_id); end if;
  return null;
end $$;
create or replace trigger confronto_transferencia after insert on public.extrato_lancamentos for each row execute function public.extrato_novo_confronto();

revoke execute on function public.extrato_transferencia(bigint[], bigint, boolean, boolean) from public, anon;
grant execute on function public.extrato_transferencia(bigint[], bigint, boolean, boolean) to authenticated;
revoke execute on function public.transferencias_confrontar(bigint) from public, anon, authenticated;
revoke execute on function public.transferencias_automaticas() from public, anon, authenticated;
revoke execute on function public.extrato_novo_confronto() from public, anon, authenticated;

do $$ declare d text; begin
  d := pg_get_functiondef('public.extrato_compensar(bigint)'::regprocedure);
  if position('transferencias_automaticas' in d) = 0 then
    d := replace(d, $x$  n := n + public.extrato_compensar_pares(p_conta);$x$, $x$  n := n + public.extrato_compensar_pares(p_conta);
  perform public.transferencias_automaticas();   -- saques com conta de destino padrão + confronto das entradas$x$);
    if position('transferencias_automaticas' in d) = 0 then raise exception 'extrato_compensar mudou: revisar 076'; end if;
    execute d;
  end if;
end $$;

select public.ligar_auditoria('transferencias_contas');
