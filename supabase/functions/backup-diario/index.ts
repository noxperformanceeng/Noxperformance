// ERP NOX · backup-diario — copia todas as tabelas do banco para a pasta privada "backups" do Storage,
// uma pasta por dia (AAAA-MM-DD/tabela.json.gz: cada linha é uma lista JSON de até 1000 registros, compactado) + estrutura e resumo.
// Chamado pela agenda (pg_cron, chave interna). Trabalha ~100 s e se chama de novo para continuar.
// Auditoria: só os últimos 2 dias (é enorme; somando os dias guardados, nada se perde).
// Guarda os últimos 14 dias + o domingo das últimas 8 semanas; apaga o resto.
import { createClient } from 'npm:@supabase/supabase-js@2';

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });
const BUCKET = 'backups', PAGINA = 1000, LIMITE_MS = 100_000;
const hojeBR = () => new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 10);

async function gz(partes: AsyncIterable<Uint8Array>): Promise<Uint8Array> {
  const cs = new CompressionStream('gzip'), w = cs.writable.getWriter();
  const lido = new Response(cs.readable).arrayBuffer();
  for await (const p of partes) await w.write(p);
  await w.close();
  return new Uint8Array(await lido);
}

// lê a tabela em páginas direto da API, sem decodificar (pouco processamento): cada linha do arquivo = uma página (lista JSON)
const NL = new Uint8Array([10]);
async function* paginasDaTabela(nome: string, ordem: string | null, cont: { n: number }) {
  const base = `${Deno.env.get('SUPABASE_URL')}/rest/v1/${encodeURIComponent(nome)}?select=*`
    + (nome === 'auditoria' ? `&em=gte.${new Date(Date.now() - 2 * 86400_000).toISOString()}` : '')
    + (ordem ? `&order=${encodeURIComponent(ordem)}.asc` : '');
  const chave = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  for (let de = 0; ; de += PAGINA) {
    const r = await fetch(`${base}&offset=${de}&limit=${PAGINA}`, { headers: { apikey: chave, Authorization: `Bearer ${chave}`, Accept: 'application/json' } });
    if (!r.ok) throw new Error(`${nome}: ${r.status} ${(await r.text()).slice(0, 200)}`);
    const m = /^(\d+)-(\d+)\//.exec(r.headers.get('content-range') ?? '');
    const n = m ? Number(m[2]) - Number(m[1]) + 1 : 0;
    const corpo = new Uint8Array(await r.arrayBuffer());
    if (n) { cont.n += n; yield corpo; yield NL; }
    if (n < PAGINA) return;
  }
}

async function enviar(caminho: string, bytes: Uint8Array, tipo: string) {
  const { error } = await db.storage.from(BUCKET).upload(caminho, bytes, { contentType: tipo, upsert: true });
  if (error) throw new Error(`gravar ${caminho}: ${error.message}`);
}

async function limparAntigos() {
  const { data } = await db.storage.from(BUCKET).list('', { limit: 1000 });
  const dias = (data ?? []).map(x => x.name).filter(n => /^\d{4}-\d{2}-\d{2}$/.test(n)).sort().reverse();
  const hoje = new Date(hojeBR() + 'T12:00:00Z').getTime();
  const apagar = dias.filter(d => { const t = new Date(d + 'T12:00:00Z'), idade = (hoje - t.getTime()) / 86400_000;
    return !(idade < 14 || (t.getUTCDay() === 0 && idade < 56)); });
  for (const d of apagar) {
    const { data: arqs } = await db.storage.from(BUCKET).list(d, { limit: 1000 });
    if (arqs?.length) await db.storage.from(BUCKET).remove(arqs.map(a => `${d}/${a.name}`));
  }
  return apagar;
}

async function continuar(chave: string) {
  await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/backup-diario`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-nox-chave': chave }, body: JSON.stringify({ acao: 'continuar' }) });
}

async function rodar(chave: string) {
  const inicio = Date.now(), dia = hojeBR();
  let { data: ex } = await db.from('backup_execucoes').select('*').eq('dia', dia).order('id', { ascending: false }).limit(1).maybeSingle();
  if (ex?.situacao === 'ok') return;
  if (!ex || ex.situacao === 'erro') ({ data: ex } = await db.from('backup_execucoes').insert({ dia }).select('*').single());
  const salvar = (c: Record<string, unknown>) => db.from('backup_execucoes').update(c).eq('id', ex!.id);
  try {
    const { data: tabs, error } = await db.rpc('backup_tabelas');
    if (error) throw new Error('lista de tabelas: ' + error.message);
    const feitas = new Set<string>(ex!.feitas ?? []);
    if (!feitas.size) {   // começo do dia (ou refeito): limpa o que sobrou de uma tentativa anterior
      const { data: velhos } = await db.storage.from(BUCKET).list(dia, { limit: 1000 });
      if (velhos?.length) await db.storage.from(BUCKET).remove(velhos.map(a => `${dia}/${a.name}`));
    }
    let linhas = Number(ex!.linhas), bytes = Number(ex!.bytes);
    await salvar({ tabelas: tabs.length });
    for (const t of tabs as { nome: string; ordem: string | null }[]) {
      if (feitas.has(t.nome)) continue;
      if (Date.now() - inicio > LIMITE_MS) { await continuar(chave); return; }
      const cont = { n: 0 };
      const arq = await gz(paginasDaTabela(t.nome, t.ordem, cont));
      await enviar(`${dia}/${t.nome}.json.gz`, arq, 'application/gzip');
      feitas.add(t.nome); linhas += cont.n; bytes += arq.length;
      await salvar({ feitas: [...feitas], linhas, bytes });
    }
    const { data: estr } = await db.rpc('backup_estrutura');
    const e = await gz((async function* () { yield new TextEncoder().encode(String(estr ?? '')); })());
    await enviar(`${dia}/_estrutura.sql.gz`, e, 'application/gzip');
    bytes += e.length;
    await enviar(`${dia}/_resumo.json`, new TextEncoder().encode(JSON.stringify({ dia, gerado_em: new Date().toISOString(), tabelas: tabs.length, linhas, bytes }, null, 1)), 'application/json');
    const apagados = await limparAntigos();
    await salvar({ situacao: 'ok', bytes, concluido_em: new Date().toISOString(),
      mensagem: `${tabs.length} tabelas, ${linhas} registros` + (apagados.length ? ` · apagados backups antigos: ${apagados.join(', ')}` : '') });
  } catch (err) {
    await salvar({ situacao: 'erro', mensagem: String((err as Error).message ?? err).slice(0, 500) });
  }
}

Deno.serve(async req => {
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  const chave = cfg?.valor ?? '';
  if (!chave || req.headers.get('x-nox-chave') !== chave) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({}));
  if (corpo.acao === 'rodar' || corpo.acao === 'continuar') {
    // @ts-ignore EdgeRuntime existe no Supabase
    EdgeRuntime.waitUntil(rodar(chave));
    return resp({ ok: true });
  }
  return resp({ erro: 'Ação desconhecida' });
});
