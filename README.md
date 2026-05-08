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
- `plz.el` for Hacker News login, reply submission, and voting requests.

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

Key bindings:

| Key | Action |
| --- | --- |
| `g` | Refresh current buffer |
| `f` | Switch feed |
| `s` | Switch feed sub-section |
| `1`-`6` | Open Top, Ask, Show, Best, New, Active |
| `RET` | Open the item at point |
| `o` | Open original story URL in the system browser |
| `e` | Open original story URL in EWW |
| `a` | Open original story URL in hnview's article reader |
| `b` | Toggle bookmark |
| `r` | Compose a reply to the story or comment at point |
| `u` | Upvote the story or comment at point |
| `t` | Toggle translation at point, translating first if needed |
| `T` | Toggle translation for all visible titles, comments, or article blocks |
| `TAB` | Toggle comment folding |
| `+` | Load more comments in a thread |
| `*` | Load all comments in a thread |
| `n` / `p` | Move between items |
| `q` | Quit the current hnview buffer |

When Evil is active, hnview buffers enter Emacs state by default so the native
read-only keymap above works unchanged.  Set
`hnview-use-emacs-state-in-evil` to nil if you prefer to manage Evil state
yourself.

In profile buffers:

| Key | Action |
| --- | --- |
| `f` | Switch profile section |
| `RET` | Open the item at point |

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

Press `a` on a story to open the original URL in `hnview-article-mode`. The
article reader extracts the main page content into an Emacs buffer, keeps
paragraphs as logical lines wrapped by `visual-line-mode`, and scales oversized
images to the current window width. Use `i` to toggle images, `RET` or `TAB` to
work with links, `o` to open the page externally, and `e` to open it in EWW.

Article buffers reuse the same translation cache and async translation pipeline
as HN feeds and comments. Press `t` to translate or restore the title or block
at point, and `T` to translate or restore the article title and all readable
text blocks. Article translation cache entries are stored in SQLite with a
synthetic article identity derived from the source URL, so cache hits do not
call the LLM provider again.

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

Press `t` to toggle translation for the item or article block at point,
translating it first if needed. Press `T` to toggle translation for all visible
titles, comments, or article blocks:
when any visible translation is active it switches visible items back to the
original text; otherwise it shows cached translations and starts missing
translations asynchronously. Translated text replaces the original text in
place and keeps the existing story, comment, or article layout where possible:
metadata, status markers, indentation, and comment hierarchy stay unchanged.
While translations are
pending, the original text stays visible and the mode line shows the pending
translation count. Batch translation is throttled by
`hnview-translation-concurrency` so `T` does not start every visible comment at
once. Empty translation results are retried according to
`hnview-translation-empty-retry-count` and are not cached. Successful
translations are cached in the SQLite database at `hnview-database-file`.
Cached translations do not replace originals by default unless
`hnview-translate-by-default` is enabled or you toggle translation with `t`/`T`.
Cache hits are served from SQLite without calling the LLM provider, so showing
an already cached translation does not consume API tokens. Changing the target
language, prompt template, glossary, backend, or source text creates a different
cache key and may trigger a new translation request.

Upvoting uses Hacker News' logged-in vote endpoint. Run `M-x hnview-login`
first. After a successful `u` vote, hnview shows `△` as a session-local status
marker; it is not stored in SQLite.

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

Press `r` on a story or comment to open a reply buffer. In that buffer:

| Key | Action |
| --- | --- |
| `C-c C-t` | Translate the current draft to `hnview-reply-translate-target-language` |
| `C-c C-c` | Submit the current draft to Hacker News |
| `C-c C-k` | Cancel the reply draft |

The default reply translation target is English:

```elisp
(setq hnview-reply-translate-target-language "English")
```
