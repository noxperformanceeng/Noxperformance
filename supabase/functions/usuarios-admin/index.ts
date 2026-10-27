// ERP NOX · usuarios-admin — cria login de usuário e gera link para a pessoa criar a própria senha.
// Só administrador do sistema (eh_admin) pode chamar. Ninguém digita nem vê senha:
// o login nasce com senha aleatória e a pessoa define a dela pelo link (válido por pouco tempo).
//   { acao: 'criar', email, nome, perfil_id }  → cria (ou reaproveita) o login e devolve { link }
//   { acao: 'link',  usuario_id }               → novo link de "criar/trocar senha" para um usuário existente
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
// para onde o link manda (tela de login do sistema, que já sabe receber "nova senha")
const SITES = ['https://noxperformanceeng.github.io/Noxperformance/', 'http://localhost:8000/'];

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: admin } = await usuario.rpc('eh_admin');
    if (admin !== true) return resp({ erro: 'Só administrador cria usuários' }, 403);

    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const corpo = await req.json().catch(() => ({}));
    const site = SITES.find(s => String(corpo.site || '').startsWith(s)) ?? SITES[0];
    const redirectTo = site + 'index.html';

    const gerarLink = async (email: string) => {
      const { data, error } = await db.auth.admin.generateLink({ type: 'recovery', email, options: { redirectTo } });
      if (error) throw new Error('link: ' + error.message);
      return data.properties?.action_link;
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
        const senha = crypto.randomUUID() + crypto.randomUUID();   // ninguém usa: a pessoa cria a dela pelo link
        const { data, error } = await db.auth.admin.createUser({ email, password: senha, email_confirm: true, user_metadata: { nome } });
        if (error) return resp({ erro: 'Não criou o login: ' + error.message }, 400);
        id = data.user.id;
      }
      const { error: eu } = await db.from('usuarios').update({ nome, perfil_id: perfil, ativo: true }).eq('id', id);
      if (eu) return resp({ erro: 'Login criado, mas não gravou o perfil: ' + eu.message }, 500);
      return resp({ ok: true, id, ja_existia: !!ja, link: await gerarLink(email) });
    }

    if (corpo.acao === 'link') {
      const { data: u } = await db.from('usuarios').select('email').eq('id', String(corpo.usuario_id || '')).maybeSingle();
      if (!u?.email) return resp({ erro: 'Usuário não encontrado' }, 404);
      return resp({ ok: true, link: await gerarLink(u.email) });
    }
    return resp({ erro: 'Ação desconhecida' }, 400);
  } catch (e) {
    return resp({ erro: String((e as Error).message || e) }, 500);
  }
});
