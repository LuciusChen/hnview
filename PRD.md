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
| Comment UX | Done | Keyboard folding, inline `N more`, quote rendering, author styling. |
| Translation | Done | `llm.el`, `t`/`T`, in-place replacement, SQLite cache, pruning. |
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
- Switch feeds with both feed picker and number shortcuts; switch sub-sections
  with `s`.
- Refresh the current buffer with `g`.
- Display each story with title, domain, points, author, age, and comment count.
- Open original URLs through the system browser or EWW.

### 6.2 Thread Reading

- Open story threads inside Emacs.
- Render story title, metadata, and optional story text.
- Render nested comments with indentation and stable metadata alignment.
- Load more comments with `+`.
- Load all comments with `*`.
- Detect truncated comment trees and show a load-more hint.

### 6.3 Comment Interaction

- Navigate between items with `n` and `p`.
- Fold/unfold comments with `TAB`.
- Show folded comments as inline metadata, for example:

  ```text
  alice • 3 hours ago • 4 more
  ```

- Count hidden descendants, not just direct children.
- Render HN quote lines that begin with `>` as quote blocks using
  `hnview-quote-symbol`.
- Use orange author names matching the story domain face.

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
- `t` toggles translation for the current item:
  - If not translated, start translation.
  - If translated and visible, show original.
  - If translated and hidden, show translation again.
- `T` toggles translation for all visible items.
- Missing translations started by `T` must run asynchronously and must not
  block normal Emacs interaction.
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
- Upvote the item at point with `u`.
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
- Switch profile sections with `f` and fixed number keys.
- Profile activity items should support the same open, bookmark, upvote, reply,
  and translation commands as feed/thread items where applicable.

## 7. UX Requirements

- Use `special-mode` for read-only UI buffers.
- Keep UI dense and readable.
- Prefer faces and text properties over decorative UI.
- Avoid web-style cards and heavy chrome.
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
| `g` | feed/thread/inbox/profile | Refresh |
| `f` | feed/profile | Switch feed or profile section |
| `1`-`7` | feed | Open fixed feed |
| `1`-`6` | profile | Open fixed profile section |
| `RET` | feed/thread/profile | Open thread, item, or URL |
| `o` | feed/thread/inbox/profile | Open original URL |
| `e` | feed/thread/inbox/profile | Open original URL in EWW |
| `b` | feed/thread/profile | Toggle bookmark |
| `u` | feed/thread/inbox/profile | Upvote item |
| `r` | feed/thread/inbox/profile | Reply |
| `t` | feed/thread/inbox/profile | Toggle item translation |
| `T` | feed/thread/inbox/profile | Toggle visible item translations |
| `TAB` | thread | Fold/unfold comment |
| `+` | thread | Load more comments |
| `*` | thread | Load all comments |
| `n`/`p` | feed/thread/inbox | Next/previous item |
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
