// ERP NOX · sugestão de resposta para pergunta do Mercado Livre (Claude, API da Anthropic)
// Chave só no servidor: segredo ANTHROPIC_API_KEY (Supabase › Edge Functions › Secrets). Modelo: ANTHROPIC_MODELO.
// Nada é enviado ao cliente aqui: a sugestão fica gravada e a equipe confere na tela antes de responder.
import { mlGet, tokenValido, Conta } from '../_shared/ml.ts';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

const PARADAS = new Set('o a os as de da do das dos e em no na nos nas um uma para pra pro com por que se eu meu minha voce vc tem ter esse essa este esta isso ola oi bom dia boa tarde noite amigo serve servir'.split(' '));
const semAc = (t: string) => String(t || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
// "2,5" vira "2.5" antes de limpar (senão a medida some)
const palavras = (t: string) => new Set(semAc(t).replace(/(\d),(\d)/g, '$1.$2').replace(/[^a-z0-9.\s]/g, ' ').split(/\s+/).filter(w => w.length > 1 && !PARADAS.has(w)));
function parecida(a: Set<string>, b: Set<string>) { let c = 0; a.forEach(w => { if (b.has(w)) c++; }); return c / Math.sqrt(Math.max(a.size, 1) * Math.max(b.size, 1)); }

const REGRAS = `Você responde, em nome da NOX (fabricante de peças automotivas de performance em inox: intakes, defletores, ponteiras, abafadores), perguntas de clientes nos anúncios do Mercado Livre. Sua resposta vira uma SUGESTÃO que um atendente confere antes de enviar.

Como responder:
- Português do Brasil, curto e simpático, no estilo da casa: comece exatamente com "{SAUDACAO}" e vá direto ao ponto (1 a 3 frases).
- Baseie-se SÓ no anúncio (título, ficha técnica, descrição) e nas respostas que a NOX já deu a perguntas parecidas. Nunca invente medida, compatibilidade, prazo, estoque ou característica.
- Compatibilidade ("serve no meu carro?"): a BASE DE COMPATIBILIDADE DA NOX é a fonte oficial e vale mais que tudo. Confira marca, modelo, ano, motor e potência (ex.: o mesmo carro pode ter kits diferentes para 116, 127 e 140 cv) e respeite as observações da base. Se o cliente não informou o que falta para decidir (ano, motor, potência), pergunte de forma educada. Fora da base, só afirme que serve se o carro/motor/ano estiver claramente no anúncio ou em resposta anterior da NOX para o mesmo caso. Se não servir e houver na lista "outros anúncios da NOX" um que sirva claramente, indique-o colocando o link dele na resposta. Se não houver certeza, escreva uma resposta prudente e marque alerta "compatibilidade".
- Preço, desconto, pagamento à vista, atacado: escreva uma resposta neutra (sem prometer desconto) e marque alerta "preco".
- Proibido pelo Mercado Livre: telefone, WhatsApp, e-mail, site ou redes sociais, combinar fora do ML, links que não sejam do Mercado Livre.
- Se o cliente pede outra medida, cor ou versão, procure em "outros anúncios da NOX" a versão pedida (ex.: entrada 2,5") e mande o link. Só diga que não temos depois de olhar a lista inteira.
- PONTEIRA ("serve no meu carro?", "precisa de adaptação?"): a ponteira da NOX é UNIVERSAL. Responda sempre que ela é universal e pode ser instalada sim no carro do cliente, e que a instalação deve ser feita por um profissional. Não peça medidas nem diga que não dá para garantir; confiança "alta" e alerta "nenhum".
- Quando o anúncio da pergunta não serve no carro do cliente, NÃO explique o porquê (não cite adaptação, outra linha, outro modelo): vá direto ao kit certo ("Para o seu <carro> o kit certo é este: <link>").
- INTAKE (resposta simples, opção demais faz o cliente desistir): no MÁXIMO 2 links: o kit COM FILTRO NOX e o kit COM FILTRO K&N (quando existir), os dois na versão CAMPEÃ DE VENDAS (maior "vendas" na lista; em empate, a [FULL]). Diga qual link é qual. As outras variações (outra medida de entrada, ex. 3", ou sem filtro) cite só em meia frase, SEM link (ex.: "Também temos na versão 3\" e sem filtro, é só pedir!"). O link do kit SEM filtro só vai se o cliente EXIGIR sem filtro: aí mande o sem filtro campeão de vendas. Se não existe versão com defletor para o carro, diga isso em poucas palavras.
- Entre anúncios equivalentes (mesmo produto em contas ou anúncios diferentes), mande o campeão de vendas, preferindo o [FULL]. Pode usar anúncio de qualquer conta da NOX.
- Respostas marcadas "REVISADA pelo Paulo" ou "resposta do Paulo" são a referência (o Paulo é o dono e engenheiro da NOX): em conflito com outras respostas, siga as dele.
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
  return h < 12 ? 'Ótimo dia, tudo bom?' : h < 18 ? 'Ótima tarde, tudo bom?' : 'Ótima noite, tudo bom?';   // padrão definido pelo Paulo
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
    // Pesos: respostas do Paulo (até maio/2026) e respostas revisadas por ele são a referência. Correção de vendedor
    // sem revisão vale como exemplo comum (o vendedor também erra). Revisada "IA certa": vale a sugestão da IA;
    // "os dois errados": vale o texto que o Paulo escreveu.
    const { data: hist } = await db.from('ml_perguntas').select('item_id, texto, resposta, respondida_em, sugestao, revisao, revisao_texto')
      .not('resposta', 'is', null).order('criada_em', { ascending: false }).limit(6000);
    type H = { item_id: string; texto: string; resposta: string; respondida_em: string | null; sugestao: string | null; revisao: string | null; revisao_texto: string | null };
    const certa = (h: H) => h.revisao === 'ia' ? h.sugestao : h.revisao === 'nenhum' ? h.revisao_texto : h.resposta;
    const doPaulo = (h: H) => !!h.respondida_em && h.respondida_em < '2026-06-01';
    const rotulo = (h: H) => h.revisao ? ' (REVISADA pelo Paulo: resposta certa)' : doPaulo(h) ? ' (resposta do Paulo: referência)' : '';
    const exemplos = ((hist ?? []) as H[]).filter(h => certa(h))
      .map(h => ({ h, n: parecida(w, palavras(h.texto)) + (h.item_id === q.item_id ? 0.3 : 0) + (h.revisao ? 0.3 : doPaulo(h) ? 0.25 : 0) }))
      .filter(o => o.n > 0.25).sort((a, b) => b.n - a.n).slice(0, 15)
      .map(o => `P${o.h.item_id === q.item_id ? ' (mesmo anúncio)' : ''}: ${o.h.texto}\nR${rotulo(o.h)}: ${certa(o.h)}`).join('\n\n');
    // outros anúncios ativos que podem servir (mesmas palavras do carro/motor)
    // o banco entrega no máximo 1.000 linhas por consulta: lê em páginas
    const todas = async <T,>(f: (de: number, ate: number) => PromiseLike<{ data: T[] | null }>) => { const out: T[] = []; for (let de = 0; ; de += 1000) { const { data } = await f(de, de + 999); out.push(...(data ?? [])); if ((data ?? []).length < 1000) return out; } };
    const itens = await todas<{ item_id: string; titulo: string; link: string; preco: number }>((de, ate) => db.from('ml_itens').select('item_id, titulo, link, preco').eq('situacao', 'active').order('item_id').range(de, ate));   // anúncios de todas as contas da NOX (o Paulo prefere o melhor link, de qualquer conta)
    // ...e as outras versões do mesmo produto (título parecido com o deste anúncio: outras medidas, cores, entradas)
    const wt = palavras(item?.title ?? '');
    const outrosRank = (itens ?? []).filter(i => i.item_id !== q.item_id).map(i => { const ti = palavras(i.titulo ?? ''); return { i, n: parecida(w, ti) + 0.6 * parecida(wt, ti) }; })
      .filter(o => o.n > 0).sort((a, b) => b.n - a.n).slice(0, 30);
    // base de compatibilidade: linhas do SKU deste anúncio + linhas do carro citado na pergunta
    const { data: anu } = await db.from('anuncios').select('sku').eq('anuncio_id', q.item_id);
    const skus = [...new Set((anu ?? []).map(a => String(a.sku ?? '').toUpperCase()).filter(Boolean))];
    const { data: comp } = await db.from('compatibilidades').select('sku, marca, modelo, ano_inicial, ano_final, motorizacao, codigo_motor, combustivel, potencia, observacoes').eq('situacao', 'ativo');
    const wq = palavras(q.texto + ' ' + (item?.title ?? ''));
    // anúncios ativos desta conta por SKU (o SKU do anúncio pode ter sufixo, ex.: ITKFD068KN)
    const anCanal = await todas<{ sku: string; anuncio_id: string }>((de, ate) => db.from('anuncios').select('sku, anuncio_id').not('sku', 'is', null).order('id').range(de, ate));
    const ativos = new Map((itens ?? []).map(i => [i.item_id, i.link]));
    const linkDo = (sku: string) => (anCanal ?? []).filter(a => String(a.sku).toUpperCase().startsWith(sku) && ativos.has(a.anuncio_id)).map(a => `${a.anuncio_id}${full.has(a.anuncio_id) ? ' [FULL]' : ''}${vend(a.anuncio_id)} SKU ${a.sku} ${ativos.get(a.anuncio_id)}`).join(' ; ');   // todas as versões (filtro NOX e K&N)
    const doSku = (c: { sku: string }) => c.sku.split('/').map((x: string) => x.trim()).filter(Boolean);
    const compatRank = (comp ?? []).map(c => ({ c, n: (skus.some(k => doSku(c).some((x: string) => k.startsWith(x))) ? 1 : 0)
        + parecida(wq, palavras(`${c.marca} ${c.modelo} ${c.motorizacao ?? ''} ${c.codigo_motor ?? ''}`)) }))
      .filter(o => o.n > 0.2).sort((a, b) => b.n - a.n).slice(0, 40);
    const idsCompat = compatRank.flatMap(({ c }) => doSku(c).flatMap(sku => (anCanal ?? []).filter(a => String(a.sku).toUpperCase().startsWith(sku) && ativos.has(a.anuncio_id)).map(a => a.anuncio_id)));
    // quais estão no FULL (o ML informa no envio do anúncio) e o SKU (identifica filtro K&N: sufixo KN)
    const full = new Set<string>(), idsFull = [...new Set([q.item_id, ...outrosRank.map(o => o.i.item_id), ...idsCompat])];
    for (let k = 0; k < idsFull.length; k += 20) {
      const r = await mlGet(token, `/items?ids=${idsFull.slice(k, k + 20).join(',')}&attributes=id,shipping`).catch(() => null);
      (r ?? []).forEach((x: { code: number; body: { id: string; shipping?: { logistic_type?: string } } }) => { if (x.code === 200 && x.body.shipping?.logistic_type === 'fulfillment') full.add(x.body.id); });
    }
    const { data: skusOutros } = await db.from('anuncios').select('anuncio_id, sku').in('anuncio_id', idsFull);
    const skuDe = new Map((skusOutros ?? []).map(a => [a.anuncio_id, a.sku]));
    // versões COM FILTRO (NOX e K&N/RS) do mesmo carro do anúncio: título com "filtro" e sem "s/ filtro", mesmas palavras do carro
    const GEN = new Set('intake filtro esportivo kn rs nox noxp pecas sem kit'.split(' '));
    const carro = (t: string) => new Set([...palavras(t.replace(/s\/\s*filtro|sem filtro|k&n/gi, ' '))].filter(x => !GEN.has(x) && x !== 's'));
    const comFiltro = (t: string) => /filtro/i.test(t) && !/s\/\s*filtro|sem filtro/i.test(t);
    const carroDoAnuncio = carro(item?.title ?? '');
    const versoesFiltro = (itens ?? []).filter(i => i.item_id !== q.item_id && comFiltro(i.titulo ?? '') && carroDoAnuncio.size && parecida(carroDoAnuncio, carro(i.titulo ?? '')) >= 0.75).slice(0, 14);
    const semFull = versoesFiltro.map(i => i.item_id).filter(x => !idsFull.includes(x));
    if (semFull.length) {
      const r = await mlGet(token, `/items?ids=${semFull.join(',')}&attributes=id,shipping`).catch(() => null);
      (r ?? []).forEach((x: { code: number; body: { id: string; shipping?: { logistic_type?: string } } }) => { if (x.code === 200 && x.body.shipping?.logistic_type === 'fulfillment') full.add(x.body.id); });
    }
    // vendas de cada anúncio candidato nos últimos 180 dias (o "campeão de vendas" de cada versão)
    const idsVenda = [...new Set([...idsFull, ...versoesFiltro.map(i => i.item_id)])];
    const vendas = new Map<string, number>();
    for (let k = 0; k < idsVenda.length; k += 100) {
      const { data: vs } = await db.from('pedidos_venda_itens').select('anuncio_id, quantidade, pedidos_venda!inner(data_pedido, situacao)')
        .in('anuncio_id', idsVenda.slice(k, k + 100)).gte('pedidos_venda.data_pedido', new Date(Date.now() - 180 * 864e5).toISOString()).neq('pedidos_venda.situacao', 'cancelado');
      (vs ?? []).forEach((v: { anuncio_id: string; quantidade: number }) => vendas.set(v.anuncio_id, (vendas.get(v.anuncio_id) ?? 0) + Number(v.quantidade || 0)));
    }
    const vend = (id: string) => ` | vendas ${vendas.get(id) ?? 0}`;
    const filtroTxt = versoesFiltro.map(i => `${i.item_id}${full.has(i.item_id) ? ' [FULL]' : ''}${vend(i.item_id)} | ${i.titulo} | ${/k&n|\bkn\b|\brs\b/i.test(i.titulo ?? '') ? 'filtro K&N/RS' : 'filtro NOX'} | ${i.link}`).join('\n');
    const outros = outrosRank.map(o => `${o.i.item_id}${full.has(o.i.item_id) ? ' [FULL]' : ''}${vend(o.i.item_id)} | ${o.i.titulo} | SKU ${skuDe.get(o.i.item_id) ?? '-'} | ${o.i.link}`).join('\n');
    const compat = compatRank
      .map(({ c }) => [c.sku, c.marca, c.modelo, `${c.ano_inicial ?? '?'}-${c.ano_final ?? '?'}`, c.motorizacao, c.codigo_motor, c.combustivel, c.potencia, c.observacoes,
        doSku(c).map(linkDo).filter(Boolean).map(l => 'anúncio: ' + l).join(' ; ')].map(v => v ?? '').join(' | ')).join('\n');
    const contexto = `ANÚNCIO DA PERGUNTA (${q.item_id})\nTítulo: ${item?.title ?? ''}${full.has(q.item_id) ? ' [FULL]' : ''}\nPreço: ${item?.price ?? ''}\nFicha técnica:\n${ficha}\nDescrição:\n${String(desc?.plain_text ?? '').slice(0, 4000)}

BASE DE COMPATIBILIDADE DA NOX — FONTE OFICIAL (SKU | marca | modelo | anos | motorização | código do motor | combustível | potência | observações | nosso anúncio desse SKU, para indicar)${skus.length ? `\nSKU deste anúncio: ${skus.join(', ')}` : ''}
${compat || '(nada na base para este caso)'}

RESPOSTAS QUE A NOX JÁ DEU A PERGUNTAS PARECIDAS
${exemplos || '(nenhuma)'}

VERSÕES COM FILTRO PARA O MESMO CARRO DESTE ANÚNCIO (MLB [FULL] | vendas 180 dias | título | tipo de filtro | link)
${filtroTxt || '(nenhuma)'}

OUTROS ANÚNCIOS DA NOX QUE PODEM SERVIR (MLB [FULL = no Full] | vendas 180 dias | título | SKU | link)
${outros || '(nenhum)'}

PERGUNTA DO CLIENTE (${new Date(q.criada_em).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })})
${q.texto}`;
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': chave, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: Deno.env.get('ANTHROPIC_MODELO') || 'claude-sonnet-5-5', max_tokens: 2000,
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
    if (!s?.resposta) throw new Error(`IA não devolveu resposta (${j.stop_reason ?? 'sem motivo'})`);
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
