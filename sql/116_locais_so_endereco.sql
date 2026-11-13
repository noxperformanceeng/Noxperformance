-- =====================================================================
-- 116 · Locais de estoque viram só endereço; o produto é alocado no local pela Posição de estoque
--  · Quem pode alterar a tela Locais também pode alocar produto em local (a função aceita o nível
--    "alterar" de Locais, além de Estoque, Almoxarifado e Produtos).
--  · Acerto dos locais já cadastrados com o código do produto (ex.: 2000219):
--    1) o produto de mesmo código passa a apontar para o local (só se ele ainda estiver sem local);
--    2) o código do local passa a ser o endereço (ex.: RUA 1-B-016; sem rua, o nome do depósito);
--    3) a descrição (que era o nome do produto) é apagada. Observações ficam como estão.
--    Nenhum local é apagado. As etiquetas impressas com o código antigo precisam ser refeitas.
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

-- 2) e 3) Local que tinha código de produto: código = endereço, descrição limpa
update public.locais_estoque l
   set codigo = upper(coalesce(nullif(concat_ws('-', l.rua, l.prateleira, l.posicao), ''), l.deposito, l.codigo)),
       descricao = null
 where exists (select 1 from public.produtos p where upper(trim(p.codigo)) = upper(trim(l.codigo)));

-- Conferência: esperado 27 locais com código = endereço (RUA 1-A-001 …), cada um com 1 produto
select l.codigo, l.deposito, l.descricao,
       count(p.id) as produtos, string_agg(p.codigo, ', ') as codigos
  from public.locais_estoque l left join public.produtos p on p.local_id = l.id
 group by l.id order by l.id;
