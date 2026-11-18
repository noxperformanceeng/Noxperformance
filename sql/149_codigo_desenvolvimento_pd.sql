-- =====================================================================
-- 149 · Código próprio para produtos de Desenvolvimento (P&D): PD001, PD002…
--  · Nova origem no cadastro de produtos: "Desenvolvimento (P&D)" — peça comprada para desenvolver produto
--    (amostra, peça original do carro para medir e testar encaixe). Fica no grupo Desenvolvimento (P&D),
--    com aba própria na lista de produtos e o botão "Gerar" sugere o código PD + número (PD001, PD002…),
--    sem se misturar com os adquiridos prontos (4000xxx).
--  · Entra no estoque normalmente (com local) e o gasto vai para 6.09.004 DESENV. PROTÓTIPOS E AMOSTRAS.
--  · Só acrescenta um caso na função que sugere o próximo código; o resto não muda.
-- =====================================================================

create or replace function public.produtos_proximo_codigo(p_tipo text, p_grupo text)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_max int;
begin
  if not (public.pode('produtos', 'criar')) then raise exception 'Sem permissão para cadastrar produtos'; end if;
  if p_tipo = 'semiacabado' and upper(trim(coalesce(p_grupo, ''))) = 'USINAGEM' then
    select coalesce(max(n), 0) + 1 into v_max from (
      select substring(upper(codigo) from 3)::int n from public.produtos where upper(codigo) ~ '^NX\d{1,3}$'
      union all
      select substring(upper(trim(resumo->>'codigo')) from 3)::int from public.tiny_brutos
       where recurso = 'produtos' and upper(trim(resumo->>'codigo')) ~ '^NX\d{1,3}$') z
     where n < 300;
    return 'NX' || v_max;
  end if;
  if upper(trim(coalesce(p_grupo, ''))) = 'DESENVOLVIMENTO (P&D)' then
    select coalesce(max(substring(upper(codigo) from 3)::int), 0) + 1 into v_max
      from public.produtos where upper(codigo) ~ '^PD\d{1,6}$';
    return 'PD' || lpad(v_max::text, 3, '0');
  end if;
  return public.produtos_proximo_codigo(p_tipo);
end $$;
