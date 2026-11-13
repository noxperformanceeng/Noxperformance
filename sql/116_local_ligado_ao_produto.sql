-- =====================================================================
-- 116 · Locais de estoque: o local criado já fica ligado ao produto
--  · A tela Locais de estoque agora escolhe "o que fica guardado aqui": ao salvar, o produto passa a
--    apontar para o local e aparece na Posição de estoque e no Inventário, sem refazer o trabalho lá.
--  · Por isso quem pode alterar o cadastro de locais também pode ligar produto a local (a função de
--    ligar aceita o nível "alterar" da tela Locais, além de Estoque, Almoxarifado e Produtos).
--  · Acerto dos dados: os locais cadastrados com o código do produto (ex.: 2000217) que ainda não
--    estavam ligados a ele passam a ficar ligados. Só preenche produto sem local; não apaga nem muda
--    nenhum local.
-- =====================================================================
create or replace function public.estoque_definir_local(p_produtos bigint[], p_local bigint)
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not (public.pode('estoque', 'alterar') or public.pode('almoxarifado', 'alterar') or public.pode('produtos', 'alterar')
          or public.pode('locais', 'alterar')) then
    raise exception 'Sem permissão para definir local';
  end if;
  if p_local is not null and not exists (select 1 from public.locais_estoque where id = p_local and situacao = 'ativo') then
    raise exception 'Local não encontrado ou inativo';
  end if;
  update public.produtos set local_id = p_local where id = any(p_produtos);
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function public.estoque_definir_local(bigint[], bigint) from public, anon;
grant execute on function public.estoque_definir_local(bigint[], bigint) to authenticated;

-- Liga cada local que tem o código de um produto a esse produto (só onde o produto ainda está sem local)
update public.produtos p set local_id = l.id
  from public.locais_estoque l
 where upper(trim(l.codigo)) = upper(trim(p.codigo)) and l.situacao = 'ativo' and p.local_id is null;

-- Conferência: cada local com o(s) produto(s) guardado(s) nele. Esperado: nenhum local com 0 produtos
-- entre os que têm código de produto.
select l.codigo, concat_ws('-', l.rua, l.prateleira, l.posicao) as endereco,
       count(p.id) as produtos, string_agg(p.codigo, ', ') as codigos
  from public.locais_estoque l left join public.produtos p on p.local_id = l.id
 group by l.id order by l.id;
