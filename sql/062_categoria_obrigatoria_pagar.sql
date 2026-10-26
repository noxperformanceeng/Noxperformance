-- =====================================================================
-- 062 · Categoria financeira obrigatória no contas a pagar
--  · Lançamento: título incluído por um usuário precisa de categoria financeira ou de rateio
--    (conferido no fim da gravação, para aceitar título + rateio salvos juntos).
--  · Baixa: não registra pagamento de título sem categoria/rateio (vale para os antigos importados).
--  · Cargas automáticas (Tiny, integrações) não passam por aqui; os sem categoria seguem na Quarentena.
-- =====================================================================
create or replace function public.titulo_pagar_exige_categoria()
returns trigger language plpgsql set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;
  -- relê o título no fim da transação (a categoria pode ter sido preenchida depois do insert)
  if exists (select 1 from public.titulos_pagar t where t.id = new.id and t.categoria_financeira_id is null and t.situacao <> 'cancelado')
     and not exists (select 1 from public.titulos_pagar_rateio where titulo_id = new.id) then
    raise exception 'Informe a categoria financeira do título (ou faça o rateio)';
  end if;
  return null;
end $$;
revoke execute on function public.titulo_pagar_exige_categoria() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'exige_categoria' and tgrelid = 'public.titulos_pagar'::regclass) then
    create constraint trigger exige_categoria after insert on public.titulos_pagar
      deferrable initially deferred for each row execute function public.titulo_pagar_exige_categoria();
  end if;
end $$;

create or replace function public.pagamento_exige_categoria()
returns trigger language plpgsql set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if exists (select 1 from public.titulos_pagar t where t.id = new.titulo_id and t.categoria_financeira_id is null)
     and not exists (select 1 from public.titulos_pagar_rateio where titulo_id = new.titulo_id) then
    raise exception 'Título sem categoria financeira: informe a categoria antes de registrar o pagamento';
  end if;
  return new;
end $$;
revoke execute on function public.pagamento_exige_categoria() from public, anon, authenticated;
create or replace trigger exige_categoria before insert on public.pagamentos for each row execute function public.pagamento_exige_categoria();
