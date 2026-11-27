// ERP NOX · sefaz-certificado — recebe o certificado A1 (.pfx) e a senha enviados pelo administrador na tela Integrações,
// confere se a senha abre o arquivo, se o CNPJ é o da empresa e se está na validade, e guarda no cofre (Vault).
// O arquivo e a senha nunca voltam para a tela nem ficam em log.
import { createClient } from 'npm:@supabase/supabase-js@2';
import forge from 'npm:node-forge@1.3.1';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const resp = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const digitos = (t: string) => String(t || '').replace(/\D/g, '');

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: admin } = await usuario.rpc('eh_admin');
    const { data: quem } = await usuario.auth.getUser();
    if (admin !== true || !quem?.user) return resp({ erro: 'Só o administrador envia o certificado' }, 403);

    const { empresa_id, pfx_base64, senha } = await req.json().catch(() => ({}));
    if (!empresa_id || !pfx_base64 || typeof senha !== 'string') return resp({ erro: 'Escolha a empresa, o arquivo .pfx e digite a senha' }, 400);
    if (pfx_base64.length > 200_000) return resp({ erro: 'Arquivo grande demais para um certificado A1' }, 400);

    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data: emp } = await db.from('empresas').select('id, nome, cnpj').eq('id', empresa_id).maybeSingle();
    if (!emp) return resp({ erro: 'Empresa não encontrada' }, 400);

    // abre o .pfx com a senha
    let p12;
    try { p12 = forge.pkcs12.pkcs12FromAsn1(forge.asn1.fromDer(forge.util.decode64(pfx_base64)), senha); }
    catch { return resp({ erro: 'Não abriu o certificado: senha errada ou arquivo não é um .pfx/.p12 válido' }, 400); }
    const certs = (p12.getBags({ bagType: forge.pki.oids.certBag })[forge.pki.oids.certBag] || []).map((b: any) => b.cert).filter(Boolean);
    const chaves = [...(p12.getBags({ bagType: forge.pki.oids.pkcs8ShroudedKeyBag })[forge.pki.oids.pkcs8ShroudedKeyBag] || []),
                    ...(p12.getBags({ bagType: forge.pki.oids.keyBag })[forge.pki.oids.keyBag] || [])];
    if (!certs.length || !chaves.length) return resp({ erro: 'O arquivo não tem certificado com chave privada (precisa ser o A1 completo)' }, 400);
    // o certificado da empresa é o que não é de autoridade certificadora
    const cert = certs.find((c: any) => !(c.getExtension('basicConstraints')?.cA)) || certs[0];
    const cn = String(cert.subject.getField('CN')?.value || '');
    const cnpjCert = (cn.match(/(\d{14})\s*$/) || [])[1] || (digitos(cn).length >= 14 ? digitos(cn).slice(-14) : '');
    if (cnpjCert && digitos(emp.cnpj) && cnpjCert !== digitos(emp.cnpj)) {
      return resp({ erro: `Este certificado é do CNPJ ${cnpjCert.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5')}, não da ${emp.nome} (${emp.cnpj})` }, 400);
    }
    const ate = cert.validity.notAfter as Date, de = cert.validity.notBefore as Date;
    if (ate.getTime() < Date.now()) return resp({ erro: `Certificado vencido em ${ate.toLocaleDateString('pt-BR')}` }, 400);

    const { error } = await db.rpc('sefaz_cert_guardar', {
      p_empresa: emp.id, p_pfx_b64: pfx_base64, p_senha: senha, p_cnpj: cnpjCert || digitos(emp.cnpj),
      p_titular: cn.replace(/:\d{14}\s*$/, '').trim(), p_valido_de: de.toISOString(), p_valido_ate: ate.toISOString(), p_por: quem.user.id });
    if (error) return resp({ erro: 'Não guardou: ' + error.message }, 500);
    return resp({ ok: true, empresa: emp.nome, cnpj: cnpjCert || digitos(emp.cnpj), titular: cn, valido_ate: ate.toISOString() });
  } catch (e) {
    return resp({ erro: 'Falha ao processar o certificado: ' + String((e as Error).message ?? e).slice(0, 200) }, 500);
  }
});
