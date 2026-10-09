# ERP NOX — pacote inicial (Fase 0 + Fase 1)

## 1. Banco (Supabase) — uma vez
1. Supabase → SQL Editor → New → abrir `sql/001_base.sql`, copiar tudo, colar → **Run**.
2. Authentication → Sign In / Providers → Email: **desligar "Confirm email"** e **desligar "Allow new users to sign up"**
   (só entra quem você cadastrar).
3. Authentication → Users → **Add user → Create new user** → seu e-mail e senha → marcar **Auto Confirm User**.
   O primeiro usuário vira Administrador automaticamente.
4. Authentication → URL Configuration → **Site URL** = `https://noxperformanceeng.github.io/Noxperformance/`

## 2. Chave do banco — uma vez
Project Settings → API Keys → copiar a **Publishable key** (ou "anon public").
Abrir `assets/js/supabase.js` e colar no lugar de `COLE_AQUI_A_PUBLISHABLE_KEY`.
Nunca use a chave "secret" / "service_role".

## 3. Subir os arquivos (GitHub)
1. Repositório Noxperformance → **enviando um arquivo existente** (uploading an existing file).
2. Arrastar o CONTEÚDO desta pasta (index.html, inicio.html, assets, pages, sql, LEIA-ME.md) → **Commit changes**.
3. Settings → Pages → Source: **Deploy from a branch** → Branch **main** / **(root)** → Save.
4. Em 1–2 min o sistema abre em `https://noxperformanceeng.github.io/Noxperformance/`

## 4. Cadastrar a equipe
Supabase → Authentication → Users → Add user (Auto Confirm) para cada pessoa.
Depois, no sistema: Configurações → Usuários e acessos → escolher o perfil e, em **Editar**,
liberar telas a mais ou bloquear telas só daquela pessoa. Aba **Empresas**: nome, CNPJ e regime.

## Atualizações futuras
Cada entrega nova vem com o caminho do arquivo. No GitHub: abrir o arquivo → lápis (editar) →
colar → Commit. Arquivo novo: Add file → Upload files, mantendo a pasta indicada.
