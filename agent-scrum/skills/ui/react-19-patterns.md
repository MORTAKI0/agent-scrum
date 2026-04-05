## Domain: React 19 — hooks, actions, server/client boundaries
## Applies to: any story adding hooks, forms, state, optimistic UI, context

### New hooks you should use (React 19 stable)
useActionState(action, initialState)
  — replaces useFormState (removed in React 19)
  — returns [state, dispatch, isPending]
  — use this for all server action form wiring

useFormStatus()
  — must be called inside a component rendered inside a <form>
  — returns { pending, data, method }
  — use for submit buttons that need a loading state

useOptimistic(value, updateFn)
  — show optimistic UI while server action is in flight
  — reverts automatically on error

use(promise | context)
  — can be called conditionally (unlike hooks)
  — use for reading context in async boundaries
  — use for passing promises from server to client

### Old patterns that are gone in React 19
useFormState → replaced by useActionState from 'react' (not react-dom)
React.memo, useMemo, useCallback → React Compiler handles this automatically
  — do not add memoization unless profiler shows a real problem

### Server actions as form actions (React 19 stable pattern)
async function myAction(formData: FormData) {
  'use server'
  // runs on server, no API route needed
}
<form action={myAction}>...</form>
This gives progressive enhancement for free — works without JS.

### Client component with server action + useActionState
'use client'
import { useActionState } from 'react'
import { myAction } from '@/lib/actions/my-action'

const [state, dispatch, isPending] = useActionState(myAction, null)
return <form action={dispatch}>...</form>

### Pitfalls
- Using useFormState (old) instead of useActionState (new) → import error in React 19
- Adding useMemo/useCallback everywhere → redundant with React Compiler, adds noise
- Calling a hook inside a server component → "hooks can only be called in function components"
- Importing server component from client component → build error
- Passing non-serializable values (functions, class instances) from server to client as props → runtime error
- Creating a promise in a client component without Suspense → uncached promise warning
