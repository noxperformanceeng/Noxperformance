-- =====================================================================
-- 171 · Ordem de compra de transporte não avisa o almoxarifado
--  · Pedido do Paulo (25/11/2026): frete, coleta e retirada de material não têm o que o Glauvens conferir.
--  · É transporte quando o fornecedor está na categoria "Transporte" ou quando todos os itens do pedido estão
--    em categoria financeira de frete (ex.: 3.06.001 Frete sobre compras, 4.01.004 Frete de venda).
--  · Esses pedidos deixam de gerar o recado "Ordem de compra aprovada" para o almoxarifado; os recados que já
--    existem desses pedidos (PC-00046, PC-00053, PC-00054) são concluídos como "transporte: nada a conferir".
--  · O resto do pedido não muda (aprovação, contas a pagar). Para desfazer: reaplicar a função do 170.
-- =====================================================================

create or replace function public.pc_eh_transporte(p_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pedidos_compra p join public.fornecedores f on f.id = p.fornecedor_id
                  where p.id = p_id and f.categoria ilike 'transporte%')
      or (exists (select 1 from public.pedidos_compra_itens where pedido_id = p_id)
          and not exists (select 1 from public.pedidos_compra_itens i left join public.categorias_financeiras c on c.id = i.categoria_financeira_id
                           where i.pedido_id = p_id and coalesce(c.nome, '') !~* 'frete'));
$$;
revoke execute on function public.pc_eh_transporte(bigint) from public, anon, authenticated;

create or replace function public.pc_avisar_almoxarifado()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_link text := 'pages/compras/pedidos.html?abrir=' || new.id; v_forn text; v_de uuid;
begin
  if new.situacao = 'aprovado' and old.situacao is distinct from 'aprovado' and coalesce(new.origem, 'sistema') <> 'tiny'
     and not exists (select 1 from public.recados where link = v_link)
     and not public.pc_eh_transporte(new.id) then
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

-- recados que já foram para o almoxarifado de pedidos de transporte: concluídos
update public.recados r set feito_em = now(), resposta = coalesce(r.resposta, 'Transporte: nada a conferir no almoxarifado')
  from public.pedidos_compra p
 where r.link = 'pages/compras/pedidos.html?abrir=' || p.id and r.feito_em is null and public.pc_eh_transporte(p.id);
