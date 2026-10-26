-- =====================================================================
-- 085 · Grupos de produtos enxutos (18 grupos de verdade)
--  · O grupo diz o que a peça é na fábrica; a categoria financeira continua dizendo para onde vai o custo.
--  · Os 111 grupos antigos (muitos vindos da 1ª palavra da descrição) foram unidos em 18.
--    Os antigos ficam inativos com a anotação "Unido ao grupo X" (nada é apagado).
--  · Produtos sem grupo recebem um quando a regra é clara (manutenção, abafador, ponteira, defletor,
--    intake, corte a laser, usinagem, EPI, ferramenta); o resto continua sem grupo para revisar.
--  · Cada grupo tem uma categoria padrão: ela preenche só os produtos comprados que estavam SEM categoria
--    (categoria já escolhida não muda) e vem preenchida no cadastro de produto novo.
-- =====================================================================
do $$
declare v record;
begin
  -- 1) Os 18 grupos, com tipo e categoria padrão
  for v in select * from (values
    ('Intake', 'acabado', null, 'Kits de intake vendidos'),
    ('Defletor', 'acabado', null, 'Conjuntos de defletor (DF)'),
    ('Ponteira', 'acabado', null, 'Ponteiras de escapamento'),
    ('Abafador', 'acabado', null, 'Abafadores (ABF, NXI, NXC)'),
    ('Pressurização e acessórios', 'acabado', null, 'Pressurização, inlet, difusor, downpipe, tubo d''água, portinhola e outros acessórios vendidos'),
    ('Corte a laser', 'semiacabado', '3.05.001', 'Peças de chapa cortadas e dobradas por terceiros (família 200)'),
    ('Usinagem', 'semiacabado', '3.05.005', 'Peças usinadas por terceiros (família NX)'),
    ('Tubos, curvas e conexões', 'materia_prima', '3.01.011', 'Tubos, curvas, reduções e flexíveis'),
    ('Barras e maciços', 'materia_prima', '3.01.008', 'Barras chatas e maciços (inox, alumínio, aço, nylon)'),
    ('Pré-moldados, perfurados e mantas', 'materia_prima', '3.01.009', 'Matéria-prima de abafador'),
    ('Componentes de montagem', 'componente', '3.02.006', 'Peças compradas prontas que entram nos kits e defletores (abraçadeira, filtro, anel, mangueira, válvula, borracha…)'),
    ('Fixadores', 'materia_prima', '3.02.016', 'Parafusos, porcas, arruelas e rebites'),
    ('Embalagem', 'materia_prima', '3.03.003', 'Caixas, fitas, sacos, plástico, etiquetas e papel'),
    ('Consumíveis de produção', 'materia_prima', '3.04.013', 'Lixas, discos, gases, solda, polimento, tintas, fluidos e materiais de consumo'),
    ('EPI e uniformes', 'materia_prima', '3.07.005', 'Equipamentos de proteção e uniformes'),
    ('Ferramentas', 'ferramenta', '3.04.003', 'Ferramentas e dispositivos'),
    ('Manutenção', 'despesa', '6.03.007', 'Peças e materiais de manutenção de máquinas e do galpão'),
    ('Escritório e limpeza', 'despesa', '6.06.003', 'Material de escritório, copa e limpeza')
  ) x(nome, tipo, cat, descr) loop
    if exists (select 1 from public.produto_grupos where upper(nome) = upper(v.nome)) then
      update public.produto_grupos set tipo_produto = v.tipo, descricao = v.descr, situacao = 'ativo',
             categoria_financeira_id = coalesce((select id from public.categorias_financeiras where codigo = v.cat), categoria_financeira_id)
       where upper(nome) = upper(v.nome);
    else
      insert into public.produto_grupos (nome, tipo_produto, categoria_financeira_id, descricao)
      values (v.nome, v.tipo, (select id from public.categorias_financeiras where codigo = v.cat), v.descr);
    end if;
  end loop;

  -- 2) Grupos antigos → grupo novo
  for v in select * from (values
    ('Pressurização','Pressurização e acessórios'), ('Inlet','Pressurização e acessórios'), ('Difusor','Pressurização e acessórios'),
    ('Downpipe','Pressurização e acessórios'), ('Tubo d''água','Pressurização e acessórios'), ('Portinhola','Pressurização e acessórios'),
    ('Tubo','Tubos, curvas e conexões'), ('Curva','Tubos, curvas e conexões'), ('Redução','Tubos, curvas e conexões'),
    ('Flexivel','Tubos, curvas e conexões'), ('Aço','Tubos, curvas e conexões'), ('Malha','Tubos, curvas e conexões'),
    ('Maciço','Barras e maciços'), ('Barra','Barras e maciços'),
    ('Pré-moldado','Pré-moldados, perfurados e mantas'), ('Perfurado','Pré-moldados, perfurados e mantas'), ('Manta','Pré-moldados, perfurados e mantas'),
    ('Abraçadeira','Componentes de montagem'), ('Filtro','Componentes de montagem'), ('Anel','Componentes de montagem'),
    ('Mangueira','Componentes de montagem'), ('Valvula','Componentes de montagem'), ('Coxim','Componentes de montagem'),
    ('Adaptador','Componentes de montagem'), ('Adesivo','Componentes de montagem'), ('Adesivos','Componentes de montagem'),
    ('Borracha','Componentes de montagem'), ('Conector','Componentes de montagem'), ('Debrum','Componentes de montagem'),
    ('Espigão','Componentes de montagem'), ('Niple','Componentes de montagem'), ('Passa','Componentes de montagem'),
    ('PASSA FIO','Componentes de montagem'), ('Pinos','Componentes de montagem'), ('Pino','Componentes de montagem'),
    ('Respiro','Componentes de montagem'), ('Tampão','Componentes de montagem'), ('Trafilado','Componentes de montagem'),
    ('COMPONENTES PARA KITS','Componentes de montagem'), ('Mangote','Componentes de montagem'), ('Capa','Componentes de montagem'),
    ('Suporte','Componentes de montagem'), ('Inbox','Componentes de montagem'), ('Fdrs65120l','Componentes de montagem'),
    ('Fdrs65150l','Componentes de montagem'), ('Fdrs75120l','Componentes de montagem'), ('Abip141627','Componentes de montagem'),
    ('Abit146382','Componentes de montagem'), ('Bmw','Componentes de montagem'), ('Wolk','Componentes de montagem'),
    ('Turob','Componentes de montagem'), ('Cartucho','Componentes de montagem'), ('Registro','Componentes de montagem'),
    ('Medidor','Componentes de montagem'), ('Redutor','Componentes de montagem'), ('Tela','Componentes de montagem'),
    ('Folego','Componentes de montagem'), ('Abr','Componentes de montagem'), ('Tudo','Componentes de montagem'),
    ('Parafuso','Fixadores'), ('Arruela','Fixadores'), ('Porca','Fixadores'), ('Rebite','Fixadores'),
    ('Fita','Embalagem'), ('Saco','Embalagem'), ('Sacos','Embalagem'), ('Plastico','Embalagem'), ('Etiqueta','Embalagem'), ('Papel','Embalagem'),
    ('Mini','Consumíveis de produção'), ('Cinta','Consumíveis de produção'), ('Lixa','Consumíveis de produção'),
    ('Disco','Consumíveis de produção'), ('Roda','Consumíveis de produção'), ('Argonio','Consumíveis de produção'),
    ('Nitrogênio','Consumíveis de produção'), ('Mistura','Consumíveis de produção'), ('Cola','Consumíveis de produção'),
    ('Massa','Consumíveis de produção'), ('Sebo','Consumíveis de produção'), ('Thinner','Consumíveis de produção'),
    ('Tinta','Consumíveis de produção'), ('Tungstênio','Consumíveis de produção'), ('Vareta','Consumíveis de produção'),
    ('Bocal','Consumíveis de produção'), ('Rolo','Consumíveis de produção'), ('Fluido','Consumíveis de produção'),
    ('Oleo','Consumíveis de produção'), ('Gel','Consumíveis de produção'), ('Desengraxante','Consumíveis de produção'),
    ('Desengripante','Consumíveis de produção'), ('Aditivo','Consumíveis de produção'), ('Agua','Consumíveis de produção'),
    ('Pano','Consumíveis de produção'), ('Frasco','Consumíveis de produção'), ('Lamina','Consumíveis de produção'),
    ('Pedra','Consumíveis de produção'), ('Pincel','Consumíveis de produção'), ('Ponta','Consumíveis de produção'),
    ('Pinça','Consumíveis de produção'),
    ('Correia','Manutenção'), ('Rolamento','Manutenção'),
    ('Prancheta','Escritório e limpeza'),
    ('Pintura', null)
  ) x(antigo, novo) loop
    if v.novo is not null then
      update public.produtos set grupo = v.novo where upper(grupo) = upper(v.antigo);
    end if;
    update public.produto_grupos set situacao = 'inativo',
           descricao = coalesce('Unido ao grupo ' || v.novo, 'Pintura é serviço (sem SKU)') || ' em 26/10/2026'
     where upper(nome) = upper(v.antigo) and situacao = 'ativo';
  end loop;
end $$;

-- 3) Produtos ativos sem grupo: regra clara pela descrição/código
update public.produtos p set grupo = r.grupo
  from (select id, case
      when upper(descricao) like 'MANUTEN%' then 'Manutenção'
      when upper(descricao) like 'EPI%' or upper(descricao) like 'UNIFORME%' then 'EPI e uniformes'
      when upper(descricao) like 'ABAFADOR%' then 'Abafador'
      when upper(descricao) like 'PONTEIRA%' then 'Ponteira'
      when codigo ~ '^DF-' then 'Defletor'
      when upper(descricao) like 'INTAKE%' then 'Intake'
      when upper(descricao) like '%CORTE A LASER%' then 'Corte a laser'
      when upper(descricao) like '%USINAGEM%' then 'Usinagem'
      when upper(descricao) like 'TUBO DAGUA%' or upper(descricao) like 'TUBO D''AGUA%' or upper(descricao) like 'PRESSURIZA%'
        or upper(descricao) like 'DOWNPIPE%' or upper(descricao) like 'INLET%' then 'Pressurização e acessórios'
      when tipo = 'ferramenta' then 'Ferramentas'
      when tipo = 'componente' then 'Componentes de montagem' end grupo
    from public.produtos where situacao = 'ativo' and coalesce(trim(grupo), '') = '') r
 where p.id = r.id and r.grupo is not null;

-- 4) Categoria padrão do grupo só onde o produto comprado está sem categoria
update public.produtos p set categoria_financeira_id = g.categoria_financeira_id
  from public.produto_grupos g
 where g.nome = p.grupo and g.categoria_financeira_id is not null and p.categoria_financeira_id is null
   and p.tipo not in ('acabado', 'kit');
