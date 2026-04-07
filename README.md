# byobu-claude

A byobu/tmux-based tool for orchestrating multiple Claude Code instances. A main Claude Code process spawns, delegates to, monitors, and collects results from child Claude Code processes running in separate tmux windows.

## For AI Assistants

If you are a Claude Code instance and this tool is installed, you have these slash commands available:

| Command | Usage |
|---------|-------|
| `/bc-delegate <task>` | Spawn a child and delegate a task to it |
| `/bc-orchestrate <goal>` | Full orchestration loop: decompose, delegate, wait, collect, iterate |
| `/bc-status` | Check status of all child processes |
| `/bc-collect` | Collect results from completed children |
| `/bc-kill <task_id>` | Kill a child process |

Use `/bc-delegate` for single tasks, `/bc-orchestrate` for complex multi-step goals.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  byobu session                                      │
│                                                     │
│  ┌──────────┐  tmux send-keys  ┌──────────────────┐ │
│  │  Main    │ ───────────────> │  Child Claude 1  │ │
│  │  Claude  │ <─────────────── │  (bc-{task_id})  │ │
│  │  Code    │  bc.sh notify    └──────────────────┘ │
│  │          │                                       │
│  │          │  tmux send-keys  ┌──────────────────┐ │
│  │          │ ───────────────> │  Child Claude 2  │ │
│  │          │ <─────────────── │  (bc-{task_id})  │ │
│  └──────────┘  bc.sh notify    └──────────────────┘ │
│                                                     │
│  Communication: /tmp/claude-comm/                   │
│  ├── tasks/{id}.result.md    (result files)         │
│  ├── status/{id}.status      (pending/running/done) │
│  └── registry.json           (child registry)       │
└─────────────────────────────────────────────────────┘
```

**Communication flow:**
- Main → Child: `tmux send-keys` sends prompts directly into child's Claude Code session
- Child → Main: `bc.sh notify` sends a message back to the main process via `tmux send-keys`
- Results: Children write results to `/tmp/claude-comm/tasks/{id}.result.md`
- Children run interactively with `--dangerously-skip-permissions` and persist their sessions

## Installation

### Prerequisites

- Linux with `byobu` / `tmux` installed
- `claude` CLI (Claude Code) installed and authenticated
- `python3` (for JSON handling, no extra packages needed)
- `bash` 4+

### Setup

```bash
# 1. Clone the repository
git clone https://github.com/chen-squared/byobu-claude.git
cd byobu-claude

# 2. Install slash commands to ~/.claude/commands/
bash bc.sh install

# 3. Set BC_HOME in Claude Code settings so commands can find bc.sh
# Add to ~/.claude/settings.json:
#   "env": { "BC_HOME": "/path/to/byobu-claude" }
#
# Or run this one-liner:
python3 -c "
import json, os
f = os.path.expanduser('~/.claude/settings.json')
d = json.load(open(f))
d.setdefault('env',{})['BC_HOME'] = '$(pwd)'
json.dump(d, open(f,'w'), indent=2)
"
```

After installation, start Claude Code inside a byobu session and use `/bc-delegate` or `/bc-orchestrate`.

## CLI Reference

`bc.sh` is a single script with subcommands:

```
bc.sh <command> [args...]
```

| Command | Description |
|---------|-------------|
| `init` | Initialize communication directory `/tmp/claude-comm/` |
| `spawn [--workdir <dir>] [--model <m>] [--name <n>]` | Spawn a child Claude Code in a new tmux window |
| `send <task_id> <message>` | Send a message/task to a child via `tmux send-keys` |
| `status [task_id]` | Show status of all children (or a specific one) |
| `collect [task_id]` | Collect results from completed tasks |
| `wait [task_id...] [--timeout <s>]` | Block until tasks complete (shell-level polling, no API cost) |
| `notify <message>` | Send notification to the master process (used by children) |
| `done <task_id>` | Mark a task as done (called by children) |
| `logs <task_id> [--lines N]` | View child's live terminal output |
| `kill <task_id>` | Kill a child process |
| `cleanup [--done\|--error\|--all]` | Clean up finished tasks, windows, and files |
| `master [--workdir <dir>] [--session <s>]` | Start a master Claude in a new byobu session |
| `install` | Install slash commands to `~/.claude/commands/` |
| `help` | Show usage information |

## Configuration

All settings are configurable via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `BC_HOME` | *(required for slash commands)* | Path to byobu-claude directory |
| `BC_COMM_DIR` | `/tmp/claude-comm` | Communication directory for task files and registry |
| `BC_MAX_CHILDREN` | `10` | Maximum concurrent child processes |
| `BC_TIMEOUT` | `1800` | Wait timeout in seconds (30 min) |
| `BC_MAX_RESTARTS` | `20` | Max auto-restarts on crash per child |
| `BC_POLL_INTERVAL` | `5` | Polling interval in seconds for `wait` |

Set these in `~/.claude/settings.json` under `"env"` or export them in your shell profile.

## Example Workflow

### Manual CLI usage

```bash
# Inside a byobu session with Claude Code running:

# Initialize
bash bc.sh init

# Spawn a child
TASK_ID=$(bash bc.sh spawn --workdir /path/to/project --model sonnet)

# Wait for child to start (~8 seconds), then send a task
sleep 8
bash bc.sh send $TASK_ID "Review the code in src/ and write a summary to /tmp/claude-comm/tasks/${TASK_ID}.result.md. When done, run: bash bc.sh done ${TASK_ID} && bash bc.sh notify 'Task ${TASK_ID} completed'"

# Check status
bash bc.sh status

# Wait for completion
bash bc.sh wait $TASK_ID

# Collect results
bash bc.sh collect

# Reuse the same child for another task (status auto-resets)
bash bc.sh send $TASK_ID "Now fix the issues found..."

# Clean up when done
bash bc.sh cleanup --done
```

### Via slash commands (recommended)

In Claude Code, just type:
```
/bc-delegate Review all test files and report coverage gaps
```
Or for complex multi-step goals:
```
/bc-orchestrate Implement user authentication with tests
```

## Auto-restart

Children (and masters started via `bc.sh master`) run inside an auto-restart wrapper. If Claude Code crashes due to API errors, it automatically restarts with `--continue` to resume the session. Features:

- Exponential backoff on rapid failures (5s → 10s → 20s → ... → 60s max)
- Clean exit (exit code 0) is not restarted
- Configurable max restarts via `BC_MAX_RESTARTS`

## Child Constraints

Children are started with:
- `--dangerously-skip-permissions` — no user confirmation needed
- `--disable-slash-commands` — prevents children from using `/bc-*` commands
- `--append-system-prompt` — instructs children to write results, call `bc.sh done`, and notify the main process

Children cannot spawn sub-children or communicate with each other. All communication goes through the main process.

## License

MIT
