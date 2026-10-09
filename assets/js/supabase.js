/* =====================================================================
   ERP NOX · supabase.js — conexão com o banco
   Troque apenas as duas linhas abaixo se mudar de projeto.
   A chave "publishable" / "anon public" é pública por natureza: a
   proteção dos dados é feita pelas regras (RLS) no banco.
   NUNCA coloque aqui a chave "secret" / "service_role".
   ===================================================================== */
const SUPABASE_URL = 'https://qijeqdfhwwruhoruvvgb.supabase.co';
const SUPABASE_KEY = 'sb_publishable_NANqT_NG-4IkuZqhv9gj1g_x4FTAILq';

// Cada alteração leva o id da tela de origem, para a Auditoria saber de onde veio.
window.db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  global: { headers: { 'x-tela': document.body?.dataset.modulo || 'inicio' } }
});
