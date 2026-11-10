# herdr-claude-resume

Keep your Claude Code sessions when Windows restarts, updates, or WSL shuts down, if you run them in [herdr](https://herdr.dev) tabs.

## The problem

herdr keeps its spaces and tabs after a restart. A terminal lost to a reboot, a `wsl --shutdown` or a Windows update comes back as a **bare shell in its last folder**, though. herdr never runs the original command again, so every `claude` that was open is gone and you have to find each session and `claude --resume <id>` it by hand.

## Why this exists, and when to stop using it

This is a stopgap. The older herdr TUI resumed agent sessions after a restart; the herdr app and herdr-core (0.1.x) don't yet. Upstream tracks it in:

- [herdr-app#406](https://github.com/herdrdev/herdr-app/issues/406): after a reboot, agent sessions aren't resumed. A comment there reproduces it with Claude Code: every tab came back as a fresh shell, and nothing tied a tab to the session it had been running.
- [herdr-core#15](https://github.com/herdrdev/herdr-core/issues/15): the design for a proper fix. Agents would report how to continue their conversation through OSC 7501, the escape code herdr already uses for agent status. herdr-core would store that on the terminal, and the app would offer to resume it.
- [herdr-core#133](https://github.com/herdrdev/herdr-core/issues/133): the same loss when herdr-core is updated on a remote machine.

Once herdr resumes Claude Code sessions itself, run `./install.sh --uninstall`; otherwise both would try to resume the same tab. Check those issues, or herdr's release notes, for a "resume" feature.

It also avoids two bugs that the herdr TUI's built-in resume had: resuming the session from before a `/clear` ([herdr#5547](https://github.com/herdrdev/herdr/issues/5547)), and a nested `claude -p --resume` overwriting the tab's session ([herdr#4919](https://github.com/herdrdev/herdr/issues/4919)). The hook runs again after `/clear`, and it ignores any `claude` started by another `claude`.

## How it works

Each herdr tab keeps the same address (`HC_TERMINAL_ID`, e.g. `t7`) after a restart. This setup uses that:

1. A Claude Code `SessionStart` hook writes the tab's current session id and folder to `~/.local/state/herdr-claude/<tab>`. It runs on start, `/resume` and `/clear`, so the file follows the session you are actually in. It ignores a `claude` started by another `claude` (e.g. `claude -p` from a tool call).
2. A zsh snippet runs when the tab's shell shows its first prompt. If the tab has a saved session, it changes to that folder and runs `claude --resume <id>`.
3. A small `claude` wrapper deletes the tab's file when you exit Claude yourself, so sessions you closed on purpose don't come back. A restart kills Claude without running that cleanup, so the file stays and the session resumes.

## Requirements

- Windows + WSL (or plain Linux), with **zsh** as the shell in herdr tabs
- `jq` (`sudo apt install jq`)
- Claude Code, and herdr with its core running in WSL

## Install

```sh
./install.sh                                          # resume with plain `claude --resume`
./install.sh --args "--permission-mode acceptEdits"   # resume with these flags too
```

`--args` sets the flags used when resuming. It also sets the command behind herdr-app's **Claude Code** menu entry (`programs.claude.run` in `%USERPROFILE%\.config\herdr-app\settings.json`), so menu tabs start the same way. Restart herdr-app afterwards.

The installer can be re-run safely and backs up every file it changes (`*.bak-herdr-claude.<timestamp>`). It changes:

| File | Change |
|---|---|
| `~/.claude/hooks/herdr-session.sh` | new hook script |
| `~/.claude/settings.json` | adds the `SessionStart` hook |
| `~/.config/herdr-claude/resume.zsh` | new zsh snippet |
| `~/.zshrc` | one `source` line, tagged `# herdr-claude-resume` |
| herdr-app `settings.json` | `programs.claude.run`, only with `--args` |

Tabs that are already open start being recorded the next time Claude starts in them, or when you run `/clear` or `/resume`.

## Test

1. Open Claude in a few herdr tabs and send a message in each.
2. Run `ls ~/.local/state/herdr-claude/`: you should see one file per tab.
3. Run `wsl --shutdown` in PowerShell, or reboot, then open herdr-app.
4. Each tab prints `herdr: resuming Claude session <id>` and reopens its conversation.

If a tab doesn't resume, check that `echo $HC_TERMINAL_ID` in that tab matches a file in `~/.local/state/herdr-claude/`, then run `_herdr_claude_resume` by hand to see the error.

## Uninstall

```sh
./install.sh --uninstall
```

This removes the hook, the snippet and the `.zshrc` line. It leaves herdr-app's `programs.claude` entry alone, so remove that by hand if you set one.

## Limits

- zsh only; bash would need the same logic in `PROMPT_COMMAND`.
- One Claude per tab. A tab split into several panes works, since each pane is its own terminal.
- If you close a tab, its file stays in `~/.local/state/herdr-claude/` until you delete it. It does no harm, because herdr doesn't reuse terminal addresses.

<!-- 2335fd43-3c69-4571-aa15-f08c088ec072 -->
