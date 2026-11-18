-- =====================================================================
-- 142 · Solicitação de compra enxerga os serviços terceirizados
--  · Quem pede compra (ex.: almoxarifado) não via nenhum serviço na lista "Serviço" da Solicitação de compra:
--    a leitura dos serviços estava liberada só para Compras, Contas a pagar e Notas fiscais.
--  · Passa a ler também quem tem a tela Solicitações de compra. Só leitura (nome, unidade): cadastrar e alterar
--    serviço continua só com Compras.
-- =====================================================================

alter policy "ver servicos" on public.servicos
  using ((select public.pode('compras')) or (select public.pode('pagar')) or (select public.pode('notas'))
         or (select public.pode('solicitacoes_compra')));
