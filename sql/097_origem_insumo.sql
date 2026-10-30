-- =====================================================================
-- 097 · Origens do produto mais simples + Insumo, Dispositivo e Gabarito
--  · Nova origem de produto: INSUMO — material consumido na produção que não vira parte da peça
--    (massa e rodas de polimento, discos de corte e lixa, gases como argônio e nitrogênio, solda…).
--  · Os produtos do grupo "Consumíveis de produção" passam para Insumo (o grupo também).
--  · O código automático do insumo segue a família 4 (4000xxx), como os demais itens comprados.
--  · Ferramentas ganham dois grupos: DISPOSITIVOS (servem para fabricar várias peças) e GABARITOS (feitos
--    para uma peça só). Ferramentas sem grupo vão para "Ferramentas". Todas seguem o código F.
-- =====================================================================
alter table public.produtos drop constraint if exists produtos_tipo_check;
alter table public.produtos add constraint produtos_tipo_check
  check (tipo in ('materia_prima', 'componente', 'insumo', 'semiacabado', 'acabado', 'kit', 'ferramenta', 'despesa'));
alter table public.produto_grupos drop constraint if exists produto_grupos_tipo_produto_check;
alter table public.produto_grupos add constraint produto_grupos_tipo_produto_check
  check (tipo_produto in ('materia_prima', 'componente', 'insumo', 'semiacabado', 'acabado', 'kit', 'ferramenta', 'despesa'));

update public.produto_grupos set tipo_produto = 'insumo' where nome = 'Consumíveis de produção';
update public.produtos set tipo = 'insumo' where grupo = 'Consumíveis de produção' and tipo in ('materia_prima', 'componente');

-- código automático: insumo = família 4
do $$
declare v text;
begin
  v := pg_get_functiondef('public.produtos_proximo_codigo(text)'::regprocedure);
  if position('''insumo''' in v) = 0 then
    v := replace(v, 'when ''componente'' then ''4''', 'when ''componente'' then ''4'' when ''insumo'' then ''4''');
    execute v;
  end if;
end $$;

-- grupos de ferramentas
insert into public.produto_grupos (nome, tipo_produto, descricao)
select v.nome, 'ferramenta', v.descr
  from (values ('Dispositivos', 'Dispositivo usado para fabricar várias peças'),
               ('Gabaritos', 'Gabarito feito para fabricar uma peça específica')) v(nome, descr)
 where not exists (select 1 from public.produto_grupos g where g.nome = v.nome);
update public.produtos set grupo = 'Ferramentas' where tipo = 'ferramenta' and grupo is null;
