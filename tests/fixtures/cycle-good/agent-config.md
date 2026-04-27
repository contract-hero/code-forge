---
project_domains: []

required_subagents: []

recommended_agents:
  - subagent_type: "superpowers:test-driven-development"
    rationale: "Cross-cutting TDD discipline; user-favored."
    suitable_for: [test-author, implementer]
    domain_relevance: medium
---

# Routing decisions

Greenfield/non-Sui project: no project_domain, no glob bindings. Soft roster
preserves user favoritism for general TDD discipline; orchestrator falls back
to general-purpose for everything else.
