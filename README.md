# agentpro

The pro(xy) version of your coding agent.

agentpro runs Claude Code and Codex CLI against a shared [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) server, so one API key reaches every model on it. The server owner hands out the keys; none is in this repository.

- `claudepro` starts Claude Code.
- `codexpro` starts [Codex CLI](https://github.com/openai/codex).

## Install

Linux and macOS, from bash, zsh or fish. Needs `curl` and `python3`:

```sh
curl -fsSL https://raw.githubusercontent.com/beanbocchi/agentpro/main/install.sh | bash
```

Windows, from PowerShell:

```powershell
irm https://raw.githubusercontent.com/beanbocchi/agentpro/main/install.ps1 | iex
```

The installer asks for the key and checks it against the server before writing anything. It installs Claude Code if `claude` is missing; `codexpro` needs Codex CLI, which you install yourself. Run the installer again to update; it reuses the saved key. `CLAUDEPRO_KEY`, and `CLAUDEPRO_URL` for another server, skip the prompt.

The commands land in `~/.local/bin` on Linux and macOS, and in `%USERPROFILE%\.claudepro\bin` on Windows, which the installer adds to the user PATH.

## Use

```sh
claudepro                        # same arguments as claude
claudepro -p "explain this repo"
codexpro                         # same arguments as codex
codexpro exec "explain this repo"
```

Neither asks for permissions: Claude Code runs with `--dangerously-skip-permissions`, Codex with `approval_policy=never` and `sandbox_mode=danger-full-access`.

In `claudepro`, `/quota` shows the plan limits of the server's accounts. Ask for a picture and Claude calls the `generate_image` tool, which uses `gpt-image-2.5` on the server and can edit or follow reference images. The tool needs Python (`python3`, or `python` on Windows).

## Models

`/model` lists every chat model on the server, read again at each start, so a model the server adds shows up the next time. Image, audio and video generation models, embeddings and Codex's internal reviewer are left out.

`claudepro` lists the Claude models first and `codexpro` the GPT models. Within a family the newest generation comes first, and within a generation the larger line: Fable, Opus, Sonnet, Haiku for Claude; Astra, Sol, Terra, Luna for GPT.

Neither command pins a model. `claudepro` keeps Claude Code's own Default, Opus, Sonnet and Haiku rows, whose aliases move to the newest model with each Claude Code update, and Claude Code saves a `/model` choice as usual. `codexpro` starts on the model Codex itself would pick and keeps a `/model` choice too. To pin one for a run:

```sh
CLAUDEPRO_MODEL=claude-sonnet-5-5 claudepro
CODEXPRO_MODEL=gpt-6.1-sol codexpro
```

On Windows, `set CLAUDEPRO_MODEL=...` in cmd or `$env:CLAUDEPRO_MODEL = '...'` in PowerShell. A server owner pins a model for everyone with a model alias named `claudepro-default.<model id>` or `codexpro-default.<model id>`.

Both commands run every model, but GPT models are trained on Codex's prompt and tools and do better in `codexpro`. In Codex, a model the installed Codex does not ship, Claude models included, runs on Codex's `gpt-5.5` settings with OpenAI-only features turned off.

## Files and uninstall

| | Linux, macOS | Windows |
|---|---|---|
| Commands | `~/.local/bin/claudepro`, `codexpro` | `%USERPROFILE%\.claudepro\bin\` |
| Server URL and key | `~/.config/claudepro/url`, `key` | `%USERPROFILE%\.claudepro\url`, `key` |
| Launcher files | `~/.local/share/claudepro/` | `%USERPROFILE%\.claudepro\` |
| Codex config and sessions | `~/.local/share/claudepro/codex-home/` | `%USERPROFILE%\.claudepro\codex-home\` |

Codex keeps its own folder apart from `~/.codex`, so `codexpro resume` lists only `codexpro` sessions and `~/.codex/AGENTS.md` is not read.

To uninstall on Linux and macOS: `rm -rf ~/.local/bin/claudepro ~/.local/bin/codexpro ~/.local/share/claudepro ~/.config/claudepro`. On Windows, delete `%USERPROFILE%\.claudepro` and remove its `bin` folder from the user PATH.
