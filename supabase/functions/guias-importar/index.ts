// ERP NOX · guias-importar — sobe as imagens das páginas do guia de montagem para o bucket privado "guias".
// Uso interno (chave x-nox-chave). Recebe um link temporário do Dropbox de um .zip com as imagens (pagina-NN.jpg)
// e grava cada uma em "<pasta>/<nome>". Não mexe em mais nada.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { unzipSync } from 'npm:fflate@0.8.2';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async req => {
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({})) as { zip_url?: string; pasta?: string };
  try {
    const u = new URL(String(corpo.zip_url || ''));
    if (u.protocol !== 'https:' || !u.hostname.endsWith('.dropboxusercontent.com')) throw new Error('url não permitida');
    const pasta = String(corpo.pasta || 'catalogo').replace(/[^a-z0-9_-]/gi, '');
    const r = await fetch(u); if (!r.ok) throw new Error('download ' + r.status);
    const arquivos = unzipSync(new Uint8Array(await r.arrayBuffer()));
    const feitos: string[] = [], erros: string[] = [];
    for (const [nome, bytes] of Object.entries(arquivos)) {
      const base = nome.split('/').pop() || '';
      if (!/^[a-z0-9_-]+\.(jpg|jpeg|png)$/i.test(base)) continue;
      const { error } = await db.storage.from('guias').upload(`${pasta}/${base}`, bytes, { contentType: /png$/i.test(base) ? 'image/png' : 'image/jpeg', upsert: true });
      (error ? erros : feitos).push(error ? `${base}: ${error.message}` : base);
    }
    // carga inicial das páginas (guias.json dentro do zip), só se a tabela estiver vazia
    let paginas = 0;
    const js = Object.entries(arquivos).find(([n]) => n.endsWith('guias.json'));
    if (js) {
      const { count } = await db.from('guias_montagem').select('id', { count: 'exact', head: true });
      if (!count) {
        const lista = JSON.parse(new TextDecoder().decode(js[1])) as { ordem: number; categoria: string; titulo: string; texto: string; imagem: string; skus: string[] }[];
        const todos = [...new Set(lista.flatMap(g => g.skus))];
        const { data: ps } = todos.length ? await db.from('produtos').select('id, codigo').in('codigo', todos) : { data: [] };
        const porCod = new Map((ps ?? []).map(p => [String(p.codigo).toUpperCase(), p.id]));
        const linhas = lista.map(g => ({ ordem: g.ordem, categoria: g.categoria, titulo: g.titulo, texto: g.texto || null, imagem: g.imagem,
          produto_ids: [...new Set(g.skus.map(s => porCod.get(s.toUpperCase())).filter(Boolean))] }));
        const { error } = await db.from('guias_montagem').insert(linhas);
        if (error) erros.push('páginas: ' + error.message); else paginas = linhas.length;
      }
    }
    return resp({ ok: true, feitos: feitos.length, paginas, erros });
  } catch (e) { return resp({ erro: String((e as Error).message ?? e) }, 400); }
});
