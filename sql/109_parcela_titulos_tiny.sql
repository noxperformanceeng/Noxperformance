-- =====================================================================
-- 109 · Contas a pagar: parcela dos títulos que vieram do Tiny
--  · No Tiny a parcela ficava só escrita no histórico ("... - Parcela (6/60)", "(parcela 2/60)").
--  · Agora o número da parcela e o total vão para os campos Parcela / de, e aparecem na coluna
--    Parcela da lista (ex.: 6/60). Vale para o que já foi importado e para as próximas importações.
--  · Só preenche quando o campo está vazio; não mexe em valor, datas nem pagamentos.
-- =====================================================================

create or replace function public.titulos_parcela_do_historico()
returns trigger language plpgsql set search_path = public as $$
declare m text[];
begin
  if new.origem = 'importacao' and new.parcela is null and new.descricao is not null then
    m := regexp_match(new.descricao, 'parcela\s*\(?\s*(\d{1,3})\s*/\s*(\d{1,3})', 'i');
    if m is not null and m[1]::int between 1 and m[2]::int then
      new.parcela := m[1]::int; new.parcelas := m[2]::int;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.titulos_parcela_do_historico() from public, anon, authenticated;

drop trigger if exists parcela_do_historico on public.titulos_pagar;
create trigger parcela_do_historico before insert or update of descricao, parcela on public.titulos_pagar
  for each row execute function public.titulos_parcela_do_historico();

-- Títulos já importados
update public.titulos_pagar t
   set parcela = (m)[1]::int, parcelas = (m)[2]::int
  from (select id, regexp_match(descricao, 'parcela\s*\(?\s*(\d{1,3})\s*/\s*(\d{1,3})', 'i') m
          from public.titulos_pagar where origem = 'importacao' and parcela is null) x
 where t.id = x.id and x.m is not null and (x.m)[1]::int between 1 and (x.m)[2]::int;
