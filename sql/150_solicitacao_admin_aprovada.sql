-- =====================================================================
-- 150 · Solicitação de compra feita pela diretoria já nasce aprovada
--  · Pedido do Paulo (18/11/2026): quando quem faz a solicitação é administrador (Paulo, Leila…), ela já vai
--    como APROVADA, direto para a fila do comprador — ninguém precisa aprovar o que a própria diretoria pediu.
--  · Vale também quando o próprio administrador altera a solicitação dele (continua aprovada).
--  · Solicitação de qualquer outra pessoa segue igual: aguarda aprovação da diretoria.
--  · As solicitações de administradores que estão hoje aguardando aprovação passam para aprovadas.
-- =====================================================================

do $$
declare d text; n text;
begin
  d := replace(pg_get_functiondef('public.solicitacao_compra_salvar(jsonb, jsonb)'::regprocedure), E'\r\n', E'\n');
  if position('JÁ NASCE APROVADA' in d) = 0 then
    n := replace(d, '  return v_id;
end', '  -- administrador: a solicitação dele JÁ NASCE APROVADA (vai direto para o comprador)
  if public.eh_admin() then
    update public.solicitacoes_compra set situacao = ''aprovado'', motivo_recusa = null, decidido_por = auth.uid(), decidido_em = now()
     where id = v_id and solicitante_id = auth.uid() and situacao = ''em_aprovacao'';
  end if;
  return v_id;
end');
    if n = d then raise exception 'solicitacao_compra_salvar: trecho não encontrado'; end if;
    execute n;
  end if;
end $$;

-- as que já estão esperando e foram feitas por administrador
update public.solicitacoes_compra s set situacao = 'aprovado', motivo_recusa = null, decidido_por = s.solicitante_id, decidido_em = now()
  from public.usuarios u
 where u.id = s.solicitante_id and u.perfil_id = 'admin' and u.ativo and s.situacao = 'em_aprovacao';
