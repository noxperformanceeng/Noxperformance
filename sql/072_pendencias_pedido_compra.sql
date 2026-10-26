-- =====================================================================
-- 072 · Pedido de compra: pendências avisadas antes, sem perder o pedido
--  · O rascunho salva mesmo com dados faltando; o que falta aparece como pendência no pedido, na aba
--    "Com pendência" e, para o master, como aviso na tela de Aprovações pendentes (só aviso, não aprovação).
--  · Só o "enviar para aprovação" exige tudo resolvido (ex.: categoria financeira de cada item).
--  · Pendências: item sem categoria, item sem cadastro não liberado, produto sem categoria no cadastro,
--    sem condição de pagamento, sem previsão de entrega, fornecedor sem e-mail/WhatsApp.
-- =====================================================================
create or replace function public.pc_pendencias(p_id bigint)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x), '[]') from (
    select jsonb_build_object('id', 'sem_categoria', 'bloqueia', true, 'texto', count(*) || ' item(ns) sem categoria financeira') x
      from public.pedidos_compra_itens i where i.pedido_id = p_id and i.categoria_financeira_id is null having count(*) > 0
    union all
    select jsonb_build_object('id', 'avulso', 'bloqueia', true, 'texto', 'Item sem cadastro aguardando liberação: ' || array_to_string(public.pc_avulsos_pendentes(p_id), ', '))
     where cardinality(public.pc_avulsos_pendentes(p_id)) > 0
    union all
    select jsonb_build_object('id', 'produto_sem_categoria', 'bloqueia', false, 'texto', 'Produto sem categoria no cadastro: ' || string_agg(distinct coalesce(pr.codigo, pr.descricao), ', '))
      from public.pedidos_compra_itens i join public.produtos pr on pr.id = i.produto_id
     where i.pedido_id = p_id and pr.categoria_financeira_id is null and not i.uso_consumo having count(*) > 0
    union all
    select jsonb_build_object('id', 'sem_condicao', 'bloqueia', false, 'texto', 'Sem condição de pagamento')
      from public.pedidos_compra p where p.id = p_id and p.condicao_pagamento_id is null
    union all
    select jsonb_build_object('id', 'sem_entrega', 'bloqueia', false, 'texto', 'Sem previsão de entrega')
      from public.pedidos_compra p where p.id = p_id and p.data_entrega_prevista is null
    union all
    select jsonb_build_object('id', 'sem_contato', 'bloqueia', false, 'texto', 'Fornecedor sem e-mail e sem WhatsApp para envio')
      from public.pedidos_compra p join public.fornecedores f on f.id = p.fornecedor_id
     where p.id = p_id and coalesce(nullif(p.email_fornecedor, ''), nullif(f.email, ''), nullif(p.whatsapp_fornecedor, ''), nullif(f.telefone, '')) is null
  ) z
$$;
revoke execute on function public.pc_pendencias(bigint) from public, anon;
grant execute on function public.pc_pendencias(bigint) to authenticated;

-- Enviar para aprovação: exige as pendências que bloqueiam resolvidas (o rascunho continua salvando)
do $$ declare d text; begin
  d := pg_get_functiondef('public.pedido_compra_acao(bigint, text, text, jsonb)'::regprocedure);
  if position('pc_pendencias' in d) = 0 then
    d := replace(d, $x$then raise exception 'Inclua os itens do pedido'; end if;$x$,
      $x$then raise exception 'Inclua os itens do pedido'; end if;
    if exists (select 1 from jsonb_array_elements(public.pc_pendencias(p_id)) x where (x->>'bloqueia')::boolean) then
      raise exception 'Resolva antes de enviar: %', (select string_agg(x->>'texto', '; ') from jsonb_array_elements(public.pc_pendencias(p_id)) x where (x->>'bloqueia')::boolean);
    end if;$x$);
    if position('pc_pendencias' in d) = 0 then raise exception 'pedido_compra_acao mudou: revisar 072'; end if;
    execute d;
  end if;
end $$;
