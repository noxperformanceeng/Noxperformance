-- =====================================================================
-- 068 · Excluir registro é só do master; os demais usuários inativam
--  · Cadastros principais (produtos, clientes, títulos, pedidos, colaboradores…) já não tinham exclusão.
--  · Agora também só o master exclui: fornecedores, arquivos/desenhos de produto, marcações de ponto,
--    fechamento de ponto (desfazer) e lançamentos manuais da folha.
--  · Continuam livres as linhas internas de um documento em edição (itens/tarifas do pedido, rateio,
--    vínculos produto × fornecedor) e as regerações automáticas da folha — tudo fica na auditoria.
--  · Política "restritiva": soma-se às que já existem, sem apagar nenhuma.
-- =====================================================================
do $$ declare t text; begin
  foreach t in array array['fornecedores','produto_arquivos','rh_marcacoes','rh_ponto_fechamentos'] loop
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'exclusao so master') then
      execute format('create policy "exclusao so master" on public.%I as restrictive for delete to authenticated using ((select public.eh_admin()))', t);
    end if;
  end loop;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'rh_lancamentos' and policyname = 'exclusao so master') then
    create policy "exclusao so master" on public.rh_lancamentos as restrictive for delete to authenticated
      using ((select public.eh_admin()) or origem <> 'lancamentos');
  end if;
end $$;
