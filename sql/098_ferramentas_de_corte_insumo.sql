-- =====================================================================
-- 098 · Ferramentas de corte e eletrodos viram Insumo; mesas de solda viram Dispositivo
--  · Brocas, machos e serras (copo e fita) se gastam e são recompradas sempre: passam para a origem
--    INSUMO, num grupo próprio "Ferramentas de corte", separado dos outros insumos (polimento, gases…).
--    As categorias financeiras de cada item não mudam.
--  · Ficam como FERRAMENTA só as de uso durável (chaves, vira-macho, retificadeira, curvador…).
--  · Mesas de solda giratórias passam para o grupo DISPOSITIVOS (usadas para fabricar várias peças).
-- =====================================================================
insert into public.produto_grupos (nome, tipo_produto, descricao)
select 'Ferramentas de corte', 'insumo', 'Ferramentas que se desgastam e são repostas: broca, macho, serra copo, serra fita'
 where not exists (select 1 from public.produto_grupos where nome = 'Ferramentas de corte');

update public.produtos set tipo = 'insumo', grupo = 'Ferramentas de corte'
 where tipo = 'ferramenta'
   and (descricao ~* '^broca' or descricao ~* '^macho (manual|maquina|máquina)' or descricao ~* 'serra (copo|fita)');

update public.produtos set grupo = 'Dispositivos'
 where tipo = 'ferramenta' and descricao ~* '^mesa de solda';

-- Eletrodos de solda (antigo F04, família de ferramentas) são consumidos: Insumo, grupo Consumíveis de
-- produção e código de insumo 4000740. O Tiny continua reconhecendo pelo SKU antigo (ref_tiny.sku_tiny = F04).
-- A pinça da tocha TIG continua Ferramenta (é peça da tocha).
update public.produtos set tipo = 'insumo', grupo = 'Consumíveis de produção', codigo = '4000740', descricao = 'ELETRODOS E-6013 GERDAU'
 where codigo = 'F04' and not exists (select 1 from public.produtos where codigo = '4000740');
