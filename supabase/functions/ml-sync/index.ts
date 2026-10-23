// ERP NOX · ml-sync — busca as vendas de um período no Mercado Livre (botão na tela Canais de venda)
// Só para quem pode editar Canais de venda. Período curto por chamada (a tela divide em semanas).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { adminDb, buscarEGravarVenda, cors, mlGet, tokenValido, Conta } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async req => {
  // pré-verificação do navegador: libera os cabeçalhos que o supabase-js enviar
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { ...cors, 'Access-Control-Allow-Headers': req.headers.get('access-control-request-headers') ?? cors['Access-Control-Allow-Headers'], 'Access-Control-Max-Age': '600' } });
  // Chamada interna (banco/agendamento): completa o envio e a etapa das vendas já guardadas, em lotes
  const db0 = adminDb();
  const { data: cfg } = await db0.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (cfg?.valor && req.headers.get('x-nox-chave') === cfg.valor) {
    const corpo = await req.json().catch(() => ({}));
    if (corpo.acao === 'etapas') {
      const tarefa = (async () => {
        const inicio = Date.now(); let feitos = 0;
        const { data: contas } = await db0.from('ml_contas').select('*').eq('situacao', 'ativo');
        const { data: pend } = await db0.from('ml_pedidos_brutos').select('ml_order_id, canal_id').is('envio', null).not('ordem->shipping->>id', 'is', null).order('ml_order_id', { ascending: false }).limit(400);
        for (const b of pend ?? []) {
          if (Date.now() - inicio > 110_000) break;
          const conta = (contas ?? []).find((c: { canal_id: number }) => c.canal_id === b.canal_id);
          if (!conta) continue;
          try { await buscarEGravarVenda(db0, conta as Conta, b.ml_order_id); feitos++; } catch { /* fica para a próxima */ }
        }
        if ((pend ?? []).length > feitos && feitos > 0)
          await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/ml-sync`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-nox-chave': cfg.valor }, body: JSON.stringify({ acao: 'etapas' }) });
      })();
      // @ts-ignore EdgeRuntime existe no Supabase
      EdgeRuntime.waitUntil(tarefa);
      return resp({ ok: true });
    }
    if (corpo.acao === 'buscar_periodo') {
      // busca vendas de um período longo, semana a semana, continuando sozinho até o fim (pula as já guardadas sem alteração)
      const tarefa = (async () => {
        const inicio = Date.now();
        const { data: conta } = await db0.from('ml_contas').select('*').eq('canal_id', corpo.canal_id).maybeSingle();
        if (!conta) return;
        const token = await tokenValido(db0, conta as Conta);
        let de = new Date(corpo.de + 'T12:00:00Z'); const fim = new Date(corpo.ate + 'T12:00:00Z');
        let offset = Number(corpo.offset ?? 0);
        while (de <= fim) {
          const ate = new Date(Math.min(de.getTime() + 6 * 864e5, fim.getTime()));
          const d1 = de.toISOString().slice(0, 10), d2 = ate.toISOString().slice(0, 10);
          const q = `/orders/search?seller=${conta.ml_user_id}&order.date_created.from=${d1}T00:00:00.000-03:00&order.date_created.to=${d2}T23:59:59.999-03:00&sort=date_asc&limit=50&offset=${offset}`;
          const pag = await mlGet(token, q);
          const lista = pag?.results ?? [];
          const ids = lista.map((o: { id: number }) => o.id);
          const { data: ja } = await db0.from('ml_pedidos_brutos').select('ml_order_id, ordem->>last_updated, processado_em, envio').in('ml_order_id', ids.length ? ids : [0]);
          const igual = new Set((ja ?? []).filter((x: Record<string, unknown>) => x.processado_em && x.envio).map((x: Record<string, unknown>) => `${x.ml_order_id}|${x.last_updated ?? ''}`));
          for (const o of lista) {
            if (Date.now() - inicio > 110_000) {
              await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/ml-sync`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-nox-chave': cfg.valor },
                body: JSON.stringify({ acao: 'buscar_periodo', canal_id: corpo.canal_id, de: d1, ate: corpo.ate, offset }) });
              return;
            }
            if (!igual.has(`${o.id}|${o.last_updated ?? ''}`)) { try { await buscarEGravarVenda(db0, conta as Conta, o.id); } catch { /* segue */ } }
            offset++;
          }
          if (!lista.length || offset >= (pag?.paging?.total ?? 0)) { de = new Date(ate.getTime() + 864e5); offset = 0; }
        }
        await db0.from('ml_contas').update({ ultima_sync: new Date().toISOString() }).eq('id', conta.id);
      })();
      // @ts-ignore EdgeRuntime existe no Supabase
      EdgeRuntime.waitUntil(tarefa);
      return resp({ ok: true });
    }
    return resp({ erro: 'Ação desconhecida' });
  }
  // quem está pedindo (login do sistema)
  const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
  const { data: pode } = await usuario.rpc('pode', { p_modulo: 'canais_venda', p_nivel: 'editar' });
  if (pode !== true) return resp({ erro: 'Sem permissão' });

  const { canal_id, de, ate } = await req.json().catch(() => ({}));
  if (!canal_id || !/^\d{4}-\d{2}-\d{2}$/.test(de ?? '') || !/^\d{4}-\d{2}-\d{2}$/.test(ate ?? '')) return resp({ erro: 'Informe canal, de e até (aaaa-mm-dd)' });
  const db = adminDb();
  const { data: conta } = await db.from('ml_contas').select('*').eq('canal_id', canal_id).maybeSingle();
  if (!conta) return resp({ erro: 'Canal sem conta do ML autorizada' });
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
    return resp({ ...res, erro: String((e as Error).message ?? e) });
  }
});
