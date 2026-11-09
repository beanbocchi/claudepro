# claudepro

`claudepro` runs Claude Code against a shared [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) server. It fetches the server's model list, fills the `/model` picker with it, starts on the model the server picks as default, and adds a `/quota` command that shows the plan limits of the server's accounts.

You need an API key for the server. Ask the server owner for one; it is not in this repository.

## Install

Linux and macOS, from bash, zsh or fish. Needs `curl` and `python3`:

```sh
curl -fsSL https://raw.githubusercontent.com/beanbocchi/claudepro/main/install.sh | bash
```

Windows, from PowerShell:

```powershell
irm https://raw.githubusercontent.com/beanbocchi/claudepro/main/install.ps1 | iex
```

The installer asks for the key and checks it against the server before writing anything. It installs Claude Code if `claude` is missing. Run it again to update; it reuses the saved key.

To install without the prompt, set `CLAUDEPRO_KEY` (and `CLAUDEPRO_URL` for a server other than the default) before running it.

| | Linux, macOS | Windows |
|---|---|---|
| Command | `~/.local/bin/claudepro` | `%USERPROFILE%\.claudepro\bin\claudepro.cmd`, plus `claudepro` for Git Bash |
| Server URL and key | `~/.config/claudepro/url`, `key` | `%USERPROFILE%\.claudepro\url`, `key` |
| Launcher files | `~/.local/share/claudepro/` | `%USERPROFILE%\.claudepro\` |

If `~/.local/bin` is not on your PATH, the installer prints the line to add for your shell. On Windows it adds the `bin` folder to the user PATH; open a new terminal afterwards.

## Use

```sh
claudepro                        # interactive, same arguments as claude
claudepro -p "explain this repo"
CLAUDEPRO_MODEL=gpt-6-luna claudepro    # another model for one run
```

On Windows: `set CLAUDEPRO_MODEL=gpt-6-luna` in cmd, or `$env:CLAUDEPRO_MODEL = 'gpt-6-luna'` in PowerShell.

Claude Code runs with `--dangerously-skip-permissions`, and `--permission-mode` is refused.

## Uninstall

Linux and macOS: `rm -rf ~/.local/bin/claudepro ~/.local/share/claudepro ~/.config/claudepro`.

Windows: delete `%USERPROFILE%\.claudepro` and remove its `bin` folder from the user PATH.

## Repository layout

- `install.sh`, `bin/claudepro`, `lib/claudepro-settings`: the Linux and macOS installer, launcher, and the Python script that builds the model picker settings.
- `install.ps1`, `windows/claudepro.ps1`: the Windows installer and launcher.
- `quota-mod/`: the Claude Code mod behind `/quota`. Tests run with `claude plugin test` inside it.
- `server/quota-server.py`: the service on the proxy host that `/quota` calls, on port 8318.

The server chooses the default model with a model alias named `claudepro-default.<model id>`. Without one, the launcher falls back to `claude-opus-5-5`, then `gpt-6-luna`.
