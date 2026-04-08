---
description: Delegate a task to a child Claude Code process in a new byobu window
argument-hint: <task-description>
allowed-tools: Bash, Read, Write
---

# Delegate Task to Child Process

You are delegating a task to a child Claude Code process running in a separate byobu window.

The bc.sh script location: !`echo "${BC_HOME:-/home/chen/workspace/byobu-claude}"`

Set BC for convenience: `BC="${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh"`

## Step 1: Initialize

!`bash "${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh" init 2>&1`

## Step 2: Current status

!`bash "${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh" status 2>&1`

## Step 3: Prepare and Delegate

The task to delegate: $ARGUMENTS

You must:

1. **Spawn a child** by running: `bash "$BC" spawn --workdir <dir> [--model <model>] [--name <name>]`
   - Use the current working directory as `--workdir` unless the task specifies otherwise
   - Use `--model sonnet` for routine tasks, omit for complex tasks (inherits main model)
   - The command outputs the task_id on the last line

2. **Wait a few seconds** for the child to start up (5-8 seconds), then check the child window is ready:
   Run `bash "$BC" logs <task_id> --lines 5` to verify claude is running.

3. **Send the task** via: `bash "$BC" send <task_id> '<detailed task description>'`
   
   CRITICAL: Include enough context in the message that the child can work independently:
   - Relevant file paths and their purposes
   - Architecture decisions or constraints
   - Expected behavior and acceptance criteria
   - The result file path: `$BC_COMM_DIR/tasks/<task_id>.result.md` (get `BC_COMM_DIR` by running `echo $BC_COMM_DIR`)
   - Remind the child to run `bash $BC done <task_id>` when complete
   - Remind the child to run `bash $BC notify "Task <task_id> completed"` to notify you

4. **Report** the task_id back so status can be checked later with `/bc-status`
