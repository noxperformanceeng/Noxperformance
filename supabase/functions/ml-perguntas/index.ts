// ERP NOX · ml-perguntas — perguntas do Mercado Livre com rascunho da IA
// Chamadas:
//  · agenda (x-nox-chave): { acao: 'sincronizar' } a cada 10 min — pega perguntas cujo aviso se perdeu
//  · tela Perguntas ML (login): { acao: 'enviar', id, texto } · { acao: 'gerar', id, instrucao? } · { acao: 'ignorar', id }
//                               · { acao: 'sincronizar' }
// Responder exige acesso "alterar" na tela; sincronizar exige "ver".
import { createClient } from 'npm:@supabase/supabase-js@2';
import { adminDb, cors, Conta } from '../_shared/ml.ts';
import { enviarResposta, processarPergunta, sincronizarPerguntas } from '../_shared/perguntas.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const msg = (e: unknown) => String((e as Error)?.message ?? e);

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { ...cors, 'Access-Control-Allow-Headers': req.headers.get('access-control-request-headers') ?? cors['Access-Control-Allow-Headers'], 'Access-Control-Max-Age': '600' } });
  const db = adminDb();
  const corpo = await req.json().catch(() => ({}));
  const contasAtivas = async () => ((await db.from('ml_contas').select('*').eq('situacao', 'ativo')).data ?? []) as Conta[];

  // ---- Agenda interna ----
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (cfg?.valor && req.headers.get('x-nox-chave') === cfg.valor) {
    if (corpo.acao !== 'sincronizar') return resp({ erro: 'Ação desconhecida' });
    const tarefa = sincronizarPerguntas(db, await contasAtivas()).catch(e => console.error(e));
    // @ts-ignore EdgeRuntime existe no Supabase
    EdgeRuntime.waitUntil(tarefa);
    return resp({ ok: true });
  }

  // ---- Tela ----
  const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
  const { data: eu } = await usuario.auth.getUser();
  if (!eu?.user) return resp({ erro: 'Faça login de novo' }, 401);
  const nivel = corpo.acao === 'sincronizar' ? 'ver' : 'alterar';
  const { data: pode } = await usuario.rpc('pode', { p_modulo: 'perguntas_ml', p_nivel: nivel });
  if (pode !== true) return resp({ erro: 'Sem permissão para esta ação na tela Perguntas ML' }, 403);

  try {
    if (corpo.acao === 'sincronizar') return resp(await sincronizarPerguntas(db, await contasAtivas(), 50_000));

    const id = Number(corpo.id);
    if (!id) return resp({ erro: 'Informe a pergunta' }, 400);
    const { data: p } = await db.from('ml_perguntas').select('*').eq('id', id).maybeSingle();
    if (!p) return resp({ erro: 'Pergunta não encontrada' }, 404);
    const { data: conta } = await db.from('ml_contas').select('*').eq('canal_id', p.canal_id).maybeSingle();
    if (!conta) return resp({ erro: 'Conta do ML desta pergunta não está autorizada' }, 400);

    if (corpo.acao === 'enviar') {
      const texto = String(corpo.texto ?? '').trim();
      const origem = !p.rascunho_ia ? 'manual' : texto === String(p.rascunho_ia).trim() ? 'ia_aprovada' : 'ia_editada';
      await enviarResposta(db, conta as Conta, id, texto, eu.user.id, origem);
      return resp({ ok: true, origem });
    }
    if (corpo.acao === 'gerar') {
      const r = await processarPergunta(db, conta as Conta, id, { forcarIa: true, instrucao: String(corpo.instrucao ?? '').trim().slice(0, 1000) || undefined });
      return resp({ ok: true, pergunta: r });
    }
    if (corpo.acao === 'ignorar') {
      await db.from('ml_perguntas').update({ situacao: 'ignorada', ignorada_por: eu.user.id }).eq('id', id).in('situacao', ['nova', 'aguardando', 'erro']);
      return resp({ ok: true });
    }
    if (corpo.acao === 'reabrir') {
      await db.from('ml_perguntas').update({ situacao: 'aguardando', ignorada_por: null }).eq('id', id).eq('situacao', 'ignorada');
      return resp({ ok: true });
    }
    return resp({ erro: 'Ação desconhecida' }, 400);
  } catch (e) {
    return resp({ erro: msg(e) }, 400);
  }
});
