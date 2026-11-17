-- =====================================================================
-- 145 · Usinagem: envio do material ao prestador e volta das peças
--  · No pedido de compra de usinagem, o almoxarifado registra o envio do material ("Registrar envio do
--    material…"): a barra SAI do local dela no estoque e fica "EM PODER DE TERCEIRO" (o prestador), ligada
--    ao pedido e à peça. Ela continua contando no estoque físico (é da NOX), mas não no disponível.
--  · Na entrada das peças usinadas, o sistema sozinho:
--      1) dá entrada nas peças (como já fazia);
--      2) dá baixa no material que estava no prestador, na proporção das peças que voltaram
--         (ex.: pediu 100, voltaram 50 → consome metade do material enviado; voltou tudo → consome tudo);
--      3) soma o custo do material consumido ao custo da peça (custo real = serviço + material).
--  · Sobra e perda: o que ficar no prestador continua na lista "Fora do estoque" (Posição de estoque):
--      "Chegou / guardar" = sobra que voltou; "Baixar" = perda (com o motivo).
--  · O material escolhido fica lembrado na ficha de usinagem da peça (próximo envio já vem sugerido).
--  · Nada muda nos pedidos e no estoque que já existem. Para desfazer: o trigger estoque_usinagem pode ser
--    desligado (alter table public.pedidos_compra_recebimentos disable trigger estoque_usinagem).
-- =====================================================================

alter table public.estoque_fora_local add column if not exists pedido_compra_item_id bigint
  references public.pedidos_compra_itens(id) on delete set null;
create index if not exists estoque_fora_item on public.estoque_fora_local (pedido_compra_item_id) where pedido_compra_item_id is not null;
alter table public.produto_usinagem add column if not exists material_produto_id bigint references public.produtos(id);

-- ---------- Registrar envio do material para a usinagem ----------
create or replace function public.pc_usinagem_enviar_material(p_item bigint, p_material bigint, p_quantidade numeric, p_obs text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare i public.pedidos_compra_itens; p public.pedidos_compra; m public.produtos; pc public.produtos;
        v_terc bigint; v_custo numeric; v_saida bigint; v_entra bigint; v_fora bigint; v_obs text; v_doc text; v_forn text;
begin
  if not (public.pode('estoque', 'criar') or public.pode('almoxarifado', 'criar') or public.pode('compras', 'alterar')) then
    raise exception 'Sem permissão para registrar envio de material';
  end if;
  select * into i from public.pedidos_compra_itens where id = p_item;
  if i.id is null or i.tipo_item <> 'servico_usinagem' then raise exception 'Este item não é serviço de usinagem'; end if;
  select * into p from public.pedidos_compra where id = i.pedido_id for update;
  if p.situacao not in ('aprovado', 'enviado', 'recebido_parcial') then
    raise exception 'O material só é enviado com o pedido aprovado e ainda não todo recebido';
  end if;
  if coalesce(p_quantidade, 0) <= 0 then raise exception 'Informe a quantidade de material enviada'; end if;
  select * into m from public.produtos where id = p_material;
  if m.id is null then raise exception 'Escolha o material (produto cadastrado no estoque)'; end if;
  if m.id = i.produto_id then raise exception 'O material enviado não pode ser a própria peça que volta usinada'; end if;
  if not coalesce(m.controla_estoque, false) then raise exception 'O produto % não controla estoque', coalesce(m.codigo, m.descricao); end if;
  v_terc := public.local_da_area('terceiros');
  if v_terc is null then raise exception 'Cadastre um local ativo da área "Em terceiros" (ex.: PODER DE TERCEIRO)'; end if;
  select * into pc from public.produtos where id = i.produto_id;
  select upper(coalesce(nullif(nome_fantasia, ''), nome)) into v_forn from public.fornecedores where id = p.fornecedor_id;
  v_custo := public.estoque_custo_medio(m.id);
  v_obs := nullif(upper(trim(p_obs)), '');
  v_doc := p.numero || ' · USINAGEM ' || coalesce(pc.codigo, pc.descricao);

  insert into public.estoque_movimentos (produto_id, local_id, tipo, quantidade, unidade, custo_unitario, pedido_compra_id, observacao)
  values (m.id, m.local_id, 'envio_terceiro', -p_quantidade, m.unidade, v_custo, p.id, concat_ws(' · ', 'ENVIADO PARA USINAGEM: ' || v_forn, v_doc, v_obs))
  returning id into v_saida;
  insert into public.estoque_movimentos (produto_id, local_id, tipo, quantidade, unidade, custo_unitario, pedido_compra_id, observacao)
  values (m.id, v_terc, 'envio_terceiro', p_quantidade, m.unidade, v_custo, p.id, concat_ws(' · ', 'EM PODER DE ' || v_forn, v_doc, v_obs))
  returning id into v_entra;
  insert into public.estoque_fora_local (tipo, produto_id, quantidade, unidade, custo_unitario, local_id, terceiro_id, motivo, documento,
    movimento_id, pedido_compra_id, pedido_compra_item_id)
  values ('terceiro', m.id, p_quantidade, m.unidade, v_custo, v_terc, p.fornecedor_id, concat_ws(' · ', 'USINAGEM', v_obs), v_doc,
    v_entra, p.id, i.id)
  returning id into v_fora;
  update public.estoque_movimentos set fora_local_id = v_fora where id in (v_saida, v_entra);

  update public.produto_usinagem set material_produto_id = m.id where produto_id = i.produto_id and material_produto_id is distinct from m.id;
  perform public.pc_evento(p.id, 'material_enviado',
    'Material enviado para usinagem: ' || trim_scale(p_quantidade) || coalesce(' ' || m.unidade, '') || ' ' || coalesce(m.codigo || ' ', '') || m.descricao
      || ' (para ' || coalesce(pc.codigo, pc.descricao) || ')' || coalesce(' · ' || v_obs, ''),
    jsonb_build_object('fora_local_id', v_fora, 'item_id', i.id));
  return v_fora;
end $$;
revoke execute on function public.pc_usinagem_enviar_material(bigint, bigint, numeric, text) from public, anon;
grant execute on function public.pc_usinagem_enviar_material(bigint, bigint, numeric, text) to authenticated;

-- ---------- Material de usinagem de um pedido (enviado, consumido, voltou, perda, no prestador) ----------
create or replace function public.pc_usinagem_material(p_pedido bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not ((select public.pode('compras')) or (select public.pode('estoque')) or (select public.pode('almoxarifado'))) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', f.id, 'item_id', f.pedido_compra_item_id, 'produto_id', f.produto_id, 'codigo', pr.codigo, 'descricao', pr.descricao, 'unidade', f.unidade,
      'enviado', f.quantidade, 'custo_unitario', f.custo_unitario, 'em_poder', f.quantidade - f.quantidade_resolvida, 'situacao', f.situacao,
      'consumido', coalesce(-(select sum(x.quantidade) from public.estoque_movimentos x where x.fora_local_id = f.id and x.tipo = 'consumo'), 0),
      'voltou', coalesce(-(select sum(x.quantidade) from public.estoque_movimentos x where x.fora_local_id = f.id and x.tipo = 'retorno_terceiro' and x.local_id = f.local_id), 0),
      'baixado', coalesce(-(select sum(x.quantidade) from public.estoque_movimentos x where x.fora_local_id = f.id and x.tipo = 'saida'), 0),
      'em', f.criado_em, 'por', f.criado_por, 'obs', f.motivo) order by f.id)
    from public.estoque_fora_local f join public.produtos pr on pr.id = f.produto_id
   where f.pedido_compra_id = p_pedido and f.pedido_compra_item_id is not null), '[]'::jsonb);
end $$;
revoke execute on function public.pc_usinagem_material(bigint) from public, anon;
grant execute on function public.pc_usinagem_material(bigint) to authenticated;

-- ---------- Entrada das peças: consome o material no prestador e soma o custo dele na peça ----------
create or replace function public.pc_recebimento_usinagem()
returns trigger language plpgsql security definer set search_path = public as $$
declare x record; f record; v_enviado numeric; v_ja numeric; v_alvo numeric; v_falta numeric; v_q numeric; v_custo numeric; v_qpeca numeric;
        v_doc text;
begin
  v_doc := case when new.nf_numero = 'SEM NF' then 'SEM NF' else 'NF ' || new.nf_numero end;
  for x in select i.id, i.produto_id, i.quantidade_recebida, greatest(i.quantidade - coalesce(i.quantidade_cancelada, 0), 0) qped, pr.codigo
             from jsonb_to_recordset(coalesce(new.itens, '[]')) r(item_id bigint, quantidade numeric)
             join public.pedidos_compra_itens i on i.id = r.item_id and i.tipo_item = 'servico_usinagem'
             left join public.produtos pr on pr.id = i.produto_id
            where r.quantidade > 0 loop
    -- quanto do material já devia ter sido consumido: enviado × peças recebidas até agora ÷ peças do pedido
    select coalesce(sum(quantidade), 0) into v_enviado from public.estoque_fora_local where pedido_compra_item_id = x.id;
    continue when v_enviado = 0;
    select coalesce(-sum(m.quantidade), 0) into v_ja from public.estoque_movimentos m
     where m.tipo = 'consumo' and m.fora_local_id in (select id from public.estoque_fora_local where pedido_compra_item_id = x.id);
    v_alvo := case when x.qped <= 0 or x.quantidade_recebida >= x.qped then v_enviado else round(v_enviado * x.quantidade_recebida / x.qped, 4) end;
    v_falta := v_alvo - v_ja; v_custo := 0;
    for f in select * from public.estoque_fora_local where pedido_compra_item_id = x.id and situacao = 'aberto' order by id for update loop
      exit when v_falta <= 0;
      v_q := least(v_falta, f.quantidade - f.quantidade_resolvida);
      continue when v_q <= 0;
      insert into public.estoque_movimentos (produto_id, local_id, tipo, quantidade, unidade, custo_unitario, pedido_compra_id, recebimento_id, fora_local_id, observacao, data)
      values (f.produto_id, f.local_id, 'consumo', -v_q, f.unidade, f.custo_unitario, new.pedido_id, new.id, f.id,
              concat_ws(' · ', 'CONSUMIDO NA USINAGEM DE ' || coalesce(x.codigo, 'PEÇA'), v_doc, f.documento), new.data_recebimento);
      update public.estoque_fora_local set quantidade_resolvida = quantidade_resolvida + v_q,
             situacao = case when quantidade_resolvida + v_q >= quantidade then 'resolvido' else 'aberto' end,
             resolvido_em = case when quantidade_resolvida + v_q >= quantidade then now() end
       where id = f.id;
      v_custo := v_custo + v_q * coalesce(f.custo_unitario, 0);
      v_falta := v_falta - v_q;
    end loop;
    -- custo real da peça desta entrada = serviço + material consumido (rateado pelas peças que entraram)
    if v_custo > 0 then
      select sum(quantidade) into v_qpeca from public.estoque_movimentos
       where recebimento_id = new.id and produto_id = x.produto_id and tipo = 'entrada_compra' and quantidade > 0;
      if coalesce(v_qpeca, 0) > 0 then
        update public.estoque_movimentos set custo_unitario = round(coalesce(custo_unitario, 0) + v_custo / v_qpeca, 6),
               observacao = concat_ws(' · ', observacao, 'MATERIAL R$ ' || to_char(v_custo / v_qpeca, 'FM999G990D00') || '/PÇ')
         where recebimento_id = new.id and produto_id = x.produto_id and tipo = 'entrada_compra' and quantidade > 0;
      end if;
    end if;
  end loop;
  return new;
end $$;
revoke execute on function public.pc_recebimento_usinagem() from public, anon, authenticated;

-- roda depois do "estoque_entrada" (os triggers rodam em ordem alfabética do nome)
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'estoque_usinagem' and tgrelid = 'public.pedidos_compra_recebimentos'::regclass) then
    create trigger estoque_usinagem after insert on public.pedidos_compra_recebimentos for each row execute function public.pc_recebimento_usinagem();
  end if;
end $$;

-- Conferência: esperado 1 trigger estoque_usinagem e as duas colunas novas
select (select count(*) from pg_trigger where tgname = 'estoque_usinagem') trigger_ok,
       (select count(*) from information_schema.columns where table_schema = 'public'
         and ((table_name = 'estoque_fora_local' and column_name = 'pedido_compra_item_id') or (table_name = 'produto_usinagem' and column_name = 'material_produto_id'))) colunas_ok;
