-- =====================================================================
-- 140 · Cotações: lembrete para o comprador conferir se os fornecedores responderam
--  · Cada cotação nova ganha um lembrete para 24 horas depois de criada.
--  · Passou da hora e a cotação continua aberta: o número de Cotações no menu fica vermelho e piscando,
--    a cotação aparece na lista com a etiqueta "conferir retorno" e, dentro dela, um aviso com o botão
--    "Já conferi · lembrar em 24h" (adia o lembrete por mais 24 horas).
--  · Concluir ou cancelar a cotação tira o lembrete sozinho.
--  · As cotações que já estão abertas (ex.: CT-00001) recebem o lembrete para 24h depois da criação.
--  · Não apaga nem altera preços, itens ou pedidos. Rodar de novo não faz nada.
-- =====================================================================

-- ---------- Coluna do lembrete ----------
alter table public.cotacoes_compra add column if not exists lembrete_em timestamptz;
alter table public.cotacoes_compra alter column lembrete_em set default (now() + interval '24 hours');
update public.cotacoes_compra set lembrete_em = coalesce(criado_em, now()) + interval '24 hours' where lembrete_em is null and situacao = 'aberta';

-- ---------- "Já conferi": adia o lembrete (por padrão 24 horas) ----------
create or replace function public.cotacao_lembrar(p_id bigint, p_horas int default 24)
returns void language plpgsql security definer set search_path = public as $$
declare v_sit text;
begin
  if not public.pode('cotacoes_compra', 'alterar') then raise exception 'Sem permissão para alterar a cotação'; end if;
  select situacao into v_sit from public.cotacoes_compra where id = p_id for update;
  if v_sit is distinct from 'aberta' then raise exception 'Só cotação aberta tem lembrete'; end if;
  update public.cotacoes_compra set lembrete_em = now() + make_interval(hours => greatest(1, least(coalesce(p_horas, 24), 168))) where id = p_id;
end $$;
revoke execute on function public.cotacao_lembrar(bigint, int) from public, anon;
grant execute on function public.cotacao_lembrar(bigint, int) to authenticated;

-- ---------- Contador do menu: cotações abertas com o lembrete vencido ficam em vermelho ----------
do $$
declare d text;
begin
  d := pg_get_functiondef('public.menu_contadores()'::regprocedure);
  if position('lembrete_em' in d) = 0 then
    d := replace(d, $x$select count(*) into a from public.cotacoes_compra where situacao = 'aberta';$x$,
      $x$select count(*) into a from public.cotacoes_compra where situacao = 'aberta';
    select count(*) into r from public.cotacoes_compra where situacao = 'aberta' and lembrete_em <= now();$x$);
    d := replace(d, $x$jsonb_build_object('cotacoes_compra', jsonb_build_object('amarelo', a, 'vermelho', 0))$x$,
      $x$jsonb_build_object('cotacoes_compra', jsonb_build_object('amarelo', a, 'vermelho', r))$x$);
    if position('lembrete_em' in d) = 0 or position($x$'vermelho', r))$x$ in d) = 0 then raise exception 'menu_contadores: trecho das cotações não encontrado'; end if;
    execute d;
  end if;
end $$;
