-- =====================================================================
-- 101 · Posição de estoque e inventário (telas do almoxarifado)
--  · Cada produto ganha um LOCAL DE ARMAZENAGEM padrão (rua/prateleira, do cadastro "Locais de estoque").
--  · Posição de estoque: saldo de cada produto (soma de todos os movimentos), última movimentação e extrato.
--  · Inventário (contagem): o almoxarifado digita a quantidade contada; o sistema lança a diferença como
--    movimento de INVENTÁRIO, e o saldo fica igual ao contado. É assim que entra o saldo inicial.
--  · Entrada e saída avulsas (sem nota / sem pedido: devolução, uso interno, amostra, achado), sempre com motivo.
--  · Ninguém grava movimento direto na tabela: só por estas funções, com permissão da tela.
-- =====================================================================

alter table public.produtos add column if not exists local_id bigint references public.locais_estoque(id);
create index if not exists produtos_local on public.produtos (local_id);

-- saldo de todos os produtos (uma linha por produto que já teve movimento)
create or replace function public.estoque_saldos()
returns table (produto_id bigint, saldo numeric, ultimo_mov timestamptz, ultima_contagem timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('estoque') or public.pode('almoxarifado') or public.pode('inventario') or public.pode('compras')
          or public.pode('ordens') or public.pode('apontamento')) then
    raise exception 'Sem permissão para ver estoque';
  end if;
  return query select m.produto_id, sum(m.quantidade), max(m.data), max(m.data) filter (where m.tipo = 'inventario')
                 from public.estoque_movimentos m group by m.produto_id;
end $$;
revoke execute on function public.estoque_saldos() from public, anon;
grant execute on function public.estoque_saldos() to authenticated;

-- extrato de um produto: movimentos com saldo acumulado
create or replace function public.estoque_extrato(p_produto bigint, p_limite int default 200)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('estoque') or public.pode('almoxarifado') or public.pode('inventario') or public.pode('compras')) then
    raise exception 'Sem permissão para ver estoque';
  end if;
  return coalesce((select jsonb_agg(x order by x->>'data' desc, (x->>'id')::bigint desc) from (
    select jsonb_build_object('id', m.id, 'data', m.data, 'tipo', m.tipo, 'quantidade', m.quantidade, 'unidade', m.unidade,
             'saldo', sum(m.quantidade) over (order by m.data, m.id), 'obs', m.observacao, 'quem', u.nome, 'custo', m.custo_unitario) x
      from public.estoque_movimentos m left join public.usuarios u on u.id = m.criado_por
     where m.produto_id = p_produto order by m.data desc, m.id desc limit greatest(p_limite, 1)) s), '[]'::jsonb);
end $$;
revoke execute on function public.estoque_extrato(bigint, int) from public, anon;
grant execute on function public.estoque_extrato(bigint, int) to authenticated;

-- contagem: [{"produto_id": 1, "contado": 12}, …] → lança a diferença (contagem igual ao saldo também fica registrada)
create or replace function public.estoque_contagem(p_itens jsonb, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v_dif int := 0; r record; v_saldo numeric; v_un text;
begin
  if not (public.pode('inventario', 'criar') or public.pode('estoque', 'editar')) then raise exception 'Sem permissão para lançar contagem'; end if;
  if p_itens is null or jsonb_array_length(p_itens) = 0 then raise exception 'Nenhuma quantidade informada'; end if;
  for r in select (x->>'produto_id')::bigint pid, (x->>'contado')::numeric contado from jsonb_array_elements(p_itens) x loop
    if r.contado is null or r.contado < 0 then raise exception 'Quantidade contada inválida'; end if;
    select unidade into v_un from public.produtos where id = r.pid;
    if not found then raise exception 'Produto % não encontrado', r.pid; end if;
    perform 1 from public.produtos where id = r.pid for update;
    v_saldo := public.estoque_saldo(r.pid);
    insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, custo_unitario, observacao)
    values (r.pid, 'inventario', r.contado - v_saldo, v_un, public.estoque_custo_medio(r.pid),
            'CONTAGEM: ' || trim_scale(r.contado)::text || coalesce(' ' || v_un, '') || ' (sistema tinha ' || v_saldo::text || ')' || coalesce(' · ' || nullif(upper(trim(p_obs)), ''), ''));
    v_n := v_n + 1; if r.contado <> v_saldo then v_dif := v_dif + 1; end if;
  end loop;
  return jsonb_build_object('contados', v_n, 'com_diferenca', v_dif);
end $$;
revoke execute on function public.estoque_contagem(jsonb, text) from public, anon;
grant execute on function public.estoque_contagem(jsonb, text) to authenticated;

-- entrada ou saída avulsa (sem nota e sem pedido), sempre com motivo
create or replace function public.estoque_movimento_avulso(p_produto bigint, p_sentido text, p_quantidade numeric, p_motivo text,
  p_custo numeric default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_un text;
begin
  if not (public.pode('estoque', 'criar') or public.pode('almoxarifado', 'criar')) then raise exception 'Sem permissão para movimentar estoque'; end if;
  if p_sentido not in ('entrada', 'saida') then raise exception 'Informe se é entrada ou saída'; end if;
  if coalesce(p_quantidade, 0) <= 0 then raise exception 'Informe a quantidade'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo'; end if;
  if p_custo is not null and p_custo < 0 then raise exception 'Custo inválido'; end if;
  select unidade into v_un from public.produtos where id = p_produto;
  if not found then raise exception 'Produto não encontrado'; end if;
  insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, custo_unitario, observacao)
  values (p_produto, 'ajuste', case when p_sentido = 'entrada' then p_quantidade else -p_quantidade end, v_un,
          case when p_sentido = 'entrada' then coalesce(p_custo, public.estoque_custo_medio(p_produto)) else public.estoque_custo_medio(p_produto) end,
          upper(case when p_sentido = 'entrada' then 'ENTRADA AVULSA · ' else 'SAÍDA AVULSA · ' end || trim(p_motivo)))
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.estoque_movimento_avulso(bigint, text, numeric, text, numeric) from public, anon;
grant execute on function public.estoque_movimento_avulso(bigint, text, numeric, text, numeric) to authenticated;

-- local de armazenagem padrão do produto (o almoxarifado define sem precisar mexer no cadastro do produto)
create or replace function public.estoque_definir_local(p_produtos bigint[], p_local bigint)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not (public.pode('estoque', 'alterar') or public.pode('almoxarifado', 'alterar') or public.pode('produtos', 'alterar')) then
    raise exception 'Sem permissão para definir local';
  end if;
  if p_local is not null and not exists (select 1 from public.locais_estoque where id = p_local and situacao = 'ativo') then
    raise exception 'Local não encontrado ou inativo';
  end if;
  update public.produtos set local_id = p_local where id = any(p_produtos);
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function public.estoque_definir_local(bigint[], bigint) from public, anon;
grant execute on function public.estoque_definir_local(bigint[], bigint) to authenticated;

-- quem trabalha no estoque e na produção enxerga o cadastro de produtos (política a mais, somada à que existe)
drop policy if exists "ver produtos estoque producao" on public.produtos;
create policy "ver produtos estoque producao" on public.produtos for select to authenticated
  using ((select public.pode('estoque')) or (select public.pode('almoxarifado')) or (select public.pode('inventario'))
      or (select public.pode('ordens')) or (select public.pode('apontamento')));
