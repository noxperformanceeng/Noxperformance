-- =====================================================================
-- 170 · Compras simples: compra direta, sem "enviar ao fornecedor" e aviso automático ao almoxarifado
--  · Pedido do Paulo (25/11/2026): o fluxo de compras estava burocrático demais.
--  · Pedido de compra NÃO precisa mais de solicitação vinculada (solicitação fica só para quem pede ao comprador).
--  · Compra em loja/marketplace (Mercado Livre, Shopee, Magalu, AliExpress… marcados no cadastro do fornecedor)
--    não exige cotação, de qualquer valor. Fornecedor tradicional continua com cotação a partir de R$500.
--  · Pagamento antecipado: basta a data ("Pagar até" ou a data em que já pagou); Pix/boleto/link ficam opcionais.
--  · Sem bloqueio por fornecedor sem e-mail/WhatsApp: mandar o pedido ao fornecedor deixa de ser etapa.
--  · Pedido lançado pela diretoria (quem aprova) já nasce APROVADO ao clicar em "Enviar para aprovação".
--  · Pedido aprovado → recado automático na Minha mesa do almoxarifado (perfil estoque): "Ordem de compra
--    PC-xxx aprovada", com o link para abrir/imprimir. Quando a entrada da NF fecha o pedido, o recado se conclui.
--  · Para desfazer: reaplicar as versões anteriores das funções (166/151) e desligar o gatilho.
-- =====================================================================

-- ---------- Fornecedor de loja / marketplace: compra sem cotação ----------
alter table public.fornecedores add column if not exists compra_sem_cotacao boolean not null default false;
comment on column public.fornecedores.compra_sem_cotacao is 'Loja ou marketplace com preço público (Mercado Livre, Shopee…): pedido não exige cotação';
update public.fornecedores set compra_sem_cotacao = true
 where not compra_sem_cotacao and nome ~* '(mercado ?livre|shopee|amazon|magazine luiza|magalu|aliexpress|kabum|leroy merlin|americanas|casas bahia)';

-- ---------- Por que o pedido pode seguir sem cotação (null = precisa de cotação) ----------
create or replace function public.pc_dispensa_cotacao(p_id bigint)
returns text language sql stable security definer set search_path to 'public' as $$
  select case
    when p.id is null then null
    when p.origem = 'tiny' then 'tiny'
    when p.valor_total < cfg.minimo then 'abaixo_limite'
    when exists (select 1 from public.fornecedores f where f.id = p.fornecedor_id and f.compra_sem_cotacao) then 'loja'
    when exists (select 1 from public.cotacoes_compra_fornecedores cf where cf.pedido_id = p.id) then 'cotacao'
    when p.cotacao_dispensa is not null then 'dispensa_diretoria'
    when coalesce(p.pagamento_antecipado, false) or coalesce(p.pagamento_urgente, false) then 'urgente'
    when exists (select 1 from public.pedidos_compra_itens i where i.pedido_id = p.id)
     and not exists (
       select 1 from public.pedidos_compra_itens i
        where i.pedido_id = p.id
          and not coalesce((
            select i.valor_unitario <= u.valor_unitario * (1 + cfg.tol / 100)
              from public.pedidos_compra_itens u join public.pedidos_compra q on q.id = u.pedido_id
             where q.id <> p.id and q.fornecedor_id = p.fornecedor_id
               and q.situacao in ('aprovado','enviado','recebido_parcial','recebido')
               and (i.produto_id is not null or i.servico_id is not null)
               and u.produto_id is not distinct from i.produto_id and u.servico_id is not distinct from i.servico_id
               and u.valor_unitario > 0
             order by q.data_pedido desc, u.id desc limit 1), false))
    then 'recompra'
  end
  from (select 1) d
  left join public.pedidos_compra p on p.id = p_id
  cross join lateral (select coalesce(max(cotacao_valor_minimo), 500) minimo, coalesce(max(recompra_tolerancia_pct), 5) tol from public.compras_config) cfg
  where (select public.pode('compras'))
$$;
revoke all on function public.pc_dispensa_cotacao(bigint) from public, anon;
grant execute on function public.pc_dispensa_cotacao(bigint) to authenticated;

-- ---------- Pendências do pedido (menos travas) ----------
create or replace function public.pc_pendencias(p_id bigint)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(x), '[]') from (
    select jsonb_build_object('id', 'sem_categoria', 'bloqueia', true, 'texto', count(*) || ' item(ns) sem categoria financeira') x
      from public.pedidos_compra_itens i where i.pedido_id = p_id and i.categoria_financeira_id is null having count(*) > 0
    union all
    select jsonb_build_object('id', 'avulso', 'bloqueia', true, 'texto', 'Item sem cadastro aguardando liberação: ' || array_to_string(public.pc_avulsos_pendentes(p_id), ', '))
     where cardinality(public.pc_avulsos_pendentes(p_id)) > 0
    union all
    select jsonb_build_object('id', 'antecipado_incompleto', 'bloqueia', true, 'texto', 'Pagamento antecipado: informe "Pagar até" (ou a data em que já pagou)')
      from public.pedidos_compra p where p.id = p_id and p.pagamento_antecipado and p.pagamento_data is null
    union all
    select jsonb_build_object('id', 'sem_forma', 'bloqueia', true, 'texto', 'Sem forma de pagamento (Pix, boleto, cartão…)')
      from public.pedidos_compra p where p.id = p_id and p.forma_pagamento_id is null
    union all
    select jsonb_build_object('id', 'produto_sem_categoria', 'bloqueia', false, 'texto', 'Produto sem categoria no cadastro: ' || string_agg(distinct coalesce(pr.codigo, pr.descricao), ', '))
      from public.pedidos_compra_itens i join public.produtos pr on pr.id = i.produto_id
     where i.pedido_id = p_id and pr.categoria_financeira_id is null and not i.uso_consumo and i.servico_id is null having count(*) > 0
    union all
    select jsonb_build_object('id', 'aumento_preco', 'bloqueia', false, 'texto', 'Preço acima da última compra: ' ||
           string_agg((a->>'descricao') || ' R$ ' || replace(to_char((a->>'ultimo')::numeric, 'FM999999990.00'), '.', ',') || ' → R$ ' || replace(to_char((a->>'atual')::numeric, 'FM999999990.00'), '.', ',')
                      || ' (+' || replace(a->>'pct', '.', ',') || '%)', '; '))
      from jsonb_array_elements(public.pc_aumentos(p_id)) a having count(*) > 0
    union all
    select jsonb_build_object('id', 'sem_condicao', 'bloqueia', false, 'texto', 'Sem condição de pagamento')
      from public.pedidos_compra p where p.id = p_id and p.condicao_pagamento_id is null and coalesce(cardinality(p.prazo_livre_dias), 0) = 0
    union all
    select jsonb_build_object('id', 'sem_entrega', 'bloqueia', false, 'texto', 'Sem previsão de entrega')
      from public.pedidos_compra p where p.id = p_id and p.data_entrega_prevista is null
    union all
    select jsonb_build_object('id', 'cotacao_obrigatoria', 'bloqueia', not public.eh_admin(), 'texto',
           'Compra de R$' || replace(replace(replace(to_char(p.valor_total, 'FM999,999,990.00'), ',', '#'), '.', ','), '#', '.')
           || ' (a partir de R$' || replace(replace(replace(to_char(cfg.minimo, 'FM999,999,990.00'), ',', '#'), '.', ','), '#', '.')
           || ') com fornecedor tradicional precisa passar pela COTAÇÃO. Dispensa: loja/marketplace, recompra sem aumento de preço, pagamento antecipado/urgente ou liberação da diretoria')
      from public.pedidos_compra p
      cross join lateral (select coalesce(max(cotacao_valor_minimo), 500) minimo from public.compras_config) cfg
     where p.id = p_id and public.pc_dispensa_cotacao(p_id) is null
  ) z where (select public.pode('compras'))
$$;
revoke all on function public.pc_pendencias(bigint) from public, anon;
grant execute on function public.pc_pendencias(bigint) to authenticated;

-- ---------- Ações do pedido: diretoria que lança já aprova ----------
create or replace function public.pedido_compra_acao(p_id bigint, p_acao text, p_motivo text, p_dados jsonb)
returns text language plpgsql security definer set search_path to 'public' as $function$
declare p public.pedidos_compra; v_nivel int; v_nome text; v_niveis int[];
begin
  select * into p from public.pedidos_compra where id = p_id for update;
  if p.id is null then raise exception 'Pedido não encontrado'; end if;
  if not public.pode('compras') then raise exception 'Sem acesso a compras'; end if;
  if p_acao = 'enviar_aprovacao' then
    if not public.pode('compras', 'criar') then raise exception 'Sem permissão'; end if;
    if p.situacao not in ('rascunho','recusado') then raise exception 'Só rascunho ou recusado vai para aprovação'; end if;
    if not exists (select 1 from public.pedidos_compra_itens where pedido_id = p_id) then raise exception 'Inclua os itens do pedido'; end if;
    if exists (select 1 from jsonb_array_elements(public.pc_pendencias(p_id)) x where (x->>'bloqueia')::boolean) then
      raise exception 'Resolva antes de enviar: %', (select string_agg(x->>'texto', '; ') from jsonb_array_elements(public.pc_pendencias(p_id)) x where (x->>'bloqueia')::boolean);
    end if;
    if p.valor_total <= 0 then raise exception 'Pedido sem valor'; end if;
    if cardinality(public.pc_avulsos_pendentes(p_id)) > 0 then
      raise exception 'Item sem cadastro precisa de liberação do administrador: %', array_to_string(public.pc_avulsos_pendentes(p_id), ', ');
    end if;
    select coalesce(array_agg(distinct a.nivel order by a.nivel), '{}') into v_niveis from public.compras_alcadas a
     where a.ativo and a.valor_minimo <= p.valor_total and (a.empresa_id is null or a.empresa_id = p.empresa_id);
    if cardinality(v_niveis) = 0 then v_niveis := '{0}'; end if;
    -- quem lança é aprovador de todas as etapas (diretoria): já sai aprovado, sem passar pela fila
    if public.eh_admin() or not exists (
         select 1 from unnest(v_niveis) n
          where not (case when n = 0 then public.pode_acao('compras.aprovar')
                          else exists (select 1 from public.compras_alcadas a where a.ativo and a.nivel = n
                                          and (a.empresa_id is null or a.empresa_id = p.empresa_id) and auth.uid() = any(a.aprovadores)) end)) then
      update public.pedidos_compra set situacao = 'aprovado', niveis_exigidos = v_niveis, niveis_aprovados = v_niveis, motivo_recusa = null where id = p_id;
      perform public.pc_projetar(p_id);
      perform public.pc_evento(p_id, 'aprovado', 'Lançado e aprovado pela diretoria · R$ ' || to_char(p.valor_total, 'FM999G999G990D00'), jsonb_build_object('niveis', v_niveis));
      return 'aprovado';
    end if;
    update public.pedidos_compra set situacao = 'em_aprovacao', niveis_exigidos = v_niveis, niveis_aprovados = '{}', motivo_recusa = null where id = p_id;
    perform public.pc_evento(p_id, 'enviado_aprovacao', 'Enviado para aprovação · R$ ' || to_char(p.valor_total, 'FM999G999G990D00'), jsonb_build_object('niveis', v_niveis));
    return 'em_aprovacao';
  elsif p_acao = 'aprovar' then
    if not public.pc_pode_aprovar(p_id) then raise exception 'Você não é aprovador da etapa atual deste pedido'; end if;
    select n into v_nivel from unnest(p.niveis_exigidos) n where not n = any(p.niveis_aprovados) order by n limit 1;
    select string_agg(distinct nome, ' / ') into v_nome from public.compras_alcadas where nivel = v_nivel and ativo;
    update public.pedidos_compra set niveis_aprovados = niveis_aprovados || v_nivel where id = p_id returning * into p;
    perform public.pc_evento(p_id, 'aprovado_nivel', 'Aprovado' || case when v_nivel > 0 then ' · nível ' || v_nivel || coalesce(' (' || v_nome || ')', '') else '' end
      || coalesce(' · ' || nullif(p_motivo, ''), ''), jsonb_build_object('nivel', v_nivel));
    if not exists (select 1 from unnest(p.niveis_exigidos) n where not n = any(p.niveis_aprovados)) then
      update public.pedidos_compra set situacao = 'aprovado' where id = p_id;
      perform public.pc_projetar(p_id);
      perform public.pc_evento(p_id, 'aprovado', 'Pedido aprovado · parcelas previstas lançadas no contas a pagar (aguardando NF)');
      return 'aprovado';
    end if;
    return 'em_aprovacao';
  elsif p_acao = 'recusar' then
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo da recusa'; end if;
    if p.situacao = 'em_aprovacao' then
      if not public.pc_pode_aprovar(p_id) then raise exception 'Você não é aprovador da etapa atual deste pedido'; end if;
    elsif p.situacao in ('aprovado','enviado') then
      if not (public.eh_admin() or public.pode_acao('compras.aprovar')) then raise exception 'Sem permissão para recusar pedido aprovado'; end if;
      if p.valor_recebido > 0 then raise exception 'Pedido já tem recebimento'; end if;
    else raise exception 'Este pedido não está em aprovação'; end if;
    update public.pedidos_compra set situacao = 'recusado', motivo_recusa = p_motivo, niveis_aprovados = '{}' where id = p_id;
    perform public.pc_projetar(p_id);
    perform public.pc_evento(p_id, 'recusado', 'Recusado: ' || p_motivo);
    return 'recusado';
  elsif p_acao = 'reabrir' then
    if not public.pode('compras', 'alterar') then raise exception 'Sem permissão'; end if;
    if p.situacao not in ('em_aprovacao','aprovado','enviado','recusado') then raise exception 'Não dá para reabrir nesta situação'; end if;
    if p.valor_recebido > 0 then raise exception 'Pedido já tem recebimento: não volta para rascunho'; end if;
    update public.pedidos_compra set situacao = 'rascunho', niveis_aprovados = '{}', niveis_exigidos = '{}' where id = p_id;
    perform public.pc_projetar(p_id);
    perform public.pc_evento(p_id, 'reaberto', 'Voltou para rascunho (aprovação anterior desfeita)' || coalesce(' · ' || nullif(p_motivo, ''), ''));
    return 'rascunho';
  elsif p_acao = 'enviado_fornecedor' then
    if not public.pode('compras', 'criar') then raise exception 'Sem permissão'; end if;
    if p.situacao not in ('aprovado','enviado','recebido_parcial') then raise exception 'Só pedido aprovado pode ir ao fornecedor'; end if;
    update public.pedidos_compra set situacao = case when situacao = 'aprovado' then 'enviado' else situacao end, enviado_em = now(), enviado_por = auth.uid(),
      enviado_via = p_dados->>'via', enviado_para = p_dados->>'para', pdf_path = coalesce(p_dados->>'pdf', pdf_path) where id = p_id;
    perform public.pc_evento(p_id, 'enviado_fornecedor', 'Enviado ao fornecedor por ' || coalesce(p_dados->>'via', '?') || coalesce(' para ' || (p_dados->>'para'), '')
      || ' · confirmado pelo comprador', p_dados);
    return 'enviado';
  elsif p_acao = 'pdf' then
    update public.pedidos_compra set pdf_path = p_dados->>'pdf' where id = p_id;
    perform public.pc_evento(p_id, 'pdf', 'PDF gerado', p_dados);
    return p.situacao;
  elsif p_acao = 'cancelar' then
    if not public.pode('compras', 'total') then raise exception 'Sem permissão para cancelar pedido de compra'; end if;
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo do cancelamento'; end if;
    if p.situacao in ('recebido','cancelado') then raise exception 'Pedido % não pode ser cancelado', p.situacao; end if;
    update public.pedidos_compra set situacao = 'cancelado', motivo_cancelamento = p_motivo where id = p_id;
    perform public.pc_projetar(p_id);
    perform public.pc_evento(p_id, 'cancelado', 'Cancelado: ' || p_motivo);
    return 'cancelado';
  elsif p_acao = 'liberar_avulso' then
    if not (public.eh_admin() or public.pode_acao('compras.liberar_avulso')) then raise exception 'Só administrador libera item sem cadastro'; end if;
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo (ex.: compra ocasional para manutenção)'; end if;
    if p.situacao not in ('rascunho','recusado') then raise exception 'Libere antes de enviar para aprovação'; end if;
    update public.pedidos_compra set liberacao_avulso = jsonb_build_object('por', auth.uid(), 'em', now(), 'motivo', p_motivo,
      'itens', (select coalesce(jsonb_agg(descricao), '[]') from public.pedidos_compra_itens where pedido_id = p_id and produto_id is null and servico_id is null)) where id = p_id;
    perform public.pc_evento(p_id, 'liberado_avulso', 'Item(ns) sem cadastro liberado(s): ' ||
      (select string_agg(descricao, ', ') from public.pedidos_compra_itens where pedido_id = p_id and produto_id is null and servico_id is null) || ' · ' || p_motivo);
    return p.situacao;
  elsif p_acao = 'comentario' then
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Escreva o comentário'; end if;
    perform public.pc_evento(p_id, 'comentario', p_motivo);
    return p.situacao;
  end if;
  raise exception 'Ação desconhecida: %', p_acao;
end $function$;
revoke all on function public.pedido_compra_acao(bigint, text, text, jsonb) from public, anon;
grant execute on function public.pedido_compra_acao(bigint, text, text, jsonb) to authenticated;

-- ---------- Aviso automático ao almoxarifado ----------
-- Pedido aprovado → recado para cada pessoa ativa do perfil estoque (uma vez por pedido).
-- Pedido recebido (ou cancelado) → os recados dele se concluem sozinhos.
create or replace function public.pc_avisar_almoxarifado()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_link text := 'pages/compras/pedidos.html?abrir=' || new.id; v_forn text; v_de uuid;
begin
  if new.situacao = 'aprovado' and old.situacao is distinct from 'aprovado' and coalesce(new.origem, 'sistema') <> 'tiny'
     and not exists (select 1 from public.recados where link = v_link) then
    select nome into v_forn from public.fornecedores where id = new.fornecedor_id;
    v_de := coalesce(auth.uid(), new.comprador_id, new.criado_por);
    if v_de is null then return new; end if;
    insert into public.recados (de_id, para_id, texto, link, prazo)
    select v_de, u.id,
           'Ordem de compra ' || new.numero || ' aprovada · ' || coalesce(v_forn, 'fornecedor') || ' · R$ '
           || replace(replace(replace(to_char(new.valor_total, 'FM999,999,990.00'), ',', '#'), '.', ','), '#', '.')
           || case when new.data_entrega_prevista is not null then ' · chega até ' || to_char(new.data_entrega_prevista, 'DD/MM') else '' end
           || '. Quando a mercadoria chegar, dê entrada da NF no pedido (dá para imprimir o pedido por lá).',
           v_link, new.data_entrega_prevista
      from public.usuarios u where u.ativo and u.perfil_id = 'estoque' and u.id <> v_de;
  elsif new.situacao in ('recebido', 'cancelado') and old.situacao is distinct from new.situacao then
    update public.recados set feito_em = now(), resposta = coalesce(resposta, case when new.situacao = 'recebido' then 'Entrada da NF registrada' else 'Pedido cancelado' end)
     where link = v_link and feito_em is null;
  end if;
  return new;
end $$;
revoke execute on function public.pc_avisar_almoxarifado() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'pc_avisar_almoxarifado' and tgrelid = 'public.pedidos_compra'::regclass) then
    create trigger pc_avisar_almoxarifado after update of situacao on public.pedidos_compra
      for each row execute function public.pc_avisar_almoxarifado();
  end if;
end $$;
create index if not exists recados_link_idx on public.recados (link) where link is not null;
