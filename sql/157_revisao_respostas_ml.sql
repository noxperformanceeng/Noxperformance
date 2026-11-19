-- =====================================================================
-- 157 · Revisão das respostas do Mercado Livre pelo Paulo (o que a IA aprende)
--  · Na aba "Aprendizado da IA", cada caso em que o vendedor mudou a sugestão da IA pode ser revisado por um
--    administrador (Paulo, Leila): "Vendedor certo", "IA estava certa" ou "Os dois errados" (com a resposta
--    certa escrita ali). Só a revisão decide o que vira exemplo forte para a IA — correção sem revisão não
--    ganha peso, porque o vendedor também pode errar.
--  · As respostas até maio/2026 (quando era o Paulo quem respondia) são a referência principal da IA.
--  · "IA estava certa" conta como acerto da IA no painel; resposta marcada errada sai dos exemplos.
--  · Colunas novas na tabela de perguntas e uma função que só administrador usa. Nada existente muda.
-- =====================================================================

alter table public.ml_perguntas add column if not exists revisao text check (revisao in ('vendedor', 'ia', 'nenhum'));
alter table public.ml_perguntas add column if not exists revisao_texto text;   -- resposta certa (quando os dois erraram)
alter table public.ml_perguntas add column if not exists revisado_por uuid references public.usuarios(id);
alter table public.ml_perguntas add column if not exists revisado_em timestamptz;

create or replace function public.ml_pergunta_revisar(p_id bigint, p_revisao text, p_texto text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'Só administrador revisa as respostas'; end if;
  if p_revisao is not null and p_revisao not in ('vendedor', 'ia', 'nenhum') then raise exception 'Revisão inválida'; end if;
  if p_revisao = 'nenhum' and nullif(btrim(coalesce(p_texto, '')), '') is null then raise exception 'Escreva a resposta certa'; end if;
  update public.ml_perguntas
     set revisao = p_revisao, revisao_texto = case when p_revisao = 'nenhum' then left(btrim(p_texto), 2000) end,
         revisado_por = case when p_revisao is null then null else auth.uid() end,
         revisado_em = case when p_revisao is null then null else now() end, atualizado_em = now()
   where id = p_id and resposta is not null;
  if not found then raise exception 'Pergunta não encontrada ou ainda sem resposta'; end if;
end $$;
revoke execute on function public.ml_pergunta_revisar(bigint, text, text) from public, anon;
grant execute on function public.ml_pergunta_revisar(bigint, text, text) to authenticated;
