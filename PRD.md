# hnview PRD

## 1. Product Summary

`hnview` is an Emacs-native Hacker News reader inspired by Haiker's clean
reading experience, but designed around Emacs conventions: buffers, faces,
keymaps, text properties, SQLite state, and keyboard-first workflows.

The product is not a WebView clone. It should feel like a focused Emacs tool
for reading HN, following threads, translating content, and replying when
logged in.

## 2. Current Completion Status

The first usable version is largely complete for reading, translating, folding
comments, bookmarking, inbox scanning, login, upvote, reply workflows, and
SQLite-backed HN cookie storage.

It is not fully complete as a polished product. The main remaining product
work is packaging polish plus a few advanced HN workflows.

| Area | Status | Notes |
| --- | --- | --- |
| Feed browsing | Done | Top, Ask, Show, Best, New, Active; Ask/Show and Best/New sub-sections. |
| Thread reading | Done | Story header, nested comments, load more/all. |
| Article reader | Prototype | Extracts original story pages into native Emacs buffers with Markdown fallback, syntax-highlighted code, bounded image scaling, and block translation. |
| Comment UX | Done | Keyboard folding, inline `N more`, quote rendering, author styling. |
| Translation | Done | `llm.el`, `C-c C-v t`/`C-c C-v T`, in-place replacement, SQLite cache, pruning. |
| Point preservation | Done | Translation toggle keeps point in the current comment. |
| Bookmarks | Done | SQLite-backed local bookmarks. |
| Login/reply | Done | `auth-source` credentials, HN web forms, reply buffer. |
| Upvote | Done | Uses HN vote endpoint; status marker is session-local. |
| Inbox | Done | Scans user submissions and shows direct replies. |
| Profile/activity views | Done | About, Stories, Comments, Favorites, Upvoted, Hidden. |
| HTTP transport | Done | Uses `plz` for HTTP requests. |
| Cookie storage | Done | Stores HN cookies in SQLite. |
| Packaging | Needs work | Needs final install instructions and package metadata polish. |

## 3. Goals

- Provide a readable, low-noise HN feed and thread experience inside Emacs.
- Keep all primary workflows keyboard-first.
- Support LLM translation without coupling hnview to one LLM provider.
- Cache expensive translation results locally.
- Preserve Emacs UI/UX expectations rather than copying web UI literally.
- Keep implementation compact in one `.el` file until splitting is clearly
  justified.

## 4. Non-Goals

- No WebView or browser embedding.
- No mobile push notifications.
- No downvoting in v1.
- No full HN submission workflow in v1.
- No attempt to mirror every Haiker visual detail.
- No automatic migration from legacy cookie files in v1; users can log in
  again to populate the SQLite cookie store.

## 5. Users

Primary user:

- An Emacs user who reads HN regularly, prefers keyboard navigation, and wants
  translation available in-place.

Secondary user:

- A bilingual or multilingual reader who wants HN comments translated while
  retaining the original structure, indentation, quote blocks, and thread
  hierarchy.

## 6. Functional Requirements

### 6.1 Feed Browsing

- Show Top, Ask, Show, Best, New, and Active feeds.
- Support Ask/Show Top and New sub-sections, plus Best/New Stories and
  Comments sub-sections.
- Switch feeds with both feed picker and prefixed number shortcuts; switch
  sub-sections with `C-c C-v s`.
- Refresh the current buffer with `C-c C-v g`.
- Display each story with title, domain, points, author, age, and comment count.
- Open original URLs through the system browser or EWW.

### 6.2 Thread Reading

- Open story threads inside Emacs.
- Render story title, metadata, and optional story text.
- Render nested comments with indentation and stable metadata alignment.
- Load more comments with `C-c C-v +`.
- Load all comments with `C-c C-v *`.
- Detect truncated comment trees and show a load-more hint.

### 6.3 Comment Interaction

- Navigate between items with `n`/`p`.
- Fold/unfold comments with `TAB`.
- Show folded comments as inline metadata, for example:

  ```text
  alice • 3 hours ago • 4 more
  ```

- Count hidden descendants, not just direct children.
- Render HN quote lines that begin with `>` as quote blocks using
  `hnview-quote-symbol`.
- Use orange author names matching the story domain face.
- Render inline URLs as compact buttons with readable domain/path labels while
  preserving original paragraph layout in source and translated text.

### 6.4 Translation

- Use `llm.el` as the provider-neutral LLM transport.
- Allow `hnview-llm-provider` to be either a provider object or a provider
  factory function.
- Provide a customizable translation prompt template through
  `hnview-translation-prompt-template`; the default prompt should favor
  natural, idiomatic Simplified Chinese for technical readers.
- Provide `hnview-translation-glossary` for preferred technical terminology
  and render it into the translation prompt.
- Translate titles, story text, and comments.
- `hnview-translate-by-default` enables translated display and asynchronous
  missing translation requests by default across hnview buffers.
- `C-c C-v t` toggles translation for the current item:
  - If not translated, start translation.
  - If translated and visible, show original.
  - If translated and hidden, show translation again.
- `C-c C-v T` toggles translation for all visible items.
- Missing translations started by `C-c C-v T` must run asynchronously and must
  not block normal Emacs interaction.
- Batch translation should throttle concurrent item requests through
  `hnview-translation-concurrency`.
- Translation replaces text in place while preserving layout.
- Pending translations should keep original text visible and report progress
  in the mode line instead of inserting inline loading text.
- Async translation callbacks should preserve the current point, not the point
  from when the batch was started.
- Toggling translation from any point in a comment should work, including
  paragraph blank lines.
- Toggling translation should preserve point within the current item.
- Successful translations are cached in SQLite.
- Translation cache keys include the prompt template and glossary so changed
  translation style settings do not reuse older cached wording.
- Translation display overrides are buffer/session-local; cached translations
  are persistent and do not force translated display unless global translated
  display is enabled.
- Cache pruning should support TTL and max-entry limits.

### 6.5 Persistence

- Store bookmarks in SQLite.
- Store translation cache in SQLite.
- Store cache maintenance metadata in SQLite.
- Do not store HN passwords.
- Read HN credentials from `auth-source`.
- Store HN cookies in SQLite.

### 6.6 Login, Reply, and Voting

- Log in using HN's regular web form and `auth-source` credentials.
- Compose replies in a dedicated text buffer.
- Submit replies through HN's regular web form.
- Translate reply drafts to `hnview-reply-translate-target-language`.
- Cancel reply drafts with `C-c C-k`.
- Upvote the item at point with `C-c C-v u`.
- Upvote must call HN's vote endpoint and require a valid login.
- Show an upvote marker only after a successful upvote in the current Emacs
  session.
- Do not persist local upvote state as product truth.

### 6.7 Inbox

- Fetch a configured user's recent submissions.
- Find direct replies to those submissions.
- Render replies in an inbox buffer.
- Inbox should not require login because it uses public HN API data.

### 6.8 Profile and Activity

- Open a profile buffer for `hnview-username` or a prompted username.
- Render profile sections for About, Stories, Comments, Favorites, Upvoted,
  and Hidden.
- About, Stories, and Comments should use public HN API data.
- Favorites, Upvoted, and Hidden should use HN web pages and existing logged-in
  cookies when HN requires them.
- Switch profile sections with `C-c C-v f` and fixed number keys.
- Profile activity items should support the same open, bookmark, upvote, reply,
  and translation commands as feed/thread items where applicable.

### Article Reader

- `C-c C-v a` opens the original story URL in an Emacs-native article reader
  buffer.
- Article buffers extract the main readable content from HTML rather than
  embedding a WebView.
- JavaScript shell pages that declare a Markdown source should fetch and render
  that Markdown source instead of showing raw Markdown text.
- Markdown article rendering should cover headings, paragraphs, lists, tables,
  links, images, block quotes, horizontal rules, and fenced code blocks.
- Fenced code blocks should be syntax-highlighted with Emacs font-lock.
  Tree-sitter major modes should be preferred when the matching grammar is
  available, with regular major modes used as the fallback.
- Paragraphs should remain logical lines and rely on Emacs visual wrapping.
- Images should shrink only when their actual width is wider than the current
  window. Oversized images should use 80% of the window width, but should not
  shrink below 50% of their original width. Smaller images should keep their
  original width.
- `C-c C-v t` toggles the title or readable block at point.
- `C-c C-v T` toggles the article title and all readable text blocks.
- Article translations reuse the shared LLM transport, visibility state,
  asynchronous queue, and SQLite translation cache.

## 7. UX Requirements

- Use `special-mode` for read-only UI buffers.
- Keep UI dense and readable.
- Prefer faces and text properties over decorative UI.
- Avoid web-style cards and heavy chrome.
- When Evil is active, hnview should enter Emacs state for read-only buffers so
  the native hnview keymap works without an Evil dependency.
- Keep comments visually aligned:
  - fold marker
  - optional local status marker
  - author
  - time
  - folded descendant count
- Do not show fake controls. If an element is not actionable by mouse, it may
  still be a status marker, but primary action should be via keybinding.

## 8. Keybindings

| Key | Scope | Action |
| --- | --- | --- |
| `C-c C-v g` | feed/thread/inbox/profile/article | Refresh |
| `C-c C-v f` | feed/profile | Switch feed or profile section |
| `C-c C-v s` | feed | Switch feed sub-section |
| `C-c C-v 1`-`6` | feed | Open fixed feed |
| `C-c C-v 1`-`6` | profile | Open fixed profile section |
| `RET` | feed/thread/profile/article | Open thread, item, URL, or link |
| `C-c C-v o` | feed/thread/inbox/profile/article | Open original URL |
| `C-c C-v e` | feed/thread/inbox/profile/article | Open original URL in EWW |
| `C-c C-v a` | feed/thread/inbox/profile | Open article reader |
| `C-c C-v b` | feed/thread/profile | Toggle bookmark |
| `C-c C-v u` | feed/thread/inbox/profile | Upvote item |
| `C-c C-v r` | feed/thread/inbox/profile | Reply |
| `C-c C-v t` | feed/thread/inbox/profile/article | Toggle item or article block translation |
| `C-c C-v T` | feed/thread/inbox/profile/article | Toggle visible item or article translations |
| `TAB` | thread | Fold/unfold comment |
| `C-c C-v +` | thread | Load more comments |
| `C-c C-v *` | thread | Load all comments |
| `C-c C-v i` | article | Toggle inline images |
| `n`/`p` | feed/thread/inbox/profile | Next/previous item |
| `q` | feed/thread/inbox/profile/article | Quit buffer |
| `C-c C-t` | reply | Translate draft |
| `C-c C-c` | reply | Submit draft |
| `C-c C-k` | reply | Cancel draft |

## 9. Data Model

Current SQLite tables:

- `translations`
  - cache key
  - backend
  - target language
  - item id
  - segment
  - source hash
  - source text
  - translated text
  - created time
  - last access time
  - access count
- `bookmarks`
  - item id
  - created time
- `metadata`
  - key
  - value

- `cookies`
  - host
  - path
  - name
  - value
  - secure flag
  - http-only flag if available
  - expiry if available
  - updated time

## 10. Technical Requirements

- Keep the main implementation in `hnview.el` for now.
- Use structured APIs for JSON, DOM, SQLite, and auth.
- Keep LLM calls asynchronous.
- Never make network or LLM calls during package load.
- Surface user-facing errors through `message` or `user-error`.
- Keep tests in `test/hnview-test.el`.

## 11. Open Decisions

- Whether to add story submission and Ask HN submission.
- Whether to support persistent user-specific read state.

## 12. Acceptance Criteria

V1 is acceptable when:

- All v1 feature areas listed as Done remain covered by ERT tests.
- `emacs -Q --batch -L . -l test/hnview-test.el -f ert-run-tests-batch-and-exit`
  passes.
- `byte-compile-file` reports no warnings for `hnview.el`.
- `checkdoc-file` reports no warnings for `hnview.el`.
- `package-lint-batch-and-exit hnview.el` reports no warnings.
- A user can browse a feed, open a thread, translate a comment, fold comments,
  bookmark an item, open profile activity, log in, upvote, and
  compose/cancel/submit a reply.

## 13. Next Phase Plan

1. Polish package installation docs.
2. Add story submission and Ask HN submission if needed.
3. Add persistent read state if needed.
4. Revisit Haiker parity for any remaining high-value workflows.
