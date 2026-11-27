-- =====================================================================
-- 192 · Pedidos de venda: valor das vendas só para quem pode ver
--  · A tela Pedidos de venda (que mostra o valor de cada venda) sai dos perfis Comercial, Expedição,
--    Estoque / Almoxarifado, Produção (líder) e Pós-venda. Continua com administradores e Financeiro.
--  · Kleyton (vendas) continua com a tela, liberada só para ele: vê o valor de cada venda, mas não a soma do
--    período (o rodapé com os totais da lista só aparece para quem tem "Ver valores da empresa").
--  · Quem perde a tela continua vendo os pedidos SEM valores na tela de Separação/Expedição (o Pós-venda ganha
--    essa tela só para consulta). Avisos de venda nova, expedição e estoque não mudam (usam a Separação).
--  · Nada é apagado além das permissões; dá para desfazer liberando a tela de novo.
-- =====================================================================

-- Kleyton: Pedidos de venda liberado só para ele (antes vinha do perfil Comercial)
insert into public.permissoes_usuario (usuario_id, modulo_id, nivel)
select id, 'pedidos', 'editar' from public.usuarios where perfil_id = 'comercial' and upper(nome) like 'KLEYTON%'
on conflict (usuario_id, modulo_id) do update set nivel = 'editar';

-- Pós-venda: consulta dos pedidos pela Separação (sem valores)
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('pos_venda', 'separacao', 'ver')
on conflict do nothing;

-- Perfis sem a tela Pedidos de venda
delete from public.permissoes
 where modulo_id = 'pedidos' and perfil_id in ('comercial', 'expedicao', 'estoque', 'producao_lider', 'pos_venda');
