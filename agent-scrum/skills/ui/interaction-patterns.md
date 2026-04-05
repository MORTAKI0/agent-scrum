# Domain: Frontend interaction patterns for dashboard widgets
# Applies to: frontend-feature stories adding new interactive UI behavior without backend changes

## Use this when the story adds a new interaction surface
- Prefer extending an existing dashboard surface before creating a new subsystem.
- Keep changes component-local and reuse existing props/data contracts.
- Preserve server/client boundaries; new interaction logic should stay in client components.

## File targeting guidance
- Start from existing dashboard composition files (for example, `app/(app)/dashboard/*`).
- Add or adjust focused selectors/assertions in existing dashboard e2e coverage when interaction behavior changes.
- Avoid service/data layer edits when the story explicitly says "without backend changes."

## Scope controls
- Do not modify auth/session/middleware/policy files for frontend-feature stories.
- Do not introduce API routes or database changes for interaction-only work.
- Keep CSS edits limited to feature-adjacent selectors.

## Evidence expectations
- Ensure at least one explicit, user-visible status/call-to-action is present.
- Keep accessibility labels stable when adding action controls.
- Validate with the story's `validation_profile` command list.
