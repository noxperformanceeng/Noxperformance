-- ============================================================================
-- 056 · NX48 passa a ser o coxim da capa do motor Golf 1.4
--   O que muda: o cadastro antigo NX48 (LUVA MIOXI FLAUTA, inativo, sem vínculo nem movimento) é removido
--   (continua na cópia bkp_produtos_20261025) e o NX48 é cadastrado como COXIM CAPA MOTOR GOLF 1.4 - USINAGEM.
-- ============================================================================
delete from public.produtos
 where codigo = 'NX48' and descricao = 'LUVA MIOXI FLAUTA' and situacao = 'inativo'
   and not exists (select 1 from public.pedidos_venda_itens i where i.produto_id = produtos.id)
   and not exists (select 1 from public.pedidos_compra_itens i where i.produto_id = produtos.id)
   and not exists (select 1 from public.anuncios a where a.produto_id = produtos.id)
   and not exists (select 1 from public.produto_fornecedores f where f.produto_id = produtos.id);

insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, codigo_desenho, observacoes)
select 'NX48', 'COXIM CAPA MOTOR GOLF 1.4 - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 'NX48=COXIM CAPA MOTOR GOLF 1.4',
       'Material: PP PRETO · Matéria-prima: TARUGO Ø16mm X 30mm · O cadastro antigo NX48 (LUVA MIOXI FLAUTA, inativo, sem movimento) foi descadastrado em 25/10/2026'
 where not exists (select 1 from public.produtos where upper(codigo) = 'NX48');
