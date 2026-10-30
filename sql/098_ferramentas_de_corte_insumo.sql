-- =====================================================================
-- 098 · Ferramentas de corte viram Insumo; mesas de solda viram Dispositivo
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
