-- =====================================================================
-- 079 · Novo tipo de produto: "Componente comprado"
--  · Peças que a NOX compra prontas de terceiros (diferente de matéria-prima, que é transformada).
--  · Código segue a família 4xxxxxx dos itens comprados; exige fornecedor como a matéria-prima.
-- =====================================================================
alter table public.produtos drop constraint if exists produtos_tipo_check;
alter table public.produtos add constraint produtos_tipo_check check (tipo in ('materia_prima','componente','semiacabado','acabado','kit','ferramenta','despesa'));
alter table public.produto_grupos drop constraint if exists produto_grupos_tipo_produto_check;
alter table public.produto_grupos add constraint produto_grupos_tipo_produto_check check (tipo_produto in ('materia_prima','componente','semiacabado','acabado','kit','ferramenta','despesa'));
do $$ declare d text; begin
  d := pg_get_functiondef('public.produtos_proximo_codigo(text)'::regprocedure);
  if position('componente' in d) = 0 then
    d := replace(d, $x$when 'materia_prima' then$x$, $x$when 'materia_prima' then (select (coalesce(max(codigo::bigint), 4000000) + 1)::text from public.produtos where codigo ~ '^4\d{6}$')
    when 'componente' then$x$);
    execute d;
  end if;
end $$;
