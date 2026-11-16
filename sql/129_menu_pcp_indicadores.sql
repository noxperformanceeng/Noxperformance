-- =====================================================================
-- 129 · Menu: tela PCP na Produção e novo grupo Indicadores
--  · Cria as telas no cadastro de permissões (ainda "em breve" no menu, sem conteúdo):
--    - PCP (planejamento e controle da produção), no grupo Produção;
--    - Indicadores: Financeiro, Produção e Marketing (dados da empresa toda), num grupo novo.
--  · Ninguém ganha acesso novo: só o Administrador vê (ele vê tudo). Os outros perfis
--    recebem acesso pela tela Usuários e acessos quando as telas ficarem prontas.
--  · Não mexe em nenhuma tabela nem dado existente.
-- =====================================================================

insert into public.modulos (id, grupo, nome, ordem) values
  ('pcp',            'producao',    'PCP',                       40),
  ('ind_financeiro', 'indicadores', 'Indicadores financeiros',   91),
  ('ind_producao',   'indicadores', 'Indicadores de produção',   92),
  ('ind_marketing',  'indicadores', 'Indicadores de marketing',  93)
on conflict (id) do nothing;
