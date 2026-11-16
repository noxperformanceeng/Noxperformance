#!/bin/bash
# ERP NOX · libera som e avisos do sistema neste Mac, sem o funcionário precisar clicar em nada.
# Vale para Google Chrome e Microsoft Edge. Rodar uma vez por computador (duplo clique) e reabrir o navegador.
SITE="https://noxperformanceeng.github.io"
for APP in com.google.Chrome com.microsoft.Edge; do
  defaults write "$APP" AutoplayAllowlist -array "$SITE"
  defaults write "$APP" NotificationsAllowedForUrls -array "$SITE"
done
osascript -e 'quit app "Google Chrome"' 2>/dev/null; osascript -e 'quit app "Microsoft Edge"' 2>/dev/null
echo ""
echo "Pronto: som e avisos do sistema NOX liberados neste computador."
echo "Abra o navegador de novo e entre no sistema."
read -n 1 -s -r -p "Aperte qualquer tecla para fechar."
