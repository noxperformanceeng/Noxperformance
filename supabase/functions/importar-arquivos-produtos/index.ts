// ERP NOX · importar-arquivos-produtos — anexa desenhos (PDF/DXF) do Dropbox aos produtos e gera a foto
// a partir da 1ª página do PDF. Uso interno (chave x-nox-chave); só aceita links temporários do Dropbox
// ou da pasta temporária _envio do site (foto enviada no chat), ou o arquivo embutido (base64). tipo 'foto' vira a foto principal se o produto não tiver.
import { createClient } from 'npm:@supabase/supabase-js@2';
import * as mupdf from 'npm:mupdf@1';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });
type Item = { produto_id: number; url?: string; base64?: string; nome: string; tipo: 'desenho' | 'outro' | 'foto'; caminho: string; mime?: string;
  revisao_data?: string | null; foto?: { caminho: string; nome: string } };

async function renderizar(pdf: Uint8Array): Promise<Uint8Array> {
  const doc = mupdf.Document.openDocument(pdf, 'application/pdf');
  const pg = doc.loadPage(0);
  const [x0, y0, x1, y1] = pg.getBounds();
  const escala = Math.min(3, 1400 / Math.max(x1 - x0, y1 - y0));
  const pix = pg.toPixmap(mupdf.Matrix.scale(escala, escala), mupdf.ColorSpace.DeviceRGB, false, true);
  return pix.asPNG();
}

Deno.serve(async req => {
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const { itens = [] } = await req.json().catch(() => ({})) as { itens: Item[] };
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
          const png = await renderizar(bytes);
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
