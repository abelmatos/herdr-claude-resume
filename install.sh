#!/usr/bin/env bash
# Keep Claude Code sessions across Windows/WSL restarts when using herdr (https://herdr.dev).
#
# herdr keeps its tabs across a restart, but a lost terminal (reboot, `wsl --shutdown`,
# Windows update) comes back as a bare shell: the `claude` that ran in it is gone. Each tab
# keeps its address (HC_TERMINAL_ID), so this setup records which Claude session ran in which
# tab and resumes it when the tab's shell starts again.
#
# Installs:
#   1. ~/.claude/hooks/herdr-session.sh + a SessionStart hook in ~/.claude/settings.json
#   2. ~/.config/herdr-claude/resume.zsh, sourced from ~/.zshrc
#   3. (optional, with --args) herdr-app's Claude Code menu entry starts claude with those args
#
# Usage:  ./install.sh [--args "--permission-mode acceptEdits"] [--uninstall]
# Needs:  WSL (or Linux) with zsh as the tab shell, jq, Claude Code, herdr.
set -euo pipefail

ARGS="" UNINSTALL=0
while (($#)); do
  case "$1" in
    --args) ARGS="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required (sudo apt install jq)" >&2; exit 1; }

HOOK="$HOME/.claude/hooks/herdr-session.sh"
SETTINGS="$HOME/.claude/settings.json"
ZFILE="$HOME/.config/herdr-claude/resume.zsh"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
SOURCE_LINE='[[ -r ~/.config/herdr-claude/resume.zsh ]] && source ~/.config/herdr-claude/resume.zsh  # herdr-claude-resume'
HOOK_CMD='~/.claude/hooks/herdr-session.sh'

# herdr-app's settings live in the Windows profile (%USERPROFILE%\.config\herdr-app),
# or in ~/.config/herdr-app on a Linux/macOS install.
herdr_app_settings() {
  [[ -n "${HERDR_APP_SETTINGS:-}" ]] && { echo "$HERDR_APP_SETTINGS"; return; }
  local win
  if [[ -x /mnt/c/Windows/System32/cmd.exe ]]; then
    win=$(cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')
    [[ -n "$win" ]] && { echo "$(wslpath -u "$win")/.config/herdr-app/settings.json"; return; }
  fi
  echo "${HERDR_APP_HOME:-$HOME/.config/herdr-app}/settings.json"
}

backup() { [[ -f "$1" ]] && cp -p "$1" "$1.bak-herdr-claude.$(date +%Y%m%d%H%M%S)"; return 0; }

if ((UNINSTALL)); then
  rm -f "$HOOK" "$ZFILE"
  if [[ -f "$SETTINGS" ]]; then
    backup "$SETTINGS"
    jq --arg c "$HOOK_CMD" '
      if .hooks.SessionStart then
        .hooks.SessionStart |= map(.hooks |= map(select(.command != $c)) | select(.hooks | length > 0))
        | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
      else . end' "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  fi
  [[ -f "$ZSHRC" ]] && { backup "$ZSHRC"; grep -vF '# herdr-claude-resume' "$ZSHRC" >"$ZSHRC.tmp" || true; mv "$ZSHRC.tmp" "$ZSHRC"; }
  echo "Uninstalled. herdr-app's programs.claude entry (if any) was left in $(herdr_app_settings)."
  exit 0
fi

# 1. SessionStart hook ---------------------------------------------------------------------
mkdir -p "$(dirname "$HOOK")"
cat >"$HOOK" <<'EOF'
#!/usr/bin/env bash
# SessionStart hook: remember which Claude session runs in which herdr terminal, so the
# shell can resume it after a restart. Writes ~/.local/state/herdr-claude/<HC_TERMINAL_ID>:
# line 1 session id, line 2 working directory.
[[ -n "$HC_TERMINAL_ID" ]] || exit 0

# Only the tab's top-level claude counts: skip a claude started by another claude
# (e.g. `claude -p` from a tool call), which inherits the same HC_TERMINAL_ID.
n=0 pid=$PPID
while [[ "$pid" -gt 1 ]]; do
  [[ "$(cat /proc/$pid/comm 2>/dev/null)" == claude ]] && n=$((n + 1))
  pid=$(awk '{print $4}' /proc/$pid/stat 2>/dev/null) || break
  [[ -n "$pid" ]] || break
done
[[ "$n" -eq 1 ]] || exit 0

input=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$sid" ]] || exit 0

dir="$HOME/.local/state/herdr-claude"
mkdir -p "$dir"
printf '%s\n%s\n' "$sid" "${cwd:-$PWD}" >"$dir/$HC_TERMINAL_ID.tmp" &&
  mv -f "$dir/$HC_TERMINAL_ID.tmp" "$dir/$HC_TERMINAL_ID"
exit 0
EOF
chmod +x "$HOOK"

[[ -f "$SETTINGS" ]] || echo '{}' >"$SETTINGS"
if ! jq -e --arg c "$HOOK_CMD" '[.hooks.SessionStart[]?.hooks[]?.command] | index($c)' "$SETTINGS" >/dev/null; then
  backup "$SETTINGS"
  jq --arg c "$HOOK_CMD" '.hooks.SessionStart += [{"matcher":"","hooks":[{"type":"command","command":$c,"timeout":10}]}]' \
    "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

# 2. zsh: resume on shell start, forget on normal exit ---------------------------------------
mkdir -p "$(dirname "$ZFILE")"
{
  echo '# herdr: resume this tab'"'"'s Claude session after a restart (installed by herdr-claude-resume).'
  printf 'typeset -ga HERDR_CLAUDE_ARGS=(%s)\n' "$ARGS"
  cat <<'EOF'
if [[ -n $HC_TERMINAL_ID && -o interactive && -z $CLAUDECODE ]]; then
  # Exiting claude normally forgets the tab's session; a restart kills it, so it stays.
  claude() {
    command claude "$@"
    local rc=$?
    rm -f -- ~/.local/state/herdr-claude/$HC_TERMINAL_ID
    return $rc
  }
  # Runs once, at the first prompt, after the rest of .zshrc has loaded.
  _herdr_claude_resume() {
    add-zsh-hook -d precmd _herdr_claude_resume
    local f=~/.local/state/herdr-claude/$HC_TERMINAL_ID
    [[ -r $f ]] || return
    local -a rec=("${(@f)$(<$f)}")
    [[ -n ${rec[1]} ]] || return
    [[ -d ${rec[2]} ]] && cd -- "${rec[2]}"
    print -P "%F{8}herdr: resuming Claude session ${rec[1]}%f"
    claude "${HERDR_CLAUDE_ARGS[@]}" --resume "${rec[1]}"
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _herdr_claude_resume
fi
EOF
} >"$ZFILE"

touch "$ZSHRC"
grep -qF '# herdr-claude-resume' "$ZSHRC" || { backup "$ZSHRC"; printf '\n%s\n' "$SOURCE_LINE" >>"$ZSHRC"; }

# 3. herdr-app menu entry (only with --args) -------------------------------------------------
if [[ -n "$ARGS" ]]; then
  HS=$(herdr_app_settings)
  if [[ -d "$(dirname "$HS")" ]]; then
    [[ -f "$HS" ]] || echo '{}' >"$HS"
    backup "$HS"
    read -ra argv <<<"$ARGS"
    jq --argjson run "$(printf '%s\n' claude "${argv[@]}" | jq -R . | jq -s .)" '.programs.claude.run = $run' \
      "$HS" >"$HS.tmp" && mv "$HS.tmp" "$HS"
    echo "herdr-app: Claude Code menu entry now runs: claude $ARGS ($HS)"
  else
    echo "herdr-app settings folder not found ($(dirname "$HS")); skipped the menu entry." >&2
  fi
fi

cat <<EOF
Installed.
  hook:     $HOOK (SessionStart in $SETTINGS)
  shell:    $ZFILE (sourced from $ZSHRC)
Sessions are recorded from the next Claude start (or /clear, /resume) in each herdr tab.
Open a new herdr tab (or restart herdr-app) so the shell picks up the change.
EOF
