-- =====================================================================
-- 070 · Ordens de compra do Tiny no sistema (para vincular a NF)
--  · A API do Tiny que temos (v2) não entrega ordens de compra. Por isso a NF que chega de uma compra feita
--    no Tiny é vinculada informando o nº da ordem do Tiny: o sistema cria o pedido marcado "TINY nº",
--    separado dos pedidos do sistema (origem Tiny, etiqueta própria, sem escala de aprovação, sem projeção no CP).
--  · NF já lançada no Tiny (o contas a pagar já veio da leitura do Tiny): fica "lançada" sem gerar
--    novo título — evita pagar em dobro. O sistema avisa quando acha a mesma NF nas notas de entrada do Tiny.
--  · NF ainda não lançada no Tiny: segue o caminho normal (conferir → recebimento no pedido → CP + estoque).
-- =====================================================================
alter table public.pedidos_compra add column if not exists origem text not null default 'sistema';
alter table public.pedidos_compra add column if not exists numero_tiny text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pedidos_compra_origem_ck') then
    alter table public.pedidos_compra add constraint pedidos_compra_origem_ck check (origem in ('sistema','tiny'));
  end if;
end $$;
create unique index if not exists pedidos_compra_tiny_uk on public.pedidos_compra (empresa_id, numero_tiny) where numero_tiny is not null;

-- Pedido do Tiny não gera projeção no contas a pagar (o título vem do Tiny ou do recebimento da NF)
do $$ declare d text; begin
  d := pg_get_functiondef('public.pc_projetar(bigint)'::regprocedure);
  if position('origem = ''tiny''' in d) = 0 then
    d := replace(d, $x$  if p.situacao not in ('aprovado','enviado','recebido_parcial') then return 0; end if;$x$,
                    $x$  if p.situacao not in ('aprovado','enviado','recebido_parcial') or p.origem = 'tiny' then return 0; end if;$x$);
    if position('origem = ''tiny''' in d) = 0 then raise exception 'pc_projetar mudou: revisar 070'; end if;
    execute d;
  end if;
end $$;

-- A NF já está nas notas de entrada do Tiny? (mesmo CNPJ do emitente, mesmo número e mesma empresa)
create or replace function public.nfe_no_tiny()
returns table (nfe_id bigint, tiny_id text, situacao_tiny text)
language sql stable security definer set search_path = public as $$
  select n.id, b.tiny_id, b.resumo->>'descricao_situacao'
    from public.nfe_entrada n
    join public.tiny_brutos b on b.recurso = 'notas_entrada' and b.empresa_id = n.empresa_id
     and regexp_replace(coalesce(b.resumo->>'numero', ''), '\D', '', 'g') ~ '^\d+$'
     and (regexp_replace(b.resumo->>'numero', '\D', '', 'g'))::bigint = nullif(regexp_replace(n.numero, '\D', '', 'g'), '')::bigint
     and regexp_replace(coalesce(b.resumo->'cliente'->>'cpf_cnpj', ''), '\D', '', 'g') = regexp_replace(coalesce(n.emitente_cnpj, ''), '\D', '', 'g')
   where (select public.pode('notas')) or (select public.pode('compras'))
$$;
revoke execute on function public.nfe_no_tiny() from public, anon;
grant execute on function public.nfe_no_tiny() to authenticated;

-- Vincula a NF a uma ordem de compra do Tiny (cria o pedido TINY-nº com os itens da NF, se ainda não existir)
create or replace function public.nfe_vincular_oc_tiny(p_nf bigint, p_numero_tiny text, p_ja_lancada boolean)
returns bigint language plpgsql security definer set search_path = public as $$
declare n public.nfe_entrada; v_pc bigint; v_num text := upper(trim(p_numero_tiny));
begin
  if not ((select public.pode('notas', 'alterar')) or (select public.pode('compras', 'criar'))) then raise exception 'Sem permissão'; end if;
  if coalesce(v_num, '') = '' then raise exception 'Informe o nº da ordem de compra no Tiny'; end if;
  select * into n from public.nfe_entrada where id = p_nf for update;
  if n.id is null then raise exception 'NF não encontrada'; end if;
  if n.situacao not in ('nova','conferida') then raise exception 'NF % está "%": volte para nova antes', n.numero, n.situacao; end if;
  if n.fornecedor_id is null then raise exception 'Vincule o fornecedor da NF antes'; end if;
  if n.situacao_sefaz <> 'autorizada' then raise exception 'NF % está % na SEFAZ', n.numero, n.situacao_sefaz; end if;
  select id into v_pc from public.pedidos_compra where empresa_id = n.empresa_id and numero_tiny = v_num;
  if v_pc is not null and (select fornecedor_id from public.pedidos_compra where id = v_pc) <> n.fornecedor_id then
    raise exception 'A ordem % do Tiny já está no sistema com outro fornecedor', v_num;
  end if;
  if v_pc is null then
    insert into public.pedidos_compra (numero_tiny, origem, empresa_id, fornecedor_id, comprador_id, data_pedido, situacao, valor_produtos, frete,
        outras_despesas, desconto, valor_total, valor_recebido, niveis_exigidos, niveis_aprovados, observacoes_internas)
    values (v_num, 'tiny', n.empresa_id, n.fornecedor_id, auth.uid(), (n.data_emissao at time zone 'America/Sao_Paulo')::date, 'enviado',
        0, 0, 0, 0, 0, 0, '{}', '{}',
        'ORDEM DE COMPRA ' || v_num || ' DO TINY (APROVADA NO TINY). CRIADA NO SISTEMA PARA VINCULAR A NF ' || n.numero || '.')
    returning id into v_pc;
    insert into public.pedidos_compra_itens (pedido_id, produto_id, descricao, unidade, codigo_fornecedor, quantidade, valor_unitario, desconto, uso_consumo)
    select v_pc, (select pf.produto_id from public.produto_fornecedores pf where pf.fornecedor_id = n.fornecedor_id and pf.codigo_fornecedor = it->>'codigo' limit 1),
           upper(it->>'descricao'), it->>'unidade', it->>'codigo', (it->>'quantidade')::numeric, (it->>'valor_unitario')::numeric, greatest(round((it->>'quantidade')::numeric * (it->>'valor_unitario')::numeric, 2) - coalesce((it->>'valor')::numeric, 0), 0), false
      from jsonb_array_elements(coalesce(n.itens, '[]')) it where coalesce((it->>'quantidade')::numeric, 0) > 0;
    update public.pedidos_compra set valor_produtos = (select coalesce(sum(valor_total), 0) from public.pedidos_compra_itens where pedido_id = v_pc),
           valor_total = n.valor_total where id = v_pc;
    perform public.pc_evento(v_pc, 'criado', 'Ordem de compra ' || v_num || ' do Tiny vinculada à NF ' || n.numero, '{}'::jsonb);
  end if;
  update public.nfe_entrada set pedido_compra_id = v_pc where id = n.id;
  if p_ja_lancada then
    update public.nfe_entrada set situacao = 'lancada', conferida_por = auth.uid(), conferida_em = now(),
           observacoes = concat_ws(' · ', observacoes, 'JÁ LANÇADA NO TINY: o contas a pagar vem da leitura do Tiny (não gerou título aqui)') where id = n.id;
    update public.pedidos_compra set situacao = 'recebido', valor_recebido = valor_total where id = v_pc;
    perform public.pc_evento(v_pc, 'recebido', 'NF ' || n.numero || ' já lançada no Tiny', '{}'::jsonb);
  end if;
  return v_pc;
end $$;
revoke execute on function public.nfe_vincular_oc_tiny(bigint, text, boolean) from public, anon;
grant execute on function public.nfe_vincular_oc_tiny(bigint, text, boolean) to authenticated;

-- Leitura diária das notas de entrada do Tiny (só a lista, últimos 60 dias) para o aviso "já está no Tiny"
select cron.schedule('nox-tiny-nfe-30', '55 8 * * *', $$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '30', 'recurso', 'notas_entrada', 'detalhar', false, 'filtros', jsonb_build_object('dataInicial', to_char(current_date - 60, 'DD/MM/YYYY'), 'dataFinal', to_char(current_date, 'DD/MM/YYYY'))))$$);
select cron.schedule('nox-tiny-nfe-37', '58 8 * * *', $$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '37', 'recurso', 'notas_entrada', 'detalhar', false, 'filtros', jsonb_build_object('dataInicial', to_char(current_date - 60, 'DD/MM/YYYY'), 'dataFinal', to_char(current_date, 'DD/MM/YYYY'))))$$);
