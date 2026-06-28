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
- Use `condition-case` only at explicit boundaries or around recoverable
  non-essential operations. Do not catch internal failures just to return a
  plausible default.
- If two attempted fixes fail on the same issue, stop patching and switch back
  to diagnosis before changing more code.

## Refactoring Rules

- A refactor must create net value: simpler architecture, less meaningful
  duplication, clearer ownership, better robustness, or stronger tests.
- Do not add wrappers, accessors, or helper layers around a single use site
  unless they name a real domain rule or remove real complexity.
- When helper piles appear, fix the owner or data flow instead of adding more
  pass-through functions.
- Move whole responsibilities together: state, operations, validation, and
  rendering/formatting that belong to the same workflow.
- Keep broad refactors evidence-driven. Inspect code, tests, docs, and
  integration points before choosing boundaries.
- Do not split code into `utils`, `common`, or vague helper files.

## Documentation Rules

- Keep `README.md` focused on user-facing usage and `PRD.md` focused on product
  behavior, scope, and tradeoffs.
- Any change to key bindings, defaults, login/session behavior, cache behavior,
  translation UX, article reading, or visible layout must update docs in the
  same change.
- If code and docs diverge, treat code as the source of truth and fix docs
  immediately.
- Optimize Markdown for rendered reading. Do not rewrap unchanged prose just to
  satisfy source-width aesthetics.

## Emacs Lisp Rules

- Every file uses lexical binding.
- Public names use `hnview-`.
- Private names use `hnview--`.
- Predicate names end in `-p`; unused arguments start with `_`.
- Read-only UI buffers derive from `special-mode`.
- Per-buffer state uses `defvar-local`.
- User options use `defcustom` with precise `:type` and `:group`.
- Use text properties for item metadata; overlays only for ephemeral visuals.
- Build buffers from cached structured data, not by reparsing displayed text.
- Rendering must be deterministic from buffer-local state and structured data.
- Keep control flow flat where possible. Prefer `if-let*`, `when-let*`, and
  `pcase`/`pcase-let` over nested `car`/`cdr`/`nth` chains.
- Prefer stock Emacs primitives and protocols (`completing-read`,
  `special-mode`, hooks, text properties, `text-property-search-forward`) over
  custom frameworks.
- Add `;;;###autoload` only to user-facing commands and user-facing minor
  modes.
- Loading files must not alter Emacs behavior; activation must be explicit.
- Do not call another package's double-dash private symbols. Add or require a
  public API instead.
- Require direct runtime dependencies explicitly; do not rely on transitive
  loading.
- Use `declare-function` and `defvar` to keep byte-compilation honest, but do
  not use declarations to patch unclear ownership boundaries.
- Avoid `with-eval-after-load` in package code unless registering an optional
  integration at a clear package boundary.

## Version and Package Rules

- Keep the Emacs baseline and direct dependency versions explicit in
  `Package-Requires`.
- Do not silently raise the Emacs or dependency baseline. If a change requires
  it, update package metadata and user documentation in the same change.
- Before using a newer Emacs API, verify when it was introduced. Guard or avoid
  APIs above the declared baseline.
- Keep the main package header MELPA-friendly: short first-line description,
  `Author`, `URL`, `Version`, and complete direct `Package-Requires`.
- Public `defun`, `defmacro`, `defcustom`, and `defvar` forms need docstrings.
  Docstring first lines should be complete sentences ending with a period, and
  argument names should be uppercased.
- If the package is ever split, package metadata stays in the main package file;
  implementation files get their own file headers and license metadata without
  duplicating `Package-Requires`.

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

## Testing Rules

- For user-visible bugs, write or update a failing test that reproduces the
  broken public path before fixing the code when practical.
- Tests should fail when the implementation is wrong. Assert specific,
  distinguishable behavior rather than only checking that helpers return
  something plausible.
- For dispatch, hook, command routing, async callback, or completion bugs, test
  the installed/public dispatch path, not only a helper-level candidate list.
- Match test weight to risk and blast radius. Use the smallest test that proves
  the intended behavior.
- Update existing tests for changed behavior in the same change; remove tests
  that only lock in irrelevant implementation details.

## Quality Gates

Before committing:

- Run ERT tests.
- Byte-compile with zero warnings.
- Run `checkdoc` with zero warnings.
- Run `package-lint` with zero warnings for package files.
- Run `git diff --check`.
- Read the full diff.
