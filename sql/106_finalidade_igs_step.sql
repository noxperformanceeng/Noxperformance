-- =====================================================================
-- 106 — Arquivos 3D (IGS/STEP) contam como arquivo de corte
-- O que muda: além do DXF, os arquivos .igs/.iges/.stp/.step anexados como
-- desenho de uma peça passam a ser tratados como "arquivo de corte" (vão no
-- pacote de desenhos que o comprador manda ao fornecedor de laser/tubo).
-- Nada é apagado; só muda a classificação automática.
-- =====================================================================

create or replace function public.arquivo_finalidade(p_nome text, p_tipo text)
returns text language sql immutable set search_path = public as $$
  select case
    when p_tipo is distinct from 'desenho' then 'outro'
    when p_nome ~* '\.(dxf|igs|iges|stp|step)$' then case when p_nome ~* 'dobra' then 'dobra_dxf' else 'corte_dxf' end
    when p_nome ~* '\.pdf$' then case
      when p_nome ~* 'dobra' then 'dobra_pdf'
      when p_nome ~* '^DF-?[0-9]' or p_nome ~* '(montagem|conjunto|conferencia)' then 'montagem'
      else 'corte_pdf' end
    else 'outro' end
$$;

-- reclassifica os arquivos 3D que já estavam anexados como "outro"
update public.produto_arquivos
   set finalidade = public.arquivo_finalidade(nome, tipo)
 where tipo = 'desenho' and nome ~* '\.(igs|iges|stp|step)$'
   and finalidade is distinct from public.arquivo_finalidade(nome, tipo);
