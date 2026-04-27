# Test spec — e2e-extract.sh fixture

## Vision
Tiny spec for exercising e2e-extract.sh.

## Core Features
- A single feature.

## Architecture Overview
None.

## E2E Tests

```yaml
- id: E-001
  name: user signs in and sees their counter
  kind: ui
  preconditions:
    - app running on localhost:3000
  steps:
    - navigate to /sign-in
    - fill #email with 'test@example.com'
    - click button:has-text('Sign in')
    - wait for url '/dashboard'
    - assert text 'Counter: 0' visible
  expected: Dashboard loads showing zero counter for new user
  covers_contract: [R1.1, R3.2]
  tooling: chrome-devtools-mcp

- id: E-002
  name: cli help prints usage
  kind: cli
  preconditions: []
  steps:
    - run "myapp --help"
  expected: stdout contains 'Usage:'
  covers_contract: [R5.1]
  tooling: null
```
