-- =====================================================================
-- 091 · Quem cadastra o quê (decisão do Paulo em 27/10/2026)
--  · Financeiro: cadastra e altera fornecedores e clientes.
--  · Almoxarifado (perfil Estoque / Almoxarifado): cadastra e altera produtos.
--  · Compras: passa a só consultar fornecedores (produtos já era só consulta). Continua cadastrando
--    serviços terceirizados e fazendo pedidos.
--  · Administradores (Paulo, Leila e Alexandre) continuam com acesso a tudo.
-- =====================================================================
insert into public.permissoes (perfil_id, modulo_id, nivel) values
  ('financeiro', 'fornecedores', 'editar'),
  ('financeiro', 'clientes',     'editar'),
  ('estoque',    'produtos',     'editar'),
  ('compras',    'fornecedores', 'ver')
on conflict (perfil_id, modulo_id) do update set nivel = excluded.nivel;

-- Ajuste individual antigo do usuário do financeiro (fornecedores "alterar") deixava o acesso abaixo do perfil
update public.permissoes_usuario pu set nivel = 'editar'
  from public.usuarios u
 where u.id = pu.usuario_id and u.perfil_id = 'financeiro' and pu.modulo_id = 'fornecedores' and pu.nivel <> 'nenhum';
