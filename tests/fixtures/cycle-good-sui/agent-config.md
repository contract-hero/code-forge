---
project_domains:
  - sui-dapp

required_subagents:
  - match: "**/*.move"
    subagent_type: "sui-pilot:sui-pilot-agent"
    applies_to: [planner, implementer-worker, reviewer]
  - match: "Move.toml"
    subagent_type: "sui-pilot:sui-pilot-agent"
    applies_to: [planner, implementer-worker]

recommended_agents:
  - subagent_type: "sui-pilot:sui-pilot-agent"
    rationale: "Primary Sui/Move specialist; user-favored."
    suitable_for: [planner, test-author, implementer, reviewer]
    domain_relevance: high
  - subagent_type: "superpowers:test-driven-development"
    rationale: "Cross-cutting TDD discipline; user-favored."
    suitable_for: [test-author, implementer]
    domain_relevance: high
---

# Routing decisions

Detected `Move.toml` and `@mysten/sui` in `package.json` → tagged as `sui-dapp`.
With `sui-dapp` in `project_domains`, forge-guard rule 6 forces
`sui-pilot:sui-pilot-agent` for every Task dispatch in this run regardless of
file extension. The per-glob `required_subagents` entries below stay as
fallback for any future variant of this config that drops the project domain.
