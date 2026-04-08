---
description: Orchestrate a multi-child workflow - decompose, delegate, monitor, iterate
argument-hint: <high-level-goal>
allowed-tools: Bash, Read, Write
---

# Orchestrate Multi-Child Workflow

Goal: $ARGUMENTS

Set BC for convenience: `BC="${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh"`

## Phase 1: Initialize and Plan

!`bash "${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh" init 2>&1`

Analyze the goal and decompose it into independent, parallelizable sub-tasks.
For each sub-task, determine:
- Clear description with all needed context
- Working directory
- Whether it needs a powerful model or sonnet is sufficient

## Phase 2: Delegate

For each sub-task:
1. Spawn a child: `bash "$BC" spawn --workdir <dir> [--model <model>]`
2. Wait 5-8 seconds for child to initialize
3. Send the task: `bash "$BC" send <task_id> '<task description>'`
4. Include in the message:
   - Full task context
   - Result file: `$BC_COMM_DIR/tasks/<task_id>.result.md` (get `BC_COMM_DIR` by running `echo $BC_COMM_DIR`)
   - Completion commands: `bash $BC done <task_id>` and `bash $BC notify "Task <task_id> completed"`

## Phase 3: Wait

Wait for all children to complete:
`bash "$BC" wait --timeout 600 2>&1`

Or poll periodically:
`bash "$BC" status 2>&1`

## Phase 4: Collect and Analyze

`bash "$BC" collect 2>&1`

Read each result file and analyze for completeness and correctness.

## Phase 5: Iterate if Needed

If issues are found:
1. Send follow-up tasks to existing children: `bash "$BC" send <task_id> '<correction>'`
2. Or spawn new children for new sub-tasks
3. Wait and collect again

Report progress to the user at each phase boundary.

## Phase 6: Cleanup

When all tasks are satisfactorily complete:
`bash "$BC" cleanup --done 2>&1`

Summarize what was accomplished and list all changes made.
