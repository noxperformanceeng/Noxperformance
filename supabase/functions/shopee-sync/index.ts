// ERP NOX · shopee-sync — busca as vendas da Shopee
// Interno (cron/banco, chave x-nox-chave): {acao:'recentes'} = alteradas nas últimas 48 h; {acao:'periodo', canal_id, dias|de/ate}.
// Tela (login, quem pode editar Canais de venda): {canal_id, de, ate} = busca o período (aaaa-mm-dd).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { adminDb, buscarEGravarVendas, cors, listarVendas, ContaShopee } from '../_shared/shopee.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const seg = (d: string, fim = false) => Math.floor(Date.parse(`${d}T${fim ? '23:59:59' : '00:00:00'}-03:00`) / 1000);

async function rodar(db: ReturnType<typeof adminDb>, conta: ContaShopee, de: number, ate: number, campo: 'create_time' | 'update_time') {
  const lista = await listarVendas(db, conta, de, ate, campo);
  const r = await buscarEGravarVendas(db, conta, lista);
  await db.from('shopee_contas').update({ ultima_sync: new Date().toISOString(), ...(r.erros.length ? { ultimo_erro: r.erros[0] } : { ultimo_erro: null }) }).eq('id', conta.id);
  return { encontradas: lista.length, ...r };
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { ...cors, 'Access-Control-Allow-Headers': req.headers.get('access-control-request-headers') ?? cors['Access-Control-Allow-Headers'] } });
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  const corpo = await req.json().catch(() => ({}));
  if (cfg?.valor && req.headers.get('x-nox-chave') === cfg.valor) {
    const tarefa = (async () => {
      const { data: contas } = await db.from('shopee_contas').select('*').eq('situacao', 'ativo');
      for (const conta of (contas ?? []) as ContaShopee[]) {
        if (corpo.canal_id && conta.canal_id !== Number(corpo.canal_id)) continue;
        const fim = Math.floor(Date.now() / 1000);
        try {
          if (corpo.acao === 'recentes') await rodar(db, conta, fim - 2 * 86400, fim, 'update_time');
          else if (corpo.acao === 'periodo') await rodar(db, conta, corpo.de ? seg(corpo.de) : fim - Number(corpo.dias ?? 30) * 86400, corpo.ate ? seg(corpo.ate, true) : fim, 'create_time');
        } catch (e) { await db.from('shopee_contas').update({ ultimo_erro: String((e as Error).message ?? e).slice(0, 500) }).eq('id', conta.id); }
      }
    })();
    // @ts-ignore EdgeRuntime existe no Supabase
    EdgeRuntime.waitUntil(tarefa);
    return resp({ ok: true });
  }
  const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
  const { data: pode } = await usuario.rpc('pode', { p_modulo: 'canais_venda', p_nivel: 'editar' });
  if (pode !== true) return resp({ erro: 'Sem permissão' });
  const { canal_id, de, ate } = corpo;
  if (!canal_id || !/^\d{4}-\d{2}-\d{2}$/.test(de ?? '') || !/^\d{4}-\d{2}-\d{2}$/.test(ate ?? '')) return resp({ erro: 'Informe canal, de e até (aaaa-mm-dd)' });
  const { data: conta } = await db.from('shopee_contas').select('*').eq('canal_id', canal_id).maybeSingle();
  if (!conta) return resp({ erro: 'Canal sem loja Shopee autorizada' });
  try { return resp(await rodar(db, conta as ContaShopee, seg(de), seg(ate, true), 'create_time')); }
  catch (e) { return resp({ erro: String((e as Error).message ?? e) }); }
});
