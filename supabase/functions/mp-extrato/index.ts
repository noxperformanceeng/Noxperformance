// ERP NOX · mp-extrato — extrato (relatório de liberações) das contas Mercado Pago ligadas às contas do ML
// Usa a mesma autorização das contas do ML (o usuário do ML é o mesmo do Mercado Pago).
// 'gerar' pede o relatório do período; 'listar' mostra os prontos; 'baixar' devolve o CSV para a tela de conciliação importar.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { adminDb, cors, tokenValido, Conta, MP_API } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

async function mp(token: string, metodo: string, caminho: string, corpo?: unknown) {
  const r = await fetch(MP_API + caminho, { method: metodo, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: '*/*' }, body: corpo ? JSON.stringify(corpo) : undefined });
  const texto = await r.text();
  let j: unknown = texto; try { j = JSON.parse(texto); } catch { /* CSV */ }
  return { status: r.status, corpo: j };
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { ...cors, 'Access-Control-Allow-Headers': req.headers.get('access-control-request-headers') ?? cors['Access-Control-Allow-Headers'], 'Access-Control-Max-Age': '600' } });
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  const interno = !!cfg?.valor && req.headers.get('x-nox-chave') === cfg.valor;
  if (!interno) {
    const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: pode } = await usuario.rpc('pode', { p_modulo: 'conciliacao', p_nivel: 'editar' });
    if (pode !== true) return resp({ erro: 'Sem permissão' });
  }
  const corpo = await req.json().catch(() => ({}));
  const { data: contas } = await db.from('ml_contas').select('*').eq('situacao', 'ativo');
  const lista = (contas ?? []).filter((c: { canal_id: number }) => !corpo.canal_id || c.canal_id === Number(corpo.canal_id));
  const out: Record<string, unknown> = {};
  for (const c of lista) {
    try {
      const token = await tokenValido(db, c as Conta);
      if (corpo.acao === 'teste' || corpo.acao === 'listar') {
        out[c.canal_id] = await mp(token, 'GET', '/v1/account/release_report/list');
      } else if (corpo.acao === 'config') {
        out[c.canal_id] = await mp(token, 'GET', '/v1/account/release_report/config');
      } else if (corpo.acao === 'criar_config') {
        // colunas que a tela de conciliação lê (nomes em inglês, separador vírgula, fuso de Brasília)
        const colunas = ['DATE','SOURCE_ID','EXTERNAL_REFERENCE','RECORD_TYPE','DESCRIPTION','NET_CREDIT_AMOUNT','NET_DEBIT_AMOUNT','GROSS_AMOUNT',
          'MP_FEE_AMOUNT','FINANCING_FEE_AMOUNT','SHIPPING_FEE_AMOUNT','TAXES_AMOUNT','COUPON_AMOUNT','INSTALLMENTS','PAYMENT_METHOD',
          'TRANSACTION_APPROVAL_DATE','ORDER_ID','SHIPPING_ID','PACK_ID','BALANCE_AMOUNT'];
        out[c.canal_id] = await mp(token, 'POST', '/v1/account/release_report/config', { file_name_prefix: 'nox-extrato', include_withdrawal_at_end: false,
          detailed: true, execute_after_withdrawal: false, separator: ',', display_timezone: 'GMT-03', report_translation: 'en', scheduled: false,
          frequency: corpo.frequencia ?? { hour: 0, type: 'monthly', value: 1 }, columns: (corpo.colunas ?? colunas).map((key: string) => ({ key })) });
      } else if (corpo.acao === 'gerar') {
        out[c.canal_id] = await mp(token, 'POST', '/v1/account/release_report', { begin_date: `${corpo.de}T00:00:00Z`, end_date: `${corpo.ate}T23:59:59Z` });
      } else if (corpo.acao === 'baixar') {
        const r = await mp(token, 'GET', `/v1/account/release_report/${encodeURIComponent(corpo.arquivo)}`);
        out[c.canal_id] = { status: r.status, csv: typeof r.corpo === 'string' ? r.corpo : JSON.stringify(r.corpo) };
      } else out[c.canal_id] = 'ação desconhecida';
    } catch (e) { out[c.canal_id] = String((e as Error).message ?? e); }
  }
  if (corpo.acao === 'teste') await db.from('integracao_config').upsert({ chave: 'mp_teste', valor: JSON.stringify(out).slice(0, 20000) });
  return resp(out);
});
