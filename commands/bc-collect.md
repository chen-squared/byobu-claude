---
description: Collect results from completed child Claude Code processes
argument-hint: [task_id]
allowed-tools: Bash, Read
---

# Collect Results from Child Processes

!`bash "${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh" collect $ARGUMENTS 2>&1`

After collecting, analyze each result:
1. Which tasks completed successfully
2. What changes were made
3. Any issues or errors encountered
4. Suggested next steps

If there are errors, read the log files by running `bash "${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh" logs <task_id>`.
