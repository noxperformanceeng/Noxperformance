-- 051 · Não deixa pagar a PROJEÇÃO de pedido de compra (evita pagar em dobro quando a NF chega)
create or replace function public.pagamento_projecao_pc()
returns trigger language plpgsql set search_path = public as $$
begin
  if exists (select 1 from public.titulos_pagar t where t.id = new.titulo_id and t.origem = 'pedido_compra' and t.projecao) then
    raise exception 'Este título é a previsão de um pedido de compra: registre a NF no pedido (Pedidos de compra › Registrar recebimento) e pague o título real';
  end if;
  return new;
end $$;
drop trigger if exists projecao_pc on public.pagamentos;
create trigger projecao_pc before insert on public.pagamentos for each row execute function public.pagamento_projecao_pc();
