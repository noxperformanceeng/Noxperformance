-- =====================================================================
-- 038 · Colaboradores no RH + revisão dos perfis Financeiro e RH
-- O cadastro de funcionários vira "Colaboradores" dentro do RH (um só cadastro:
-- módulo 'funcionarios'). O módulo 'colaboradores' (tela que nunca existiu) é
-- incorporado: quem tinha acesso a ele passa a ter ao cadastro.
-- =====================================================================

-- quem tinha 'colaboradores' recebe o mesmo nível em 'funcionarios' (sem rebaixar)
insert into public.permissoes (perfil_id, modulo_id, nivel)
select perfil_id, 'funcionarios', nivel from public.permissoes where modulo_id = 'colaboradores'
on conflict (perfil_id, modulo_id) do update set nivel = case when excluded.nivel = 'editar' then 'editar' else public.permissoes.nivel end;

insert into public.permissoes_usuario (usuario_id, modulo_id, nivel)
select usuario_id, 'funcionarios', nivel from public.permissoes_usuario where modulo_id = 'colaboradores'
on conflict (usuario_id, modulo_id) do nothing;

delete from public.permissoes_usuario where modulo_id = 'colaboradores';
delete from public.permissoes where modulo_id = 'colaboradores';
delete from public.modulos where id = 'colaboradores';

update public.modulos set nome = 'Colaboradores', grupo = 'rh', ordem = 71 where id = 'funcionarios';

-- Perfil Financeiro: acompanha as integrações (só ver) e concilia com o extrato
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('financeiro', 'integracoes', 'ver')
on conflict (perfil_id, modulo_id) do nothing;
insert into public.perfil_acoes (perfil_id, acao_id)
select 'financeiro', a from unnest(array['pagar.conciliar', 'receber.conciliar']) a
where not exists (select 1 from public.perfil_acoes where perfil_id = 'financeiro' and acao_id = a);

update public.perfis set descricao = 'Contas a pagar e a receber, extratos e conciliação, fluxo de caixa e cadastros financeiros' where id = 'financeiro';
update public.perfis set descricao = 'Colaboradores (cadastro e acesso), ponto, escala, férias, lançamentos, holerites e documentos' where id = 'rh';
