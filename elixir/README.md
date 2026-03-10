# Symphony Elixir

An orchestrator that polls Linear issues and executes them using Codex, Claude Code, or Gemini CLI.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Quick Start

```bash
# 1. Install mise (Elixir/Erlang version manager)
curl https://mise.run | sh
echo 'eval "$($HOME/.local/bin/mise activate zsh)"' >> ~/.zshrc
source ~/.zshrc

# 2. Install Elixir/Erlang and build
cd symphony/elixir
mise trust
mise install                    # Installs Erlang 28 + Elixir 1.19.5
mise exec -- mix setup          # Fetch dependencies
mise exec -- mix build          # Build escript binary

# 3. Install your preferred agent CLI
# Claude Code: https://docs.anthropic.com/en/docs/claude-code
# Gemini CLI:  https://github.com/google-gemini/gemini-cli
# Codex:       https://github.com/openai/codex

# 4. Configure WORKFLOW.md and run
export LINEAR_API_KEY="lin_api_..."
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md --port 8080
```

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates an isolated workspace per issue
3. Launches an agent backend (Codex, Claude Code, or Gemini CLI) inside the workspace
4. Sends a workflow prompt to the agent
5. Keeps the agent working on the issue until the work is done

### Supported backends

| Backend | Config value | CLI | Notes |
|---------|-------------|-----|-------|
| Codex | `codex` | `codex app-server` | JSON-RPC stdio, `linear_graphql` tool |
| Claude Code | `claude` | `claude -p` | Stateless per-turn, built-in tools + MCP |
| Gemini CLI | `gemini` | `gemini -p` | Stateless per-turn |

Use `--backend <name>` on the command line or set `agent.backend` in WORKFLOW.md to select a backend.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  backend: claude          # "codex" | "claude" | "gemini"
  max_concurrent_agents: 10
  max_turns: 20
# Backend-specific settings (only the active backend's section is used)
codex:
  command: codex app-server
claude:
  model: claude-sonnet-4-6
  allowed_tools: "Bash,Read,Edit,Write,Glob,Grep"
gemini:
  model: gemini-2.5-pro
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.backend` selects the agent backend: `codex` (default), `claude`, or `gemini`.
- `agent.max_turns` caps how many back-to-back turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `claude.model` sets the Claude model (default: `claude-sonnet-4-6`).
- `claude.allowed_tools` sets allowed tools for Claude Code (default: `Bash,Read,Edit,Write,Glob,Grep`).
- `claude.extra_flags` passes additional CLI flags to `claude -p`.
- `claude.turn_timeout_ms` sets the turn timeout (default: `3600000`).
- `gemini.model` sets the Gemini model (default: `gemini-2.5-pro`).
- `gemini.extra_flags` passes additional CLI flags to `gemini`.
- `gemini.turn_timeout_ms` sets the turn timeout (default: `3600000`).
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/symphony_elixir/codex/`: Codex app-server backend (original)
- `lib/symphony_elixir/claude/`: Claude Code backend adapter
- `lib/symphony_elixir/gemini/`: Gemini CLI backend adapter
- `lib/symphony_elixir/agent_runner.ex`: Backend-agnostic agent runner
- `lib/`: remaining application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
