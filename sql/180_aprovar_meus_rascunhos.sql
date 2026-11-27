-- =====================================================================
-- 180 · Central de Aprovações mostra as compras diretas do administrador prontas para aprovar
--  · Hoje a tela "Aprovações" só lista pedidos de compra que alguém ENVIOU para aprovação. O pedido
--    que o próprio administrador lança (ex.: compra direta no Mercado Livre) fica em rascunho e não
--    aparece lá — era preciso achar um por um no painel de compras.
--  · Agora, para o administrador, entram também os rascunhos (ou recusados) LANÇADOS POR ELE (ou em que
--    ele é o comprador) que já estão prontos: com itens, com valor, sem pendência que bloqueie e sem
--    item sem cadastro aguardando liberação. Rascunho do comprador (Elvis) continua só com ele até ser enviado.
--  · Aprovar na central (um ou vários de uma vez) faz o mesmo que o botão "Aprovar e lançar a compra" do pedido:
--    aprova e já lança no contas a pagar.
--  · Para desfazer: voltar a versão anterior de minhas_aprovacoes e aprovacao_decidir (só troca de texto da consulta).
-- =====================================================================

-- Rascunho do próprio administrador pronto para aprovar
create or replace function public.pc_pronto_para_mim(p_id bigint)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare p public.pedidos_compra;
begin
  if not (select public.eh_admin()) then return false; end if;
  select * into p from public.pedidos_compra where id = p_id;
  if p.id is null or p.situacao not in ('rascunho', 'recusado') or coalesce(p.origem, '') = 'tiny' then return false; end if;
  if auth.uid() is distinct from coalesce(p.comprador_id, p.criado_por) and auth.uid() is distinct from p.criado_por then return false; end if;
  if coalesce(p.valor_total, 0) <= 0 or not exists (select 1 from public.pedidos_compra_itens i where i.pedido_id = p_id) then return false; end if;
  if cardinality(public.pc_avulsos_pendentes(p_id)) > 0 then return false; end if;
  return not exists (select 1 from jsonb_array_elements(public.pc_pendencias(p_id)) x where (x->>'bloqueia')::boolean);
end $$;
revoke execute on function public.pc_pronto_para_mim(bigint) from public, anon, authenticated;

-- 1) A central lista também esses rascunhos
do $$ declare d text; n text; begin
  d := pg_get_functiondef('public.minhas_aprovacoes()'::regprocedure);
  if position('pc_pronto_para_mim' in d) > 0 then return; end if;   -- já aplicado
  n := replace(d,
    $x$   where p.situacao = 'em_aprovacao' and public.pc_pode_aprovar(p.id);$x$,
    $x$   where (p.situacao = 'em_aprovacao' and public.pc_pode_aprovar(p.id)) or public.pc_pronto_para_mim(p.id);$x$);
  if n = d then raise exception 'minhas_aprovacoes: ponto de troca não encontrado'; end if;
  execute n;
end $$;

-- 2) Aprovar na central: rascunho do administrador passa pelo mesmo caminho do botão do pedido
do $$ declare d text; n text; begin
  d := pg_get_functiondef('public.aprovacao_decidir(text,bigint[],boolean,text)'::regprocedure);
  if position('pc_pronto_para_mim' in d) > 0 then return; end if;   -- já aplicado
  n := replace(d,
    $x$      perform public.pedido_compra_acao(v_id, case when p_aprovar then 'aprovar' else 'recusar' end, v_mot, '{}'::jsonb);$x$,
    $x$      if public.pc_pronto_para_mim(v_id) then
        if not p_aprovar then raise exception 'Pedido em rascunho não se recusa: abra o pedido e cancele ou ajuste'; end if;
        perform public.pedido_compra_acao(v_id, 'enviar_aprovacao', null, '{}'::jsonb);
      else
        perform public.pedido_compra_acao(v_id, case when p_aprovar then 'aprovar' else 'recusar' end, v_mot, '{}'::jsonb);
      end if;$x$);
  if n = d then raise exception 'aprovacao_decidir: ponto de troca não encontrado'; end if;
  execute n;
end $$;
