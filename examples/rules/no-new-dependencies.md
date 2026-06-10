# Project rules: no new dependencies without sign-off

Hard constraints for the planning, review, and coding agents.

- Do not add new third-party packages (composer / npm / pip / cargo / go get / …)
  as part of an automated change. Use what is already in the project's lockfile.
- If a task seems to need a new dependency, STOP and raise it as a question for a
  human to approve — do not add it silently.
- Prefer the standard library and existing utilities over pulling in a package.
- Reviewer: flag any new dependency introduced by the plan or the diff as `[BLOCKING]`.
