// ERP NOX · usuarios-admin — cria login de usuário e convite para a pessoa criar a própria senha.
// Ninguém digita nem vê a senha de outra pessoa: o login nasce com senha aleatória e a pessoa grava a dela
// pela página senha.html, com o convite (vale 48 h, uma vez só). Abrir o link ou a prévia do WhatsApp não gasta o convite.
//   { acao: 'criar', email, nome, perfil_id }   (administrador) → cria (ou reaproveita) o login e devolve { link }
//   { acao: 'link',  usuario_id }                (administrador) → convite novo para um usuário existente
//   { acao: 'ver_convite', convite }             (qualquer um)   → { nome, email, expira_em } se o convite vale
//   { acao: 'definir_senha', convite, senha }    (qualquer um)   → grava a senha e encerra o convite
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const SITES = ['https://noxperformanceeng.github.io/Noxperformance/', 'http://localhost:8000/'];
const HORAS = 48;

const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
async function hash(t: string) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t)));
  return [...d].map(x => x.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { ...cors, 'Access-Control-Allow-Headers': req.headers.get('access-control-request-headers') ?? cors['Access-Control-Allow-Headers'], 'Access-Control-Max-Age': '600' } });
  try {
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const corpo = await req.json().catch(() => ({}));

    // ---------- Página do convite (sem login) ----------
    if (corpo.acao === 'ver_convite' || corpo.acao === 'definir_senha') {
      const t = String(corpo.convite || '');
      if (t.length < 30) return resp({ erro: 'Convite inválido' }, 400);
      const { data: c } = await db.from('usuarios_convites').select('id, usuario_id, expira_em, usado_em, cancelado_em').eq('token_hash', await hash(t)).maybeSingle();
      if (!c) return resp({ erro: 'Convite não encontrado. Peça um novo ao administrador.' }, 404);
      if (c.usado_em) return resp({ erro: 'Este convite já foi usado: a senha já foi criada. Entre com seu e-mail e senha, ou use "Esqueci minha senha".' }, 410);
      if (c.cancelado_em) return resp({ erro: 'Este convite foi substituído por um mais novo. Use o último link que você recebeu.' }, 410);
      if (new Date(c.expira_em) < new Date()) return resp({ erro: 'Este convite venceu (vale 48 horas). Peça um novo ao administrador.' }, 410);
      const { data: u } = await db.from('usuarios').select('nome, email, ativo').eq('id', c.usuario_id).maybeSingle();
      if (!u?.ativo) return resp({ erro: 'Usuário inativo. Fale com o administrador.' }, 403);
      if (corpo.acao === 'ver_convite') return resp({ ok: true, nome: u.nome, email: u.email, expira_em: c.expira_em });
      const senha = String(corpo.senha || '');
      if (senha.length < 8) return resp({ erro: 'A senha precisa ter pelo menos 8 caracteres' }, 400);
      // marca como usado antes de gravar (evita dois usos ao mesmo tempo)
      const { data: marcado } = await db.from('usuarios_convites').update({ usado_em: new Date().toISOString() }).eq('id', c.id).is('usado_em', null).select('id');
      if (!marcado?.length) return resp({ erro: 'Este convite já foi usado.' }, 410);
      const { error } = await db.auth.admin.updateUserById(c.usuario_id, { password: senha, email_confirm: true });
      if (error) {
        await db.from('usuarios_convites').update({ usado_em: null }).eq('id', c.id);
        return resp({ erro: 'Não gravou a senha: ' + error.message }, 400);
      }
      return resp({ ok: true, email: u.email });
    }

    // ---------- Daqui para baixo: só administrador ----------
    const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: admin } = await usuario.rpc('eh_admin');
    if (admin !== true) return resp({ erro: 'Só administrador cria usuários' }, 403);
    const { data: eu } = await usuario.auth.getUser((req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, ''));
    const site = SITES.find(s => String(corpo.site || '').startsWith(s)) ?? SITES[0];

    const convite = async (usuarioId: string) => {
      await db.from('usuarios_convites').update({ cancelado_em: new Date().toISOString() }).eq('usuario_id', usuarioId).is('usado_em', null).is('cancelado_em', null);
      const t = b64url(crypto.getRandomValues(new Uint8Array(32)));
      const expira = new Date(Date.now() + HORAS * 3600e3).toISOString();
      const { error } = await db.from('usuarios_convites').insert({ usuario_id: usuarioId, token_hash: await hash(t), criado_por: eu?.user?.id ?? null, expira_em: expira });
      if (error) throw new Error('convite: ' + error.message);
      return { link: site + 'senha.html?c=' + t, expira_em: expira };
    };

    if (corpo.acao === 'criar') {
      const email = String(corpo.email || '').trim().toLowerCase();
      const nome = String(corpo.nome || '').trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return resp({ erro: 'E-mail inválido' }, 400);
      if (!nome) return resp({ erro: 'Informe o nome' }, 400);
      const perfil = corpo.perfil_id ? String(corpo.perfil_id) : null;
      if (perfil) { const { data: p } = await db.from('perfis').select('id').eq('id', perfil).maybeSingle(); if (!p) return resp({ erro: 'Perfil não encontrado' }, 400); }

      const { data: ja } = await db.from('usuarios').select('id').ilike('email', email).maybeSingle();
      let id = ja?.id as string | undefined;
      if (!id) {
        const senha = b64url(crypto.getRandomValues(new Uint8Array(32)));   // ninguém usa: a pessoa cria a dela pelo convite
        const { data, error } = await db.auth.admin.createUser({ email, password: senha, email_confirm: true, user_metadata: { nome } });
        if (error) return resp({ erro: 'Não criou o login: ' + error.message }, 400);
        id = data.user.id;
      }
      const { error: eu2 } = await db.from('usuarios').update({ nome, perfil_id: perfil, ativo: true }).eq('id', id);
      if (eu2) return resp({ erro: 'Login criado, mas não gravou o perfil: ' + eu2.message }, 500);
      return resp({ ok: true, id, ja_existia: !!ja, ...(await convite(id!)) });
    }

    if (corpo.acao === 'link') {
      const { data: u } = await db.from('usuarios').select('id').eq('id', String(corpo.usuario_id || '')).maybeSingle();
      if (!u) return resp({ erro: 'Usuário não encontrado' }, 404);
      return resp({ ok: true, ...(await convite(u.id)) });
    }
    return resp({ erro: 'Ação desconhecida' }, 400);
  } catch (e) {
    return resp({ erro: String((e as Error).message || e) }, 500);
  }
});
