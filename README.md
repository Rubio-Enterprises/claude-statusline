# claude-statusline

Configure your Claude Code statusline to show limits, directory and git info

![demo](./.github/demo.png)

## Install

Run the command below to set it up

```bash
npx @kamranahmedse/claude-statusline
```

It backups your old status line if any and copies the status line script to `~/.claude/statusline.sh` and configures your Claude Code settings.

## Requirements

- [jq](https://jqlang.github.io/jq/) — for parsing JSON
- curl — for fetching Claude rate-limit data (the default provider)
- git — for branch info
- [Codex CLI](https://developers.openai.com/codex/cli/) — only when using the optional Codex rate-limit provider

On macOS:

```bash
brew install jq
```

## Rate-limit provider

Claude limits remain the default. To show weekly Codex and Codex Spark limits
from the active Codex CLI account instead:

```bash
export STATUSLINE_RATE_LIMIT_PROVIDER=codex
```

The Codex provider uses a background, single-flight `codex app-server --stdio`
request and never calls Anthropic or consumes Claude rate limits from stdin.
Unset the variable (or set it to `claude`) to restore Claude limits. Any other
value hides rate-limit segments without fetching either provider.

## Uninstall

```bash
npx @kamranahmedse/claude-statusline --uninstall
```

If you had a previous statusline, it restores it from the backup. Otherwise it removes the script and cleans up your settings.

## License

MIT
