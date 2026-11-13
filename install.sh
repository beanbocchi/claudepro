#!/usr/bin/env bash
# Installs agentpro, the claudepro and codexpro commands, on Linux and macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/beanbocchi/agentpro/main/install.sh | bash
#
# It asks for the API key, checks it against the server, and writes
#   ~/.config/claudepro/{url,key}
#   ~/.local/share/claudepro/{claudepro-settings,quota-mod/,image-mod/}
#   ~/.local/bin/{claudepro,codexpro}
# It installs Claude Code if `claude` is missing. Run it again to update.
#
# CLAUDEPRO_KEY and CLAUDEPRO_URL skip the prompt and the default server.
set -euo pipefail

DEFAULT_URL=http://khoakomlem-internal.ddns.net:8317
TARBALL=https://codeload.github.com/beanbocchi/agentpro/tar.gz/refs/heads/main
tmp=''

fail() {
    echo "claudepro install: $*" >&2
    exit 1
}

main() {
    local config="$HOME/.config/claudepro"
    local share="$HOME/.local/share/claudepro"
    local bindir="$HOME/.local/bin"

    command -v python3 >/dev/null || fail 'python3 is required; install it and run this again'
    command -v curl >/dev/null || fail 'curl is required'

    # Use the files next to this script when run from a clone, else download them.
    local src=''
    [ -z "${BASH_SOURCE[0]:-}" ] || src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [ ! -f "$src/bin/claudepro" ] || [ ! -f "$src/lib/claudepro-settings" ]; then
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        curl -fsSL "$TARBALL" | tar xz -C "$tmp" --strip-components=1 || fail "cannot download $TARBALL"
        src=$tmp
    fi

    local url="${CLAUDEPRO_URL:-}"
    [ -n "$url" ] || url=$(cat "$config/url" 2>/dev/null || true)
    [ -n "$url" ] || url=$DEFAULT_URL
    url=${url%/}

    local key="${CLAUDEPRO_KEY:-}"
    if [ -z "$key" ] && [ -s "$config/key" ]; then
        key=$(cat "$config/key")
        echo "Using the API key already in $config/key"
    fi
    if [ -z "$key" ]; then
        { : </dev/tty; } 2>/dev/null || fail 'no terminal to ask for the API key; set CLAUDEPRO_KEY'
        printf 'API key for %s: ' "$url" >/dev/tty
        IFS= read -rs key </dev/tty
        printf '\n' >/dev/tty
    fi
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    [ -n "$key" ] || fail 'the API key is empty'

    echo "Checking the key against $url ..."
    CLAUDEPRO_BASE_URL=$url CLAUDEPRO_AUTH_TOKEN=$key python3 "$src/lib/claudepro-settings" >/dev/null ||
        fail 'the server rejected the key or is unreachable (message above)'

    mkdir -p "$config" "$share" "$bindir"
    chmod 700 "$config"
    printf '%s\n' "$url" >"$config/url"
    (umask 077 && printf '%s\n' "$key" >"$config/key")

    install -m 755 "$src/lib/claudepro-settings" "$share/claudepro-settings"
    rm -rf "$share/quota-mod"
    cp -R "$src/quota-mod" "$share/quota-mod"
    rm -rf "$share/quota-mod/tests"
    rm -rf "$share/image-mod"
    cp -R "$src/image-mod" "$share/image-mod"
    rm -rf "$share/image-mod/tests"
    python3 - "$url" "$config/key" "$share/quota-mod/quota.json" <<'EOF'
import json, os, sys
from urllib.parse import urlsplit
url, key_file, out = sys.argv[1:]
quota = os.environ.get("CLAUDEPRO_QUOTA_URL") or f"{urlsplit(url).scheme}://{urlsplit(url).hostname}:8318/quota"
with open(out, "w") as f:
    json.dump({"url": quota, "keyFile": key_file}, f)
EOF
    install -m 755 "$src/bin/claudepro" "$bindir/claudepro"
    install -m 755 "$src/bin/codexpro" "$bindir/codexpro"

    if ! command -v claude >/dev/null && [ ! -x "$bindir/claude" ]; then
        echo 'Claude Code is not installed. Installing it ...'
        curl -fsSL https://claude.ai/install.sh | bash
    fi

    echo
    echo "Installed $bindir/claudepro and $bindir/codexpro"
    command -v codex >/dev/null || echo 'codexpro needs Codex CLI, which is not installed: https://github.com/openai/codex'
    case ":$PATH:" in
        *":$bindir:"*) ;;
        *)
            echo "$bindir is not on your PATH. Add it, then open a new terminal:"
            case "$(basename "${SHELL:-}")" in
                zsh) echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
                fish) echo '  fish_add_path ~/.local/bin' ;;
                *) echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
            esac
            ;;
    esac
    if [ -f "$HOME/.config/fish/functions/claudepro.fish" ]; then
        echo "Note: fish runs the function in ~/.config/fish/functions/claudepro.fish before $bindir/claudepro."
    fi
    echo 'Run: claudepro    (Claude Code, Claude models first; /quota inside it shows the accounts'"'"' plan limits)'
    echo '     codexpro     (Codex CLI, GPT models first)'
}

main "$@"
