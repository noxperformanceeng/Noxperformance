-- =====================================================================
-- 144 · Produto: "feito por usinagem terceirizada" (marca no cadastro)
--  · Nem toda peça NX é usinada a mando da NOX: algumas a NOX compra prontas (ex.: NX42 prolongador de sonda,
--    NX64 luva de sonda lambda, NX74 boost tap). A regra da solicitação de compra passa a seguir uma marca no
--    cadastro do produto, e não mais o código NX:
--      - marcado: a NOX manda o material e paga a usinagem → pede-se como Serviço › USINAGEM + a peça;
--      - desmarcado: compra-se pronto → pede-se como Produto.
--  · Já vem marcado nas peças que têm ficha de usinagem, menos NX42, NX64 e NX74 (compradas prontas).
--    Para ajustar, é só marcar/desmarcar no cadastro do produto.
-- =====================================================================

alter table public.produtos add column if not exists usinagem_terceiro boolean not null default false;
comment on column public.produtos.usinagem_terceiro is 'Feito por usinagem terceirizada: a NOX manda o material e paga o serviço (solicitação = Serviço › Usinagem + peça)';

-- marca inicial (só na primeira vez: se já houver alguma marcada, não mexe)
update public.produtos p set usinagem_terceiro = true
 where not exists (select 1 from public.produtos where usinagem_terceiro)
   and exists (select 1 from public.produto_usinagem u where u.produto_id = p.id)
   and p.codigo not in ('NX42', 'NX64', 'NX74');

-- lista das peças usinadas por terceiro, para a tela de solicitação (quem pede compra pode não ver o cadastro)
create or replace function public.sc_pecas_usinagem()
returns setof bigint language sql stable security definer set search_path = public as $$
  select p.id from public.produtos p where (select public.pode('solicitacoes_compra')) and p.usinagem_terceiro and p.situacao = 'ativo'
$$;
revoke execute on function public.sc_pecas_usinagem() from public, anon;
grant execute on function public.sc_pecas_usinagem() to authenticated;

-- solicitação: a trava passa a usar a marca do cadastro
do $$
declare d text; n text;
begin
  d := replace(pg_get_functiondef('public.solicitacao_compra_salvar(jsonb, jsonb)'::regprocedure), E'\r\n', E'\n');
  if position('usinagem_terceiro' in d) = 0 then
    n := replace(d, 'where pr.codigo ~ ''^NX[0-9]'') then
    raise exception ''Peça usinada (NX) não se pede como Produto:',
'where pr.usinagem_terceiro) then
    raise exception ''Esta peça é feita por usinagem terceirizada e não se pede como Produto:');
    if n = d then raise exception 'solicitacao_compra_salvar: trecho não encontrado'; end if;
    execute n;
  end if;
end $$;
