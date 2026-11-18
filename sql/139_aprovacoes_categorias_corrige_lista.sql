-- =====================================================================
-- 139 · Aprovações pendentes: grupo "Categorias financeiras novas" mostrava os comprovantes
--  · Desde o 077, a lista de comprovantes divergentes era montada antes de o grupo de categorias
--    ser gravado, e o grupo de categorias saía com os comprovantes no lugar das categorias.
--  · Agora cada grupo mostra só o que é dele: as categorias pendentes de verdade voltam a aparecer
--    e os comprovantes ficam só em "Pagamentos com comprovante divergente".
--  · Não muda dados; só a ordem dentro da função minhas_aprovacoes. Rodar de novo não faz nada.
-- =====================================================================
do $$
declare d text;
  cat text := $x$    v := v || jsonb_build_object('tipo', 'categoria_nova', 'area', 'Cadastros', 'titulo', 'Categorias financeiras novas para aprovar', 'itens', v_itens, 'aprovar_aqui', true);$x$;
  ancora text := $x$where c.aprovacao = 'pendente';$x$;
begin
  d := pg_get_functiondef('public.minhas_aprovacoes()'::regprocedure);
  if position(ancora || E'\n' || cat in d) > 0 then return; end if;   -- já corrigido
  if position(cat in d) = 0 or position(ancora in d) = 0 then raise exception 'minhas_aprovacoes mudou: revisar 139'; end if;
  d := replace(d, E'\n' || cat, '');
  d := replace(d, ancora, ancora || E'\n' || cat);
  if position(ancora || E'\n' || cat in d) = 0 then raise exception 'Correção não aplicada: revisar 139'; end if;
  execute d;
end $$;
