/* =====================================================================
   ERP NOX · auth.js — login, logout e checagem de acesso
   ===================================================================== */

// Endereço da raiz do sistema (funciona no GitHub Pages e local)
const RAIZ = new URL('../../', document.currentScript.src).href;

// Carrega quem está logado + telas liberadas. Sem login → volta para o login.
async function carregarSessao() {
  const { data: { session } } = await db.auth.getSession();
  if (!session) { location.href = RAIZ + 'index.html'; return null; }

  const [{ data: usuario }, { data: perms, error }] = await Promise.all([
    db.from('usuarios').select('id, nome, email, perfil_id, ativo, perfis(nome)').eq('id', session.user.id).maybeSingle(),
    db.rpc('minhas_permissoes')
  ]);

  if (error) console.error(error);
  if (usuario && !usuario.ativo) {
    await db.auth.signOut();
    alert('Seu acesso está desativado. Fale com o administrador.');
    location.href = RAIZ + 'index.html';
    return null;
  }

  const niveis = {};
  (perms || []).forEach(p => { niveis[p.modulo_id] = p.nivel; });

  return {
    usuario: usuario || { id: session.user.id, email: session.user.email, nome: session.user.email },
    admin: usuario?.perfil_id === 'admin',
    niveis,
    pode: (modulo, nivel = 'ver') => niveis[modulo] === 'editar' || (nivel === 'ver' && niveis[modulo] === 'ver')
  };
}

async function sair() {
  await db.auth.signOut();
  location.href = RAIZ + 'index.html';
}
