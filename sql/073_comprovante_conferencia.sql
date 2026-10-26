-- =====================================================================
-- 073 · Comprovante obrigatório na baixa do contas a pagar, com leitura automática
--  · A tela lê o comprovante (PDF ou foto) e confere fornecedor (nome ou CNPJ), valor e data do pagamento.
--  · O resultado da conferência fica guardado no anexo; divergência só passa com justificativa,
--    que também fica registrada no pagamento.
-- =====================================================================
alter table public.titulos_anexos add column if not exists conferencia jsonb;
