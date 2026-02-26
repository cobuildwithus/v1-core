Objective:
Identify griefing, liveness, and denial-of-service vectors where an attacker can cause disproportionate harm.

Review priorities:
- Permissionless entrypoints that can be spammed to force expensive paths.
- Queue, loop, or fanout patterns with attacker-controlled growth.
- State transitions that can be stalled by unresolved external dependencies.
- Best-effort failure handling that can be abused to keep the system degraded.
- Dust/minimum-value edge cases that create persistent cleanup overhead.
