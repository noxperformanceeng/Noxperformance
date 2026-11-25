-- =====================================================================
-- 169 · Cotação: incluir fornecedor novo só com o nome (prospecção)
--  · Pedido do Paulo (25/11/2026): para prospectar, o comprador não precisa ter o fornecedor cadastrado.
--    Na cotação, em "+ Fornecedor", ele digita o nome; se não existir, inclui ali mesmo só com nome,
--    contato, WhatsApp e e-mail (o resto do cadastro — CNPJ, endereço — fica para depois).
--  · O cadastro rápido nasce ativo e com a observação "cadastro rápido · completar CNPJ e endereço".
--  · Quem pode alterar cotações (comprador) usa, mesmo sem permissão de criar na tela de Fornecedores.
--  · Não deixa criar fornecedor com nome igual a um que já existe (mostra o existente).
--  · Nada existente muda. Para desfazer: deixar de usar o botão (a função fica sem uso).
-- =====================================================================

create or replace function public.cotacao_fornecedor_novo(p_cotacao bigint, p_nome text, p_contato text default null,
  p_telefone text default null, p_email text default null)
returns bigint
language plpgsql security definer
set search_path = public
as $$
declare v_nome text := upper(btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g'))); v_num text; v_id bigint;
begin
  if not public.pode('cotacoes_compra', 'alterar') then raise exception 'Sem permissão para alterar cotações'; end if;
  select numero into v_num from public.cotacoes_compra where id = p_cotacao and situacao = 'aberta';
  if v_num is null then raise exception 'A cotação não está aberta'; end if;
  if length(v_nome) < 3 then raise exception 'Escreva o nome do fornecedor (pelo menos 3 letras)'; end if;
  select id into v_id from public.fornecedores
   where upper(btrim(nome)) = v_nome or upper(btrim(coalesce(nome_fantasia, ''))) = v_nome limit 1;
  if v_id is not null then raise exception 'Já existe um fornecedor com esse nome: escolha na lista'; end if;
  insert into public.fornecedores (nome, contato, telefone, email, observacoes)
  values (v_nome, nullif(btrim(p_contato), ''), nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), ''),
          nullif(lower(btrim(p_email)), ''), 'Cadastro rápido na cotação ' || v_num || ' · completar CNPJ e endereço')
  returning id into v_id;
  insert into public.cotacoes_compra_fornecedores (cotacao_id, fornecedor_id) values (p_cotacao, v_id);
  return v_id;
end $$;
revoke execute on function public.cotacao_fornecedor_novo(bigint, text, text, text, text) from public, anon;
grant execute on function public.cotacao_fornecedor_novo(bigint, text, text, text, text) to authenticated;
