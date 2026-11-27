// ERP NOX · ml-anuncios — lista completa dos anúncios das contas do Mercado Livre
// Só chamada interna (banco/agendamento, chave x-nox-chave). Ação:
//  · catalogo: lê todos os anúncios ATIVOS de cada conta, com o SKU do anúncio e de cada variação, e grava em
//    ml_itens (título, link, foto, preço, situação) e em anuncios (um por anúncio/variação, situação 'ativo').
//    Anúncio da conta que não está ativo no ML (pausado, encerrado) fica 'inativo' em anuncios. Não mexe no produto já ligado.
//    Anúncio novo cujo SKU é igual ao código de um produto (único) já nasce ligado a ele.
import { adminDb, mlGet, tokenValido, Conta } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });
type Db = ReturnType<typeof adminDb>;
type Attr = { id: string; value_name?: string | null };
const skuDe = (attrs: Attr[] | undefined, campo?: string | null) =>
  (attrs ?? []).find(a => a.id === 'SELLER_SKU')?.value_name?.trim() || campo?.trim() || null;

async function catalogo(db: Db) {
  const { data: contas } = await db.from('ml_contas').select('*').eq('situacao', 'ativo');
  const res: Record<string, unknown>[] = [];
  for (const conta of (contas ?? []) as (Conta & { ml_user_id: number })[]) {
    const token = await tokenValido(db, conta);
    // 1) todos os ids (scan pagina com scroll_id)
    const ids: string[] = [];
    let scroll: string | null = null;
    for (let i = 0; i < 200; i++) {
      const r = await mlGet(token, `/users/${conta.ml_user_id}/items/search?search_type=scan&status=active&limit=100${scroll ? `&scroll_id=${scroll}` : ''}`);
      const lote: string[] = r?.results ?? [];
      if (!lote.length) break;
      ids.push(...lote); scroll = r.scroll_id;
      if (!scroll) break;
    }
    // 2) SKU e situação em lotes de 20 (o ML recusa o lote se pedir título; anúncio antigo bloqueado volta com code 403 e é ignorado)
    const { data: conhecidos } = await db.from('ml_itens').select('item_id, titulo').eq('canal_id', conta.canal_id);
    const titulos = new Map((conhecidos ?? []).filter(x => x.titulo).map(x => [x.item_id, x.titulo as string]));
    const situacoes: Record<string, unknown>[] = [], novos: Record<string, unknown>[] = [], anuncios: Record<string, unknown>[] = [];
    let bloqueados = 0;
    for (let i = 0; i < ids.length; i += 20) {
      const lote = ids.slice(i, i + 20), campos = 'attributes=id,status,attributes,variations,seller_custom_field';
      let r = await mlGet(token, `/items?ids=${lote.join(',')}&${campos}`).catch(() => null);
      // lote recusado: busca um a um (o que vier bloqueado é ignorado)
      if (!Array.isArray(r)) { r = []; for (const id of lote) { const b = await mlGet(token, `/items/${id}?${campos}`).catch(() => null); r.push(b ? { code: 200, body: b } : { code: 403 }); } }
      for (const x of r) {
        if (x.code !== 200) { bloqueados++; continue; }
        const b = x.body;
        const ativo = b.status === 'active';
        let titulo = titulos.get(b.id) ?? null;
        if (!titulo) {
          // anúncio que o sistema ainda não conhece: busca título, link, foto e preço um a um
          const d = await mlGet(token, `/items/${b.id}?attributes=id,title,permalink,thumbnail,price`).catch(() => null);
          titulo = d?.title ?? null;
          novos.push({ item_id: b.id, canal_id: conta.canal_id, titulo, link: d?.permalink ?? null, foto: String(d?.thumbnail ?? '').replace(/^http:/, 'https:') || null,
            preco: d?.price ?? null, situacao: b.status, atualizado_em: new Date().toISOString() });
        } else situacoes.push({ item_id: b.id, canal_id: conta.canal_id, situacao: b.status, atualizado_em: new Date().toISOString() });
        const skuItem = skuDe(b.attributes, b.seller_custom_field);
        let vars = b.variations ?? [];
        // SKU da variação: se o lote não trouxe, busca a lista completa do anúncio
        if (vars.some((v: { attributes?: Attr[]; seller_custom_field?: string }) => !skuDe(v.attributes, v.seller_custom_field))) {
          const completas = await mlGet(token, `/items/${b.id}/variations`).catch(() => null);
          if (Array.isArray(completas) && completas.length) vars = completas;
        }
        const tit = titulo ?? b.id;
        if (!vars.length) anuncios.push({ canal_id: conta.canal_id, anuncio_id: b.id, variacao_id: '', sku: skuItem, titulo: tit, situacao: ativo ? 'ativo' : 'inativo' });
        for (const v of vars) {
          const nomeVar = (v.attribute_combinations ?? []).map((c: { value_name?: string }) => c.value_name).filter(Boolean).join(' / ');
          anuncios.push({ canal_id: conta.canal_id, anuncio_id: b.id, variacao_id: String(v.id), sku: skuDe(v.attributes, v.seller_custom_field) || skuItem,
            titulo: nomeVar ? `${tit} · ${nomeVar}` : tit, situacao: ativo ? 'ativo' : 'inativo' });
        }
      }
    }
    for (const lista of [situacoes, novos])
      for (let i = 0; i < lista.length; i += 200) { const { error } = await db.from('ml_itens').upsert(lista.slice(i, i + 200)); if (error) throw error; }
    for (let i = 0; i < anuncios.length; i += 200) {
      const { error } = await db.from('anuncios').upsert(anuncios.slice(i, i + 200), { onConflict: 'canal_id,anuncio_id,variacao_id' });
      if (error) throw error;
    }
    // o que a conta tem no sistema e não está ativo no ML (pausado, encerrado) fica inativo
    const ativosMl = new Set(anuncios.map(a => a.anuncio_id as string));
    const { data: daConta } = await db.from('anuncios').select('id, anuncio_id').eq('canal_id', conta.canal_id).eq('situacao', 'ativo');
    // trava: se a leitura do ML veio vazia ou pela metade, não desativa nada
    const desativar = ativosMl.size < 50 || ativosMl.size < (daConta ?? []).length * 0.5 ? [] : (daConta ?? []).filter(a => !ativosMl.has(a.anuncio_id)).map(a => a.id);
    for (let i = 0; i < desativar.length; i += 200) await db.from('anuncios').update({ situacao: 'inativo' }).in('id', desativar.slice(i, i + 200));
    res.push({ canal_id: conta.canal_id, desativados: desativar.length, anuncios_ml: ids.length, bloqueados, novos: novos.length,
      ativos: [...situacoes, ...novos].filter(x => x.situacao === 'active').length, linhas_anuncio: anuncios.length,
      sem_sku: anuncios.filter(a => !a.sku).length });
  }
  // liga ao produto pelo SKU (só quando o código é único e o anúncio ainda não tem produto)
  const { data: lig, error } = await db.rpc('anuncios_ligar_por_sku');
  return { contas: res, ligados_por_sku: error ? `erro: ${error.message}` : lig };
}

Deno.serve(async req => {
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({}));
  if (corpo.acao === 'teste') {
    // diagnóstico: quais consultas o ML aceita para um anúncio
    const { data: contas } = await db.from('ml_contas').select('*').eq('canal_id', corpo.canal_id ?? 1);
    const conta = (contas ?? [])[0] as Conta & { ml_user_id: number };
    const token = await tokenValido(db, conta);
    const id = corpo.item ?? 'MLB2695525167';
    const caminhos = [`/items/${id}`, `/items/${id}?attributes=id,status,attributes,variations,seller_custom_field`, `/items/${id}/variations`,
      `/items?ids=${id}&attributes=id,title,status`, `/items?ids=${id}&attributes=id,status,variations`, `/items?ids=${id}&attributes=id,status,attributes`,
      `/users/${conta.ml_user_id}/items/search?seller_sku=KITNXTD1`];
    const out: Record<string, unknown> = {};
    for (const c of caminhos) {
      const r = await fetch('https://api.mercadolibre.com' + c, { headers: { Authorization: `Bearer ${token}` } });
      const t = await r.text(); out[c] = `${r.status} ${t.slice(0, 300)}`;
    }
    return resp(out);
  }
  if (corpo.acao !== 'catalogo') return resp({ erro: 'ação desconhecida' }, 400);
  const tarefa = (async () => {
    const res = await catalogo(db).catch(e => ({ erro: (e as Error).message }));
    await db.from('integracao_config').upsert({ chave: 'ml_catalogo_ultimo', valor: JSON.stringify({ em: new Date().toISOString(), ...res }) }, { onConflict: 'chave' });
  })();
  // @ts-ignore EdgeRuntime existe no Supabase
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(tarefa); else await tarefa;
  return resp({ ok: true, iniciado: true });
});
