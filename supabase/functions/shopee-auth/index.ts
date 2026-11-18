// ERP NOX · shopee-auth — autorização da loja Shopee
// ?inicio=<state>: assina e manda para a Shopee. Retorno (?state, code, shop_id): troca o código pelos acessos e guarda
// em shopee_contas, ligado ao canal escolhido na tela. Sem login do sistema (a Shopee chama direto).
import { adminDb, linkAutorizacao, trocarCodigo, shopeeGet, ContaShopee } from '../_shared/shopee.ts';

const TELA = 'https://noxperformanceeng.github.io/Noxperformance/pages/cadastros/canais-venda.html';
const voltar = (titulo: string, texto: string, ok: boolean, canal?: number) => {
  const u = new URL(TELA);
  u.searchParams.set('ml', ok ? 'ok' : 'erro');
  u.searchParams.set('msg', `${titulo}: ${texto}`.slice(0, 300));
  if (canal) u.searchParams.set('canal', String(canal));
  return new Response(null, { status: 302, headers: { Location: u.toString() } });
};
const uuid = (s: string | null) => !!s && /^[0-9a-f-]{36}$/.test(s);

Deno.serve(async req => {
  const url = new URL(req.url), db = adminDb();
  const inicio = url.searchParams.get('inicio');
  if (inicio) {
    if (!uuid(inicio)) return voltar('Link inválido', 'Gere um novo link em Canais de venda.', false);
    const { data: aut } = await db.from('shopee_autorizacoes').select('*').eq('state', inicio).maybeSingle();
    if (!aut || aut.usado_em || Date.now() - Date.parse(aut.criado_em) > 60 * 60 * 1000) return voltar('Link vencido', 'Gere um novo link em Canais de venda.', false);
    try { return new Response(null, { status: 302, headers: { Location: await linkAutorizacao(inicio) } }); }
    catch (e) { return voltar('Integração não configurada', String((e as Error).message ?? e), false); }
  }
  const state = url.searchParams.get('state'), code = url.searchParams.get('code'), shopId = Number(url.searchParams.get('shop_id'));
  if (!uuid(state) || !code || !shopId) return voltar('Autorização não concluída', 'A Shopee não devolveu a loja. Tente de novo.', false);
  const { data: aut } = await db.from('shopee_autorizacoes').select('*').eq('state', state).maybeSingle();
  if (!aut || aut.usado_em || Date.now() - Date.parse(aut.criado_em) > 60 * 60 * 1000) return voltar('Link vencido ou já usado', 'Gere um novo link em Canais de venda.', false);
  try {
    const t = await trocarCodigo(code, shopId);
    const { data: outro } = await db.from('shopee_contas').select('canal_id').eq('shop_id', shopId).maybeSingle();
    if (outro && outro.canal_id !== aut.canal_id) return voltar('Loja já ligada a outro canal', `A loja ${shopId} já está em outro canal de venda.`, false);
    const { data: conta, error } = await db.from('shopee_contas').upsert({
      canal_id: aut.canal_id, shop_id: shopId, access_token: t.access_token, refresh_token: t.refresh_token,
      expira_em: new Date(Date.now() + t.expire_in * 1000).toISOString(), refresh_expira_em: new Date(Date.now() + 30 * 864e5).toISOString(),
      autorizado_em: new Date().toISOString(), autorizado_por: aut.criado_por, situacao: 'ativo', ultimo_erro: null, atualizado_em: new Date().toISOString(),
    }, { onConflict: 'canal_id' }).select('*').single();
    if (error) throw error;
    const info = await shopeeGet(db, conta as ContaShopee, '/api/v2/shop/get_shop_info').catch(() => null);
    if (info?.shop_name) await db.from('shopee_contas').update({ loja: info.shop_name }).eq('id', conta.id);
    await db.from('shopee_autorizacoes').update({ usado_em: new Date().toISOString() }).eq('state', state);
    await db.from('canais_venda').update({ id_externo: String(shopId) }).eq('id', aut.canal_id);
    // primeira busca: vendas dos últimos 30 dias
    const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
    await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/shopee-sync`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-nox-chave': cfg?.valor ?? '' },
      body: JSON.stringify({ acao: 'periodo', canal_id: aut.canal_id, dias: 30 }) }).catch(() => null);
    return voltar('Loja autorizada', `A loja ${info?.shop_name ?? shopId} foi ligada ao sistema. As vendas dos últimos 30 dias estão chegando.`, true, aut.canal_id);
  } catch (e) {
    console.error(e);
    return voltar('Não foi possível autorizar', String((e as Error).message ?? e).slice(0, 250), false);
  }
});
