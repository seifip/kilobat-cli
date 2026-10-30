# Kilobat CLI

Kilobat is a macOS command-line tool and MCP server for network monitoring and diagnostics: which apps use the network, Wi-Fi signal and channels, latency and packet loss, DNS, speed tests, why one host or API won't connect, where traffic leaves (VPN or not), metered hotspots and data budgets, and keeping the Mac awake while long jobs and AI agents run. Every command speaks JSON. The native Kilobat menu-bar app is a separate product: https://kilobat.app.

## Use with AI agents (MCP)

`kilobat mcp` is a stdio MCP server with 43 tools. Read-only tools need no confirmation; tools that change something tell the agent to ask you first.

- **Claude Code:** `claude mcp add kilobat -- kilobat mcp`
- **Codex CLI:** `codex mcp add kilobat -- kilobat mcp`
- **Claude Desktop:** download `kilobat-mcp-<version>.mcpb` from [Releases](https://github.com/seifip/kilobat-cli/releases/latest) and open it.
- **Cursor, Windsurf, Zed, Gemini CLI, Cline and others:** add a stdio server with command `kilobat` and argument `mcp`.

Step-by-step setup for each agent, with example prompts: https://kilobat.app/agents/. Agent skills that teach agents when and how to use Kilobat: `npx skills add seifip/kilobat-skills`.

Ask your agent things like "why is my internet slow?", "is this a hotspot before I download 5 GB?", "why can't this API connect from my Mac?" or "keep the Mac awake until this build finishes".

## Install with Homebrew

```sh
brew install seifip/kilobat/kilobat
```

This builds from source and requires Xcode 16 or newer.

## Build

Requires macOS 14 or later and Swift 6.

```sh
swift build -c release
.build/release/kilobat --help
swift test
```

Run `kilobat --help` for commands and `kilobat mcp --help` for agent integration. Commands that change system settings may require confirmation and administrator authorization.

macOS shows Wi-Fi network names only to apps with Location permission. When the Kilobat app is running, the CLI reads names, filter status and per-network budgets from it; without the app, Wi-Fi signal, channels and everything else still work, but network names read as hidden.

## License

Kilobat CLI and the source in this repository are licensed under the GNU General Public License version 3.0 only; see [LICENSE](LICENSE). Kilobat's name and artwork are not licensed for use as trademarks. The separate Kilobat desktop app is distributed under its own terms.
