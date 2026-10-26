-- =====================================================================
-- 080 · Código do produto respeita o Tiny + produtos que faltavam
--  · O botão "Gerar" do código passa a olhar também os códigos que já existem no Tiny
--    (antes olhava só o sistema e sugeriu 4000724, que já tinha sido usado no Tiny).
--  · Os produtos cadastrados no Tiny que não estavam no sistema entram agora (origem Tiny),
--    com uma observação para revisar tipo, grupo e categoria.
--  · Todo dia o sistema lê a lista de produtos do Tiny (só a lista) e traz os novos.
-- =====================================================================

-- Próximo código: maior entre sistema e Tiny, por família
create or replace function public.produtos_proximo_codigo(p_tipo text)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_pre text; v_max bigint;
begin
  if not (public.pode('produtos', 'criar')) then raise exception 'Sem permissão para cadastrar produtos'; end if;
  if p_tipo = 'ferramenta' then
    select coalesce(max(n), 0) + 1 into v_max from (
      select substring(codigo from 2)::bigint n from public.produtos where codigo ~ '^F\d{1,9}$'
      union all
      select substring(upper(trim(resumo->>'codigo')) from 2)::bigint from public.tiny_brutos
       where recurso = 'produtos' and upper(trim(resumo->>'codigo')) ~ '^F\d{1,9}$') z;
    return 'F' || lpad(v_max::text, 2, '0');
  end if;
  v_pre := case p_tipo when 'materia_prima' then '4' when 'componente' then '4' when 'semiacabado' then '2' end;
  if v_pre is null then return null; end if;
  select coalesce(max(n), (v_pre || '000000')::bigint) + 1 into v_max from (
    select codigo::bigint n from public.produtos where codigo ~ ('^' || v_pre || '\d{6}$')
    union all
    select trim(resumo->>'codigo')::bigint from public.tiny_brutos
     where recurso = 'produtos' and trim(resumo->>'codigo') ~ ('^' || v_pre || '\d{6}$')) z;
  return v_max::text;
end $$;
revoke execute on function public.produtos_proximo_codigo(text) from public, anon;
grant execute on function public.produtos_proximo_codigo(text) to authenticated;

-- Traz do Tiny os produtos que ainda não existem no sistema (pelo código)
create or replace function public.tiny_carregar_produtos_novos()
returns int language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if auth.uid() is not null and not public.eh_admin() then raise exception 'Só o administrador'; end if;
  with t as (
    select distinct on (upper(trim(b.resumo->>'codigo'))) upper(trim(b.resumo->>'codigo')) cod, b.resumo r, b.tiny_id, b.empresa_id
      from public.tiny_brutos b
     where b.recurso = 'produtos' and coalesce(trim(b.resumo->>'codigo'), '') <> ''
     order by upper(trim(b.resumo->>'codigo')), b.empresa_id
  ), f as (
    select t.*, coalesce(nullif(substring(t.cod from '^[A-Z]+'), ''), left(t.cod, 1)) pre
      from t where not exists (select 1 from public.produtos p where upper(p.codigo) = t.cod)
  )
  insert into public.produtos (codigo, descricao, tipo, unidade, situacao, gtin, origem, ref_tiny, aprovacao, observacoes)
  select f.cod,
         upper(regexp_replace(trim(f.r->>'nome'), '\s+', ' ', 'g')),
         case when upper(f.r->>'nome') like 'MANUTEN%' then 'despesa'
              when f.cod ~ '^4\d{6}' then 'materia_prima'
              when f.cod ~ '^2\d{6}' then 'semiacabado'
              when f.cod ~ '^F\d+$' then 'ferramenta'
              else coalesce((select p.tipo from public.produtos p
                              where coalesce(nullif(substring(upper(p.codigo) from '^[A-Z]+'), ''), left(p.codigo, 1)) = f.pre
                              group by p.tipo order by count(*) desc limit 1), 'acabado') end,
         case regexp_replace(upper(trim(coalesce(f.r->>'unidade', ''))), '[^A-ZÇ]', '', 'g')
              when '' then 'UN' when 'PÇ' then 'PC' when 'PC' then 'PC' when 'PACOTE' then 'PCT'
              when 'PARES' then 'PAR' when 'CENTIM' then 'CM'
              else upper(trim(f.r->>'unidade')) end,
         case when f.r->>'situacao' = 'I' then 'inativo' else 'ativo' end,
         nullif(trim(f.r->>'gtin'), ''),
         'tiny',
         jsonb_build_object('tiny_id', f.tiny_id, 'sku_tiny', f.r->>'codigo', 'empresa_id', f.empresa_id,
                            'data_criacao', f.r->>'data_criacao', 'importado_em', current_date),
         'aprovado',
         'Importado do Tiny em ' || to_char(current_date, 'DD/MM/YYYY') || ': revisar tipo, grupo e categoria financeira.'
    from f;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function public.tiny_carregar_produtos_novos() from public, anon, authenticated;
grant execute on function public.tiny_carregar_produtos_novos() to service_role;

-- Carga agora
select public.tiny_carregar_produtos_novos();

-- Rotina diária: lê a lista de produtos do Tiny (empresas 30 e 37) e, depois, traz os novos
select cron.schedule('nox-tiny-prod-30', '5 9 * * *',
  $c$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '30', 'recurso', 'produtos', 'detalhar', false))$c$);
select cron.schedule('nox-tiny-prod-37', '8 9 * * *',
  $c$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '37', 'recurso', 'produtos', 'detalhar', false))$c$);
select cron.schedule('nox-tiny-prod-carga', '40 9 * * *', $c$select public.tiny_carregar_produtos_novos()$c$);
