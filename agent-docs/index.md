# Cobuild Protocol Agent Docs Index

Last verified: 2026-02-26

## Purpose

This index is the table of contents for durable protocol context that agents should use.

## Canonical Docs

| Path | Purpose | Source of truth | Owner | Review cadence | Criticality | Last verified |
| --- | --- | --- | --- | --- | --- | --- |
| `agent-docs/design-docs/index.md` | Index for durable design/principles docs. | `agent-docs/design-docs/**` | Protocol Maintainers | Monthly | Medium | 2026-02-18 |
| `agent-docs/design-docs/core-beliefs.md` | Core agent-first repo principles. | Team architecture and process decisions | Protocol Maintainers | Quarterly | Medium | 2026-02-18 |
| `agent-docs/product-specs/index.md` | Index for protocol behavior contracts. | `agent-docs/product-specs/**` | Protocol + Product Maintainers | Monthly | High | 2026-02-18 |
| `agent-docs/product-specs/protocol-lifecycle-and-invariants.md` | Lifecycle and consumer-facing protocol behavior constraints. | `src/goals/**`, `src/Flow.sol`, `src/tcr/**` | Protocol Maintainers | Per behavior-change PR | High | 2026-02-22 |
| `ARCHITECTURE.md` | Top-level repository architecture and invariants. | `src/**`, `test/**`, workflows | Protocol Maintainers | Per architecture PR | High | 2026-02-24 |
| `agent-docs/cobuild-protocol-architecture.md` | Detailed module/domain architecture map and interaction flows. | `src/**`, `test/**` | Protocol Maintainers | Per architecture PR | High | 2026-02-24 |
| `agent-docs/protocol-audit-deep-dive.md` | Auditor guide to lifecycle states, fund routes, unlock gates, and review anchors. | `src/goals/**`, `src/hooks/**`, `src/Flow.sol`, `src/tcr/**`, `test/**` | Protocol Maintainers | Per protocol behavior PR | High | 2026-02-23 |
| `agent-docs/PLANS.md` | Execution plan workflow and quality bar. | `agent-docs/exec-plans/**` | Protocol Maintainers | Per process change | Medium | 2026-02-18 |
| `agent-docs/operations/verification-and-runtime.md` | Verification lanes, required-check matrix, queue behavior, and runtime guardrails. | `package.json`, `scripts/**`, completion policy in `AGENTS.md` | Protocol Maintainers | Per process/CI change | High | 2026-02-26 |
| `agent-docs/operations/completion-workflow.md` | Post-implementation simplify, coverage-audit, and completion-audit sequence. | `agent-docs/prompts/**`, completion policy in `AGENTS.md` | Protocol Maintainers | Per process change | High | 2026-02-24 |
| `agent-docs/operations/deployment-notes.md` | Deployment-time security guardrails for initializer-based clone/proxy flows. | `src/goals/**`, `src/hooks/**`, `src/tcr/**`, deployment procedures | Protocol Maintainers | Per deployment-model PR | High | 2026-02-26 |
| `agent-docs/prompts/simplify.md` | Prompt for behavior-preserving simplification pass after implementation. | Completion workflow in `AGENTS.md` | Protocol Maintainers | Per process change | Medium | 2026-02-23 |
| `agent-docs/prompts/test-coverage-audit.md` | Prompt for post-simplify subagent pass that audits coverage and implements highest-impact tests. | Completion workflow in `AGENTS.md` | Protocol Maintainers | Per process change | High | 2026-02-23 |
| `agent-docs/prompts/task-finish-review.md` | Prompt for final completion audit pass before handoff. | Completion workflow in `AGENTS.md` | Protocol Maintainers | Per process change | High | 2026-02-23 |
| `agent-docs/PRODUCT_SENSE.md` | Product-level protocol intent and stability expectations. | Protocol behavior across Flow/TCR/goals modules | Protocol + Product Maintainers | Monthly | Medium | 2026-02-18 |
| `agent-docs/QUALITY_SCORE.md` | Quality posture tracker by subsystem. | Architecture docs + tests + CI outputs | Protocol Maintainers | Bi-weekly | Medium | 2026-02-24 |
| `agent-docs/RELIABILITY.md` | Reliability invariants, failure modes, and verification posture. | `src/**`, `test/**`, CI checks | Protocol Maintainers | Per reliability-affecting PR | High | 2026-02-24 |
| `agent-docs/SECURITY.md` | Security boundaries and escalation criteria. | Access control, upgrade, funds, callback boundaries | Protocol Maintainers | Per security-affecting PR | High | 2026-02-22 |
| `agent-docs/references/README.md` | Internal/external reference catalog. | `agent-docs/references/**` | Protocol Maintainers | Monthly | Medium | 2026-02-18 |
| `agent-docs/references/module-boundary-map.md` | Contract/module boundary map and dependency directions. | `src/**` | Protocol Maintainers | Per module-boundary PR | High | 2026-02-23 |
| `agent-docs/references/flow-allocation-and-child-sync-map.md` | Flow allocation, snapshot/commit, and child-sync runtime map. | `src/Flow.sol`, `src/library/**`, `src/flows/CustomFlow.sol` | Protocol Maintainers | Per flow/allocation PR | High | 2026-02-23 |
| `agent-docs/references/tcr-and-arbitration-map.md` | TCR request/challenge/dispute lifecycle map. | `src/tcr/**` | Protocol Maintainers | Per tcr/arbitrator PR | High | 2026-02-24 |
| `agent-docs/references/goal-funding-and-reward-map.md` | Goal/Budget treasury funding and resolution flow map. | `src/goals/**`, `src/hooks/GoalRevnetSplitHook.sol` | Protocol Maintainers | Per goals/treasury PR | High | 2026-02-21 |
| `agent-docs/references/economic-considerations.md` | Incentive-risk notes and attack surfaces for treasury/reward/TCR interactions. | `src/goals/**`, `src/tcr/**`, protocol mechanism-design reviews | Protocol Maintainers | Per economics/mechanism PR | High | 2026-02-25 |
| `agent-docs/references/uma-deployment-recommendations.md` | Pre-launch UMA resolver deployment defaults and policy guidance (`USDC`, `$750`, bond/liveness overrides). | `src/goals/UMATreasurySuccessResolver.sol`, `src/goals/GoalTreasury.sol`, `src/goals/BudgetTreasury.sol`, UMA/Polymarket primary docs | Protocol Maintainers | Per oracle-policy PR | High | 2026-02-25 |
| `agent-docs/references/testing-ci-map.md` | Testing and CI enforcement map. | `.github/workflows/**`, `scripts/**`, `package.json` | Protocol Maintainers | Per CI/process PR | Medium | 2026-02-26 |
| `agent-docs/references/foundry-llms.txt` | External Foundry reference pack. | Foundry docs | Protocol Maintainers | Quarterly | Low | 2026-02-18 |
| `agent-docs/references/openzeppelin-upgradeable-llms.txt` | External OpenZeppelin upgrade/security references. | OpenZeppelin docs | Protocol Maintainers | Quarterly | Low | 2026-02-18 |
| `agent-docs/references/superfluid-llms.txt` | External Superfluid reference pack. | Superfluid docs | Protocol Maintainers | Quarterly | Low | 2026-02-18 |
| `agent-docs/references/bananapus-llms.txt` | External Bananapus/JBX reference pack. | Bananapus docs + source | Protocol Maintainers | Quarterly | Low | 2026-02-18 |
| `agent-docs/generated/README.md` | Generated documentation artifacts. | `agent-docs/generated/**` | Protocol Maintainers | Per script change | Medium | 2026-02-18 |
| `agent-docs/exec-plans/` | Active/completed execution plans. | PR-linked plan docs | Protocol Maintainers | Per multi-file/high-risk PR | High | 2026-02-24 |
| `agent-docs/exec-plans/tech-debt-tracker.md` | Rolling debt register with owner/priority/status. | Audits, incidents, reviews | Protocol Maintainers | Bi-weekly | Medium | 2026-02-18 |

## Conventions

- Keep `AGENTS.md` short and route-oriented.
- Update this index when adding/removing/moving docs.
- For multi-file/high-risk work, add a plan in `agent-docs/exec-plans/active/`.
