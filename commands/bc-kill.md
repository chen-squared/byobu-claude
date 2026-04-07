---
description: Kill a child Claude Code process
argument-hint: <task_id>
allowed-tools: Bash
---

# Kill Child Process

!`bash "${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh" kill $1 2>&1`

Report the result. Remaining children:
!`bash "${BC_HOME:-/home/chen/workspace/byobu-claude}/bc.sh" status 2>&1`
