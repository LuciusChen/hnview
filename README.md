# hnview

`hnview` is a modern Emacs-native Hacker News reader with LLM-assisted
translation. It takes UI cues from Haiker's clean feed layout while staying
inside Emacs conventions: buffers, faces, keymaps, text properties, and
keyboard-first navigation.

## First Version Scope

- Browse Top, Ask, Show, Best, New, and Active feeds, including feed
  sub-sections where HN exposes them.
- Open story threads inside Emacs.
- Render nested comments with compact fold and vote status markers.
- Render inline URLs as compact buttons while preserving paragraph layout.
- Open original story URLs in the browser.
- Bookmark stories and comments locally.
- Translate titles, story text, and comments through `llm.el`.
- Cache translations locally.
- Optionally auto-translate feeds and threads.
- Load more comments on demand for large threads.
- View user profiles with About, Stories, Comments, Favorites, Upvoted, and
  Hidden sections.
- Scan replies to your Hacker News submissions in an inbox buffer.
- Log in to Hacker News and compose replies from Emacs.
- Translate reply drafts to English before submitting.

Not included in the first version:

- Downvoting.
- Mobile push notifications.

## Requirements

- Emacs 29.1 or newer, built with SQLite support.
- `llm.el` for translation.
- `plz.el` for HTTP requests.

## Usage

Load the package and run:

```elisp
(add-to-list 'load-path "/path/to/hnview")
(require 'hnview)
```

With a local straight.el checkout:

```elisp
(straight-use-package 'llm)
(straight-use-package 'plz)
(add-to-list 'load-path (expand-file-name "~/repos/hnview"))
(require 'hnview)
```

Then call:

```text
M-x hnview
```

Primary key bindings use standard Emacs major-mode `C-c` bindings:

| Key | Action |
| --- | --- |
| `C-c C-l` | Refresh current buffer |
| `C-c C-f` | Switch feed, or switch profile section in profile buffers |
| `C-c C-s` | Switch feed sub-section |
| `C-c 1`-`6` | Open Top, Ask, Show, Best, New, Active, or profile sections |
| `C-c C-o` | Open original story URL in the system browser |
| `C-c C-e` | Open original story URL in EWW |
| `C-c C-a` | Open original story URL in hnview's article reader |
| `C-c C-b` | Toggle bookmark |
| `C-c C-r` | Compose a reply to the story or comment at point |
| `C-c C-u` | Upvote the story or comment at point |
| `C-c C-t` | Toggle translation at point, translating first if needed |
| `C-c C-v` | Toggle translation for all visible titles, comments, or article blocks |
| `C-c +` | Load more comments in a thread |
| `C-c *` | Load all comments in a thread |
| `C-c C-m` | Toggle images in article buffers |

Read-only buffer conventions:

| Key | Action |
| --- | --- |
| `RET` | Open the item or link at point |
| `TAB` | Fold comments in thread buffers, or move to the next link in article buffers |
| `n` / `p` | Move between items |
| `q` | Quit the current hnview buffer |

Thread buffers keep comments as logical paragraphs and enable visual wrapping
by default. When available in the running Emacs, `visual-wrap-prefix-mode` is
also enabled so wrapped comment lines keep their indentation.

When Evil is active, hnview buffers enter Emacs state by default so the native
read-only keymap above works unchanged.  Set
`hnview-use-emacs-state-in-evil` to nil if you prefer to manage Evil state
yourself.

## Profiles

Configure your Hacker News username:

```elisp
(setq hnview-username "your-hn-username")
```

Then run:

```text
M-x hnview-profile
```

About, Stories, and Comments use the public Hacker News API. Favorites,
Upvoted, and Hidden use Hacker News web pages through `plz`, so they reuse the
same SQLite-backed login cookies as reply and voting. Favorites and Upvoted
combine HN's stories and comments pages into one Emacs section. Favorites are
public when HN exposes them for that user; Upvoted and Hidden are normally only
available for the logged-in user.

## Article Reader

Press `C-c C-a` on a story to open the original URL in
`hnview-article-mode`. The article reader extracts the main page content into
an Emacs buffer, keeps paragraphs as logical lines wrapped by
`visual-line-mode`, and follows Markdown sources for JavaScript shell pages
that expose a Markdown article file. Markdown headings, lists, tables, links,
images, block quotes, and fenced code blocks are rendered as native Emacs
content instead of raw Markdown markers.

Oversized images shrink only when their actual width is wider than the current
window. In that case hnview uses 80% of the window width, but never shrinks
below 50% of the image's original width. Smaller images are not enlarged or
shrunk. Use `C-c C-m` to toggle images, `RET` or `TAB` to work with links,
`C-c C-o` to open the page externally, and `C-c C-e` to open it in EWW.

Fenced code blocks use Emacs syntax highlighting. When a matching tree-sitter
major mode and grammar are available, hnview uses the tree-sitter mode with
high-detail font-lock; otherwise it falls back to the regular major mode for
that language. Set `hnview-article-highlight-code` to nil to disable article
code highlighting.

Article buffers reuse the same translation cache and async translation pipeline
as HN feeds and comments. Press `C-c C-t` to translate or restore the title
or block at point, and `C-c C-v` to translate or restore the article title
and all readable text blocks. Article translation cache entries are stored in
SQLite with a synthetic article identity derived from the source URL, so cache
hits do not call the LLM provider again.

For local reader diagnostics, run:

```sh
emacs -Q --batch -L . -L ~/.emacs.d/straight/build/plz -l scripts/check-article-reader.el -- --fetch
```

The script stores downloaded HTML under `test/local-fixtures/articles/`, which
is intentionally ignored by git.  Rerun it without `--fetch` to validate the
cached pages without network access.  To try the current Hacker News Top feed
against the reader, run:

```sh
emacs -Q --batch -L . -L ~/.emacs.d/straight/build/plz -l scripts/check-article-reader.el -- --hn-top --fetch --limit=30
```

## Translation

`hnview` uses `llm.el` as its LLM transport but keeps its own translation API.
Configure any `llm.el` provider in your Emacs config, then set:

```elisp
(require 'llm-openai)
(setq hnview-llm-provider
      (make-llm-openai :key "YOUR_API_KEY"
                       :chat-model "MODEL_NAME"))
(setq hnview-translate-target-language "zh-CN")
```

The translation style prompt is customizable.  `{{target}}` is replaced with
`hnview-translate-target-language`, and `{{glossary}}` is replaced with the
configured glossary:

```elisp
(setq hnview-translation-prompt-template
      "You are a professional technical translator for Hacker News.

Translate the input into {{target}}.

Use natural, idiomatic Simplified Chinese for software engineers. Keep code,
URLs, commands, identifiers, product names, paragraph breaks, quote markers,
and forum tone. Apply this glossary:

{{glossary}}

Return only the translation.")
```

Optional preferred terminology:

```elisp
(setq hnview-translation-glossary
      '(("runtime" . "运行时")
        ("latency" . "延迟")
        ("API" . "API")
        ("PR" . "PR")
        ("prompt" . "提示词")))
```

Changing this prompt or glossary changes the translation cache key, so new
translations use the new style while older cached rows remain available until
normal cache pruning or `M-x hnview-clear-translation-cache`.

Optional automatic translation:

```elisp
(setq hnview-auto-translate-feed t)
(setq hnview-auto-translate-thread t)
```

To make translation the default across hnview buffers:

```elisp
(setq hnview-translate-by-default t)
```

Press `C-c C-t` to toggle translation for the item or article block at point,
translating it first if needed. Press `C-c C-v` to toggle translation for all
visible titles, comments, or article blocks:
when any visible translation is active it switches visible items back to the
original text; otherwise it shows cached translations and starts missing
translations asynchronously. Translated text replaces the original text in
place and keeps the existing story, comment, or article layout where possible:
metadata, status markers, indentation, and comment hierarchy stay unchanged.
While translations are pending, the original text stays visible and the mode
line shows the pending translation count. Comment thread redraws are coalesced
while batch translations complete so scrolling remains stable. Batch
translation is throttled by `hnview-translation-concurrency` so `C-c C-v` does
not start every visible comment at once. Empty translation results are retried
according to `hnview-translation-empty-retry-count` and are not cached.
Successful translations are cached in the SQLite database at
`hnview-database-file`.
Cached translations do not replace originals by default unless
`hnview-translate-by-default` is enabled or you toggle translation with
`C-c C-t`/`C-c C-v`.
Cache hits are served from SQLite without calling the LLM provider, so showing
an already cached translation does not consume API tokens. Changing the target
language, prompt template, glossary, backend, or source text creates a different
cache key and may trigger a new translation request.

Upvoting uses Hacker News' logged-in vote endpoint. Run `M-x hnview-login`
first. After a successful `C-c C-u` vote, hnview shows `△` as a
session-local status marker; it is not stored in SQLite.

Run `M-x hnview-translation-status` to inspect whether `llm.el` and
`hnview-llm-provider` are visible to hnview.

Cache maintenance:

| Command | Action |
| --- | --- |
| `M-x hnview-prune-translation-cache` | Delete expired entries and enforce the max cache size |
| `M-x hnview-clear-translation-cache` | Delete all cached translations |

By default, unused translation entries expire after
`hnview-translation-cache-ttl-days` days, and the cache keeps at most
`hnview-translation-cache-max-entries` entries.

## Inbox

Configure your Hacker News username:

```elisp
(setq hnview-username "your-hn-username")
```

Then run:

```text
M-x hnview-inbox
```

The inbox scans recent stories and comments submitted by that user and shows
direct replies. It uses the public Hacker News API and does not require login.

## Replying

`hnview` uses Hacker News' regular web forms for login and reply submission
through `plz`. Credentials are read from `auth-source`. `hnview` does not
prompt for or store the password. HN cookies are stored in the hnview SQLite
database, and expired cookies are pruned automatically when requests are made.

Example `~/.authinfo.gpg` entry:

```text
machine news.ycombinator.com login your-hn-username password your-password
```

For `pass`, either use `user:`/`username:` or the common `login:` field:

```text
your-password
login: your-hn-username
```

Then:

```text
M-x hnview-login
```

Press `C-c C-r` on a story or comment to open a reply buffer. In that buffer:

| Key | Action |
| --- | --- |
| `C-c C-t` | Translate the current draft to `hnview-reply-translate-target-language` |
| `C-c C-c` | Submit the current draft to Hacker News |
| `C-c C-k` | Cancel the reply draft |

The default reply translation target is English:

```elisp
(setq hnview-reply-translate-target-language "English")
```
