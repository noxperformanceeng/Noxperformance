// ERP NOX · ml-sync — busca as vendas de um período no Mercado Livre (botão na tela Canais de venda)
// Só para quem pode editar Canais de venda. Período curto por chamada (a tela divide em semanas).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { adminDb, buscarEGravarVenda, cors, mlGet, tokenValido, Conta } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  // quem está pedindo (login do sistema)
  const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
  const { data: pode } = await usuario.rpc('pode', { p_modulo: 'canais_venda', p_nivel: 'editar' });
  if (pode !== true) return resp({ erro: 'Sem permissão' }, 403);

  const { canal_id, de, ate } = await req.json().catch(() => ({}));
  if (!canal_id || !/^\d{4}-\d{2}-\d{2}$/.test(de ?? '') || !/^\d{4}-\d{2}-\d{2}$/.test(ate ?? '')) return resp({ erro: 'Informe canal, de e até (aaaa-mm-dd)' }, 400);
  const db = adminDb();
  const { data: conta } = await db.from('ml_contas').select('*').eq('canal_id', canal_id).maybeSingle();
  if (!conta) return resp({ erro: 'Canal sem conta do ML autorizada' }, 400);
  const inicio = Date.now(), res = { encontradas: 0, gravadas: 0, puladas: 0, erros: [] as string[], parcial: false };
  try {
    const token = await tokenValido(db, conta as Conta);
    let offset = 0;
    while (true) {
      const q = `/orders/search?seller=${conta.ml_user_id}&order.date_created.from=${de}T00:00:00.000-03:00&order.date_created.to=${ate}T23:59:59.999-03:00&sort=date_asc&limit=50&offset=${offset}`;
      const pag = await mlGet(token, q);
      const lista = pag?.results ?? [];
      res.encontradas = pag?.paging?.total ?? res.encontradas;
      // venda já guardada e sem alteração no ML desde então: pula (permite retomar um período parcial sem refazer)
      const ids = lista.map((o: { id: number }) => o.id);
      const { data: ja } = await db.from('ml_pedidos_brutos').select('ml_order_id, ordem->>last_updated, ordem->>date_last_updated, processado_em').in('ml_order_id', ids.length ? ids : [0]);
      const igual = new Set((ja ?? []).filter((x: Record<string, unknown>) => x.processado_em).map((x: Record<string, unknown>) => `${x.ml_order_id}|${x.last_updated ?? x.date_last_updated ?? ''}`));
      for (const o of lista) {
        if (Date.now() - inicio > 120_000) { res.parcial = true; break; }   // limite de tempo da função: a tela chama de novo
        if (igual.has(`${o.id}|${o.last_updated ?? o.date_last_updated ?? ''}`)) { res.puladas++; continue; }
        try { await buscarEGravarVenda(db, conta as Conta, o.id); res.gravadas++; }
        catch (e) { res.erros.push(`${o.id}: ${String((e as Error).message ?? e).slice(0, 160)}`); }
      }
      offset += lista.length;
      if (res.parcial || !lista.length || offset >= (pag?.paging?.total ?? 0)) break;
    }
    await db.from('ml_contas').update({ ultima_sync: new Date().toISOString() }).eq('id', conta.id);
    return resp(res);
  } catch (e) {
    return resp({ ...res, erro: String((e as Error).message ?? e) }, 500);
  }
});
