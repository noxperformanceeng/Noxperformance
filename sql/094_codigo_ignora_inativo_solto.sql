-- =====================================================================
-- 094 · Código automático: produto inativo fora da sequência não "puxa" a numeração
--  · Ex.: 2000653 (mangueira cadastrada por engano no corte a laser, inativa) fazia o próximo código
--    de corte a laser sair 2000654. Agora a conta usa os produtos ativos (e os códigos do Tiny que não
--    são de produto inativo) e o próximo volta a ser 2000437.
--  · Nunca repete um código que já existe (ativo, inativo ou no Tiny): se o número estiver ocupado, pula.
--  · Vale para as famílias 4000xxx, 2000xxx e F. A família NX (usinagem) já seguia esta lógica.
-- =====================================================================
create or replace function public.produtos_proximo_codigo(p_tipo text)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_pre text; v_re text; v_max bigint; v_cod text;
begin
  if not (public.pode('produtos', 'criar')) then raise exception 'Sem permissão para cadastrar produtos'; end if;
  v_pre := case p_tipo when 'materia_prima' then '4' when 'componente' then '4' when 'semiacabado' then '20' when 'ferramenta' then 'F' end;
  if v_pre is null then return null; end if;
  v_re := case when v_pre = 'F' then '^F\d{1,9}$' else '^' || v_pre || '\d{' || (7 - length(v_pre)) || '}$' end;

  -- maior número da família entre produtos ativos e códigos do Tiny que não sejam de produto inativo aqui
  select coalesce(max(n), case when v_pre = 'F' then 0 else rpad(v_pre, 7, '0')::bigint end) into v_max from (
    select case when v_pre = 'F' then substring(codigo from 2) else codigo end::bigint n
      from public.produtos where upper(codigo) ~ v_re and situacao = 'ativo'
    union all
    select case when v_pre = 'F' then substring(c from 2) else c end::bigint
      from (select upper(trim(resumo->>'codigo')) c from public.tiny_brutos where recurso = 'produtos') t
     where c ~ v_re and not exists (select 1 from public.produtos p where upper(p.codigo) = t.c and p.situacao <> 'ativo')) z;

  -- próximo livre (não repete código que já exista em lugar nenhum)
  loop
    v_max := v_max + 1;
    v_cod := case when v_pre = 'F' then 'F' || lpad(v_max::text, 2, '0') else v_max::text end;
    exit when not exists (select 1 from public.produtos where upper(codigo) = v_cod)
          and not exists (select 1 from public.tiny_brutos where recurso = 'produtos' and upper(trim(resumo->>'codigo')) = v_cod);
  end loop;
  return v_cod;
end $$;
revoke execute on function public.produtos_proximo_codigo(text) from public, anon;
grant execute on function public.produtos_proximo_codigo(text) to authenticated;
