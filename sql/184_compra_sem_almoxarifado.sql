-- =====================================================================
-- 184 · Compra sem entrega física (software, hospedagem, assinatura) não passa pelo almoxarifado
--  · Pedido de compra em que nenhum item é material físico — serviço marcado no cadastro como
--    "não passa pelo almoxarifado" (ex.: ASSINATURA SUPABASE PRO) ou item com categoria de Tecnologia
--    (6.04: softwares e licenças, hospedagem, nuvem, sistemas) — além do frete/transporte que já era assim:
--      · NÃO gera aviso para o almoxarifado e NÃO aparece na tela Recebimento;
--      · fica com o financeiro: se já foi pago (antecipado/cartão), o pedido se conclui na aprovação
--        (a conta já está no contas a pagar); se não, o financeiro dá a entrada da fatura no pedido.
--  · Cadastro de serviços ganha a opção "passa pelo almoxarifado" (padrão: sim; usinagem/pintura continuam passando).
--  · Para desfazer: marcar o serviço como "passa pelo almoxarifado" de novo.
-- =====================================================================

alter table public.servicos add column if not exists passa_almoxarifado boolean not null default true;
update public.servicos set passa_almoxarifado = false where upper(nome) like 'ASSINATURA SUPABASE%' and passa_almoxarifado;

-- Pedido sem nada para o almoxarifado receber
create or replace function public.pc_sem_almoxarifado(p_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select public.pc_eh_transporte(p_id)
      or (exists (select 1 from public.pedidos_compra_itens where pedido_id = p_id)
          and not exists (select 1 from public.pedidos_compra_itens i
                            left join public.servicos s on s.id = i.servico_id
                            left join public.categorias_financeiras c on c.id = i.categoria_financeira_id
                           where i.pedido_id = p_id
                             and not (coalesce(s.passa_almoxarifado, true) = false or coalesce(c.codigo, '') like '6.04.%')));
$$;
revoke execute on function public.pc_sem_almoxarifado(bigint) from public, anon, authenticated;

-- Para as telas: pedidos em aberto que não passam pelo almoxarifado
create or replace function public.pc_ids_sem_almoxarifado()
returns setof bigint language sql stable security definer set search_path = public as $$
  select p.id from public.pedidos_compra p
   where ((select public.pode('compras')) or (select public.pode('almoxarifado')) or (select public.pode('pagar')))
     and p.situacao in ('rascunho', 'em_aprovacao', 'recusado', 'aprovado', 'enviado', 'recebido_parcial')
     and public.pc_sem_almoxarifado(p.id);
$$;
revoke execute on function public.pc_ids_sem_almoxarifado() from public, anon;
grant execute on function public.pc_ids_sem_almoxarifado() to authenticated;

-- 1) Sem aviso ao almoxarifado
do $$ declare d text; n text; begin
  d := pg_get_functiondef('public.pc_avisar_almoxarifado()'::regprocedure);
  if position('pc_sem_almoxarifado' in d) > 0 then return; end if;
  n := replace(d, 'and not public.pc_eh_transporte(new.id) then', 'and not public.pc_sem_almoxarifado(new.id) then');
  if n = d then raise exception 'pc_avisar_almoxarifado: ponto de troca não encontrado'; end if;
  execute n;
end $$;

-- 2) Já pago e sem entrega física: conclui na aprovação (a conta já está no contas a pagar)
create or replace function public.pc_concluir_sem_almoxarifado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.situacao = 'aprovado' and old.situacao is distinct from 'aprovado' and new.pagamento_antecipado
     and coalesce(new.origem, 'sistema') <> 'tiny' and public.pc_sem_almoxarifado(new.id) then
    update public.pedidos_compra_itens set quantidade_recebida = quantidade where pedido_id = new.id;
    update public.pedidos_compra set situacao = 'recebido', valor_recebido = valor_total where id = new.id;
    perform public.pc_evento(new.id, 'concluido', 'Sem entrega física (serviço/software): concluído na aprovação · a conta já está no contas a pagar com o financeiro');
  end if;
  return new;
end $$;
revoke execute on function public.pc_concluir_sem_almoxarifado() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'pc_concluir_sem_almoxarifado' and tgrelid = 'public.pedidos_compra'::regclass) then
    create trigger pc_concluir_sem_almoxarifado after update of situacao on public.pedidos_compra
      for each row execute function public.pc_concluir_sem_almoxarifado();
  end if;
end $$;

-- 3) Pedido sem entrega física não pago antes: o financeiro dá a entrada da fatura
do $$ declare d text; n text; begin
  d := pg_get_functiondef('public.pedido_compra_receber(bigint,jsonb,jsonb,jsonb)'::regprocedure);
  if position('pc_sem_almoxarifado' in d) > 0 then return; end if;
  n := replace(d, $x$if not (public.pode('compras', 'alterar') or public.pode('estoque', 'alterar')) then$x$,
                  $x$if not (public.pode('compras', 'alterar') or public.pode('estoque', 'alterar') or (public.pode('pagar', 'alterar') and public.pc_sem_almoxarifado(p_id))) then$x$);
  if n = d then raise exception 'pedido_compra_receber: ponto de troca não encontrado'; end if;
  execute n;
end $$;
