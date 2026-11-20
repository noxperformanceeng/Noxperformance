// ERP NOX · shopee-chat — chat dos compradores da Shopee (Seller Chat API)
// Só chamada interna (banco/agendamento, chave x-nox-chave). Ações:
//  · sync: conversas com mensagem nova → grava as mensagens (só o que é novo) e pede a sugestão da IA;
//  · sugerir {id}: resposta pronta da IA para a conversa (fica gravada; a equipe confere e envia);
//  · enviar {id}: envia a resposta escrita na tela (shopee_chat_responder);
//  · amostra: formato devolvido pela Shopee (campos), para conferência — não grava nada.
import { adminDb, shopeeGet, shopeePost, ContaShopee } from '../_shared/shopee.ts';
import { sugerirChat } from './ia.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });
type Db = ReturnType<typeof adminDb>;
const nanoParaIso = (v: unknown) => { const n = Number(v); if (!n) return null; const ms = n > 1e17 ? n / 1e6 : n > 1e14 ? n / 1e3 : n > 1e11 ? n : n * 1000; return new Date(ms).toISOString(); };

async function contas(db: Db) { const { data } = await db.from('shopee_contas').select('*').eq('situacao', 'ativo'); return (data ?? []) as ContaShopee[]; }

// texto legível de qualquer tipo de mensagem (texto, imagem, produto, pedido, figurinha…)
function textoDe(m: Record<string, any>) {
  const c = m.content ?? {}, t = String(m.message_type ?? '');
  if (t === 'text') return String(c.text ?? '');
  if (t === 'image') return '[imagem]';
  if (t === 'sticker') return '[figurinha]';
  if (t === 'item' || t === 'product') return `[anúncio ${c.item_id ?? ''}]`;
  if (t === 'order') return `[pedido ${c.order_sn ?? ''}]`;
  if (t === 'video') return '[vídeo]';
  return c.text ? String(c.text) : `[${t || 'mensagem'}]`;
}

// mensagens de uma conversa (mais novas primeiro); para quando chega numa que já está gravada
async function lerMensagens(db: Db, conta: ContaShopee, conversa: string, conhecidas: Set<string>, limite = 60) {
  const novas: Record<string, any>[] = []; let offset = '';
  for (let pag = 0; pag < 3 && novas.length < limite; pag++) {
    const r = await shopeeGet(db, conta, '/api/v2/sellerchat/get_message', { conversation_id: conversa, page_size: 25, ...(offset ? { offset } : {}) });
    const ms = r?.messages ?? [];
    let parar = false;
    for (const m of ms) { if (conhecidas.has(String(m.message_id))) { parar = true; break; } novas.push(m); }
    offset = r?.page_result?.next_offset ?? '';
    if (parar || !offset || !ms.length) break;
  }
  return novas;
}

async function sync(db: Db) {
  const log: unknown[] = [];
  for (const conta of await contas(db)) {
    const r = await shopeeGet(db, conta, '/api/v2/sellerchat/get_conversation_list', { direction: 'older', type: 'all', page_size: 30 });
    const convs = (r?.conversations ?? []) as Record<string, any>[];
    const ids = convs.map(c => String(c.conversation_id));
    const { data: ja } = await db.from('shopee_conversas').select('id, ultima_msg_id').in('id', ids);
    const ant = new Map((ja ?? []).map(x => [x.id, x.ultima_msg_id]));
    let gravadas = 0;
    for (const c of convs) {
      const id = String(c.conversation_id), ult = String(c.latest_message_id ?? '');
      if (ant.has(id) && ant.get(id) === ult) continue;                 // nada novo nesta conversa
      const { data: kn } = await db.from('shopee_mensagens').select('id').eq('conversa_id', id).order('enviada_em', { ascending: false }).limit(200);
      const novas = await lerMensagens(db, conta, id, new Set((kn ?? []).map(x => x.id)));
      const linhas = novas.map(m => ({
        id: String(m.message_id), conversa_id: id, de_loja: Number(m.from_shop_id) === Number(conta.shop_id) || Number(m.from_id) === Number(conta.shop_id),
        tipo: String(m.message_type ?? ''), texto: textoDe(m).slice(0, 4000), conteudo: m.content ?? null,
        enviada_em: nanoParaIso(m.created_timestamp ?? m.created_timestamp_nano) ?? new Date().toISOString()
      }));
      // conversa (cabeçalho) antes das mensagens
      const ultima = linhas[0];
      // conversa parada há mais de 7 dias não entra como "aguardando" (evita alerta de conversa antiga)
      const ultimaEm = nanoParaIso(c.last_message_timestamp) ?? ultima?.enviada_em ?? null;
      const recente = !!ultimaEm && Date.now() - Date.parse(ultimaEm) < 7 * 864e5;
      const item = novas.find(m => m.content?.item_id)?.content?.item_id, pedido = novas.find(m => m.content?.order_sn)?.content?.order_sn;
      await db.from('shopee_conversas').upsert({
        id, canal_id: conta.canal_id, comprador_id: c.to_id ?? null, comprador_nome: c.to_name ?? null,
        ultima_msg_id: ult || ultima?.id || null, ultima_msg_em: nanoParaIso(c.last_message_timestamp) ?? ultima?.enviada_em ?? null,
        ultima_msg_texto: (ultima?.texto ?? (c.latest_message_content?.text ?? '')).slice(0, 500),
        aguardando: recente && (ultima ? !ultima.de_loja : Number(c.latest_message_from_id) === Number(c.to_id)),   // to_id = comprador
        nao_lidas: Number(c.unread_count ?? 0), atualizado_em: new Date().toISOString(),
        ...(item ? { item_id: String(item) } : {}), ...(pedido ? { order_sn: String(pedido) } : {})
      });
      if (linhas.length) { const { error } = await db.from('shopee_mensagens').upsert(linhas, { onConflict: 'id', ignoreDuplicates: true }); if (error) throw error; gravadas += linhas.length; }
      // comprador mandou mensagem nova: pede a sugestão da IA
      if (recente && ultima && !ultima.de_loja) await sugerirChat(db, conta, id).catch(e => console.error('sugerir', id, e));
    }
    await db.from('shopee_contas').update({ ultima_sync_chat: new Date().toISOString() }).eq('id', conta.id);
    log.push({ conta: conta.id, conversas: convs.length, mensagens: gravadas });
  }
  return log;
}

async function enviar(db: Db, id: string) {
  const { data: c } = await db.from('shopee_conversas').select('*').eq('id', id).maybeSingle();
  if (!c || !c.resposta_pendente) return { erro: 'nada a enviar' };
  const conta = (await contas(db)).find(x => x.canal_id === c.canal_id);
  try {
    if (!conta) throw new Error('loja da Shopee não autorizada no sistema');
    if (!c.comprador_id) throw new Error('comprador desconhecido nesta conversa');
    const r = await shopeePost(db, conta, '/api/v2/sellerchat/send_message', { to_id: Number(c.comprador_id), message_type: 'text', content: { text: c.resposta_pendente } });
    const agora = new Date().toISOString(), mid = String(r?.message_id ?? `sis-${Date.now()}`);
    await db.from('shopee_mensagens').upsert({ id: mid, conversa_id: id, de_loja: true, tipo: 'text', texto: c.resposta_pendente, enviada_em: agora,
      origem: 'sistema', enviada_por: c.respondida_por, sugestao: c.sugestao, usou_sugestao: c.usou_sugestao, assunto: c.assunto }, { onConflict: 'id' });
    await db.from('shopee_conversas').update({ resposta_pendente: null, resposta_erro: null, aguardando: false, ultima_msg_id: mid, ultima_msg_em: agora,
      ultima_msg_texto: String(c.resposta_pendente).slice(0, 500), sugestao: null, sugestao_msg_id: null, atualizado_em: agora }).eq('id', id);
    return { ok: true };
  } catch (e) {
    const msg = String((e as Error).message ?? e).slice(0, 500);
    await db.from('shopee_conversas').update({ resposta_erro: msg, atualizado_em: new Date().toISOString() }).eq('id', id);
    return { erro: msg };
  }
}

async function amostra(db: Db) {
  const conta = (await contas(db))[0]; if (!conta) return { erro: 'sem loja' };
  const r = await shopeeGet(db, conta, '/api/v2/sellerchat/get_conversation_list', { direction: 'older', type: 'all', page_size: 3 });
  const c = (r?.conversations ?? [])[0]; if (!c) return { conversas: 0, chaves_resposta: Object.keys(r ?? {}) };
  const m = await shopeeGet(db, conta, '/api/v2/sellerchat/get_message', { conversation_id: String(c.conversation_id), page_size: 5 });
  const ms = (m?.messages ?? []) as Record<string, any>[];
  return { shop_id: conta.shop_id, chaves_conversa: Object.keys(c), tipos_id: { conversation_id: typeof c.conversation_id, to_id: typeof c.to_id },
    last_message_timestamp: c.last_message_timestamp, latest_message_from_id_e_loja: Number(c.latest_message_from_id) === Number(conta.shop_id),
    chaves_mensagem: ms[0] ? Object.keys(ms[0]) : [], tipos_msg: ms.map(x => x.message_type), chaves_conteudo: ms.map(x => Object.keys(x.content ?? {})),
    created: ms.map(x => x.created_timestamp), de_loja: ms.map(x => Number(x.from_shop_id) === Number(conta.shop_id)), page_result: m?.page_result ?? null };
}

Deno.serve(async req => {
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({}));
  try {
    if (corpo.acao === 'amostra') return resp(await amostra(db));
    if (corpo.acao === 'enviar') return resp(await enviar(db, String(corpo.id)));
    if (corpo.acao === 'sugerir') {
      const { data: c } = await db.from('shopee_conversas').select('canal_id').eq('id', String(corpo.id)).maybeSingle();
      const conta = (await contas(db)).find(x => x.canal_id === c?.canal_id);
      return resp(conta ? await sugerirChat(db, conta, String(corpo.id), true) : { erro: 'conversa não encontrada' });
    }
    if (corpo.acao === 'sync') return resp(await sync(db));
    return resp({ erro: 'ação desconhecida' }, 400);
  } catch (e) { console.error('shopee-chat', corpo.acao, e); return resp({ erro: String((e as Error).message ?? e) }, 500); }
});
