-- =====================================================================
-- 115 · Extrato: o sistema lembra as colunas do extrato de cada conta
--  · Nova coluna "layout_extrato" em contas_bancarias: guarda qual coluna do arquivo é a data, o valor,
--    a descrição etc. na última importação daquela conta.
--  · Na próxima importação da mesma conta, a tela já vem com as colunas certas (o usuário só confere).
--  · Quem pode importar extrato (conciliação, nível editar) grava o layout pela função abaixo,
--    sem precisar de permissão para alterar o cadastro da conta.
-- =====================================================================
alter table public.contas_bancarias add column if not exists layout_extrato jsonb;

create or replace function public.salvar_layout_extrato(p_conta bigint, p_layout jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.pode('conciliacao', 'editar') then raise exception 'Sem permissão para importar extrato'; end if;
  if jsonb_typeof(p_layout) is distinct from 'object' or length(p_layout::text) > 4000 then raise exception 'Layout inválido'; end if;
  update public.contas_bancarias set layout_extrato = p_layout where id = p_conta;
end $$;
revoke execute on function public.salvar_layout_extrato(bigint, jsonb) from public, anon;
grant execute on function public.salvar_layout_extrato(bigint, jsonb) to authenticated;

-- Conferência: deve listar as contas com a coluna nova (vazia até a primeira importação)
select id, descricao, layout_extrato from public.contas_bancarias where tipo <> 'historico' order by id;
