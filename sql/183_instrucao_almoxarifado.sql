-- =====================================================================
-- 183 · Instrução para o almoxarifado no pedido de compra
--  · Campo novo no pedido: "Instrução para o almoxarifado" (onde deixar, para quem, cuidados).
--    Ex.: COMPRADO PELO PAULO · APÓS A CONFERÊNCIA, DEIXAR NA GARAGEM.
--  · Aparece em destaque no cartão do pedido na tela Recebimento e na lista impressa de conferência.
--    Não vai no PDF para o fornecedor. Pode ser alterado mesmo depois de aprovado.
--  · Para desfazer: apagar o texto do campo; a coluna nova não mexe em nada do que existe.
-- =====================================================================

alter table public.pedidos_compra add column if not exists instrucao_almox text;

do $$ declare d text; n text; begin
  d := pg_get_functiondef('public.pedido_compra_salvar(jsonb,jsonb)'::regprocedure);
  if position('instrucao_almox' in d) > 0 then return; end if;   -- já aplicado
  n := replace(d, 'whatsapp_fornecedor, observacoes, observacoes_internas)', 'whatsapp_fornecedor, observacoes, observacoes_internas, instrucao_almox)');
  n := replace(n, 'd.whatsapp_fornecedor, d.observacoes, d.observacoes_internas)', 'd.whatsapp_fornecedor, d.observacoes, d.observacoes_internas, nullif(upper(trim(d.instrucao_almox)), ''''))');
  n := replace(n, 'observacoes_internas = d.observacoes_internas, data_entrega_prevista = d.data_entrega_prevista',
                  'observacoes_internas = d.observacoes_internas, instrucao_almox = nullif(upper(trim(d.instrucao_almox)), ''''), data_entrega_prevista = d.data_entrega_prevista');
  n := replace(n, 'observacoes = d.observacoes, observacoes_internas = d.observacoes_internas' || chr(13),
                  'observacoes = d.observacoes, observacoes_internas = d.observacoes_internas, instrucao_almox = nullif(upper(trim(d.instrucao_almox)), '''')' || chr(13));
  if (length(n) - length(replace(n, 'instrucao_almox', ''))) / length('instrucao_almox') < 4 then
    raise exception 'pedido_compra_salvar: pontos de troca não encontrados';
  end if;
  execute n;
end $$;
