-- =====================================================================
-- 119 · Entrada da NF com local escolhido por item: poder de terceiro, devolução ou outro local
--  · Na entrada da NF (recebimento no pedido de compra ou NF sem pedido), cada item entra no local padrão
--    do produto, mas dá para trocar ali mesmo:
--      - PODER DE TERCEIRO: o fornecedor entregou direto em outro (ex.: beneficiamento). O nome do terceiro
--        é obrigatório. O financeiro sai normal; o produto fica no local "PODER DE TERCEIRO".
--      - DEVOLUÇÃO (defeito, faltante, outro motivo, sempre com justificativa): o produto fica no local de
--        QUARENTENA até voltar ao estoque ou ser devolvido ao fornecedor.
--      - OUTRO LOCAL: qualquer endereço ativo, com justificativa.
--  · Terceiro e devolução ficam em aberto na lista "Fora do estoque" (Posição de estoque) e aparecem como
--    aviso para o almoxarifado (Aprovações › Avisos). Ações: "Chegou / guardar" (vai para um local real)
--    e "Baixar" (devolvido ao fornecedor, não veio, perda), as duas com quantidade parcial.
--  · O que está fora conta no saldo físico (é da NOX e já foi pago), mas NÃO no disponível para venda
--    (decisão do Alexandre, 13/11/2026). A sugestão de compra continua contando (o produto vai voltar).
--  · Rodar DEPOIS do 118 (estoque reservado): este arquivo refaz estoque_disponivel descontando o que está fora.
-- =====================================================================

-- ---------- Locais especiais: PODER DE TERCEIRO (área terceiros) e QUARENTENA ----------
update public.locais_estoque set area = 'terceiros'
 where upper(trim(codigo)) = 'PODER DE TERCEIRO' and area <> 'terceiros';
insert into public.locais_estoque (codigo, area, deposito, observacoes)
select 'PODER DE TERCEIRO', 'terceiros', 'PODER DE TERCEIRO', 'Produto da NOX que está com um terceiro (beneficiamento, conserto…)'
 where not exists (select 1 from public.locais_estoque where area = 'terceiros' and situacao = 'ativo')
on conflict do nothing;
insert into public.locais_estoque (codigo, area, deposito, observacoes)
select 'QUARENTENA', 'quarentena', 'QUARENTENA', 'Produto separado na entrada: defeito, faltante ou aguardando devolução'
 where not exists (select 1 from public.locais_estoque where area = 'quarentena' and situacao = 'ativo')
on conflict do nothing;

-- primeiro local ativo da área (uso interno)
create or replace function public.local_da_area(p_area text)
returns bigint language sql stable security definer set search_path = public as $$
  select id from public.locais_estoque where area = p_area and situacao = 'ativo' order by id limit 1
$$;
revoke execute on function public.local_da_area(text) from public, anon, authenticated;

-- ---------- Produto fora do estoque normal (em terceiro ou em devolução) ----------
create table if not exists public.estoque_fora_local (
  id                   bigint generated always as identity primary key,
  tipo                 text not null check (tipo in ('terceiro', 'devolucao')),
  produto_id           bigint not null references public.produtos(id),
  quantidade           numeric(16,4) not null check (quantidade > 0),    -- na unidade de estoque
  quantidade_resolvida numeric(16,4) not null default 0,
  unidade              text,
  custo_unitario       numeric(16,6),
  local_id             bigint not null references public.locais_estoque(id),
  terceiro_id          bigint references public.fornecedores(id),        -- obrigatório quando tipo = terceiro
  motivo               text,
  previsao_retorno     date,
  documento            text,                                             -- ex.: NF 1234 · PC-00012
  movimento_id         bigint references public.estoque_movimentos(id),
  recebimento_id       bigint references public.pedidos_compra_recebimentos(id),
  nfe_entrada_id       bigint references public.nfe_entrada(id),
  pedido_compra_id     bigint references public.pedidos_compra(id),
  situacao             text not null default 'aberto' check (situacao in ('aberto', 'resolvido')),
  resolvido_em         timestamptz,
  criado_em            timestamptz not null default now(),
  criado_por           uuid default auth.uid(),
  constraint fora_terceiro_obrig check (tipo <> 'terceiro' or terceiro_id is not null),
  constraint fora_resolvida_ok check (quantidade_resolvida >= 0 and quantidade_resolvida <= quantidade)
);
create index if not exists estoque_fora_aberto on public.estoque_fora_local (produto_id) where situacao = 'aberto';
alter table public.estoque_movimentos add column if not exists fora_local_id bigint references public.estoque_fora_local(id);

alter table public.estoque_fora_local enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'estoque_fora_local' and policyname = 'ver estoque fora do local') then
    create policy "ver estoque fora do local" on public.estoque_fora_local for select to authenticated
      using ((select public.pode('estoque')) or (select public.pode('almoxarifado')) or (select public.pode('inventario'))
          or (select public.pode('compras')) or (select public.pode('notas')));
  end if;
end $$;
-- gravação só pelas funções abaixo (sem política de insert/update/delete)

-- ---------- Aplica o destino escolhido para cada item na entrada (uso interno) ----------
-- p_destinos: [{"produto_id": 1, "tipo": "padrao|local|terceiro|devolucao", "local_id": 5, "terceiro_id": 9,
--               "motivo": "DEFEITO: rosca espanada", "previsao": "2026-11-30"}]
create or replace function public.estoque_aplicar_destinos(p_recebimento bigint, p_nfe bigint, p_destinos jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare d jsonb; m record; v_tipo text; v_local bigint; v_terc bigint; v_mot text; v_n int := 0; v_achou boolean; v_doc text; v_area text; v_fora bigint;
begin
  for d in select * from jsonb_array_elements(coalesce(p_destinos, '[]')) loop
    v_tipo := coalesce(nullif(d->>'tipo', ''), 'padrao');
    continue when v_tipo = 'padrao';
    if v_tipo not in ('local', 'terceiro', 'devolucao') then raise exception 'Destino inválido: %', v_tipo; end if;
    v_mot := nullif(upper(trim(d->>'motivo')), '');
    v_terc := nullif(d->>'terceiro_id', '')::bigint;
    if v_tipo = 'terceiro' then
      if v_terc is null or not exists (select 1 from public.fornecedores where id = v_terc) then
        raise exception 'Informe o fornecedor terceiro que está com o produto';
      end if;
      v_local := public.local_da_area('terceiros');
      if v_local is null then raise exception 'Cadastre um local ativo da área "Em terceiros" (ex.: PODER DE TERCEIRO)'; end if;
    elsif v_tipo = 'devolucao' then
      if v_mot is null then raise exception 'Informe o motivo da devolução (defeito, faltante…)'; end if;
      v_local := public.local_da_area('quarentena');
      if v_local is null then raise exception 'Cadastre um local ativo da área "Quarentena / avaria"'; end if;
    else
      if v_mot is null then raise exception 'Informe a justificativa para guardar em outro local'; end if;
      v_local := nullif(d->>'local_id', '')::bigint;
      select area into v_area from public.locais_estoque where id = v_local and situacao = 'ativo';
      if v_area is null then raise exception 'Local não encontrado ou inativo'; end if;
      if v_area in ('terceiros', 'quarentena') then raise exception 'Para terceiro ou devolução use a opção própria (pede o terceiro / o motivo)'; end if;
    end if;
    v_achou := false;
    for m in select * from public.estoque_movimentos
              where tipo = 'entrada_compra' and produto_id = (d->>'produto_id')::bigint and local_id is null and fora_local_id is null
                and case when p_recebimento is not null then recebimento_id = p_recebimento
                         else nfe_entrada_id = p_nfe and recebimento_id is null end
              for update loop
      v_achou := true;
      v_doc := m.observacao;
      update public.estoque_movimentos set local_id = v_local,
             observacao = concat_ws(' · ', observacao, case v_tipo when 'terceiro' then 'EM PODER DE ' || (select upper(nome) from public.fornecedores where id = v_terc)
                                                                 when 'devolucao' then 'QUARENTENA: ' || v_mot
                                                                 else 'GUARDADO EM ' || (select codigo from public.locais_estoque where id = v_local) || ': ' || v_mot end)
       where id = m.id;
      if v_tipo in ('terceiro', 'devolucao') and m.quantidade > 0 then
        insert into public.estoque_fora_local (tipo, produto_id, quantidade, unidade, custo_unitario, local_id, terceiro_id, motivo, previsao_retorno,
          documento, movimento_id, recebimento_id, nfe_entrada_id, pedido_compra_id)
        values (v_tipo, m.produto_id, m.quantidade, m.unidade, m.custo_unitario, v_local, case when v_tipo = 'terceiro' then v_terc end, v_mot,
          nullif(d->>'previsao', '')::date, v_doc, m.id, m.recebimento_id, m.nfe_entrada_id, m.pedido_compra_id)
        returning id into v_fora;
        update public.estoque_movimentos set fora_local_id = v_fora where id = m.id;
      end if;
      v_n := v_n + 1;
    end loop;
    if not v_achou then
      raise exception 'O produto % não entrou no estoque por esta NF (não controla estoque ou sem vínculo com o fornecedor): deixe no local padrão',
        coalesce((select codigo from public.produtos where id = (d->>'produto_id')::bigint), d->>'produto_id');
    end if;
  end loop;
  return v_n;
end $$;
revoke execute on function public.estoque_aplicar_destinos(bigint, bigint, jsonb) from public, anon, authenticated;

-- ---------- Recebimento no pedido de compra com destino por item (a tela chama esta) ----------
create or replace function public.pedido_compra_receber_destinos(p_id bigint, p_nf jsonb, p_itens jsonb, p_parcelas jsonb, p_destinos jsonb default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_rec bigint;
begin
  v_rec := public.pedido_compra_receber(p_id, p_nf, p_itens, p_parcelas);   -- permissão e regras de sempre
  perform public.estoque_aplicar_destinos(v_rec, null, p_destinos);
  return v_rec;
end $$;
revoke execute on function public.pedido_compra_receber_destinos(bigint, jsonb, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.pedido_compra_receber_destinos(bigint, jsonb, jsonb, jsonb, jsonb) to authenticated;

-- ---------- NF sem pedido (aprovada pelo master) com destino por item ----------
create or replace function public.nfe_lancar_cp_destinos(p_id bigint, p_categoria bigint, p_conta bigint default null, p_parcelas jsonb default null,
  p_destinos jsonb default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  v_n := public.nfe_lancar_cp(p_id, p_categoria, p_conta, p_parcelas);       -- permissão e regras de sempre
  perform public.estoque_aplicar_destinos(null, p_id, p_destinos);
  return v_n;
end $$;
revoke execute on function public.nfe_lancar_cp_destinos(bigint, bigint, bigint, jsonb, jsonb) from public, anon;
grant execute on function public.nfe_lancar_cp_destinos(bigint, bigint, bigint, jsonb, jsonb) to authenticated;

-- ---------- Resolver o que está fora: chegou (guardar num local real) ou baixar ----------
create or replace function public.estoque_fora_resolver(p_id bigint, p_acao text, p_quantidade numeric, p_local bigint default null, p_obs text default null)
returns int language plpgsql security definer set search_path = public as $$
declare f public.estoque_fora_local; v_area text; v_aberto numeric; v_obs text; v_custo numeric;
begin
  if not (public.pode('estoque', 'criar') or public.pode('almoxarifado', 'criar')) then raise exception 'Sem permissão para movimentar estoque'; end if;
  select * into f from public.estoque_fora_local where id = p_id for update;
  if f.id is null then raise exception 'Registro não encontrado'; end if;
  if f.situacao <> 'aberto' then raise exception 'Este item já foi resolvido'; end if;
  v_aberto := f.quantidade - f.quantidade_resolvida;
  if coalesce(p_quantidade, 0) <= 0 then raise exception 'Informe a quantidade'; end if;
  if p_quantidade > v_aberto then raise exception 'Quantidade maior que a pendente (%)', trim_scale(v_aberto); end if;
  v_obs := nullif(upper(trim(p_obs)), '');
  v_custo := coalesce(f.custo_unitario, public.estoque_custo_medio(f.produto_id));
  if p_acao = 'guardar' then
    select area into v_area from public.locais_estoque where id = p_local and situacao = 'ativo';
    if v_area is null then raise exception 'Escolha o local onde o produto foi guardado'; end if;
    if v_area in ('terceiros', 'quarentena') then raise exception 'Escolha um local real do estoque (não terceiro / quarentena)'; end if;
    insert into public.estoque_movimentos (produto_id, local_id, tipo, quantidade, unidade, custo_unitario, fora_local_id, observacao) values
      (f.produto_id, f.local_id, case when f.tipo = 'terceiro' then 'retorno_terceiro' else 'ajuste' end, -p_quantidade, f.unidade, v_custo, f.id,
       concat_ws(' · ', case when f.tipo = 'terceiro' then 'CHEGOU DO TERCEIRO' else 'SAIU DA QUARENTENA' end, f.documento, v_obs)),
      (f.produto_id, p_local, case when f.tipo = 'terceiro' then 'retorno_terceiro' else 'ajuste' end, p_quantidade, f.unidade, v_custo, f.id,
       concat_ws(' · ', 'GUARDADO EM ' || (select codigo from public.locais_estoque where id = p_local), f.documento, v_obs));
    update public.produtos set local_id = p_local where id = f.produto_id and local_id is null;   -- produto sem local fica com este
  elsif p_acao = 'baixar' then
    if v_obs is null then raise exception 'Informe o motivo da baixa (ex.: devolvido ao fornecedor com NF 123, não veio, perda)'; end if;
    insert into public.estoque_movimentos (produto_id, local_id, tipo, quantidade, unidade, custo_unitario, fora_local_id, observacao)
    values (f.produto_id, f.local_id, 'saida', -p_quantidade, f.unidade, v_custo, f.id,
            concat_ws(' · ', case when f.tipo = 'terceiro' then 'BAIXA EM TERCEIRO' else 'BAIXA DA QUARENTENA' end, f.documento, v_obs));
  else raise exception 'Ação desconhecida'; end if;
  update public.estoque_fora_local set quantidade_resolvida = quantidade_resolvida + p_quantidade,
         situacao = case when quantidade_resolvida + p_quantidade >= quantidade then 'resolvido' else 'aberto' end,
         resolvido_em = case when quantidade_resolvida + p_quantidade >= quantidade then now() end
   where id = f.id;
  return 1;
end $$;
revoke execute on function public.estoque_fora_resolver(bigint, text, numeric, bigint, text) from public, anon;
grant execute on function public.estoque_fora_resolver(bigint, text, numeric, bigint, text) to authenticated;

-- ---------- Aviso para o almoxarifado (entra em Aprovações › Avisos e no "!" do menu) ----------
create or replace function public.estoque_fora_avisos()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('estoque') or public.pode('almoxarifado')) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id,
           'texto', case when f.tipo = 'terceiro' then 'EM PODER DE TERCEIRO · ' || coalesce(t.nome, '') else 'QUARENTENA · ' || coalesce(f.motivo, '') end
                    || ' · ' || coalesce(p.codigo || ' ', '') || p.descricao || ' · ' || trim_scale(f.quantidade - f.quantidade_resolvida) || coalesce(' ' || f.unidade, '')
                    || coalesce(' · ' || f.documento, '') || coalesce(' · previsão ' || to_char(f.previsao_retorno, 'DD/MM'), ''),
           'data', f.criado_em, 'quem', u.nome, 'link', 'pages/estoque/posicao.html?fora=1') order by f.criado_em)
    from public.estoque_fora_local f join public.produtos p on p.id = f.produto_id
    left join public.fornecedores t on t.id = f.terceiro_id left join public.usuarios u on u.id = f.criado_por
   where f.situacao = 'aberto'), '[]'::jsonb);
end $$;
revoke execute on function public.estoque_fora_avisos() from public, anon;
grant execute on function public.estoque_fora_avisos() to authenticated;

-- ---------- Disponível para venda desconta o que está fora (refaz a função do 118, mesmas colunas) ----------
create or replace function public.estoque_disponivel(p_produtos bigint[] default null)
returns table (produto_id bigint, fisico numeric, reservado numeric, disponivel numeric, pedidos int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('estoque') or public.pode('almoxarifado') or public.pode('inventario') or public.pode('compras')
          or public.pode('ordens') or public.pode('apontamento') or public.pode('pedidos')) then
    raise exception 'Sem permissão para ver estoque';
  end if;
  return query
  with f as (select m.produto_id, sum(m.quantidade) q from public.estoque_movimentos m
              where p_produtos is null or m.produto_id = any(p_produtos) group by 1),
       r as (select x.produto_id, sum(x.quantidade) q, count(distinct x.pedido_id)::int n from public.estoque_reservas_itens() x
              where p_produtos is null or x.produto_id = any(p_produtos) group by 1),
       o as (select e.produto_id, sum(e.quantidade - e.quantidade_resolvida) q from public.estoque_fora_local e
              where e.situacao = 'aberto' and (p_produtos is null or e.produto_id = any(p_produtos)) group by 1)
  select coalesce(f.produto_id, r.produto_id), coalesce(f.q, 0), coalesce(r.q, 0), coalesce(f.q, 0) - coalesce(r.q, 0) - coalesce(o.q, 0), coalesce(r.n, 0)
    from f full join r on r.produto_id = f.produto_id
    left join o on o.produto_id = coalesce(f.produto_id, r.produto_id);
end $$;
revoke execute on function public.estoque_disponivel(bigint[]) from public, anon;
grant execute on function public.estoque_disponivel(bigint[]) to authenticated;

select public.ligar_auditoria('estoque_fora_local');

-- Conferência: esperado 1 local em cada área (PODER DE TERCEIRO em "terceiros" e QUARENTENA em "quarentena")
select area, codigo, situacao from public.locais_estoque where area in ('terceiros', 'quarentena') order by area, id;
