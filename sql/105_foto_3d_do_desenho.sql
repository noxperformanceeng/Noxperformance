-- =====================================================================
-- 105 · Foto "3D" da peça a partir do desenho
--  · Quando alguém anexa o PDF do desenho a uma peça que ainda não tem foto, o sistema gera a foto sozinho:
--    acha a vista isométrica (a vista em 3D) na folha do desenho e recorta só ela. Sem vista 3D, usa a folha.
--  · O trabalho pesado roda no servidor (função importar-arquivos-produtos); aqui só o pedido, com permissão.
-- =====================================================================

create or replace function public.produto_gerar_foto(p_produto bigint)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not (select public.pode('produtos', 'criar')) then raise exception 'Sem permissão'; end if;
  if exists (select 1 from public.produto_arquivos where produto_id = p_produto and tipo = 'foto') then return false; end if;
  if not exists (select 1 from public.produto_arquivos where produto_id = p_produto and finalidade in ('dobra_pdf', 'corte_pdf')) then return false; end if;
  perform public.integracao_disparar('importar-arquivos-produtos', jsonb_build_object('fotos', jsonb_build_object('produtos', jsonb_build_array(p_produto))));
  return true;
end $$;
revoke execute on function public.produto_gerar_foto(bigint) from public, anon;
grant execute on function public.produto_gerar_foto(bigint) to authenticated;
