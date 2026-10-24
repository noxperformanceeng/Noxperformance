#!/usr/bin/env bash
# PreToolUse (Bash): antes de um "git commit" que leva arquivos de assets/, carimba a versão nos HTML.
cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))')
[[ "$cmd" == *"git commit"* ]] || exit 0
cd "$CLAUDE_PROJECT_DIR" || exit 0
if git diff --cached --name-only | grep -q '^assets/\(js\|css\)/'; then
  python3 tools/versao.py >&2
  git add -u -- '*.html' 'pages/*/*.html'
fi
exit 0
