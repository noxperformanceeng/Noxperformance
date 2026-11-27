-- =====================================================================
-- 191 · Dashboard: valores da empresa só para quem pode ver
--  · Ação sensível nova "Ver valores da empresa" (Usuários e acessos › Editar › Ações sensíveis): sem ela, o
--    Dashboard não mostra vendas do mês em R$, contas a pagar, contas a receber nem entradas e saídas do caixa.
--    Os cartões de quantidade (pedidos para expedir, prazo estourado etc.) continuam para todos.
--  · Quem vê: administradores (Paulo e Leila) e a Danielle (financeiro). Mais alguém só se o administrador liberar.
--  · A trava é no banco (função painel_gestor), não só na tela. Nada é apagado; dá para desfazer liberando a ação.
-- =====================================================================

insert into public.acoes (id, modulo_id, nome, descricao, ordem) values
  ('empresa.valores', 'ind_financeiro', 'Ver valores da empresa',
   'Faturamento do mês, contas a pagar e a receber e caixa no Dashboard. Sem isto, esses valores não aparecem.', 1)
on conflict (id) do nothing;

-- Danielle (financeiro) vê; o restante do perfil Financeiro não
insert into public.usuario_acoes (usuario_id, acao_id, permitido)
select id, 'empresa.valores', true from public.usuarios where upper(nome) = 'DANIELLE' and perfil_id = 'financeiro'
on conflict do nothing;

-- painel_gestor: os blocos com R$ passam a exigir a ação (troca só as condições, o resto da função fica igual)
do $$
declare d text := pg_get_functiondef('public.painel_gestor(integer)'::regprocedure); n text;
begin
  if position('pode_acao(''empresa.valores'')' in d) > 0 then return; end if;   -- já aplicado
  n := replace(d, E'if public.pode(''pedidos'') then\n    r := r || jsonb_build_object(''vendas''',
                  E'if public.pode(''pedidos'') and public.pode_acao(''empresa.valores'') then\n    r := r || jsonb_build_object(''vendas''');
  n := replace(n, E'if public.pode(''receber'') then', E'if public.pode(''receber'') and public.pode_acao(''empresa.valores'') then');
  n := replace(n, E'if public.pode(''pagar'') then', E'if public.pode(''pagar'') and public.pode_acao(''empresa.valores'') then');
  n := replace(n, E'if public.pode(''fluxo'') or (public.pode(''pagar'') and public.pode(''receber'')) then',
                  E'if public.pode_acao(''empresa.valores'') and (public.pode(''fluxo'') or (public.pode(''pagar'') and public.pode(''receber''))) then');
  if (length(n) - length(replace(n, 'pode_acao(''empresa.valores'')', ''))) / length('pode_acao(''empresa.valores'')') <> 4 then
    raise exception 'painel_gestor mudou: as 4 condições não foram encontradas, nada aplicado';
  end if;
  execute n;
end $$;
