-- =====================================================================
-- ERP NOX · 023_folha_producao_adm.sql
-- Folha separada em PRODUÇÃO (custo do produto, entra na precificação) x ADMINISTRATIVO (despesa fixa).
--  - Novo subgrupo 3.07 "Mão de obra de produção" (Custo dos produtos vendidos)
--  - Grupo 5 passa a ser "Despesas com pessoal administrativo"; as categorias do Tiny continuam lá
--  - FREELANCER PRODUÇÃO (Tiny) muda de 5.05.002 para 3.07.007 (mantém o ID do Tiny)
--  - Funcionário ganha "Área de custo" (produção / administrativo / comercial): o lançamento da folha
--    de cada pessoa vai para a categoria certa, e a precificação usa só a mão de obra de produção.
-- Pode rodar mais de uma vez.
-- =====================================================================

-- 1) Linha nova no relatório de gestão para a mão de obra de produção
insert into public.categorias_financeiras (codigo, nome, tipo, grupo_dre, natureza, aceita_lancamento, aplica_produtos, situacao, pai_id, descricao)
select '3.07', 'Mão de obra de produção', 'custo', 'Custo dos produtos vendidos', 'fixa', false, false, 'ativo',
       (select id from public.categorias_financeiras where codigo = '3'),
       'Pessoas da produção (área de custo = produção no cadastro do funcionário). Base do custo de mão de obra na precificação.'
on conflict (codigo) do nothing;

insert into public.categorias_financeiras (codigo, nome, tipo, grupo_dre, natureza, aceita_lancamento, aplica_produtos, situacao, pai_id)
select v.codigo, v.nome, 'custo', 'Custo dos produtos vendidos', 'fixa', true, false, 'ativo', (select id from public.categorias_financeiras where codigo = '3.07')
from (values ('3.07.001','SALÁRIOS - PRODUÇÃO'), ('3.07.002','ENCARGOS INSS E FGTS - PRODUÇÃO'), ('3.07.003','13º E FÉRIAS - PRODUÇÃO'),
             ('3.07.004','BENEFÍCIOS (CESTA, VALE TRANSPORTE) - PRODUÇÃO'), ('3.07.005','EPI E UNIFORMES - PRODUÇÃO'),
             ('3.07.006','RESCISÕES - PRODUÇÃO')) v(codigo, nome)
on conflict (codigo) do nothing;

-- 2) Freelancer de produção vai para o custo (mantém o ID do Tiny)
update public.categorias_financeiras
   set codigo = '3.07.007', pai_id = (select id from public.categorias_financeiras where codigo = '3.07'),
       tipo = 'custo', grupo_dre = 'Custo dos produtos vendidos', natureza = 'variavel', descricao = null
 where codigo = '5.05.002' and not exists (select 1 from public.categorias_financeiras where codigo = '3.07.007');

-- 3) Grupo 5 = pessoal administrativo
update public.categorias_financeiras set nome = 'DESPESAS COM PESSOAL ADMINISTRATIVO',
       descricao = 'Pessoas do administrativo (área de custo = administrativo no cadastro do funcionário). Despesa fixa, rateada na precificação.'
 where codigo = '5' and nome = 'DESPESAS COM PESSOAL';
update public.categorias_financeiras set grupo_dre = 'Despesas com pessoal administrativo'
 where grupo_dre = 'Despesas com pessoal';

-- 4) Funcionário: área de custo
alter table public.funcionarios add column if not exists area_custo text;
do $$ begin
  alter table public.funcionarios add constraint funcionarios_area_custo check (area_custo in ('producao','administrativo','comercial'));
exception when duplicate_object then null; end $$;
