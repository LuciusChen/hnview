# hnview

`hnview` is a modern Emacs-native Hacker News reader with LLM-assisted
translation. It takes UI cues from Haiker's clean feed layout while staying
inside Emacs conventions: buffers, faces, keymaps, text properties, and
keyboard-first navigation.

## First Version Scope

- Browse Top, Ask, Show, Best, New, Jobs, and Active feeds.
- Open story threads inside Emacs.
- Render nested comments with compact fold and vote status markers.
- Open original story URLs in the browser.
- Bookmark stories and comments locally.
- Translate titles, story text, and comments through `llm.el`.
- Cache translations locally.
- Optionally auto-translate feeds and threads.
- Load more comments on demand for large threads.
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
| `1`-`7` | Open Top, Ask, Show, Best, New, Jobs, Active |
| `RET` | Open story thread |
| `o` | Open original story URL in the system browser |
| `e` | Open original story URL in EWW |
| `b` | Toggle bookmark |
| `r` | Compose a reply to the story or comment at point |
| `u` | Upvote the story or comment at point |
| `t` | Toggle translation at point, translating first if needed |
| `T` | Toggle translation for all visible titles and comments |
| `TAB` | Toggle comment folding |
| `+` | Load more comments in a thread |
| `*` | Load all comments in a thread |
| `n` / `p` | Move between items |

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

Optional automatic translation:

```elisp
(setq hnview-auto-translate-feed t)
(setq hnview-auto-translate-thread t)
```

Press `t` to toggle translation for the item at point, translating it first if
needed. Press `T` to toggle translation for all visible titles and comments:
when any visible translation is active it switches visible items back to the
original text; otherwise it shows cached translations and starts missing
translations asynchronously. Translated text replaces the original text in
place and keeps the existing story/comment layout: metadata, status markers,
indentation, and comment hierarchy stay unchanged. Successful translations are
cached in the SQLite database at `hnview-database-file`.

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
