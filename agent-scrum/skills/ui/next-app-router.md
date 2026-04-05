## Domain: Next.js 16 App Router — routing and file structure
## Applies to: all stories touching pages, layouts, routes, navigation, loading/error states

### CRITICAL: no src/ in this repo
This repo uses root-level app/, components/, lib/ — not src/app/ or src/components/.
Do not probe or write paths beginning with src/. They do not exist.

### Special file conventions (what goes where)
app/layout.tsx             — root layout, wraps all pages, sets <html> and <body>
app/page.tsx               — homepage (/)
app/loading.tsx            — Suspense fallback for a route segment
app/error.tsx              — error boundary (must be 'use client')
app/not-found.tsx          — 404 page
app/(group)/               — route group, not included in URL, used for layout scoping
app/(group)/[slug]/page.tsx — dynamic route
app/api/**/route.ts        — API route handlers (GET, POST, etc.)

### Route groups in use
Check app/ for existing (group) folders before creating new routes.
Never create a new page without first checking if an existing group layout applies.

### Special files you must NOT create unless explicitly planned
- middleware.ts (only one, at root level, already exists)
- instrumentation.ts (do not touch)
- next.config.ts (do not touch)

### Server vs client components — the rule
Default is server component. Add 'use client' only when the component needs:
- useState, useEffect, useReducer, or any hook
- browser APIs (window, document, localStorage)
- event handlers passed as props (onClick, onChange)
- Supabase browser client
If a parent is 'use client', all its children are client too — do not import
server-only modules from a client component.

### Data fetching pattern
Server components fetch data directly with async/await — no useEffect, no SWR.
Client components that need data receive it as props from a server parent,
or use a server action to mutate and revalidate.

### Metadata API (do not use react-helmet or next/head)
export const metadata: Metadata = {
  title: 'Page title',
  description: 'Description',
}
This goes in layout.tsx or page.tsx — never in a client component.

### Navigation
Use <Link href="..."> for internal links — never <a href>.
Use useRouter() only in client components for programmatic navigation.
router.push() and router.replace() both trigger client-side navigation.

### Pitfalls
- Forgot 'use client' → hooks throw "can only be used in client component"
- Server component imports client-only library → build fails silently in dev, crashes in prod
- Creating a page without a layout wrapper when the route group has one → visual regression
- Using <a href> instead of <Link> → full page reload instead of soft navigation
- Calling cookies() or headers() in a component that renders client-side → runtime error
