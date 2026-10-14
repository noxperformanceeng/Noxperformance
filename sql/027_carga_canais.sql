-- =====================================================================
-- ERP NOX · 027_carga_canais.sql
-- Carga inicial: canais de venda e tipos de encargo → categoria (plano já existente).
-- Tudo editável nas telas. Links e palavras do extrato serão calibrados com os arquivos reais.
-- Pode rodar mais de uma vez (não sobrescreve o que já foi editado).
-- =====================================================================
insert into public.canais_venda (nome, plataforma, empresa_id, conta_bancaria_id, link_pedido, prazo_repasse_dias, categoria_receita_id, integracao, observacoes)
select v.nome, v.plat, v.emp, (select id from public.contas_bancarias where descricao = v.conta and empresa_id = v.emp),
       v.link, v.prazo, (select id from public.categorias_financeiras where codigo = v.cat), v.integ, v.obs
from (values
  ('Mercado Livre 30', 'mercado_livre', 2, 'Mercado Pago 31', 'https://www.mercadolivre.com.br/vendas/{pedido}/detalhe', 0, '1.01.001', 'planilha', 'Conta ML do CNPJ 30. Repasse no Mercado Pago 31.'),
  ('Mercado Livre 37', 'mercado_livre', 1, 'Mercado Pago 37', 'https://www.mercadolivre.com.br/vendas/{pedido}/detalhe', 0, '1.01.001', 'planilha', 'Conta ML do CNPJ 37. Repasse no Mercado Pago 37.'),
  ('Shopee', 'shopee', 2, null, null, 0, '1.01.001', 'planilha', 'Confirmar empresa e conta de repasse da Shopee.'),
  ('Distribuidores', 'distribuidor', null, null, null, 0, '1.01.002', 'manual', 'Pedidos digitados pelo atendimento de distribuidores.'),
  ('Venda direta', 'direta', null, null, null, 0, '1.01.002', 'manual', null)
) v(nome, plat, emp, conta, link, prazo, cat, integ, obs)
on conflict ((upper(nome))) do nothing;

insert into public.encargos_tipos (plataforma, codigo, nome, categoria_financeira_id, termos_extrato)
select v.plat, v.cod, v.nome, (select id from public.categorias_financeiras where codigo = v.cat), v.termos
from (values
  ('mercado_livre', 'tarifa_venda',      'Tarifa de venda',                 '2.02.006', '{tarifa de venda,tarifa por venda}'::text[]),
  ('mercado_livre', 'parcelamento',      'Taxa de parcelamento',            '2.02.008', '{parcelamento,financiamento}'),
  ('mercado_livre', 'loja_oficial',      'Taxa de loja oficial',            '2.02.007', '{loja oficial}'),
  ('mercado_livre', 'envio',             'Tarifa de envio (Mercado Envios)', '4.01.002', '{tarifa de envio,envio}'),
  ('mercado_livre', 'envio_full',        'Tarifa de envio Full',            '4.01.001', '{full}'),
  ('mercado_livre', 'ads',               'Publicidade (Mercado Ads)',       '4.02.003', '{publicidade,mercado ads,product ads}'),
  ('mercado_livre', 'frete_cliente',     'Frete pago pelo comprador',       '4.01.003', '{}'),
  ('mercado_livre', 'diferenca_debito',  'Diferença a menor no repasse',    '2.02.006', '{}'),
  ('mercado_livre', 'diferenca_credito', 'Diferença a maior / reembolso',   '1.02.001', '{reembolso,bonificação}'),
  ('shopee', 'comissao',          'Comissão Shopee',                '2.02.002', '{comissão,comissao}'),
  ('shopee', 'servico',           'Taxa de serviço Shopee',         '2.02.003', '{taxa de serviço,taxa de servico}'),
  ('shopee', 'processamento',     'Processamento de pagamento',     '2.02.004', '{transação,transacao,processamento}'),
  ('shopee', 'ads',               'Publicidade Shopee',             '4.02.004', '{anúncios,anuncios,ads}'),
  ('shopee', 'frete_cliente',     'Frete pago pelo comprador',      '4.01.003', '{}'),
  ('shopee', 'diferenca_debito',  'Diferença a menor no repasse',   '2.02.002', '{}'),
  ('shopee', 'diferenca_credito', 'Diferença a maior / reembolso',  '1.02.001', '{}'),
  ('geral', 'estorno',            'Estorno / devolução de venda',   '2.03.001', '{estorno,devolução,devolucao,mediação,mediacao,reclamação}'),
  ('geral', 'frete_nox',          'Frete por conta da NOX',         '4.01.004', '{}'),
  ('geral', 'diferenca_debito',   'Diferença a menor no recebimento', '2.03.001', '{}'),
  ('geral', 'diferenca_credito',  'Diferença a maior no recebimento', '1.02.003', '{}')
) v(plat, cod, nome, cat, termos)
on conflict (plataforma, codigo) do nothing;
