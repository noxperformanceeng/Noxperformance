# ERP NOX — pacote inicial (Fase 0 + Fase 1)

## 1. Banco (Supabase) — uma vez
1. Supabase → SQL Editor → New → abrir `sql/001_base.sql`, copiar tudo, colar → **Run**.
   Depois, uma nova aba (New) com `sql/002_auditoria.sql` → **Run**.
   Depois, `sql/003_acesso_api.sql` → **Run** (libera as tabelas para usuários logados).
2. Authentication → Sign In / Providers → Email: **desligar "Confirm email"** e **desligar "Allow new users to sign up"**
   (só entra quem você cadastrar).
3. Authentication → Users → **Add user → Create new user** → seu e-mail e senha → marcar **Auto Confirm User**.
   O primeiro usuário vira Administrador automaticamente.
4. Authentication → URL Configuration → **Site URL** = `https://noxperformanceeng.github.io/Noxperformance/`

## 2. Chave do banco
Já está configurada em `assets/js/supabase.js`. Nunca coloque ali a chave "secret" / "service_role".

## 3. Subir os arquivos (GitHub)
1. Repositório Noxperformance → **enviando um arquivo existente** (uploading an existing file).
2. Abrir a pasta descompactada no Windows Explorer, selecionar TUDO (Ctrl+A: as pastas assets, pages, sql
   e os arquivos) e ARRASTAR para a página do GitHub → **Commit changes**.
   Atenção: o botão "choose your files" não envia pastas, só arrastando. Não envie o .zip.
3. Settings → Pages → Source: **Deploy from a branch** → Branch **main** / **(root)** → Save.
4. Em 1–2 min o sistema abre em `https://noxperformanceeng.github.io/Noxperformance/`

## 4. Cadastrar a equipe
Supabase → Authentication → Users → Add user (Auto Confirm) para cada pessoa.
Depois, no sistema: Configurações → Usuários e acessos → escolher o perfil e, em **Editar**,
liberar telas a mais ou bloquear telas só daquela pessoa. Aba **Empresas**: nome, CNPJ e regime.

## Atualizações futuras
Cada entrega nova vem com o caminho do arquivo. No GitHub: abrir o arquivo → lápis (editar) →
colar → Commit. Arquivo novo: Add file → Upload files, mantendo a pasta indicada.

## Auditoria
Toda alteração de dados fica registrada (usuário, data, hora, tela, o que era e como ficou).
Consulta: Configurações → Auditoria. Ninguém consegue editar ou apagar esse histórico.
Toda tabela nova do sistema termina seu SQL com `select public.ligar_auditoria('nome_da_tabela');`
