// ERP NOX · sugestão de resposta para pergunta do Mercado Livre (Claude, API da Anthropic)
// Chave só no servidor: segredo ANTHROPIC_API_KEY (Supabase › Edge Functions › Secrets). Modelo: ANTHROPIC_MODELO.
// Nada é enviado ao cliente aqui: a sugestão fica gravada e a equipe confere na tela antes de responder.
import { mlGet, tokenValido, Conta } from '../_shared/ml.ts';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

const PARADAS = new Set('o a os as de da do das dos e em no na nos nas um uma para pra pro com por que se eu meu minha voce vc tem ter esse essa este esta isso ola oi bom dia boa tarde noite amigo serve servir'.split(' '));
const semAc = (t: string) => String(t || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
const palavras = (t: string) => new Set(semAc(t).replace(/[^a-z0-9.\s]/g, ' ').split(/\s+/).filter(w => w.length > 1 && !PARADAS.has(w)));
function parecida(a: Set<string>, b: Set<string>) { let c = 0; a.forEach(w => { if (b.has(w)) c++; }); return c / Math.sqrt(Math.max(a.size, 1) * Math.max(b.size, 1)); }

const REGRAS = `Você responde, em nome da NOX (fabricante de peças automotivas de performance em inox: intakes, defletores, ponteiras, abafadores), perguntas de clientes nos anúncios do Mercado Livre. Sua resposta vira uma SUGESTÃO que um atendente confere antes de enviar.

Como responder:
- Português do Brasil, curto e simpático, no estilo da casa: comece com "{SAUDACAO} amigo," e vá direto ao ponto (1 a 3 frases).
- Baseie-se SÓ no anúncio (título, ficha técnica, descrição) e nas respostas que a NOX já deu a perguntas parecidas. Nunca invente medida, compatibilidade, prazo, estoque ou característica.
- Compatibilidade ("serve no meu carro?"): a BASE DE COMPATIBILIDADE DA NOX é a fonte oficial e vale mais que tudo. Confira marca, modelo, ano, motor e potência (ex.: o mesmo carro pode ter kits diferentes para 116, 127 e 140 cv) e respeite as observações da base. Se o cliente não informou o que falta para decidir (ano, motor, potência), pergunte de forma educada. Fora da base, só afirme que serve se o carro/motor/ano estiver claramente no anúncio ou em resposta anterior da NOX para o mesmo caso. Se não servir e houver na lista "outros anúncios da NOX" um que sirva claramente, indique-o colocando o link dele na resposta. Se não houver certeza, escreva uma resposta prudente e marque alerta "compatibilidade".
- Preço, desconto, pagamento à vista, atacado: escreva uma resposta neutra (sem prometer desconto) e marque alerta "preco".
- Proibido pelo Mercado Livre: telefone, WhatsApp, e-mail, site ou redes sociais, combinar fora do ML, links que não sejam do Mercado Livre.
- Respostas marcadas CORRIGIDA mostram o que a IA errou antes e como o vendedor respondeu: siga a resposta do vendedor.
- Confiança: "alta" = está escrito no anúncio ou já respondemos igual; "media" = dedução razoável; "baixa" = falta informação.
Responda chamando a ferramenta "sugerir_resposta".`;

const FERRAMENTA = {
  name: 'sugerir_resposta',
  description: 'Registra a resposta sugerida para o atendente conferir.',
  input_schema: {
    type: 'object',
    properties: {
      resposta: { type: 'string', description: 'Texto pronto para enviar ao cliente (até 600 caracteres).' },
      confianca: { type: 'string', enum: ['alta', 'media', 'baixa'] },
      alerta: { type: 'string', enum: ['nenhum', 'preco', 'compatibilidade'], description: 'Assunto que a pessoa precisa conferir com atenção.' },
      assunto: { type: 'string', enum: ['compatibilidade', 'prazo_envio', 'frete', 'garantia', 'preco_desconto', 'medida_material', 'instalacao', 'estoque', 'outro'],
        description: 'Assunto principal da pergunta do cliente.' },
      indicar_item: { type: 'string', description: 'MLB do outro anúncio indicado na resposta, ou vazio.' },
      motivo: { type: 'string', description: 'Em uma frase: de onde tirou a resposta (para o atendente conferir).' }
    },
    required: ['resposta', 'confianca', 'alerta', 'assunto', 'motivo']
  }
};

function saudacao(d: Date) {
  const h = Number(new Intl.DateTimeFormat('pt-BR', { hour: 'numeric', hour12: false, timeZone: 'America/Sao_Paulo' }).format(d));
  return h < 12 ? 'Bom dia' : h < 18 ? 'Boa tarde' : 'Boa noite';
}

export async function sugerir(db: SupabaseClient, conta: Conta, id: number) {
  const chave = Deno.env.get('ANTHROPIC_API_KEY');
  const { data: q } = await db.from('ml_perguntas').select('*').eq('id', id).maybeSingle();
  if (!q || q.situacao !== 'UNANSWERED') return { ok: 'nada a sugerir' };
  if (!chave) { await db.from('ml_perguntas').update({ sugestao_erro: 'Resposta sugerida desligada: falta a chave da API da Anthropic', sugestao_em: new Date().toISOString() }).eq('id', id); return { erro: 'sem chave' }; }
  try {
    const token = await tokenValido(db, conta);
    // anúncio: título, ficha técnica e descrição
    const item = await mlGet(token, `/items/${q.item_id}?attributes=id,title,price,attributes,permalink`).catch(() => null);
    const desc = await mlGet(token, `/items/${q.item_id}/description`).catch(() => null);
    const ficha = (item?.attributes ?? []).filter((a: { value_name?: string }) => a.value_name).slice(0, 40)
      .map((a: { name: string; value_name: string }) => `${a.name}: ${a.value_name}`).join('\n');
    // histórico: respostas parecidas (o mesmo anúncio pesa mais)
    const w = palavras(q.texto);
    // respostas que o vendedor CORRIGIU (a IA sugeriu outra coisa) valem mais: é onde a IA aprende
    const { data: hist } = await db.from('ml_perguntas').select('item_id, texto, resposta, sugestao, usou_sugestao').not('resposta', 'is', null).order('criada_em', { ascending: false }).limit(6000);
    const corrigida = (h: { sugestao?: string | null; usou_sugestao?: boolean | null }) => !!h.sugestao && h.usou_sugestao === false;
    const exemplos = (hist ?? []).map(h => ({ h, n: parecida(w, palavras(h.texto)) + (h.item_id === q.item_id ? 0.3 : 0) + (corrigida(h) ? 0.2 : 0) }))
      .filter(o => o.n > 0.25).sort((a, b) => b.n - a.n).slice(0, 15)
      .map(o => `P${o.h.item_id === q.item_id ? ' (mesmo anúncio)' : ''}: ${o.h.texto}\nR${corrigida(o.h) ? ' (CORRIGIDA pelo vendedor; a IA tinha sugerido: "' + String(o.h.sugestao).slice(0, 300) + '")' : ''}: ${o.h.resposta}`).join('\n\n');
    // outros anúncios ativos que podem servir (mesmas palavras do carro/motor)
    const { data: itens } = await db.from('ml_itens').select('item_id, titulo, link, preco').eq('situacao', 'active');
    const outros = (itens ?? []).filter(i => i.item_id !== q.item_id).map(i => ({ i, n: parecida(w, palavras(i.titulo ?? '')) }))
      .filter(o => o.n > 0).sort((a, b) => b.n - a.n).slice(0, 25)
      .map(o => `${o.i.item_id} | ${o.i.titulo} | ${o.i.link}`).join('\n');
    // base de compatibilidade: linhas do SKU deste anúncio + linhas do carro citado na pergunta
    const { data: anu } = await db.from('anuncios').select('sku').eq('anuncio_id', q.item_id);
    const skus = [...new Set((anu ?? []).map(a => String(a.sku ?? '').toUpperCase()).filter(Boolean))];
    const { data: comp } = await db.from('compatibilidades').select('sku, marca, modelo, ano_inicial, ano_final, motorizacao, codigo_motor, combustivel, potencia, observacoes').eq('situacao', 'ativo');
    const wq = palavras(q.texto + ' ' + (item?.title ?? ''));
    // anúncios ativos desta conta por SKU (o SKU do anúncio pode ter sufixo, ex.: ITKFD068KN)
    const { data: anCanal } = await db.from('anuncios').select('sku, anuncio_id').eq('canal_id', q.canal_id).not('sku', 'is', null);
    const ativos = new Map((itens ?? []).map(i => [i.item_id, i.link]));
    const linkDo = (sku: string) => (anCanal ?? []).filter(a => String(a.sku).toUpperCase().startsWith(sku) && ativos.has(a.anuncio_id)).map(a => `${a.anuncio_id} ${ativos.get(a.anuncio_id)}`)[0] ?? '';
    const doSku = (c: { sku: string }) => c.sku.split('/').map((x: string) => x.trim()).filter(Boolean);
    const compat = (comp ?? []).map(c => ({ c, n: (skus.some(k => doSku(c).some((x: string) => k.startsWith(x))) ? 1 : 0)
        + parecida(wq, palavras(`${c.marca} ${c.modelo} ${c.motorizacao ?? ''} ${c.codigo_motor ?? ''}`)) }))
      .filter(o => o.n > 0.2).sort((a, b) => b.n - a.n).slice(0, 40)
      .map(({ c }) => [c.sku, c.marca, c.modelo, `${c.ano_inicial ?? '?'}-${c.ano_final ?? '?'}`, c.motorizacao, c.codigo_motor, c.combustivel, c.potencia, c.observacoes,
        doSku(c).map(linkDo).filter(Boolean).map(l => 'anúncio: ' + l).join(' ; ')].map(v => v ?? '').join(' | ')).join('\n');
    const contexto = `ANÚNCIO DA PERGUNTA (${q.item_id})\nTítulo: ${item?.title ?? ''}\nPreço: ${item?.price ?? ''}\nFicha técnica:\n${ficha}\nDescrição:\n${String(desc?.plain_text ?? '').slice(0, 4000)}

BASE DE COMPATIBILIDADE DA NOX — FONTE OFICIAL (SKU | marca | modelo | anos | motorização | código do motor | combustível | potência | observações | nosso anúncio desse SKU, para indicar)${skus.length ? `\nSKU deste anúncio: ${skus.join(', ')}` : ''}
${compat || '(nada na base para este caso)'}

RESPOSTAS QUE A NOX JÁ DEU A PERGUNTAS PARECIDAS
${exemplos || '(nenhuma)'}

OUTROS ANÚNCIOS DA NOX QUE PODEM SERVIR (MLB | título | link)
${outros || '(nenhum)'}

PERGUNTA DO CLIENTE (${new Date(q.criada_em).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })})
${q.texto}`;
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': chave, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: Deno.env.get('ANTHROPIC_MODELO') || 'claude-sonnet-5-5', max_tokens: 800,
        system: REGRAS.replace('{SAUDACAO}', saudacao(new Date())), tools: [FERRAMENTA], tool_choice: { type: 'auto' },   // este modelo não aceita forçar a ferramenta; as regras pedem para usá-la
        messages: [{ role: 'user', content: contexto }]
      })
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`IA (${r.status}): ${j?.error?.message ?? ''}`);
    let s = (j.content ?? []).find((c: { type: string }) => c.type === 'tool_use')?.input;
    // se respondeu em texto em vez de usar a ferramenta: vira sugestão de confiança baixa, para conferir
    if (!s?.resposta) { const t = (j.content ?? []).filter((c: { type: string }) => c.type === 'text').map((c: { text: string }) => c.text).join('\n').trim();
      if (t) s = { resposta: t, confianca: 'baixa', alerta: 'nenhum', motivo: 'A IA respondeu fora do formato: conferir' }; }
    if (!s?.resposta) throw new Error('IA não devolveu resposta');
    await db.from('ml_perguntas').update({
      sugestao: String(s.resposta).slice(0, 2000), sugestao_confianca: s.confianca, sugestao_alerta: s.alerta === 'nenhum' ? null : s.alerta,
      sugestao_motivo: s.motivo ?? null, assunto: s.assunto ?? null, sugestao_indicado: s.indicar_item || null, sugestao_em: new Date().toISOString(), sugestao_erro: null
    }).eq('id', id);
    return { ok: true };
  } catch (e) {
    const msg = String((e as Error).message ?? e).slice(0, 400);
    await db.from('ml_perguntas').update({ sugestao_erro: msg, sugestao_em: new Date().toISOString() }).eq('id', id);
    return { erro: msg };
  }
}
