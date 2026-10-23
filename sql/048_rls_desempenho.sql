-- =====================================================================
-- 048 · Desempenho das regras de acesso (RLS)
--   As regras chamavam pode()/eh_admin() para CADA linha lida (6 mil títulos = 6 mil checagens → ~1,2 s).
--   Envolvendo em (select ...) o Postgres calcula uma vez por consulta. Mesmo resultado, muito mais rápido.
--   Só são envolvidas chamadas com argumentos fixos (ex.: pode('pagar','editar')); pode(origem, ...) segue por linha.
-- =====================================================================
do $$
declare p record; q text; c text; re text := '(?<!select )\m(pode|eh_admin|pode_rh|pode_acao)\((''[^'']*''::text(, ''[^'']*''::text)?)?\)';
        sql text;
begin
  for p in select * from pg_policies where schemaname = 'public' loop
    q := p.qual; c := p.with_check;
    if q is not null then q := regexp_replace(q, re, '(select \1(\2))', 'g'); q := regexp_replace(q, '(?<!select )auth\.uid\(\)', '(select auth.uid())', 'g'); end if;
    if c is not null then c := regexp_replace(c, re, '(select \1(\2))', 'g'); c := regexp_replace(c, '(?<!select )auth\.uid\(\)', '(select auth.uid())', 'g'); end if;
    if q is not distinct from p.qual and c is not distinct from p.with_check then continue; end if;
    sql := format('alter policy %I on public.%I', p.policyname, p.tablename);
    if q is not null then sql := sql || ' using (' || q || ')'; end if;
    if c is not null then sql := sql || ' with check (' || c || ')'; end if;
    execute sql;
  end loop;
end $$;
