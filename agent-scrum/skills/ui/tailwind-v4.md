## Domain: Tailwind CSS v4 — utility classes, config, theming
## Applies to: all stories touching styles, layout, colors, dark mode, custom tokens

### CRITICAL: Tailwind v4 is not Tailwind v3
The config system changed completely. Know these before writing any class.

### Config lives in CSS, not JS
There is no tailwind.config.js in this project.
Design tokens are defined in the main CSS file using @theme:

@import "tailwindcss";
@theme {
  --color-primary: oklch(55% 0.2 260);
  --color-surface: oklch(98% 0 0);
  --font-sans: 'Inter', sans-serif;
  --radius-card: 12px;
}

To add or change a token: edit the CSS file, not a JS config.

### CSS import changed
v4 uses:  @import "tailwindcss";
v3 used:  @tailwind base; @tailwind components; @tailwind utilities;
Never use the old @tailwind directives — they do not exist in v4.

### Gradient classes renamed
v3: bg-gradient-to-r     → v4: bg-linear-to-r
v3: bg-gradient-to-t     → v4: bg-linear-to-t
v3: bg-gradient-to-br    → v4: bg-linear-to-br
All gradient utilities now use bg-linear-*.

### Renamed utilities (common ones)
v3: flex-shrink-0        → v4: shrink-0
v3: overflow-ellipsis    → v4: text-ellipsis
v3: decoration-clone     → v4: box-decoration-clone
Run the official codemod (npx @tailwindcss/upgrade) if doing a migration.

### CSS variable access
Every @theme token is a CSS custom property:
  background: var(--color-primary);
  border-radius: var(--radius-card);
Access tokens from plain CSS when you need them outside Tailwind utilities.

### Dark mode
Dark mode is configured via CSS, not tailwind.config.js:
@variant dark (&:where(.dark, .dark *)) {
  /* dark mode overrides */
}
Or use the class-based variant dark:bg-slate-900 in JSX as before.

### clsx + tailwind-merge pattern (always use this for conditional classes)
import { clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'
export function cn(...inputs) { return twMerge(clsx(inputs)) }
Never concatenate class strings manually — always use cn() from lib/utils.ts.

### Container queries (v4 native, no plugin needed)
<div class="@container">
  <div class="@sm:grid-cols-2">...</div>
</div>
Container queries are built in — no @tailwindcss/container-queries plugin required.

### Pitfalls
- Using @tailwind directives → no-op in v4, breaks build
- Using bg-gradient-to-r → does not exist in v4, use bg-linear-to-r
- Editing tailwind.config.js → file does not exist in this project
- Using arbitrary values with old var() shorthand like bg-[--color] → must be bg-(--color) in v4
- Not using cn() for conditional classes → class conflicts not resolved, styles unpredictable
- Using a deprecated plugin that has not updated for v4 → plugin silently does nothing
