// onvio-receber — recebe os documentos da contabilidade (portal Onvio) e guarda na pasta privada "contabil".
// Ações (sempre com o cabeçalho x-chave = integracao_config.onvio_chave):
//   POST ?acao=enviar&origem_id=..&nome=..&pasta=..  (corpo = o arquivo)  → grava e registra em documentos_contabeis
//   GET  ?acao=existentes                                                  → ids já recebidos (para não repetir)
//   GET  ?acao=baixar&id=..                                                → devolve o arquivo
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'x-chave, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

async function chaveOk(req: Request) {
  const { data } = await db.from('integracao_config').select('valor').eq('chave', 'onvio_chave').maybeSingle();
  const c = req.headers.get('x-chave') || '';
  return !!data?.valor && c.length === data.valor.length && c === data.valor;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (!(await chaveOk(req))) return json({ erro: 'não autorizado' }, 401);
  const u = new URL(req.url), acao = u.searchParams.get('acao');

  if (acao === 'existentes') {
    const { data, error } = await db.from('documentos_contabeis').select('origem_id').eq('origem', 'onvio');
    return error ? json({ erro: error.message }, 500) : json((data || []).map((r) => r.origem_id));
  }

  if (acao === 'enviar' && req.method === 'POST') {
    const origem_id = (u.searchParams.get('origem_id') || '').replace(/[^a-zA-Z0-9_-]/g, '');
    const nome = u.searchParams.get('nome') || 'documento';
    if (!origem_id) return json({ erro: 'origem_id' }, 400);
    const bytes = new Uint8Array(await req.arrayBuffer());
    if (bytes.length < 100 || bytes.length > 30_000_000) return json({ erro: 'tamanho' }, 400);
    const ext = (nome.match(/\.([a-zA-Z0-9]{1,5})$/)?.[1] || 'bin').toLowerCase();
    const caminho = `onvio/${origem_id}.${ext}`;
    const tipo = ext === 'pdf' ? 'application/pdf' : ext === 'zip' ? 'application/zip' : 'application/octet-stream';
    const up = await db.storage.from('contabil').upload(caminho, bytes, { contentType: tipo, upsert: true });
    if (up.error) return json({ erro: up.error.message }, 500);
    const { data, error } = await db.from('documentos_contabeis').upsert({
      origem: 'onvio', origem_id, nome_original: nome, pasta_origem: u.searchParams.get('pasta'), caminho, tamanho: bytes.length,
    }, { onConflict: 'origem,origem_id' }).select('id').single();
    return error ? json({ erro: error.message }, 500) : json({ ok: true, id: data.id, caminho });
  }

  if (acao === 'baixar') {
    const { data: r } = await db.from('documentos_contabeis').select('caminho').eq('id', Number(u.searchParams.get('id'))).maybeSingle();
    if (!r) return json({ erro: 'não achado' }, 404);
    const { data, error } = await db.storage.from('contabil').download(r.caminho);
    if (error || !data) return json({ erro: error?.message || 'falhou' }, 500);
    return new Response(data, { headers: { ...cors, 'Content-Type': data.type || 'application/octet-stream' } });
  }

  return json({ erro: 'ação desconhecida' }, 400);
});
