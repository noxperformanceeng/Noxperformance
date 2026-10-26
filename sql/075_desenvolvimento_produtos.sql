-- =====================================================================
-- 075 · Despesas de desenvolvimento de produtos (P&D) com linha própria no relatório de gestão
--  · Nova linha no relatório de gestão: "Despesas com desenvolvimento de produtos" (antes ia em
--    "Despesas administrativas").
--  · Grupo 6.09 Desenvolvimento de produtos ganha as categorias de dispositivos/gabaritos, protótipos e amostras,
--    moldes/matrizes de desenvolvimento — todas disponíveis no cadastro de produtos.
--  · "AQ. DISPOSITIVO - GABARITOS" sai de serviços de produção (custo) e vai para desenvolvimento (despesa).
-- =====================================================================
update public.categorias_financeiras set grupo_dre = 'Despesas com desenvolvimento de produtos'
 where codigo = '6.09' or codigo like '6.09.%';
update public.categorias_financeiras set aplica_produtos = true where codigo like '6.09.%' and aceita_lancamento;

-- Dispositivo/gabarito: muda de grupo (o código acompanha o grupo) e fica aprovado
update public.categorias_financeiras c set pai_id = g.id, codigo = public.categoria_proximo_codigo(g.id), tipo = 'despesa',
       grupo_dre = 'Despesas com desenvolvimento de produtos', aplica_produtos = true, natureza = 'variavel',
       aprovacao = 'aprovado', aprovacao_em = now(), aprovacao_motivo = null,
       descricao = coalesce(c.descricao, 'Dispositivos e gabaritos usados para desenvolver produtos novos (não é custo da peça vendida).')
  from public.categorias_financeiras g
 where g.codigo = '6.09' and c.nome = 'AQ. DISPOSITIVO - GABARITOS' and c.pai_id is distinct from g.id;

-- Categorias semelhantes (só cria se ainda não existir com o mesmo nome)
do $$ declare g bigint; x record; begin
  select id into g from public.categorias_financeiras where codigo = '6.09';
  for x in select * from (values ('DESENV. PROTÓTIPOS E AMOSTRAS', 'Peças, materiais e serviços para protótipos e amostras de produtos novos.'),
                                 ('DESENV. MOLDES, MATRIZES E FERRAMENTAL', 'Moldes, matrizes e ferramental feitos para um produto novo.'),
                                 ('DESENV. ENSAIOS E TESTES', 'Testes de bancada, dinamômetro, laboratório e validação de produto.')) v(nome, descr) loop
    if not exists (select 1 from public.categorias_financeiras c where upper(c.nome) = upper(x.nome)) then
      insert into public.categorias_financeiras (codigo, nome, pai_id, tipo, grupo_dre, natureza, aceita_lancamento, aplica_produtos, situacao, aprovacao, descricao)
      values (public.categoria_proximo_codigo(g), x.nome, g, 'despesa', 'Despesas com desenvolvimento de produtos', 'variavel', true, true, 'ativo', 'aprovado', x.descr);
    end if;
  end loop;
end $$;
