// ERP NOX · produtos-foto-ml — foto do produto a partir do anúncio do Mercado Livre
// Só chamada interna (banco/agendamento, chave x-nox-chave). Ação:
//  · importar {escopo: 'ml' | 'todos', limite?}: para cada produto ATIVO sem foto que tem anúncio no Mercado Livre
//    (escopo 'ml' = só os produtos que vieram do ML, origem 'mercado_livre'), pega a 1ª foto do anúncio em alta
//    resolução, guarda no bucket "produtos" e cadastra como foto principal (produto_arquivos).
//    Usa o anúncio com mais vendas do produto. Devolve quantos importou e os que falharam.
import { adminDb, mlGet, tokenValido, Conta } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });
type Db = ReturnType<typeof adminDb>;

async function importar(db: Db, escopo: string, limite: number) {
  const { data: contas } = await db.from('ml_contas').select('*').eq('situacao', 'ativo');
  const tokens = new Map<number, string>();
  for (const c of (contas ?? []) as Conta[]) { try { tokens.set(c.canal_id, await tokenValido(db, c)); } catch { /* conta sem token: usa a foto guardada */ } }

  let q = db.from('produtos').select('id, codigo').eq('situacao', 'ativo');
  if (escopo !== 'todos') q = q.eq('origem', 'mercado_livre');
  const { data: prods } = await q.order('id');
  const { data: comFoto } = await db.from('produto_arquivos').select('produto_id').eq('tipo', 'foto');
  const temFoto = new Set((comFoto ?? []).map(x => x.produto_id));
  const alvo = (prods ?? []).filter(p => !temFoto.has(p.id)).slice(0, limite);

  const ok: string[] = [], falhas: string[] = [];
  for (const p of alvo) {
    try {
      // anúncios do ML ligados ao produto, o mais vendido primeiro
      const { data: ans } = await db.from('anuncios').select('id, canal_id, anuncio_id').eq('produto_id', p.id).in('canal_id', [...tokens.keys(), 1, 2]);
      const lista = [];
      for (const a of ans ?? []) {
        if (!/^MLB\d+$/.test(a.anuncio_id ?? '')) continue;
        const { count } = await db.from('pedidos_venda_itens').select('id', { count: 'exact', head: true }).eq('anuncio_ref', a.id);
        lista.push({ ...a, vendas: count ?? 0 });
      }
      lista.sort((x, y) => y.vendas - x.vendas);
      if (!lista.length) { falhas.push(`${p.codigo}: sem anúncio no Mercado Livre`); continue; }

      let url: string | null = null, origem = '';
      for (const a of lista) {
        const tk = tokens.get(a.canal_id);
        if (tk) {
          const it = await mlGet(tk, `/items/${a.anuncio_id}`).catch(() => null);
          const f = it?.pictures?.[0];
          if (f) { url = f.secure_url || f.url; origem = a.anuncio_id; break; }
        }
        const { data: mi } = await db.from('ml_itens').select('foto').eq('item_id', a.anuncio_id).maybeSingle();
        if (mi?.foto) { url = String(mi.foto).replace(/-[A-Z]\.(jpg|webp|png)$/i, '-O.$1'); origem = a.anuncio_id; break; }
      }
      if (!url) { falhas.push(`${p.codigo}: anúncio sem foto`); continue; }

      const r = await fetch(url.replace(/^http:/, 'https:'));
      if (!r.ok) { falhas.push(`${p.codigo}: foto não baixou (${r.status})`); continue; }
      const mime = (r.headers.get('content-type') || 'image/jpeg').split(';')[0];
      const ext = mime.includes('webp') ? 'webp' : mime.includes('png') ? 'png' : 'jpg';
      const bytes = new Uint8Array(await r.arrayBuffer());
      const caminho = `${p.id}/${Date.now()}_ml_${origem}.${ext}`;
      const up = await db.storage.from('produtos').upload(caminho, bytes, { contentType: mime, upsert: false });
      if (up.error) { falhas.push(`${p.codigo}: ${up.error.message}`); continue; }
      const ins = await db.from('produto_arquivos').insert({
        produto_id: p.id, tipo: 'foto', nome: `${p.codigo}.${ext}`, caminho, mime, tamanho: bytes.length, principal: true,
        finalidade: 'outro', observacao: `Foto do anúncio ${origem} do Mercado Livre (importada em ${new Date().toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' })})`
      });
      if (ins.error) { await db.storage.from('produtos').remove([caminho]); falhas.push(`${p.codigo}: ${ins.error.message}`); continue; }
      ok.push(p.codigo);
    } catch (e) { falhas.push(`${p.codigo}: ${(e as Error).message}`); }
  }
  return { escopo, analisados: alvo.length, importadas: ok.length, falhas };
}

Deno.serve(async req => {
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({}));
  if (corpo.acao !== 'importar') return resp({ erro: 'ação desconhecida' }, 400);
  const escopo = corpo.escopo === 'todos' ? 'todos' : 'ml';
  const limite = Math.min(Number(corpo.limite) || 80, 400);
  // roda em segundo plano (o disparo pelo banco espera só 30 s) e grava o resultado para conferência
  const tarefa = (async () => {
    const res = await importar(db, escopo, limite).catch(e => ({ erro: (e as Error).message }));
    await db.from('integracao_config').upsert({ chave: 'produtos_foto_ml_ultimo', valor: JSON.stringify({ em: new Date().toISOString(), ...res }) }, { onConflict: 'chave' });
  })();
  // @ts-ignore EdgeRuntime existe no Supabase
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(tarefa); else await tarefa;
  return resp({ ok: true, iniciado: true, escopo, limite });
});
