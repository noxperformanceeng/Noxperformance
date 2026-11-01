// ERP NOX · importar-arquivos-produtos — anexa desenhos (PDF/DXF) do Dropbox aos produtos e gera a foto
// a partir da 1ª página do PDF. Uso interno (chave x-nox-chave); só aceita links temporários do Dropbox
// ou da pasta temporária _envio do site (foto enviada no chat), ou o arquivo embutido (base64). tipo 'foto' vira a foto principal se o produto não tiver.
import { createClient } from 'npm:@supabase/supabase-js@2';
import * as mupdf from 'npm:mupdf@1';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });
type Item = { produto_id: number; url?: string; base64?: string; nome: string; tipo: 'desenho' | 'outro' | 'foto'; caminho: string; mime?: string;
  revisao_data?: string | null; foto?: { caminho: string; nome: string } };

async function renderizar(pdf: Uint8Array, maximo = 1400): Promise<Uint8Array> {
  const doc = mupdf.Document.openDocument(pdf, 'application/pdf');
  const pg = doc.loadPage(0);
  const [x0, y0, x1, y1] = pg.getBounds();
  const escala = Math.min(3, maximo / Math.max(x1 - x0, y1 - y0));
  const pix = pg.toPixmap(mupdf.Matrix.scale(escala, escala), mupdf.ColorSpace.DeviceRGB, false, true);
  return pix.asPNG();
}

/* Foto "3D" da peça: acha a vista isométrica (ou perspectiva) na folha do desenho e recorta só ela.
   As vistas cotadas, tabelas e textos são feitos de traços horizontais/verticais ou curtos; a vista 3D é a que tem
   mais traço reto INCLINADO e comprido. Sem vista 3D clara, a foto fica com a folha inteira. */
function acharIso(pix: mupdf.Pixmap, textos: number[][] = []): [number, number, number, number] | null {
  const W = pix.getWidth(), H = pix.getHeight(), n = pix.getNumberOfComponents(), st = pix.getStride(), px = pix.getPixels();
  const esc = new Uint8Array(W * H), bx = Math.ceil(.01 * W), by = Math.ceil(.01 * H);
  for (let y = by; y < H - by; y++) for (let x = bx; x < W - bx; x++) { const i = y * st + x * n; if (px[i] + px[i + 1] + px[i + 2] < 600) esc[y * W + x] = 1; }
  for (const [a, b, c2, d] of textos) for (let y = Math.max(0, a); y < Math.min(H, c2); y++) esc.fill(0, y * W + Math.max(0, b), y * W + Math.min(W, d));
  const corridas = (lh: number, lv: number, marca: Uint8Array) => {
    for (let y = 0; y < H; y++) { let s = -1; for (let x = 0; x <= W; x++) { const v = x < W && esc[y * W + x]; if (v && s < 0) s = x; if (!v && s >= 0) { if (x - s >= lh) for (let k = s; k < x; k++) marca[y * W + k] = 1; s = -1; } } }
    for (let x = 0; x < W; x++) { let s = -1; for (let y = 0; y <= H; y++) { const v = y < H && esc[y * W + x]; if (v && s < 0) s = y; if (!v && s >= 0) { if (y - s >= lv) for (let k = s; k < y; k++) marca[k * W + x] = 1; s = -1; } } }
  };
  const longo = new Uint8Array(W * H); corridas(Math.round(.2 * W), Math.round(.2 * H), longo);   // moldura e linhas de tabela
  for (let k = 0; k < W * H; k++) if (longo[k]) esc[k] = 0;
  const lim = Math.max(6, Math.round(.012 * W)), hv = new Uint8Array(W * H); corridas(lim, lim, hv);
  const L = Math.round(.025 * W), meio = L >> 1, dirs: [number, number][][] = [];
  for (let ang = 12; ang < 170; ang += 4) { if (ang > 78 && ang < 102) continue; const r = ang * Math.PI / 180, l: [number, number][] = [];
    for (let t = -meio; t <= meio; t++) l.push([Math.round(Math.cos(r) * t), Math.round(Math.sin(r) * t)]); dirs.push(l); }
  const c = Math.max(4, Math.round(.008 * W)), GW = Math.ceil(W / c), GH = Math.ceil(H / c);
  const tot = new Int32Array(GW * GH), obl = new Int32Array(GW * GH);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { const k = y * W + x; if (!esc[k]) continue;
    const g = ((y / c) | 0) * GW + ((x / c) | 0); tot[g]++;
    if (hv[k]) continue;
    for (const l of dirs) { let ok = 0; for (const [dx, dy] of l) { const xx = x + dx, yy = y + dy; if (xx >= 0 && yy >= 0 && xx < W && yy < H && esc[yy * W + xx]) ok++; }
      if (ok >= .9 * l.length) { obl[g]++; break; } } }
  const lab = new Int32Array(GW * GH); let melhor: [number, number, number, number] | null = null, nota = -1, qtd = 0, id = 0;
  for (let g0 = 0; g0 < GW * GH; g0++) {
    if (!tot[g0] || lab[g0]) continue;
    id++; const pilha = [g0]; lab[g0] = id; let t = 0, o = 0, x0 = GW, y0 = GH, x1 = 0, y1 = 0;
    while (pilha.length) { const g = pilha.pop()!, gx = g % GW, gy = (g / GW) | 0; t += tot[g]; o += obl[g];
      x0 = Math.min(x0, gx); x1 = Math.max(x1, gx); y0 = Math.min(y0, gy); y1 = Math.max(y1, gy);
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) { const nx = gx + dx, ny = gy + dy; if (nx < 0 || ny < 0 || nx >= GW || ny >= GH) continue; const h = ny * GW + nx; if (tot[h] && !lab[h]) { lab[h] = id; pilha.push(h); } } }
    if (t < 300 || (x1 - x0 + 1) * c < .05 * W || (y1 - y0 + 1) * c < .05 * H) continue;
    if (o / t > nota) { nota = o / t; qtd = o; melhor = [x0 * c, y0 * c, (x1 + 1) * c, (y1 + 1) * c]; }
  }
  return nota >= .2 && qtd >= 300 ? melhor : null;
}
// desenha só um pedaço da folha (frações 0–1 da página), com o lado maior em "lado" pixels
// deno-lint-ignore no-explicit-any
function recortar(pg: any, f: number[], lado: number): Uint8Array {
  const [x0, y0, x1, y1] = pg.getBounds(), W = x1 - x0, H = y1 - y0;
  const bx0 = x0 + f[0] * W, by0 = y0 + f[1] * H, bx1 = x0 + f[2] * W, by1 = y0 + f[3] * H;
  const e = Math.min(6, lado / Math.max(bx1 - bx0, by1 - by0));
  const pix = new mupdf.Pixmap(mupdf.ColorSpace.DeviceRGB, [Math.floor(bx0 * e), Math.floor(by0 * e), Math.ceil(bx1 * e), Math.ceil(by1 * e)], false);
  pix.clear(255);
  const dev = new mupdf.DrawDevice(mupdf.Matrix.scale(e, e), pix); pg.run(dev, mupdf.Matrix.identity); dev.close();
  return pix.asPNG();
}
async function fotoIso(pdf: Uint8Array, lado = 800, manual?: number[]): Promise<{ png: Uint8Array; iso: boolean; tx?: number }> {
  const doc = mupdf.Document.openDocument(pdf, 'application/pdf'), pg = doc.loadPage(0);
  if (manual) return { png: recortar(pg, manual, lado), iso: true };
  const [x0, y0, x1, y1] = pg.getBounds(), W = x1 - x0, H = y1 - y0, e1 = 1400 / Math.max(W, H);
  const textos: number[][] = [];
  try {
    const j = JSON.parse(pg.toStructuredText('preserve-whitespace').asJSON());
    for (const bl of j.blocks || []) for (const ln of bl.lines || []) { const r = ln.bbox; if (!r) continue;
      textos.push([Math.floor((r.y - y0) * e1) - 3, Math.floor((r.x - x0) * e1) - 3, Math.ceil((r.y + r.h - y0) * e1) + 3, Math.ceil((r.x + r.w - x0) * e1) + 3]); }
  } catch { /* sem texto extraível */ }
  const b = acharIso(pg.toPixmap(mupdf.Matrix.scale(e1, e1), mupdf.ColorSpace.DeviceRGB, false, true), textos);
  if (!b) return { png: await renderizar(pdf), iso: false, tx: textos.length };
  const m = 15, pw = W * e1, ph = H * e1;
  return { png: recortar(pg, [(b[0] - m) / pw, (b[1] - m) / ph, (b[2] + m) / pw, (b[3] + m) / ph], lado), iso: true, tx: textos.length };
}

Deno.serve(async req => {
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({})) as { itens?: Item[]; fotos?: { produtos: number[]; previa?: boolean; escala?: number; substituir?: boolean; folha?: boolean; recortes?: Record<string, number[]> } };
  // Foto a partir do desenho já anexado (PDF de dobra, ou de corte): 1ª página vira a foto principal do produto.
  // previa: só devolve a imagem (base64) para conferir, sem gravar.
  if (corpo.fotos) {
    const res: unknown[] = [];
    for (const pid of corpo.fotos.produtos || []) {
      try {
        const { data: arqs } = await db.from('produto_arquivos').select('nome, caminho, finalidade, obsoleto, revisao_data, id')
          .eq('produto_id', pid).in('finalidade', ['dobra_pdf', 'corte_pdf']).order('obsoleto').order('revisao_data', { ascending: false, nullsFirst: false }).order('id', { ascending: false });
        const a = (arqs || []).find(x => x.finalidade === 'dobra_pdf') || (arqs || [])[0];
        if (!a) { res.push({ produto_id: pid, erro: 'sem PDF' }); continue; }
        const dl = await db.storage.from('produtos').download(a.caminho);
        if (dl.error || !dl.data) throw new Error('download: ' + dl.error?.message);
        const bytes = new Uint8Array(await dl.data.arrayBuffer());
        const { png, iso, tx } = corpo.fotos.folha ? { png: await renderizar(bytes, corpo.fotos.escala), iso: false, tx: 0 } : await fotoIso(bytes, corpo.fotos.escala, corpo.fotos.recortes?.[String(pid)]);
        if (corpo.fotos.previa) { let b = ''; png.forEach(c => b += String.fromCharCode(c)); res.push({ produto_id: pid, de: a.nome, iso, tx, png: btoa(b) }); continue; }
        const { count } = await db.from('produto_arquivos').select('id', { count: 'exact', head: true }).eq('produto_id', pid).eq('tipo', 'foto');
        if (count && !corpo.fotos.substituir) { res.push({ produto_id: pid, ok: 'já tinha foto' }); continue; }
        if (count) await db.from('produto_arquivos').update({ principal: false }).eq('produto_id', pid).eq('tipo', 'foto');
        const { data: pr } = await db.from('produtos').select('codigo').eq('id', pid).single();
        const cam = `${pid}/foto-${pr?.codigo || pid}-iso.png`;
        const up = await db.storage.from('produtos').upload(cam, png, { contentType: 'image/png', upsert: true });
        if (up.error) throw new Error(up.error.message);
        const ins = await db.from('produto_arquivos').insert({ produto_id: pid, tipo: 'foto', nome: `${pr?.codigo || pid}.png`, caminho: cam, mime: 'image/png', tamanho: png.length, principal: true });
        if (ins.error) throw new Error(ins.error.message);
        res.push({ produto_id: pid, ok: (iso ? 'foto 3D (vista isométrica) de ' : 'folha inteira de ') + a.nome });
      } catch (e) { res.push({ produto_id: pid, erro: String((e as Error).message || e) }); }
    }
    return resp({ fotos: res });
  }
  const itens = corpo.itens || [];
  const out: unknown[] = [];
  for (const it of itens) {
    try {
      if (!it.base64) {
        const u = new URL(it.url || '');
        if (u.protocol !== 'https:' || !(u.hostname.endsWith('.dropboxusercontent.com') || (u.hostname === 'noxperformanceeng.github.io' && u.pathname.startsWith('/Noxperformance/_envio/')))) throw new Error('url não permitida');
      }
      if (!it.caminho.startsWith(`${it.produto_id}/`) || it.caminho.includes('..')) throw new Error('caminho inválido');
      const { data: ja } = await db.from('produto_arquivos').select('id').eq('produto_id', it.produto_id).eq('caminho', it.caminho).maybeSingle();
      if (ja) { out.push({ nome: it.nome, ok: 'já existia' }); continue; }
      let bytes: Uint8Array;
      if (it.base64) bytes = Uint8Array.from(atob(it.base64), c => c.charCodeAt(0));
      else { const r = await fetch(it.url!); if (!r.ok) throw new Error('download ' + r.status); bytes = new Uint8Array(await r.arrayBuffer()); }
      if (bytes.length > 15e6) throw new Error('arquivo grande demais');
      const mime = it.mime || (it.nome.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'application/octet-stream');
      const up = await db.storage.from('produtos').upload(it.caminho, bytes, { contentType: mime, upsert: true });
      if (up.error) throw new Error(up.error.message);
      let principal = false;
      if (it.tipo === 'foto') {
        const { count } = await db.from('produto_arquivos').select('id', { count: 'exact', head: true }).eq('produto_id', it.produto_id).eq('tipo', 'foto').eq('principal', true);
        principal = !count;
      }
      const ins = await db.from('produto_arquivos').insert({ produto_id: it.produto_id, tipo: it.tipo, nome: it.nome, caminho: it.caminho,
        mime, tamanho: bytes.length, revisao_data: it.revisao_data ?? null, principal });
      if (ins.error) throw new Error(ins.error.message);
      let foto = '';
      if (it.foto && mime === 'application/pdf') {
        const { count } = await db.from('produto_arquivos').select('id', { count: 'exact', head: true }).eq('produto_id', it.produto_id).eq('tipo', 'foto');
        if (!count) {
          const { png } = await fotoIso(bytes);
          const fu = await db.storage.from('produtos').upload(it.foto.caminho, png, { contentType: 'image/png', upsert: true });
          if (fu.error) throw new Error('foto: ' + fu.error.message);
          const fi = await db.from('produto_arquivos').insert({ produto_id: it.produto_id, tipo: 'foto', nome: it.foto.nome, caminho: it.foto.caminho,
            mime: 'image/png', tamanho: png.length, principal: true });
          if (fi.error) throw new Error('foto: ' + fi.error.message);
          foto = ' + foto';
        }
      }
      out.push({ nome: it.nome, ok: 'anexado' + foto });
    } catch (e) { out.push({ nome: it.nome, erro: String((e as Error).message || e) }); }
  }
  return resp({ resultado: out });
});
