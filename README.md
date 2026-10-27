# Kilobat CLI

Kilobat is a macOS command-line tool for network monitoring and diagnostics, including Wi-Fi, DNS, connectivity, and local traffic. It also provides an MCP server for agent clients. The native Kilobat app is a separate product: https://kilobat.app.

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

## License

Kilobat CLI and the source in this repository are licensed under the GNU General Public License version 3.0 only; see [LICENSE](LICENSE). Kilobat's name and artwork are not licensed for use as trademarks. The separate Kilobat desktop app is distributed under its own terms.
