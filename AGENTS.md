# AGENTS.md

## Project Goal

Build `hnview`, a modern Emacs-native Hacker News reader inspired by the
best parts of Haiker: clean feed browsing, readable comment threads, local
bookmarks, and LLM-assisted translation.

This is not a WebView clone. Prefer Emacs buffers, faces, keymaps, text
properties, buttons, and keyboard-first workflows.

## File Organization

Start with a single implementation file, `hnview.el`.

Allowed initial files:

- `hnview.el`
- `test/hnview-test.el`
- `README.md`
- `PRD.md`
- `AGENTS.md`

Do not split code into additional `.el` files until there is a clear, current
maintenance problem. Prefer internal section headers over premature file
boundaries.

## Engineering Rules

- Prefer simple solutions over clever abstractions.
- Split files only when responsibilities are genuinely distinct.
- Find the root cause before changing behavior.
- Interactive commands should be thin wrappers.
- Prefer one consistent behavior model over overlapping commands or
  mode-specific branches.
- Separate data fetching, rendering, translation, and storage in code structure.
- Errors must surface clearly; do not silently swallow primary failures.
- Use `user-error` for user-caused problems and `error` for programmer bugs.
- If two attempted fixes fail on the same issue, stop patching and switch back
  to diagnosis before changing more code.

## Documentation Rules

- Keep `README.md` focused on user-facing usage and `PRD.md` focused on product
  behavior, scope, and tradeoffs.
- Any change to key bindings, defaults, login/session behavior, cache behavior,
  translation UX, article reading, or visible layout must update docs in the
  same change.
- If code and docs diverge, treat code as the source of truth and fix docs
  immediately.

## Emacs Lisp Rules

- Every file uses lexical binding.
- Public names use `hnview-`.
- Private names use `hnview--`.
- Read-only UI buffers derive from `special-mode`.
- Per-buffer state uses `defvar-local`.
- User options use `defcustom` with precise `:type` and `:group`.
- Use text properties for item metadata; overlays only for ephemeral visuals.
- Build buffers from cached structured data, not by reparsing displayed text.
- Rendering must be deterministic from buffer-local state and structured data.
- Add autoloads only to user-facing commands.
- Loading files must not alter Emacs behavior; activation must be explicit.

## UI Rules

- Keep the UI quiet, dense, and keyboard-first.
- Preserve clear hierarchy: tabs, date, title, metadata, translation.
- Use faces, not hard-coded colors in rendering code.
- Prefer compact Emacs-native state display, such as mode-line text and
  minibuffer/completing-read prompts, over web-style rows of navigation chrome.
- Translation replaces the original text in place while preserving the existing
  story/comment layout.
- Preserve point and window position across translation, refresh, and async
  completion unless a command explicitly navigates elsewhere.
- Comment and article text should use logical paragraphs and let Emacs wrap
  lines. Do not insert artificial visual wrapping into stored or rendered text.
- Linkification, quote rendering, and metadata layout must stay consistent
  before and after translation.
- Article images wider than the current window should scale down to fit the
  readable area.
- Do not use `tabulated-list-mode` for the main feed unless the design changes.
- Do not add decorative cards, icons, or web-style chrome.

## Async and Network Rules

- Feed fetches, login, voting, article fetching, and LLM translation must not
  block Emacs.
- Pending network or translation work should be visible in the mode line or a
  concise message while the original readable content remains in place.
- Async callbacks must check that the target buffer is still live and still
  represents the same source before mutating it.
- Empty or failed network/translation results should not replace good visible
  content.

## Persistence and Credentials

- SQLite stores cache, local app state, and HN session data. Do not store
  plaintext HN passwords or API keys in SQLite.
- HN credentials come from `auth-source`; provider API keys come from the
  provider integration or standard secret sources.
- Cache only successful, non-empty translations. Failed or empty translations
  should remain retryable.
- SQLite schema changes need explicit migration behavior and documented cleanup
  semantics.

## LLM Rules

- Use `llm.el` as the default request transport.
- Keep the translation API provider-neutral inside `hnview`.
- Keep translation cache, pending state, retries, prompt construction, and LLM
  dispatch centered on provider-neutral translation units. Feed/thread/profile
  and article code should adapt UI items into those units instead of owning
  translation mechanics directly.
- Never make LLM calls during package load.
- Cache successful translations and reuse them before making a new request.
- Failed translations should not break feed or comment browsing.
- Translation prompts should be customizable without changing provider code.

## Quality Gates

Before committing:

- Run ERT tests.
- Byte-compile with zero warnings.
- Run `checkdoc` with zero warnings.
- Run `package-lint` with zero warnings for package files.
- Run `git diff --check`.
- Read the full diff.
