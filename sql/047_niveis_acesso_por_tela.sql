-- =====================================================================
-- 047 · Níveis de acesso por tela (mais específicos)
--   ver      → só consulta
--   criar    → ver + incluir novos (não altera os que já existem)
--   alterar  → ver + incluir + alterar (não inativa / não exclui)
--   editar   → tudo, inclusive inativar e excluir  (= "Ver e editar" de antes; nada muda para quem já tinha)
--  · pode(m, 'editar') continua significando "pode gravar algo" (as regras de acesso das tabelas seguem iguais);
--    a separação criar / alterar / inativar é feita por um gatilho nos cadastros e títulos, só para o usuário
--    na tela (rotinas internas do sistema não passam por ele).
-- =====================================================================
alter table public.permissoes drop constraint if exists permissoes_nivel_check;
alter table public.permissoes add constraint permissoes_nivel_check check (nivel in ('ver','criar','alterar','editar'));
alter table public.permissoes_usuario drop constraint if exists permissoes_usuario_nivel_check;
alter table public.permissoes_usuario add constraint permissoes_usuario_nivel_check check (nivel in ('ver','criar','alterar','editar','nenhum'));

create or replace function public.nivel_rank(p text) returns int language sql immutable as $$
  select case p when 'ver' then 1 when 'criar' then 2 when 'alterar' then 3 when 'editar' then 4 when 'total' then 4 else 0 end
$$;

-- p_nivel: 'ver' | 'criar' | 'alterar' | 'total' (tudo) | 'editar' (qualquer gravação — compatível com as regras antigas)
create or replace function public.pode(p_modulo text, p_nivel text default 'ver')
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when p_nivel = 'editar' then public.nivel_rank(public.meu_nivel(p_modulo)) >= 2
    else public.nivel_rank(public.meu_nivel(p_modulo)) >= greatest(public.nivel_rank(p_nivel), 1) end
$$;

-- Gatilho: incluir exige "criar"; alterar exige "alterar"; inativar/excluir exige tudo ("editar")
create or replace function public.nivel_cadastro()
returns trigger language plpgsql set search_path = public as $$
declare m text := tg_argv[0]; v_sit_old text; v_sit_new text;
begin
  if current_user <> 'authenticated' or auth.uid() is null then return coalesce(new, old); end if;   -- rotinas do sistema
  if tg_op = 'INSERT' then
    if not public.pode(m, 'criar') then raise exception 'Sem permissão para incluir nesta tela (peça ao administrador)'; end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if not public.pode(m, 'total') then raise exception 'Sem permissão para excluir nesta tela (peça ao administrador)'; end if;
    return old;
  end if;
  if not public.pode(m, 'alterar') then raise exception 'Sem permissão para alterar registros nesta tela (só incluir novos)'; end if;
  v_sit_old := to_jsonb(old)->>'situacao'; v_sit_new := to_jsonb(new)->>'situacao';
  if v_sit_old is distinct from v_sit_new and (v_sit_new in ('inativo','desligado','cancelado') or v_sit_old in ('inativo','desligado','cancelado'))
     and not public.pode(m, 'total') then
    raise exception 'Sem permissão para inativar/reativar nesta tela (peça ao administrador)';
  end if;
  return new;
end $$;

do $$
declare x record;
begin
  for x in select * from (values
      ('produtos','produtos'), ('clientes','clientes'), ('fornecedores','fornecedores'), ('funcionarios','funcionarios'),
      ('locais_estoque','locais'), ('categorias_financeiras','categorias_fin'), ('contas_bancarias','contas_bancarias'),
      ('condicoes_pagamento','condicoes_pagamento'), ('formas_pagamento','condicoes_pagamento'), ('canais_venda','canais_venda'),
      ('titulos_pagar','pagar'), ('titulos_receber','receber')) v(tabela, modulo)
  loop
    if to_regclass('public.' || x.tabela) is null then continue; end if;
    execute format('drop trigger if exists nivel_acesso on public.%I', x.tabela);
    execute format('create trigger nivel_acesso before insert or update or delete on public.%I for each row execute function public.nivel_cadastro(%L)', x.tabela, x.modulo);
  end loop;
end $$;
