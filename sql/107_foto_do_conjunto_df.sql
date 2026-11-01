-- =====================================================================
-- 107 · Foto do defletor montado (conjuntos DF)
--  · Os conjuntos DF não têm desenho de corte nem de dobra, só o desenho de montagem.
--  · Agora, ao anexar o desenho de montagem a um DF sem foto, o sistema também gera a foto
--    a partir dele (a vista 3D do defletor montado).
-- =====================================================================

create or replace function public.produto_gerar_foto(p_produto bigint)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not (select public.pode('produtos', 'criar')) then raise exception 'Sem permissão'; end if;
  if exists (select 1 from public.produto_arquivos where produto_id = p_produto and tipo = 'foto') then return false; end if;
  if not exists (select 1 from public.produto_arquivos where produto_id = p_produto
                   and finalidade in ('dobra_pdf', 'corte_pdf', 'montagem') and nome ~* '\.pdf$') then return false; end if;
  perform public.integracao_disparar('importar-arquivos-produtos', jsonb_build_object('fotos', jsonb_build_object('produtos', jsonb_build_array(p_produto))));
  return true;
end $$;
revoke execute on function public.produto_gerar_foto(bigint) from public, anon;
grant execute on function public.produto_gerar_foto(bigint) to authenticated;
