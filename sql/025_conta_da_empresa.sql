-- =====================================================================
-- ERP NOX · 025_conta_da_empresa.sql
-- 1) Conta bancária sempre da mesma empresa do título (no título e no pagamento):
--    evita lançar ou baixar em conta errada e facilita a conciliação.
-- 2) Contas bancárias, formas e condições de pagamento passam para o grupo "Cadastros"
--    (lista de telas em Usuários e acessos), como no menu.
-- Pode rodar mais de uma vez. Sem comandos destrutivos.
-- =====================================================================
create or replace function public.conta_da_empresa()
returns trigger language plpgsql set search_path = public as $$
declare v_emp int; v_conta int;
begin
  if tg_table_name = 'titulos_pagar' then
    if new.conta_bancaria_id is null then return new; end if;
    v_emp := new.empresa_id;
    select empresa_id into v_conta from public.contas_bancarias where id = new.conta_bancaria_id;
  else
    select empresa_id into v_emp from public.titulos_pagar where id = new.titulo_id;
    select empresa_id into v_conta from public.contas_bancarias where id = new.conta_bancaria_id;
  end if;
  if v_conta is distinct from v_emp then
    raise exception 'A conta bancária escolhida é de outra empresa';
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'conta_da_empresa' and tgrelid = 'public.titulos_pagar'::regclass) then
    create trigger conta_da_empresa before insert or update of conta_bancaria_id, empresa_id on public.titulos_pagar
      for each row execute function public.conta_da_empresa();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'conta_da_empresa' and tgrelid = 'public.pagamentos'::regclass) then
    create trigger conta_da_empresa before insert or update of conta_bancaria_id on public.pagamentos
      for each row execute function public.conta_da_empresa();
  end if;
end $$;
revoke execute on function public.conta_da_empresa() from public, anon, authenticated;

update public.modulos set grupo = 'cadastros', ordem = 18 where id = 'contas_bancarias' and grupo <> 'cadastros';
update public.modulos set grupo = 'cadastros', ordem = 19 where id = 'condicoes_pagamento' and grupo <> 'cadastros';
