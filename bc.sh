#!/usr/bin/env bash
# bc.sh - byobu-claude: Multi Claude Code instance management tool
# Usage: bc.sh <command> [args...]
#
# Commands:
#   init                              Initialize communication directory
#   spawn  [--workdir <dir>] [--model <m>] [--name <n>]  Spawn child claude
#   send   <id> <message>             Send message to child via tmux send-keys
#   status [id]                       Check child process status
#   collect [id]                      Collect results from completed children
#   wait   [id...] [--timeout <sec>]  Wait for tasks to complete
#   notify <message>                  Send notification to master window
#   logs   <id>                       View child process output
#   kill   <id>                       Kill a child process
#   cleanup [--all]                   Clean up finished tasks

set -euo pipefail

# ============================================================
# Configuration (overridable via environment variables)
# ============================================================
# Save original BC_COMM_DIR before applying default (for detecting explicit vs auto-set)
_BC_COMM_DIR_ORIG="${BC_COMM_DIR:-}"
BC_COMM_DIR="${BC_COMM_DIR:-/tmp/claude-comm}"
BC_MAX_CHILDREN="${BC_MAX_CHILDREN:-10}"
BC_TIMEOUT="${BC_TIMEOUT:-1800}"          # 30 min default
BC_POLL_INTERVAL="${BC_POLL_INTERVAL:-5}" # seconds
BC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Master ID -- set by cmd_init, inherited by wrapper and children
BC_MASTER_ID="${BC_MASTER_ID:-}"

# ============================================================
# Helpers
# ============================================================

_log() { echo "[bc] $*" >&2; }
_err() { echo "[bc] ERROR: $*" >&2; }
_die() { _err "$@"; exit 1; }

_timestamp() { date '+%Y-%m-%dT%H:%M:%S'; }

_gen_id() {
    # 8-char hex id
    printf '%s%s' "$(date +%s%N)" "$$" | sha256sum | head -c 8
}

# Portable JSON helpers (no jq dependency)
# All use sys.argv for parameter passing -- no shell variable interpolation in Python code

_json_registry_append() {
    # _json_registry_append <json_object_string>
    local regfile="$BC_COMM_DIR/registry.json"
    python3 -c "
import json, sys, fcntl
obj = json.loads(sys.argv[1])
regfile = sys.argv[2]
with open(regfile, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        arr = json.load(f)
        arr.append(obj)
        f.seek(0)
        f.truncate()
        json.dump(arr, f, indent=2)
    finally:
        fcntl.flock(f, fcntl.LOCK_UN)
" "$1" "$regfile"
}

_json_registry_update() {
    # _json_registry_update <task_id> <key> <value>
    local regfile="$BC_COMM_DIR/registry.json"
    python3 -c "
import json, sys, fcntl
tid, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
regfile = sys.argv[4]
with open(regfile, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        arr = json.load(f)
        for item in arr:
            if item.get('task_id') == tid:
                item[key] = val
        f.seek(0)
        f.truncate()
        json.dump(arr, f, indent=2)
    finally:
        fcntl.flock(f, fcntl.LOCK_UN)
" "$1" "$2" "$3" "$regfile"
}

_json_registry_list() {
    # Fixed: use sys.argv instead of shell interpolation
    local regfile="$BC_COMM_DIR/registry.json"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        arr = json.load(f)
    for item in arr:
        print(json.dumps(item))
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(f'[bc] ERROR: registry.json: {e}', file=sys.stderr)
    sys.exit(1)
" "$regfile"
}

_json_registry_get() {
    # _json_registry_get <task_id> - print JSON object for a task
    local regfile="$BC_COMM_DIR/registry.json"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        arr = json.load(f)
    for item in arr:
        if item.get('task_id') == sys.argv[2]:
            print(json.dumps(item))
            break
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(f'[bc] ERROR: registry.json: {e}', file=sys.stderr)
    sys.exit(1)
" "$regfile" "$1"
}

_json_registry_remove() {
    # _json_registry_remove <task_id>
    local regfile="$BC_COMM_DIR/registry.json"
    python3 -c "
import json, sys, fcntl
tid = sys.argv[1]
regfile = sys.argv[2]
with open(regfile, 'r+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try:
        arr = json.load(f)
        arr = [x for x in arr if x.get('task_id') != tid]
        f.seek(0)
        f.truncate()
        json.dump(arr, f, indent=2)
    finally:
        fcntl.flock(f, fcntl.LOCK_UN)
" "$1" "$regfile"
}

# Safe JSON field extraction -- replaces eval with read-based parsing
_json_extract_fields() {
    # _json_extract_fields <json_line> <field1> [field2] ...
    # Outputs: field1_value\nfield2_value\n...
    local json_line="$1"; shift
    local fields=("$@")
    local fields_str
    fields_str=$(printf '%s\n' "${fields[@]}")
    echo "$json_line" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for field in sys.argv[1:]:
    print(d.get(field, ''))
" "${fields[@]}"
}

_get_status() {
    local tid="$1"
    local sfile="$BC_COMM_DIR/status/${tid}.status"
    if [[ -f "$sfile" ]]; then
        head -1 "$sfile"
    else
        echo "unknown"
    fi
}

_set_status() {
    local tid="$1" status="$2"
    local sfile="$BC_COMM_DIR/status/${tid}.status"
    local tmp="${sfile}.tmp.$$"
    echo "$status" > "$tmp"
    mv -f "$tmp" "$sfile"
}

_get_master_pane() {
    # Read pane_id from master.lock (field 3)
    if [[ -f "$BC_COMM_DIR/master.lock" ]]; then
        cut -d'|' -f3 "$BC_COMM_DIR/master.lock"
    fi
}

_get_master_session() {
    # Read master session name from master.lock (field 4: MASTER_ID|PID|PANE_ID|SESSION|WINDOW|TIMESTAMP)
    if [[ -f "$BC_COMM_DIR/master.lock" ]]; then
        cut -d'|' -f4 "$BC_COMM_DIR/master.lock"
    fi
}

_get_master_window() {
    # Read master window name from master.lock (field 5)
    if [[ -f "$BC_COMM_DIR/master.lock" ]]; then
        cut -d'|' -f5 "$BC_COMM_DIR/master.lock"
    fi
}

_get_master_id() {
    # Read master_id from master.lock (field 1)
    if [[ -f "$BC_COMM_DIR/master.lock" ]]; then
        cut -d'|' -f1 "$BC_COMM_DIR/master.lock"
    fi
}

# Get the current master ID -- use BC_MASTER_ID env if set, otherwise read from lock
_get_current_master_id() {
    if [[ -n "$BC_MASTER_ID" ]]; then
        echo "$BC_MASTER_ID"
    else
        _get_master_id
    fi
}

_count_active_children() {
    local count=0
    if [[ -d "$BC_COMM_DIR/status" ]]; then
        for sfile in "$BC_COMM_DIR/status"/*.status; do
            [[ -f "$sfile" ]] || continue
            local s
            s=$(head -1 "$sfile")
            if [[ "$s" == "running" || "$s" == "pending" ]]; then
                ((count++)) || true
            fi
        done
    fi
    echo "$count"
}

# ============================================================
# Commands
# ============================================================

cmd_init() {
    # If already initialized (master.lock exists with valid master_id), just reload it
    if [[ -f "$BC_COMM_DIR/master.lock" ]]; then
        local existing_id
        existing_id=$(_get_master_id)
        if [[ -n "$existing_id" ]]; then
            export BC_MASTER_ID="$existing_id"
            _log "Already initialized: $BC_COMM_DIR (master_id: $existing_id)"
            return 0
        fi
    fi

    mkdir -p "$BC_COMM_DIR"/{tasks,status,logs}
    if [[ ! -f "$BC_COMM_DIR/registry.json" ]]; then
        echo '[]' > "$BC_COMM_DIR/registry.json"
    fi

    # Generate new master_id and write master lock: MASTER_ID|PID|PANE_ID|SESSION|WINDOW|TIMESTAMP
    local master_id pane_id session_name window_name
    master_id=$(_gen_id)
    pane_id=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "unknown")
    session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "unknown")
    window_name=$(tmux display-message -p '#{window_name}' 2>/dev/null || echo "unknown")
    echo "${master_id}|$$|${pane_id}|${session_name}|${window_name}|$(_timestamp)" > "$BC_COMM_DIR/master.lock"

    # Export so child wrappers inherit it
    export BC_MASTER_ID="$master_id"

    _log "Initialized: $BC_COMM_DIR (master_id: $master_id, pane: $pane_id, session: $session_name, window: $window_name)"
}

cmd_spawn() {
    local workdir="" model="" name="" task_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workdir) workdir="$2"; shift 2 ;;
            --model)   model="$2"; shift 2 ;;
            --name)    name="$2"; shift 2 ;;
            --task-id) task_id="$2"; shift 2 ;;
            *) _die "spawn: unknown option: $1" ;;
        esac
    done

    workdir="${workdir:-$(pwd)}"
    model="${model:-}"  # empty = inherit from settings
    task_id="${task_id:-$(_gen_id)}"
    name="${name:-bc-${task_id}}"

    # Ensure init (sets BC_MASTER_ID if not already set).
    # If BC_MASTER_ID is already set (explicit override for multi-master), respect it.
    # Otherwise, load from master.lock or initialize fresh.
    if [[ -z "$BC_MASTER_ID" ]]; then
        if [[ -d "$BC_COMM_DIR/tasks" ]] && [[ -f "$BC_COMM_DIR/master.lock" ]]; then
            export BC_MASTER_ID="$(_get_master_id)"
        else
            cmd_init
        fi
    else
        # BC_MASTER_ID explicitly set -- warn if it differs from master.lock
        if [[ -f "$BC_COMM_DIR/master.lock" ]]; then
            local lock_master_id
            lock_master_id=$(_get_master_id)
            if [[ "$BC_MASTER_ID" != "$lock_master_id" ]]; then
                _log "WARNING: BC_MASTER_ID=$BC_MASTER_ID but master.lock has $lock_master_id"
                _log "Children will use $BC_MASTER_ID but notify goes to whoever last wrote master.lock"
            fi
        fi
    fi

    # Check for duplicate task_id
    local existing
    existing=$(_json_registry_get "$task_id")
    if [[ -n "$existing" ]]; then
        _die "spawn: task_id $task_id already exists. Use a different id or cleanup first."
    fi

    # Check children limit
    local active
    active=$(_count_active_children)
    if [[ "$active" -ge "$BC_MAX_CHILDREN" ]]; then
        _die "spawn: max children ($BC_MAX_CHILDREN) reached. Active: $active"
    fi

    # Set status to pending
    _set_status "$task_id" "pending"

    # Build child system prompt
    local child_prompt
    child_prompt="$(cat <<SYSPROMPT
你是一个由主进程管理的子进程 Claude Code 实例。

关键约束：
- 禁止创建子进程或启动其他 Claude 实例
- 禁止使用 /bc-delegate、/bc-orchestrate 或任何 bc-* 命令
- 禁止修改 ${BC_COMM_DIR}/ 中非指定的文件

当完成任务后，你必须：
1. 将结果写入指定的 result 文件（路径会在任务中说明）
2. 运行以下命令更新状态：bash ${BC_SCRIPT_DIR}/bc.sh done ${task_id}
3. 运行以下命令通知主进程：bash ${BC_SCRIPT_DIR}/bc.sh notify "Task ${task_id} completed"
4. 然后等待主进程的进一步指令
SYSPROMPT
)"

    # Build claude command arguments using printf %q for safe quoting
    local claude_args_parts=()
    claude_args_parts+=("--dangerously-skip-permissions")
    if [[ -n "$model" ]]; then
        claude_args_parts+=("--model" "$model")
    fi
    claude_args_parts+=("--disable-slash-commands")
    claude_args_parts+=("--append-system-prompt" "$child_prompt")

    # Build a safely-quoted wrapper command string for tmux
    local quoted_args=""
    for arg in "${claude_args_parts[@]}"; do
        quoted_args+=" $(printf '%q' "$arg")"
    done

    # Get current session (use = prefix to force session name match, avoids numeric ambiguity)
    local session session_target
    session=$(tmux display-message -p '#{session_name}' 2>/dev/null) || _die "spawn: not inside tmux/byobu"
    session_target="=${session}"

    # Create new window running the auto-restart wrapper.
    # Set BC_MASTER_ID and BC_COMM_DIR explicitly; do NOT use env -u since
    # BC_MASTER_ID may already be correct (passed from parent's exported env).
    # Both env settings ensure the child sees only the values we explicitly pass.
    local wrapper_cmd="BC_MASTER_ID=\"$(printf '%s' "$BC_MASTER_ID")\" BC_COMM_DIR=\"$(printf '%s' "$BC_COMM_DIR")\" bash $(printf '%q' "${BC_SCRIPT_DIR}/bc.sh") _wrapper $(printf '%q' "$BC_MASTER_ID")${quoted_args}"
    tmux new-window -d -t "${session_target}" -n "$name" -c "$workdir" "$wrapper_cmd"

    # Set remain-on-exit so we can inspect dead panes
    tmux set-option -t "${session_target}:${name}" remain-on-exit on 2>/dev/null || true

    # Auto-accept workspace trust dialog with retry loop
    (
        for i in 1 2 3 4 5; do
            sleep 2
            pane_output=$(tmux capture-pane -t "${session_target}:${name}" -p 2>/dev/null || true)
            if echo "$pane_output" | grep -q "trust this folder"; then
                tmux send-keys -t "${session_target}:${name}" Enter
                break
            fi
            # If claude prompt is visible, no trust dialog needed
            if echo "$pane_output" | grep -q "❯"; then
                break
            fi
        done
    ) &
    disown

    # Get pane info
    local pane_id pane_pid
    pane_id=$(tmux list-panes -t "${session_target}:${name}" -F '#{pane_id}' 2>/dev/null | head -1)
    pane_pid=$(tmux list-panes -t "${session_target}:${name}" -F '#{pane_pid}' 2>/dev/null | head -1)

    # Register -- use sys.argv for safe parameter passing
    local entry
    entry=$(python3 -c "
import json, sys
print(json.dumps({
    'task_id': sys.argv[1],
    'name': sys.argv[2],
    'pane_id': sys.argv[3],
    'pane_pid': sys.argv[4],
    'workdir': sys.argv[5],
    'model': sys.argv[6],
    'session': sys.argv[7],
    'master_id': sys.argv[8],
    'spawned_at': sys.argv[9],
    'status': 'pending'
}))
" "$task_id" "$name" "$pane_id" "$pane_pid" "$workdir" "${model:-default}" "$session" "$BC_MASTER_ID" "$(_timestamp)")
    _json_registry_append "$entry"

    _log "Spawned child: $task_id (window: $name, pane: $pane_id, pid: $pane_pid)"
    echo "$task_id"
}

cmd_send() {
    [[ $# -ge 2 ]] || _die "send: usage: bc.sh send <task_id> <message>"
    local tid="$1"; shift
    local message="$*"

    # Reject empty messages
    if [[ -z "${message// /}" ]]; then
        _die "send: message cannot be empty"
    fi

    # Look up window name from registry
    local entry
    entry=$(_json_registry_get "$tid")
    [[ -n "$entry" ]] || _die "send: task $tid not found in registry"

    local wname session
    read -r wname < <(_json_extract_fields "$entry" name)
    read -r session < <(_json_extract_fields "$entry" session)

    # Check window exists (= prefix forces session name match)
    tmux list-windows -t "=${session}" -F '#{window_name}' 2>/dev/null | grep -qx "$wname" \
        || _die "send: window $wname not found in session $session"

    # If reusing a child (done/done|collected), clear stale result file
    local current_status
    current_status=$(_get_status "$tid")
    current_status="${current_status%%|*}"  # strip collected marker
    if [[ "$current_status" == "done" ]]; then
        rm -f "$BC_COMM_DIR/tasks/${tid}.result.md"
        _log "Cleared stale result file for reused task $tid"
    fi

    # Send message via send-keys
    tmux send-keys -t "=${session}:${wname}" -l "$message"
    tmux send-keys -t "=${session}:${wname}" Enter

    _set_status "$tid" "running"
    _json_registry_update "$tid" "status" "running"

    _log "Sent message to $tid ($wname)"
}

cmd_status() {
    local filter_id="${1:-}"

    [[ -d "$BC_COMM_DIR/status" ]] || _die "status: not initialized. Run bc.sh init first."

    # Filter by current master_id if not filtering by specific task_id
    local current_master_id
    current_master_id=$(_get_current_master_id)

    # Header
    printf "%-10s %-10s %-8s %-16s %-8s %s\n" "TASK_ID" "STATUS" "MODEL" "WINDOW" "AGE" "WORKDIR"
    printf "%-10s %-10s %-8s %-16s %-8s %s\n" "-------" "------" "-----" "------" "---" "-------"

    local count_running=0 count_done=0 count_error=0 count_pending=0 count_killed=0 count_total=0

    local listing
    listing=$(_json_registry_list) || _die "status: failed to read registry"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        # Safe field extraction without eval
        local fields
        fields=$(_json_extract_fields "$line" task_id name pane_id model session workdir spawned_at master_id)
        local task_id name pane_id model session workdir spawned_at master_id
        { read -r task_id; read -r name; read -r pane_id; read -r model; read -r session; read -r workdir; read -r spawned_at; read -r master_id; } <<< "$fields"

        # Filter by master_id (only show children of current master)
        if [[ -n "$current_master_id" && "$master_id" != "$current_master_id" ]]; then
            continue
        fi

        # Filter by task_id if specified
        if [[ -n "$filter_id" && "$task_id" != "$filter_id" ]]; then
            continue
        fi

        ((count_total++)) || true

        # Read status file
        local status
        status=$(_get_status "$task_id")
        status="${status%%|*}"  # strip collected marker

        # Cross-check with tmux pane state
        local pane_dead="0"
        if tmux list-panes -t "=${session}:${name}" -F '#{pane_dead}' 2>/dev/null | grep -q '^1$'; then
            pane_dead="1"
        fi

        # Reconcile
        if [[ "$status" == "running" || "$status" == "pending" ]] && [[ "$pane_dead" == "1" ]]; then
            _set_status "$task_id" "error"
            _json_registry_update "$task_id" "status" "error"
            status="error"
        fi

        # Count by status
        case "$status" in
            running) ((count_running++)) || true ;;
            done)    ((count_done++)) || true ;;
            error)   ((count_error++)) || true ;;
            pending) ((count_pending++)) || true ;;
            killed)  ((count_killed++)) || true ;;
        esac

        # Calculate age
        local age=""
        if [[ -n "$spawned_at" ]]; then
            local start_epoch now_epoch diff
            start_epoch=$(date -d "$spawned_at" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            diff=$((now_epoch - start_epoch))
            if [[ $diff -ge 3600 ]]; then
                age="$((diff/3600))h$((diff%3600/60))m"
            elif [[ $diff -ge 60 ]]; then
                age="$((diff/60))m$((diff%60))s"
            else
                age="${diff}s"
            fi
        fi

        printf "%-10s %-10s %-8s %-16s %-8s %s\n" "$task_id" "$status" "$model" "$name" "$age" "$workdir"
    done <<< "$listing"

    # Summary line
    if [[ $count_total -gt 0 ]]; then
        echo "---"
        local parts=()
        [[ $count_running -gt 0 ]] && parts+=("${count_running} running")
        [[ $count_pending -gt 0 ]] && parts+=("${count_pending} pending")
        [[ $count_done -gt 0 ]]    && parts+=("${count_done} done")
        [[ $count_error -gt 0 ]]   && parts+=("${count_error} error")
        [[ $count_killed -gt 0 ]]  && parts+=("${count_killed} killed")
        local IFS=', '
        echo "Total: ${count_total} (${parts[*]})"
    fi
}

cmd_collect() {
    local filter_id="${1:-}"

    [[ -d "$BC_COMM_DIR/tasks" ]] || _die "collect: not initialized."

    # Filter by current master_id
    local current_master_id
    current_master_id=$(_get_current_master_id)

    local listing
    listing=$(_json_registry_list) || _die "collect: failed to read registry"
    local found=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        local tid master_id
        read -r tid < <(_json_extract_fields "$line" task_id)
        read -r master_id < <(_json_extract_fields "$line" master_id)

        # Filter by master_id (only collect children of current master)
        if [[ -n "$current_master_id" && "$master_id" != "$current_master_id" ]]; then
            continue
        fi

        if [[ -n "$filter_id" && "$tid" != "$filter_id" ]]; then
            continue
        fi

        local status
        status=$(_get_status "$tid")
        status="${status%%|*}"  # strip collected marker

        if [[ "$status" != "done" && "$status" != "error" ]]; then
            continue
        fi

        found=1
        local result_file="$BC_COMM_DIR/tasks/${tid}.result.md"
        echo "=== Task $tid ($status) ==="
        if [[ -f "$result_file" ]]; then
            cat "$result_file"
        else
            echo "(No result file found)"
            local logfile="$BC_COMM_DIR/logs/${tid}.stdout.log"
            if [[ -f "$logfile" ]]; then
                echo "--- Log output (last 50 lines) ---"
                tail -50 "$logfile"
            fi
        fi
        echo ""

        # Mark as collected
        _set_status "$tid" "${status}|collected"
    done <<< "$listing"

    if [[ $found -eq 0 ]]; then
        _log "No completed tasks to collect."
    fi
}

cmd_wait() {
    local timeout="$BC_TIMEOUT"
    local task_ids=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="$2"; shift 2 ;;
            --poll)    BC_POLL_INTERVAL="$2"; shift 2 ;;
            *) task_ids+=("$1"); shift ;;
        esac
    done

    # If no task ids given, wait for all running/pending tasks of current master
    if [[ ${#task_ids[@]} -eq 0 ]]; then
        local current_master_id
        current_master_id=$(_get_current_master_id)
        local listing
        listing=$(_json_registry_list) || _die "wait: failed to read registry"
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            local tid master_id
            read -r tid < <(_json_extract_fields "$line" task_id)
            read -r master_id < <(_json_extract_fields "$line" master_id)
            # Filter by master_id
            if [[ -n "$current_master_id" && "$master_id" != "$current_master_id" ]]; then
                continue
            fi
            local s
            s=$(_get_status "$tid")
            if [[ "$s" == "running" || "$s" == "pending" ]]; then
                task_ids+=("$tid")
            fi
        done <<< "$listing"
    fi

    if [[ ${#task_ids[@]} -eq 0 ]]; then
        _log "No active tasks to wait for."
        return 0
    fi

    _log "Waiting for ${#task_ids[@]} task(s): ${task_ids[*]}"
    _log "Timeout: ${timeout}s, Poll interval: ${BC_POLL_INTERVAL}s"

    local start_time
    start_time=$(date +%s)

    while true; do
        local all_done=true
        local summary=""

        for tid in "${task_ids[@]}"; do
            local s
            s=$(_get_status "$tid")
            s="${s%%|*}"

            case "$s" in
                done|error|killed)
                    summary+="  $tid: $s\n"
                    ;;
                *)
                    all_done=false
                    summary+="  $tid: $s\n"

                    # Check tmux pane state for reconciliation
                    local entry wname session
                    entry=$(_json_registry_get "$tid")
                    if [[ -n "$entry" ]]; then
                        read -r wname < <(_json_extract_fields "$entry" name)
                        read -r session < <(_json_extract_fields "$entry" session)
                        if tmux list-panes -t "=${session}:${wname}" -F '#{pane_dead}' 2>/dev/null | grep -q '^1$'; then
                            _set_status "$tid" "error"
                            _json_registry_update "$tid" "status" "error"
                        fi
                    fi
                    ;;
            esac
        done

        if $all_done; then
            echo "ALL_COMPLETE"
            echo -e "$summary"
            return 0
        fi

        # Check timeout
        local elapsed
        elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout ]]; then
            echo "TIMEOUT after ${elapsed}s"
            echo -e "$summary"
            return 1
        fi

        sleep "$BC_POLL_INTERVAL"
    done
}

cmd_notify() {
    [[ $# -ge 1 ]] || _die "notify: usage: bc.sh notify <message>"
    local message="$*"

    local master_session master_window
    master_session=$(_get_master_session)
    master_window=$(_get_master_window)
    if [[ -z "$master_session" || -z "$master_window" ]]; then
        _die "notify: no master session/window found. Was init called?"
    fi

    # Send to the dedicated master window in its session
    tmux send-keys -t "=${master_session}:${master_window}" -l "$message"
    tmux send-keys -t "=${master_session}:${master_window}" Enter

    _log "Notified master (${master_session}:${master_window}): $message"
}

cmd_done() {
    [[ $# -ge 1 ]] || _die "done: usage: bc.sh done <task_id>"
    local tid="$1"

    # Validate task exists in registry
    local entry
    entry=$(_json_registry_get "$tid")
    if [[ -z "$entry" ]]; then
        _die "done: task $tid not found in registry"
    fi

    _set_status "$tid" "done"
    _json_registry_update "$tid" "status" "done"
    _log "Task $tid marked as done"
}

cmd_kill() {
    [[ $# -ge 1 ]] || _die "kill: usage: bc.sh kill <task_id>"
    local tid="$1"

    local entry
    entry=$(_json_registry_get "$tid")
    [[ -n "$entry" ]] || _die "kill: task $tid not found"

    local wname session
    read -r wname < <(_json_extract_fields "$entry" name)
    read -r session < <(_json_extract_fields "$entry" session)

    tmux kill-window -t "=${session}:${wname}" 2>/dev/null || true

    # Consistent status: both status file and registry say "killed"
    _set_status "$tid" "killed"
    _json_registry_update "$tid" "status" "killed"

    _log "Killed task $tid (window: $wname)"
}

cmd_logs() {
    [[ $# -ge 1 ]] || _die "logs: usage: bc.sh logs <task_id> [--lines N]"
    local tid="$1"
    local lines=50
    [[ "${2:-}" == "--lines" ]] && lines="${3:-50}"

    local entry
    entry=$(_json_registry_get "$tid")
    [[ -n "$entry" ]] || _die "logs: task $tid not found"

    local wname session
    read -r wname < <(_json_extract_fields "$entry" name)
    read -r session < <(_json_extract_fields "$entry" session)

    # Capture live pane output
    if tmux list-windows -t "=${session}" -F '#{window_name}' 2>/dev/null | grep -qx "$wname"; then
        tmux capture-pane -t "=${session}:${wname}" -p -S "-${lines}" 2>/dev/null | tail -"${lines}"
    else
        echo "(Window $wname no longer exists)"
        local logfile="$BC_COMM_DIR/logs/${tid}.stdout.log"
        if [[ -f "$logfile" ]]; then
            echo "--- Saved log (last $lines lines) ---"
            tail -"$lines" "$logfile"
        fi
    fi
}

cmd_cleanup() {
    local mode="${1:---done}"

    # Validate mode
    case "$mode" in
        --all|--done|--error) ;;
        *) _die "cleanup: unknown option: $mode. Use --done, --error, or --all" ;;
    esac

    # Filter by current master_id
    local current_master_id
    current_master_id=$(_get_current_master_id)

    local listing
    listing=$(_json_registry_list) || _die "cleanup: failed to read registry"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        # Safe field extraction without eval
        local fields
        fields=$(_json_extract_fields "$line" task_id name session master_id)
        local task_id name session master_id
        { read -r task_id; read -r name; read -r session; read -r master_id; } <<< "$fields"

        # Filter by master_id (only cleanup children of current master)
        if [[ -n "$current_master_id" && "$master_id" != "$current_master_id" ]]; then
            continue
        fi

        local status
        status=$(_get_status "$task_id")
        status="${status%%|*}"  # strip collected marker

        local should_clean=false
        case "$mode" in
            --all) should_clean=true ;;
            --done) [[ "$status" == "done" ]] && should_clean=true ;;
            --error) [[ "$status" == "error" || "$status" == "killed" ]] && should_clean=true ;;
        esac

        if $should_clean; then
            tmux kill-window -t "=${session}:${name}" 2>/dev/null || true
            rm -f "$BC_COMM_DIR/tasks/${task_id}.task.md"
            rm -f "$BC_COMM_DIR/tasks/${task_id}.result.md"
            rm -f "$BC_COMM_DIR/status/${task_id}.status"
            rm -f "$BC_COMM_DIR/logs/${task_id}.stdout.log"
            _json_registry_remove "$task_id"
            _log "Cleaned up task $task_id"
        fi
    done <<< "$listing"
}

# Auto-restart wrapper: runs claude in a loop, auto-restarts with --continue on crash
# This runs INSIDE the tmux window, not called by users directly
# First argument is BC_MASTER_ID, remaining args are claude args
cmd_wrapper() {
    local master_id_arg="$1"; shift
    export BC_MASTER_ID="$master_id_arg"
    local claude_args=("$@")
    local max_restarts="${BC_MAX_RESTARTS:-20}"
    local restart_count=0
    local restart_delay=5
    local last_exit_time=0

    echo "[bc-wrapper] Starting claude with auto-restart (max $max_restarts restarts)"
    echo "[bc-wrapper] Args: ${claude_args[*]}"
    echo ""

    while true; do
        if [[ $restart_count -eq 0 ]]; then
            # First launch: normal start
            claude "${claude_args[@]}"
        else
            # Restart: use --continue to resume session
            echo ""
            echo "[bc-wrapper] Restarting claude (attempt $restart_count/$max_restarts) with --continue..."
            echo ""
            sleep "$restart_delay"
            claude --continue "${claude_args[@]}"
        fi

        local exit_code=$?
        local now
        now=$(date +%s)

        echo ""
        echo "[bc-wrapper] Claude exited with code $exit_code at $(date '+%H:%M:%S')"

        # Exit code 0 = normal exit (user typed /exit) -- don't restart
        if [[ $exit_code -eq 0 ]]; then
            echo "[bc-wrapper] Clean exit. Not restarting."
            break
        fi

        ((restart_count++)) || true

        if [[ $restart_count -ge $max_restarts ]]; then
            echo "[bc-wrapper] Max restarts ($max_restarts) reached. Giving up."
            break
        fi

        # If last restart was very recent (< 30s), increase delay to avoid tight loop
        if [[ $((now - last_exit_time)) -lt 30 ]] && [[ $last_exit_time -gt 0 ]]; then
            restart_delay=$((restart_delay * 2))
            [[ $restart_delay -gt 60 ]] && restart_delay=60
            echo "[bc-wrapper] Rapid failures detected. Delay increased to ${restart_delay}s"
        else
            restart_delay=5
        fi

        last_exit_time=$now
        echo "[bc-wrapper] Will restart in ${restart_delay}s... (Ctrl+C to abort)"
    done

    echo "[bc-wrapper] Wrapper finished. Restart count: $restart_count"
}

# Like cmd_wrapper but first initializes master (used by cmd_master for new sessions)
# First argument is the master_id, remaining args are claude args.
# cmd_master already wrote master.lock before spawning this session, so we
# just set BC_MASTER_ID and delegate to cmd_wrapper (which also expects master_id as $1).
cmd_master-init-wrapper() {
    local master_id_arg="$1"
    export BC_MASTER_ID="$master_id_arg"

    # Pass all args (including master_id) through to cmd_wrapper,
    # which expects master_id as its first argument.
    cmd_wrapper "$@"
}

# Start a master claude in a new byobu session with auto-restart
cmd_master() {
    local workdir="" session_name="" model="" prompt=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workdir)  workdir="$2"; shift 2 ;;
            --session)  session_name="$2"; shift 2 ;;
            --model)    model="$2"; shift 2 ;;
            --prompt)   prompt="$2"; shift 2 ;;
            *) _die "master: unknown option: $1" ;;
        esac
    done

    workdir="${workdir:-$(pwd)}"
    session_name="${session_name:-bc-master}"

    # Auto-namespace BC_COMM_DIR by session name if not explicitly set by user.
    # This prevents multiple masters from accidentally sharing the same directory.
    if [[ -z "${_BC_COMM_DIR_ORIG:-}" ]]; then
        export BC_COMM_DIR="/tmp/claude-comm-${session_name}"
        _log "Auto-namespaced BC_COMM_DIR to $BC_COMM_DIR (use explicit BC_COMM_DIR to override)"
    fi

    # Generate a unique master_id for this master
    local master_id
    master_id=$(_gen_id)

    # CRITICAL: write master.lock BEFORE tmux new-session to avoid race condition.
    # If we wrote it in the wrapper (via cmd_init), multiple masters started
    # near-simultaneously would race and overwrite each other's master_id.
    mkdir -p "$BC_COMM_DIR"/{tasks,status,logs}
    if [[ ! -f "$BC_COMM_DIR/registry.json" ]]; then
        echo '[]' > "$BC_COMM_DIR/registry.json"
    fi

    # Check if master.lock already exists with a different master_id (collision or stale).
    # If so, warn the user -- they may need to clean up or use a different session name.
    if [[ -f "$BC_COMM_DIR/master.lock" ]]; then
        local existing_master_id
        existing_master_id=$(_get_master_id)
        if [[ -n "$existing_master_id" && "$existing_master_id" != "$master_id" ]]; then
            _log "WARNING: $BC_COMM_DIR already has master_id $existing_master_id"
            _log "Starting new master with id $master_id anyway (children may conflict)"
        fi
    fi

    local master_window="bc-master"
    # Format: MASTER_ID|PID|PANE_ID|SESSION|WINDOW|TIMESTAMP
    # SESSION|WINDOW identify the master's tmux location for notify
    # pane_id is not yet known (session hasn't been created), use placeholder
    echo "${master_id}|$$|unknown|${session_name}|${master_window}|$(_timestamp)" > "$BC_COMM_DIR/master.lock"

    local claude_args_parts=("--dangerously-skip-permissions")
    if [[ -n "$model" ]]; then
        claude_args_parts+=("--model" "$model")
    fi

    local quoted_args=""
    for arg in "${claude_args_parts[@]}"; do
        quoted_args+=" $(printf '%q' "$arg")"
    done

    # Build the full argument list for _master-init-wrapper: master_id + claude args
    # Each piece must be individually quoted so they survive the outer bash -c parsing
    local master_id_quoted
    master_id_quoted=$(printf '%q' "$master_id")
    # Assemble: master_id first, then claude args (each already quoted by the loop above)
    local wrapper_args="${master_id_quoted}${quoted_args}"

    # env -u BC_MASTER_ID: prevent parent's BC_MASTER_ID from leaking.
    # export BC_COMM_DIR and BC_HOME: ensure these are in the shell's exported environment
    # so child processes of the master inherit them.
    # The master runs in a dedicated "bc-master" window so notify goes to a known window.
    local wrapper_cmd="env -u BC_MASTER_ID bash -c 'export BC_COMM_DIR=\"$(printf '%s' "$BC_COMM_DIR")\" BC_HOME=\"$(printf '%s' "$BC_SCRIPT_DIR")\"; exec bash $(printf '%q' "${BC_SCRIPT_DIR}/bc.sh") _master-init-wrapper ${wrapper_args}'"

    # Create new byobu/tmux session with master in a named window (not window 0)
    tmux new-session -d -s "$session_name" -n "$master_window" -c "$workdir" "$wrapper_cmd"

    # Verify the session was created with our window
    if ! tmux list-windows -t "=${session_name}" -F '#{window_name}' 2>/dev/null | grep -qx "$master_window"; then
        _die "master: failed to create session $session_name with window $master_window"
    fi

    _log "Master session '$session_name' created in $workdir (master_id: $master_id)"
    _log "Attach with: byobu attach -t $session_name"

    # If a prompt was given, wait for claude to start then send it
    if [[ -n "$prompt" ]]; then
        (
            # Wait for claude to be ready in the bc-master window
            for i in $(seq 1 15); do
                sleep 2
                local output
                output=$(tmux capture-pane -t "=${session_name}:${master_window}" -p 2>/dev/null || true)
                if echo "$output" | grep -q "❯"; then
                    sleep 1
                    tmux send-keys -t "=${session_name}:${master_window}" -l "$prompt"
                    tmux send-keys -t "=${session_name}:${master_window}" Enter
                    break
                fi
                # Auto-accept trust dialog
                if echo "$output" | grep -q "trust this folder"; then
                    tmux send-keys -t "=${session_name}:${master_window}" Enter
                fi
            done
        ) &
        disown
    fi
}

cmd_help() {
    cat <<'EOF'
bc.sh - byobu-claude: Multi Claude Code instance management

Usage: bc.sh <command> [args...]

Commands:
  init                                     Initialize communication directory
  spawn [--workdir <dir>] [--model <m>]    Spawn a child Claude Code instance
        [--name <n>] [--task-id <id>]
  master [--workdir <dir>] [--session <s>] Start a master claude in new session
         [--model <m>] [--prompt <p>]
  send  <task_id> <message>                Send message to child (tmux send-keys)
  status [task_id]                         Show status of children
  collect [task_id]                        Collect results from completed tasks
  wait [task_id...] [--timeout <s>]        Wait for tasks to complete
  notify <message>                         Send notification to master process
  done <task_id>                           Mark task as done (called by child)
  logs <task_id> [--lines N]               View child process output (tmux pane)
  kill <task_id>                           Kill a child process
  cleanup [--done|--error|--all]           Clean up finished tasks
  help                                     Show this help
  install                                  Install commands to ~/.claude/commands/

Environment Variables:
  BC_HOME            Path to byobu-claude directory (for commands to find bc.sh)
  BC_COMM_DIR        Communication directory (default: /tmp/claude-comm)
  BC_MAX_CHILDREN    Max concurrent children (default: 10)
  BC_TIMEOUT         Wait timeout in seconds (default: 1800)
  BC_MAX_RESTARTS    Max auto-restarts on crash (default: 20)
  BC_POLL_INTERVAL   Polling interval in seconds (default: 5)

To set BC_HOME permanently, add to ~/.claude/settings.json env section:
  "BC_HOME": "/path/to/byobu-claude"
EOF
}

cmd_install() {
    local cmd_dir="$HOME/.claude/commands"
    mkdir -p "$cmd_dir"

    # Copy command files
    local src_dir="$BC_SCRIPT_DIR/commands"
    if [[ ! -d "$src_dir" ]]; then
        _die "install: commands/ directory not found at $src_dir"
    fi

    local count=0
    for f in "$src_dir"/bc-*.md; do
        [[ -f "$f" ]] || continue
        cp "$f" "$cmd_dir/"
        ((count++)) || true
    done

    _log "Installed $count commands to $cmd_dir"
    _log ""
    _log "To complete setup, add BC_HOME to your Claude settings:"
    _log "  Add to ~/.claude/settings.json -> env:"
    _log "    \"BC_HOME\": \"$BC_SCRIPT_DIR\""
    _log ""
    _log "  Or run:"
    _log "    python3 -c \""
    _log "import json"
    _log "f = '$HOME/.claude/settings.json'"
    _log "d = json.load(open(f))"
    _log "d.setdefault('env',{})['BC_HOME'] = '$BC_SCRIPT_DIR'"
    _log "json.dump(d, open(f,'w'), indent=2)"
    _log "\""
}

# ============================================================
# Main dispatch
# ============================================================

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        init)     cmd_init "$@" ;;
        spawn)    cmd_spawn "$@" ;;
        send)     cmd_send "$@" ;;
        status)   cmd_status "$@" ;;
        collect)  cmd_collect "$@" ;;
        wait)     cmd_wait "$@" ;;
        notify)   cmd_notify "$@" ;;
        done)     cmd_done "$@" ;;
        logs)     cmd_logs "$@" ;;
        kill)     cmd_kill "$@" ;;
        cleanup)  cmd_cleanup "$@" ;;
        install)  cmd_install "$@" ;;
        master)   cmd_master "$@" ;;
        _wrapper) cmd_wrapper "$@" ;;
        _master-init-wrapper) cmd_master-init-wrapper "$@" ;;
        help|-h|--help) cmd_help ;;
        *) _die "Unknown command: $cmd. Run 'bc.sh help' for usage." ;;
    esac
}

main "$@"
