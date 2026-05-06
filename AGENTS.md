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
- Separate data fetching, rendering, translation, and storage in code structure.
- Errors must surface clearly; do not silently swallow primary failures.
- Use `user-error` for user-caused problems and `error` for programmer bugs.

## Emacs Lisp Rules

- Every file uses lexical binding.
- Public names use `hnview-`.
- Private names use `hnview--`.
- Read-only UI buffers derive from `special-mode`.
- Per-buffer state uses `defvar-local`.
- User options use `defcustom` with precise `:type` and `:group`.
- Use text properties for item metadata; overlays only for ephemeral visuals.
- Build buffers from cached structured data, not by reparsing displayed text.
- Add autoloads only to user-facing commands.
- Loading files must not alter Emacs behavior; activation must be explicit.

## UI Rules

- Keep the UI quiet, dense, and keyboard-first.
- Preserve clear hierarchy: tabs, date, title, metadata, translation.
- Use faces, not hard-coded colors in rendering code.
- Translation replaces the original text in place while preserving the existing
  story/comment layout.
- Do not use `tabulated-list-mode` for the main feed unless the design changes.
- Do not add decorative cards, icons, or web-style chrome.

## LLM Rules

- Use `llm.el` as the default request transport.
- Keep the translation API provider-neutral inside `hnview`.
- Never make LLM calls during package load.
- Cache successful translations.
- Failed translations should not break feed or comment browsing.

## Quality Gates

Before committing:

- Run ERT tests.
- Byte-compile with zero warnings.
- Run `checkdoc` with zero warnings.
- Run `package-lint` with zero warnings for package files.
- Read the full diff.
