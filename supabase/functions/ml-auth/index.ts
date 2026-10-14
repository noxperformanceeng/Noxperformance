// ERP NOX · ml-auth — retorno da autorização do Mercado Livre
// O usuário principal da conta clica em "Permitir"; o ML manda para cá um código, que é trocado pelos acessos
// e guardado na conta (ml_contas) ligada ao canal de venda escolhido na tela. Sem login do sistema (o ML chama direto).
import { adminDb, trocarCodigo, mlGet } from '../_shared/ml.ts';

const pagina = (titulo: string, texto: string, ok: boolean) => new Response(
  `<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${titulo}</title>
  <body style="font-family:system-ui,sans-serif;max-width:520px;margin:60px auto;padding:0 16px;color:#222">
  <h2 style="color:${ok ? '#1a7f37' : '#b42318'}">${titulo}</h2><p>${texto}</p><p style="color:#777">Pode fechar esta janela.</p></body></html>`,
  { headers: { 'Content-Type': 'text/html; charset=utf-8' }, status: ok ? 200 : 400 });

const esc = (s: string) => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));

Deno.serve(async req => {
  const url = new URL(req.url);
  const code = url.searchParams.get('code'), state = url.searchParams.get('state');
  if (url.searchParams.get('error')) return pagina('Autorização não concluída', esc(url.searchParams.get('error_description') ?? url.searchParams.get('error')!), false);
  if (!code || !state || !/^[0-9a-f-]{36}$/.test(state)) return pagina('Link inválido', 'Gere um novo link de autorização na tela Canais de venda.', false);
  const db = adminDb();
  const { data: aut } = await db.from('ml_autorizacoes').select('*').eq('state', state).maybeSingle();
  if (!aut || aut.usado_em || Date.now() - Date.parse(aut.criado_em) > 60 * 60 * 1000)
    return pagina('Link vencido ou já usado', 'Gere um novo link de autorização na tela Canais de venda.', false);
  try {
    const t = await trocarCodigo(code);
    const eu = await mlGet(t.access_token, '/users/me');
    // a mesma conta do ML não pode ficar em dois canais
    const { data: outro } = await db.from('ml_contas').select('canal_id').eq('ml_user_id', t.user_id).maybeSingle();
    if (outro && outro.canal_id !== aut.canal_id) return pagina('Conta já ligada a outro canal', `A conta ${esc(eu?.nickname ?? String(t.user_id))} já está autorizada em outro canal de venda.`, false);
    const { error } = await db.from('ml_contas').upsert({
      canal_id: aut.canal_id, ml_user_id: t.user_id, nickname: eu?.nickname ?? null, access_token: t.access_token, refresh_token: t.refresh_token,
      expira_em: new Date(Date.now() + t.expires_in * 1000).toISOString(), escopos: t.scope, autorizado_em: new Date().toISOString(),
      autorizado_por: aut.criado_por, situacao: 'ativo', ultimo_erro: null, atualizado_em: new Date().toISOString(),
    }, { onConflict: 'canal_id' });
    if (error) throw error;
    await db.from('ml_autorizacoes').update({ usado_em: new Date().toISOString() }).eq('state', state);
    await db.from('canais_venda').update({ id_externo: String(t.user_id) }).eq('id', aut.canal_id);
    return pagina('Conta autorizada', `A conta <b>${esc(eu?.nickname ?? String(t.user_id))}</b> foi ligada ao sistema da NOX (somente leitura).`, true);
  } catch (e) {
    console.error(e);
    return pagina('Não foi possível autorizar', esc(String((e as Error).message ?? e)).slice(0, 300), false);
  }
});
