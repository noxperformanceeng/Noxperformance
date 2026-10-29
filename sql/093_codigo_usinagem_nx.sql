-- =====================================================================
-- 093 · Código automático por família: peça usinada ganha NX
--  · O botão "Gerar" do cadastro de produtos passa a considerar o tipo E o grupo:
--      matéria-prima e componente comprado → família 4 (4000xxx)
--      semiacabado do grupo Usinagem        → família NX (próximo NX livre: NX76, NX77…)
--      demais semiacabados (corte a laser…) → família 20 (2000xxx)
--      ferramenta                           → F
--  · Na conta do NX entram os códigos já usados no sistema e no Tiny, até NX299
--    (os NX de 3 dígitos acima disso são corpos de abafador, com regra própria, e ficam de fora).
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
  return public.produtos_proximo_codigo(p_tipo);
end $$;
revoke execute on function public.produtos_proximo_codigo(text, text) from public, anon;
grant execute on function public.produtos_proximo_codigo(text, text) to authenticated;
