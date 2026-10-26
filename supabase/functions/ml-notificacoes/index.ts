// ERP NOX · ml-notificacoes — avisos do Mercado Livre (venda nova/alterada, pagamento, reclamação, pergunta)
// Responde rápido (o ML exige) e processa em seguida: busca a venda completa e atualiza o pedido no sistema.
import { adminDb, buscarEGravarVenda, CLIENT_ID, Conta } from '../_shared/ml.ts';
import { processarPergunta } from '../_shared/perguntas.ts';

Deno.serve(async req => {
  if (req.method !== 'POST') return new Response('ok');
  const n = await req.json().catch(() => null);
  if (!n || String(n.application_id) !== CLIENT_ID()) return new Response('ignorado', { status: 200 });
  const db = adminDb();
  const { data: ev } = await db.from('ml_eventos').insert({ topic: n.topic, resource: n.resource, ml_user_id: n.user_id, tentativas: n.attempts, payload: n }).select('id').single();
  const tarefa = (async () => {
    try {
      const { data: conta } = await db.from('ml_contas').select('*').eq('ml_user_id', n.user_id).eq('situacao', 'ativo').maybeSingle();
      if (!conta) throw new Error('conta não autorizada no sistema');
      if (n.topic === 'questions') {
        // pergunta nova (ou respondida pelo app): grava e a IA escreve o rascunho (tela Comercial › Perguntas ML)
        await processarPergunta(db, conta as Conta, String(n.resource).split('/').pop()!);
        await db.from('ml_eventos').update({ processado_em: new Date().toISOString(), erro: null }).eq('id', ev!.id);
        return;
      }
      let orderId: string | null = null;
      if (['orders_v2', 'orders'].includes(n.topic)) orderId = String(n.resource).split('/').pop()!;
      else if (n.topic === 'payments') {
        // pagamento: acha a venda pelo pedido do pagamento (se não achar, fica registrado para a sincronização)
        const { data } = await db.from('ml_pedidos_brutos').select('ml_order_id').contains('ordem', { payments: [{ id: Number(String(n.resource).split('/').pop()) }] }).maybeSingle();
        orderId = data ? String(data.ml_order_id) : null;
      }
      else if (n.topic === 'shipments') {
        // envio mudou (despachado, entregue, devolvido): acha a venda pelo id do envio
        const envioId = String(n.resource).split('/').pop();
        const { data } = await db.from('pedidos_venda').select('numero_externo').eq('canal_id', conta.canal_id).eq('envio_id', envioId).limit(1).maybeSingle();
        orderId = data?.numero_externo ?? null;
      }
      if (orderId) await buscarEGravarVenda(db, conta as Conta, orderId);
      await db.from('ml_eventos').update({ processado_em: new Date().toISOString(), erro: orderId ? null : 'sem venda ligada (fica para a sincronização)' }).eq('id', ev!.id);
    } catch (e) {
      await db.from('ml_eventos').update({ erro: String((e as Error).message ?? e).slice(0, 500) }).eq('id', ev!.id);
    }
  })();
  // @ts-ignore EdgeRuntime existe no Supabase
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(tarefa); else await tarefa;
  return new Response('ok');
});
