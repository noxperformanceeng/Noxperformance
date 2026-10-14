// ERP NOX · funções comuns da integração com o Mercado Livre (somente leitura)
// Os acessos (tokens) ficam na tabela ml_contas, que só o servidor lê. Nada disso vai para o navegador.
import { createClient, SupabaseClient } from 'npm:@supabase/supabase-js@2';

export const ML_API = 'https://api.mercadolibre.com';
export const MP_API = 'https://api.mercadopago.com';
export const REDIRECT_URI = 'https://qijeqdfhwwruhoruvvgb.supabase.co/functions/v1/ml-auth';

export const CLIENT_ID = () => Deno.env.get('ML_CLIENT_ID') ?? '';
export const CLIENT_SECRET = () => Deno.env.get('ML_CLIENT_SECRET') ?? '';

export function adminDb(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
}

export type Conta = { id: number; canal_id: number; ml_user_id: number; access_token: string; refresh_token: string; expira_em: string };

async function trocarToken(params: Record<string, string>) {
  const r = await fetch(`${ML_API}/oauth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
    body: new URLSearchParams({ client_id: CLIENT_ID(), client_secret: CLIENT_SECRET(), ...params }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`ML oauth ${r.status}: ${j.error ?? ''} ${j.message ?? ''}`.trim());
  return j as { access_token: string; refresh_token: string; expires_in: number; user_id: number; scope: string };
}

export function trocarCodigo(code: string) {
  return trocarToken({ grant_type: 'authorization_code', code, redirect_uri: REDIRECT_URI });
}

// Devolve um token válido; renova quando faltam menos de 10 min. O refresh token é de uso único:
// se outra execução já renovou, relê a conta e usa o token novo.
export async function tokenValido(db: SupabaseClient, conta: Conta): Promise<string> {
  if (conta.expira_em && Date.parse(conta.expira_em) - Date.now() > 10 * 60 * 1000) return conta.access_token;
  try {
    const t = await trocarToken({ grant_type: 'refresh_token', refresh_token: conta.refresh_token });
    const expira = new Date(Date.now() + t.expires_in * 1000).toISOString();
    await db.from('ml_contas').update({ access_token: t.access_token, refresh_token: t.refresh_token, expira_em: expira, situacao: 'ativo', ultimo_erro: null, atualizado_em: new Date().toISOString() }).eq('id', conta.id);
    conta.access_token = t.access_token; conta.refresh_token = t.refresh_token; conta.expira_em = expira;
    return t.access_token;
  } catch (e) {
    const { data } = await db.from('ml_contas').select('*').eq('id', conta.id).single();
    if (data && data.refresh_token !== conta.refresh_token && Date.parse(data.expira_em) > Date.now()) { Object.assign(conta, data); return data.access_token; }
    await db.from('ml_contas').update({ situacao: 'erro', ultimo_erro: String(e).slice(0, 500) }).eq('id', conta.id);
    throw e;
  }
}

export async function mlGet(token: string, caminho: string, base = ML_API, extra: Record<string, string> = {}) {
  for (let tentativa = 0; tentativa < 3; tentativa++) {
    const r = await fetch(base + caminho, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json', ...extra } });
    if (r.status === 429 || r.status >= 500) { await new Promise(ok => setTimeout(ok, 800 * (tentativa + 1))); continue; }
    if (r.status === 404) return null;
    const j = await r.json().catch(() => null);
    if (!r.ok) throw new Error(`GET ${caminho} ${r.status}: ${j?.message ?? ''}`);
    return j;
  }
  throw new Error(`GET ${caminho}: muitas tentativas`);
}

// Busca a venda completa (pedido + custos do envio + pagamentos no Mercado Pago), guarda o bruto e processa
export async function buscarEGravarVenda(db: SupabaseClient, conta: Conta, orderId: string | number) {
  const token = await tokenValido(db, conta);
  const ordem = await mlGet(token, `/orders/${orderId}`, ML_API, { 'x-format-new': 'true' });
  if (!ordem) return null;
  let envioCustos = null;
  if (ordem.shipping?.id) {
    envioCustos = await mlGet(token, `/shipments/${ordem.shipping.id}/costs`).catch(() => null);
    const envio = await mlGet(token, `/shipments/${ordem.shipping.id}`, ML_API, { 'x-format-new': 'true' }).catch(() => null);
    if (envio && envioCustos) envioCustos.logistic_type = envio.logistic?.type ?? envio.logistic_type ?? null;
    if (envio && envioCustos) envioCustos.tracking_number = envio.tracking_number ?? null;
  }
  const pagamentos = [];
  for (const p of ordem.payments ?? []) {
    const det = await mlGet(token, `/v1/payments/${p.id}`, MP_API).catch(() => null);
    pagamentos.push(det ?? p);
  }
  const { error } = await db.from('ml_pedidos_brutos').upsert({ ml_order_id: ordem.id, canal_id: conta.canal_id, ordem, envio_custos: envioCustos, pagamentos, buscado_em: new Date().toISOString(), processado_em: null });
  if (error) throw error;
  const { error: e2 } = await db.rpc('processar_pedido_ml', { p_ml_order_id: ordem.id });
  if (e2) { await db.from('ml_pedidos_brutos').update({ erro: e2.message }).eq('ml_order_id', ordem.id); throw e2; }
  if (envioCustos?.tracking_number) await db.from('pedidos_venda').update({ codigo_rastreio: envioCustos.tracking_number }).eq('canal_id', conta.canal_id).eq('numero_externo', String(ordem.id));
  return ordem.id;
}

export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
