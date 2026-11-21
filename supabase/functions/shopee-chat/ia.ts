// ERP NOX · sugestão de resposta para o chat da Shopee (Claude, API da Anthropic)
// Mesmas fontes da IA das perguntas do Mercado Livre: base de Compatibilidade (oficial), respostas do Paulo e revisadas,
// e os anúncios da loja. Nada é enviado aqui: a sugestão fica gravada e a equipe confere na tela antes de enviar.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import type { ContaShopee } from '../_shared/shopee.ts';

const PARADAS = new Set('o a os as de da do das dos e em no na nos nas um uma para pra pro com por que se eu meu minha voce vc tem ter esse essa este esta isso ola oi bom dia boa tarde noite amigo serve servir'.split(' '));
const semAc = (t: string) => String(t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
// "2,5" vira "2.5" antes de limpar (senão a medida some)
const palavras = (t: string) => new Set(semAc(t).replace(/(\d),(\d)/g, '$1.$2').replace(/[^a-z0-9.\s]/g, ' ').split(/\s+/).filter(w => w.length > 1 && !PARADAS.has(w)));
function parecida(a: Set<string>, b: Set<string>) { let c = 0; a.forEach(w => { if (b.has(w)) c++; }); return c / Math.sqrt(Math.max(a.size, 1) * Math.max(b.size, 1)); }
const linkShopee = (shop: number, item: string) => `https://shopee.com.br/product/${shop}/${item}`;

const REGRAS = `Você é atendente da NOX (Nox Performance Engineering, fabricante de peças automotivas de performance em inox: intakes, defletores, ponteiras, abafadores) no CHAT da loja na Shopee. Sua resposta vira uma SUGESTÃO que um atendente confere antes de enviar.

Como responder:
- Português do Brasil, curto e simpático (1 a 3 frases), respondendo à(s) última(s) mensagem(ns) do comprador, sem repetir o que a loja já disse.
- Se a loja ainda não falou com o comprador nas últimas 12 horas, comece exatamente com "{SAUDACAO}"; senão, vá direto ao ponto.
- Baseie-se SÓ na base de compatibilidade, nos anúncios e nas respostas que a NOX já deu. Nunca invente medida, compatibilidade, prazo, estoque ou característica.
- Compatibilidade: a BASE DE COMPATIBILIDADE DA NOX é a fonte oficial e vale mais que tudo. Confira marca, modelo, ano, motor e potência e respeite as observações. Se faltar informação para decidir (ano, motor, potência), pergunte de forma educada. Sem certeza, resposta prudente e alerta "compatibilidade".
- Se o comprador pede outra medida, versão ou carro, indique o anúncio certo da lista "anúncios da loja na Shopee" com o link completo.
- Preço, desconto, pagamento: resposta neutra (sem prometer desconto) e alerta "preco".
- Pedido já feito (prazo de envio, rastreio, troca, devolução): seja cordial, diga que vai verificar e marque confiança "baixa" se não tiver a informação.
- Proibido pela Shopee: telefone, WhatsApp, e-mail, site, redes sociais, combinar pagamento ou entrega fora da Shopee, links que não sejam da Shopee.
- Respostas marcadas "REVISADA pelo Paulo" ou "resposta do Paulo" são a referência: em conflito, siga as dele.
- Confiança: "alta" = está escrito no anúncio/base ou já respondemos igual; "media" = dedução razoável; "baixa" = falta informação.
Responda chamando a ferramenta "sugerir_resposta".`;

const FERRAMENTA = {
  name: 'sugerir_resposta', description: 'Registra a resposta sugerida para o atendente conferir.',
  input_schema: { type: 'object', properties: {
    resposta: { type: 'string', description: 'Texto pronto para enviar ao comprador (até 600 caracteres).' },
    confianca: { type: 'string', enum: ['alta', 'media', 'baixa'] },
    alerta: { type: 'string', enum: ['nenhum', 'preco', 'compatibilidade'] },
    assunto: { type: 'string', enum: ['compatibilidade', 'prazo_envio', 'frete', 'garantia', 'preco_desconto', 'medida_material', 'instalacao', 'estoque', 'pedido_pos_venda', 'outro'] },
    motivo: { type: 'string', description: 'Em uma frase: de onde tirou a resposta (para o atendente conferir).' }
  }, required: ['resposta', 'confianca', 'alerta', 'assunto', 'motivo'] }
};

function saudacao(d: Date) {
  const h = Number(new Intl.DateTimeFormat('pt-BR', { hour: 'numeric', hour12: false, timeZone: 'America/Sao_Paulo' }).format(d));
  return h < 12 ? 'Ótimo dia, tudo bom?' : h < 18 ? 'Ótima tarde, tudo bom?' : 'Ótima noite, tudo bom?';   // padrão definido pelo Paulo
}

export async function sugerirChat(db: SupabaseClient, conta: ContaShopee, id: string, forcar = false) {
  const chave = Deno.env.get('ANTHROPIC_API_KEY');
  const { data: c } = await db.from('shopee_conversas').select('*').eq('id', id).maybeSingle();
  if (!c || !c.aguardando) return { ok: 'nada a sugerir' };
  const { data: msgs } = await db.from('shopee_mensagens').select('id, de_loja, tipo, texto, enviada_em, conteudo').eq('conversa_id', id).order('enviada_em', { ascending: false }).limit(20);
  const ms = (msgs ?? []).reverse(), ultimaComprador = [...ms].reverse().find(m => !m.de_loja);
  if (!ultimaComprador) return { ok: 'nada a sugerir' };
  if (!forcar && c.sugestao_msg_id === ultimaComprador.id && (c.sugestao || c.sugestao_erro)) return { ok: 'já sugerido' };
  if (!chave) { await db.from('shopee_conversas').update({ sugestao_erro: 'Falta a chave da API da Anthropic', sugestao_em: new Date().toISOString(), sugestao_msg_id: ultimaComprador.id }).eq('id', id); return { erro: 'sem chave' }; }
  try {
    const textoComprador = ms.filter(m => !m.de_loja).slice(-4).map(m => m.texto).join(' ');
    const w = palavras(textoComprador);
    const lojaRecente = ms.some(m => m.de_loja && Date.now() - Date.parse(m.enviada_em) < 12 * 36e5);
    // anúncios da loja na Shopee (o da conversa + os parecidos com o que o comprador escreveu)
    const { data: anus } = await db.from('anuncios').select('anuncio_id, sku, titulo').eq('canal_id', conta.canal_id);
    const daConversa = new Set([c.item_id, ...ms.map(m => m.conteudo?.item_id).filter(Boolean).map(String)].filter(Boolean));
    const vistos = new Set<string>();
    const anuncios = (anus ?? []).filter(a => { if (vistos.has(a.anuncio_id)) return false; vistos.add(a.anuncio_id); return true; })
      .map(a => ({ a, n: (daConversa.has(a.anuncio_id) ? 2 : 0) + parecida(w, palavras(a.titulo ?? '')) })).filter(o => o.n > 0)
      .sort((x, y) => y.n - x.n).slice(0, 25)
      .map(({ a }) => `${daConversa.has(a.anuncio_id) ? '(DA CONVERSA) ' : ''}${a.titulo} | SKU ${a.sku ?? '-'} | ${linkShopee(conta.shop_id, a.anuncio_id)}`).join('\n');
    const skus = (anus ?? []).filter(a => daConversa.has(a.anuncio_id)).map(a => String(a.sku ?? '').toUpperCase()).filter(Boolean);
    // base de compatibilidade (oficial)
    const { data: comp } = await db.from('compatibilidades').select('sku, marca, modelo, ano_inicial, ano_final, motorizacao, codigo_motor, combustivel, potencia, observacoes').eq('situacao', 'ativo');
    const doSku = (x: { sku: string }) => x.sku.split('/').map((s: string) => s.trim()).filter(Boolean);
    const compat = (comp ?? []).map(x => ({ x, n: (skus.some(k => doSku(x).some((s: string) => k.startsWith(s))) ? 1 : 0) + parecida(w, palavras(`${x.marca} ${x.modelo} ${x.motorizacao ?? ''} ${x.codigo_motor ?? ''}`)) }))
      .filter(o => o.n > 0.2).sort((a, b) => b.n - a.n).slice(0, 30)
      .map(({ x }) => [x.sku, x.marca, x.modelo, `${x.ano_inicial ?? '?'}-${x.ano_final ?? '?'}`, x.motorizacao, x.codigo_motor, x.combustivel, x.potencia, x.observacoes].map(v => v ?? '').join(' | ')).join('\n');
    // respostas da NOX a perguntas parecidas (Mercado Livre: do Paulo e revisadas têm peso maior)
    const { data: hist } = await db.from('ml_perguntas').select('texto, resposta, respondida_em, sugestao, revisao, revisao_texto').not('resposta', 'is', null).order('criada_em', { ascending: false }).limit(6000);
    type H = { texto: string; resposta: string; respondida_em: string | null; sugestao: string | null; revisao: string | null; revisao_texto: string | null };
    const certa = (h: H) => h.revisao === 'ia' ? h.sugestao : h.revisao === 'nenhum' ? h.revisao_texto : h.resposta;
    const doPaulo = (h: H) => !!h.respondida_em && h.respondida_em < '2026-06-01';
    const exemplos = ((hist ?? []) as H[]).filter(h => certa(h)).map(h => ({ h, n: parecida(w, palavras(h.texto)) + (h.revisao ? 0.3 : doPaulo(h) ? 0.25 : 0) }))
      .filter(o => o.n > 0.25).sort((a, b) => b.n - a.n).slice(0, 12)
      .map(o => `P: ${o.h.texto}\nR${o.h.revisao ? ' (REVISADA pelo Paulo)' : doPaulo(o.h) ? ' (resposta do Paulo)' : ''}: ${certa(o.h)}`).join('\n\n');
    const conversa = ms.map(m => `${m.de_loja ? 'LOJA' : 'COMPRADOR'} (${new Date(m.enviada_em).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}): ${m.texto}`).join('\n');
    const contexto = `BASE DE COMPATIBILIDADE DA NOX — FONTE OFICIAL (SKU | marca | modelo | anos | motorização | código do motor | combustível | potência | observações)
${compat || '(nada na base para este caso)'}

ANÚNCIOS DA LOJA NA SHOPEE (título | SKU | link)
${anuncios || '(nenhum)'}

RESPOSTAS QUE A NOX JÁ DEU A PERGUNTAS PARECIDAS (Mercado Livre)
${exemplos || '(nenhuma)'}
${c.order_sn ? `\nPEDIDO CITADO NA CONVERSA: ${c.order_sn}\n` : ''}
CONVERSA COM O COMPRADOR${c.comprador_nome ? ` (${c.comprador_nome})` : ''} — a loja ${lojaRecente ? 'JÁ falou' : 'NÃO falou'} com ele nas últimas 12 horas
${conversa}`;
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST', headers: { 'x-api-key': chave, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model: Deno.env.get('ANTHROPIC_MODELO') || 'claude-sonnet-5-5', max_tokens: 2000,
        system: REGRAS.replace('{SAUDACAO}', saudacao(new Date())), tools: [FERRAMENTA], tool_choice: { type: 'auto' },
        messages: [{ role: 'user', content: contexto }] })
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`IA (${r.status}): ${j?.error?.message ?? ''}`);
    let s = (j.content ?? []).find((x: { type: string }) => x.type === 'tool_use')?.input;
    if (!s?.resposta) { const t = (j.content ?? []).filter((x: { type: string }) => x.type === 'text').map((x: { text: string }) => x.text).join('\n').trim();
      if (t) s = { resposta: t, confianca: 'baixa', alerta: 'nenhum', motivo: 'A IA respondeu fora do formato: conferir' }; }
    if (!s?.resposta) throw new Error(`IA não devolveu resposta (${j.stop_reason ?? 'sem motivo'})`);
    await db.from('shopee_conversas').update({ sugestao: String(s.resposta).slice(0, 2000), sugestao_confianca: s.confianca, sugestao_alerta: s.alerta === 'nenhum' ? null : s.alerta,
      sugestao_motivo: s.motivo ?? null, assunto: s.assunto ?? null, sugestao_msg_id: ultimaComprador.id, sugestao_em: new Date().toISOString(), sugestao_erro: null }).eq('id', id);
    return { ok: true };
  } catch (e) {
    const msg = String((e as Error).message ?? e).slice(0, 400);
    await db.from('shopee_conversas').update({ sugestao_erro: msg, sugestao_em: new Date().toISOString(), sugestao_msg_id: ultimaComprador.id }).eq('id', id);
    return { erro: msg };
  }
}
