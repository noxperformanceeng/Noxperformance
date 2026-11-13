-- =====================================================================
-- 113 · Excluir anexo enviado por engano (contas a pagar / receber)
--  · Antes (066): só o master excluía anexo. Quem anexava o arquivo errado não tinha como desfazer.
--  · Agora: quem enviou o arquivo pode excluí-lo por até 7 dias (desde que ainda possa lançar títulos).
--    O master continua podendo excluir qualquer anexo, a qualquer tempo.
--  · Vale para o registro do anexo e para o arquivo no armazenamento "financeiro".
--  · A exclusão fica registrada na auditoria (titulos_anexos já é auditada desde a 066).
-- =====================================================================
drop policy if exists "excluir anexos" on public.titulos_anexos;
create policy "excluir anexos" on public.titulos_anexos for delete to authenticated using (
  (select public.eh_admin())
  or (criado_por = (select auth.uid()) and criado_em > now() - interval '7 days'
      and ((tipo = 'pagar' and (select public.pode('pagar', 'criar'))) or (tipo = 'receber' and (select public.pode('receber', 'criar')))))
);

drop policy if exists "financeiro excluir" on storage.objects;
create policy "financeiro excluir" on storage.objects for delete to authenticated using (
  bucket_id = 'financeiro' and (
    (select public.eh_admin())
    or (owner_id = (select auth.uid())::text and created_at > now() - interval '7 days'
        and ((split_part(name, '/', 1) = 'pagar' and (select public.pode('pagar', 'criar')))
          or (split_part(name, '/', 1) = 'receber' and (select public.pode('receber', 'criar')))))
  )
);
