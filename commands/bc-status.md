---
description: Check status of all child Claude Code processes
allowed-tools: Bash
---

# Check Child Process Status

!`bash "${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh" status 2>&1`

Interpret the results:
- **pending**: Child spawned but no task sent yet
- **running**: Child is working on a task
- **done**: Child completed, results ready to collect with `/bc-collect`
- **error**: Child crashed or failed, check logs
- **killed**: Child was manually terminated

If any tasks are **done**, suggest running `/bc-collect` to gather results.
If any tasks have **error**, suggest investigating by running `bash "${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh" logs <task_id>`.
