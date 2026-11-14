-- =====================================================================
-- 116 · Locais de estoque viram só endereço; o produto é alocado no local pela Posição de estoque
--  · Quem pode alterar a tela Locais também pode alocar produto em local (a função aceita o nível
--    "alterar" de Locais, além de Estoque, Almoxarifado e Produtos).
--  · Acerto dos locais já cadastrados com o código do produto (ex.: 2000219):
--    1) o produto passa a apontar para o local feito para ele, achado pelo código ou pela descrição
--       (só se o produto ainda estiver sem local);
--    2) o código do local passa a ser o endereço (ex.: RUA 1-B-016; sem rua, o nome do depósito);
--    3) a descrição que é o nome de um produto é apagada. Observações ficam como estão.
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

-- 1) Liga o produto ao local que foi cadastrado para ele (só produto ainda sem local):
--    a) pelo código (local com o código do produto, ex.: 2000219)
update public.produtos p set local_id = l.id
  from public.locais_estoque l
 where upper(trim(l.codigo)) = upper(trim(p.codigo)) and l.situacao = 'ativo' and p.local_id is null;
--    b) pela descrição, para os locais que já tiveram o código trocado pelo endereço mas guardam o nome do
--       produto na descrição (só quando o nome é de um único produto e o local ainda está sem produto)
update public.produtos p set local_id = l.id
  from public.locais_estoque l
 where upper(trim(l.descricao)) = upper(trim(p.descricao)) and l.situacao = 'ativo' and p.local_id is null
   and not exists (select 1 from public.produtos x where x.local_id = l.id)
   and (select count(*) from public.produtos y where upper(trim(y.descricao)) = upper(trim(l.descricao))) = 1;

-- 2) Local com código de produto: o código passa a ser o endereço
update public.locais_estoque l
   set codigo = upper(coalesce(nullif(concat_ws('-', l.rua, l.prateleira, l.posicao), ''), l.deposito, l.codigo))
 where exists (select 1 from public.produtos p where upper(trim(p.codigo)) = upper(trim(l.codigo)));

-- 3) Descrição que é o nome de um produto: apagada (a tela não tem mais esse campo; observações ficam)
update public.locais_estoque l set descricao = null
 where exists (select 1 from public.produtos p where upper(trim(p.descricao)) = upper(trim(l.descricao)));

-- Conferência: esperado nenhum local com código de produto e cada local antigo com 1 produto
select l.codigo, l.deposito, l.descricao,
       count(p.id) as produtos, string_agg(p.codigo, ', ') as codigos
  from public.locais_estoque l left join public.produtos p on p.local_id = l.id
 group by l.id order by l.id;
