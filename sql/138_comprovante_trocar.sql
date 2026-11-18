-- =====================================================================
-- 138 · Comprovante divergente: o financeiro troca o comprovante errado
--  · Em Contas a pagar, o comprovante que não bateu fica marcado em vermelho no título
--    (com o que não bateu) e há o filtro "Comprovante divergente".
--  · "Trocar comprovante": o financeiro anexa o certo, o sistema confere de novo e o antigo
--    sai das pendências do master (fica guardado no título, marcado como substituído, e vai ao histórico).
--  · Se o novo também não bater, ele mesmo vai para o master, com a justificativa, como hoje.
--  · Só muda uma função nova; nada é apagado. Desfazer: basta não usar o botão.
-- =====================================================================
create or replace function public.comprovante_trocar(p_antigo bigint, p_novo bigint)
returns boolean language plpgsql security definer set search_path = public as $$
declare a record; n record;
begin
  if not (select public.pode('pagar', 'criar')) then raise exception 'Sem permissão para trocar comprovante'; end if;
  select x.*, t.documento, t.valor tvalor, f.nome forn into a from public.titulos_anexos x
    join public.titulos_pagar t on t.id = x.titulo_id left join public.fornecedores f on f.id = t.fornecedor_id
   where x.id = p_antigo and x.tipo = 'pagar' and x.categoria = 'comprovante' and x.ciente_em is null
     and (x.conferencia->>'ok')::boolean is false;
  if a.id is null then raise exception 'Este comprovante não está pendente de divergência'; end if;
  select * into n from public.titulos_anexos
   where id = p_novo and tipo = 'pagar' and titulo_id = a.titulo_id and categoria = 'comprovante'
     and criado_por = auth.uid() and criado_em > now() - interval '1 hour' and conferencia is not null;
  if n.id is null then raise exception 'O comprovante novo não foi encontrado neste título'; end if;
  update public.titulos_anexos
     set ciente_por = auth.uid(), ciente_em = now(),
         conferencia = conferencia || jsonb_build_object('substituido_por', p_novo, 'substituido_em', now())
   where id = p_antigo;
  insert into public.aprovacoes_historico (tipo, registro_id, texto, valor, decisao, motivo, criado_por_registro)
  values ('comprovante', a.titulo_id, 'TROCADO · ' || coalesce(a.documento, '#' || a.titulo_id) || ' · ' || coalesce(a.forn, ''), a.tvalor, 'aprovado',
          'COMPROVANTE TROCADO PELO FINANCEIRO · ' || case when (n.conferencia->>'ok')::boolean then 'O NOVO CONFERE' else 'O NOVO TAMBÉM DIVERGE: ' || upper(coalesce(n.conferencia->>'justificativa', '')) end,
          a.criado_por);
  return true;
end $$;
revoke execute on function public.comprovante_trocar(bigint, bigint) from public, anon;
grant execute on function public.comprovante_trocar(bigint, bigint) to authenticated;
