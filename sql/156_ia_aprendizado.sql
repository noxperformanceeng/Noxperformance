-- =====================================================================
-- 156 · Aprendizado da IA nas perguntas do Mercado Livre
--  · Cada pergunta passa a ter o ASSUNTO (compatibilidade, prazo e envio, frete, garantia, preço/desconto,
--    medida e material, instalação, estoque, outro), marcado pela IA quando ela escreve a sugestão.
--  · Com o assunto, a tela Perguntas do Mercado Livre ganha a aba "Aprendizado da IA": por semana e por
--    assunto, quantas sugestões foram enviadas sem mudança, com pequeno ajuste ou reescritas, e quais assuntos
--    já estão no ponto de a IA responder sozinha (nada é ligado sozinho: isso é decisão do Paulo, depois).
--  · A IA passa a dar mais peso, como exemplo, às respostas que os vendedores CORRIGIRAM (é onde ela aprende).
--  · Só uma coluna nova; nada existente muda. Para desfazer: a coluna pode ficar vazia sem efeito.
-- =====================================================================

alter table public.ml_perguntas add column if not exists assunto text;
create index if not exists ml_perguntas_assunto_idx on public.ml_perguntas (assunto) where assunto is not null;
