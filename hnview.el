;;; hnview.el --- Modern translated Hacker News reader -*- lexical-binding: t; -*-

;; Author: Lucius Chen
;; URL: https://github.com/luciuschen/hnview
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (llm "0.30.1") (plz "0.9"))
;; Keywords: news, hypermedia, convenience

;;; Commentary:

;; hnview is a modern Emacs-native Hacker News reader with optional
;; LLM-assisted translation through llm.el.

;;; Code:

(require 'auth-source)
(require 'button)
(require 'cl-lib)
(require 'dom)
(require 'json)
(require 'shr)
(require 'sqlite)
(require 'subr-x)
(require 'time-date)
(require 'url-parse)
(require 'url-util)

(declare-function llm-chat-async "llm")
(declare-function llm-make-chat-prompt "llm")
(declare-function plz "plz")
(declare-function plz-error-curl-error "plz")
(declare-function plz-error-message "plz")
(declare-function plz-error-response "plz")
(declare-function plz-response-body "plz")
(declare-function plz-response-headers "plz")
(declare-function plz-response-status "plz")
(declare-function eww "eww")
(defvar plz-curl-default-args)

(defgroup hnview nil
  "Modern Hacker News reader with translation."
  :group 'applications
  :prefix "hnview-")

(defcustom hnview-feed-limit 30
  "Number of stories to show in a feed."
  :type 'natnum
  :group 'hnview)

(defcustom hnview-comment-fetch-limit 180
  "Maximum number of comments to fetch for a story."
  :type 'natnum
  :group 'hnview)

(defcustom hnview-comment-fetch-step 180
  "Number of additional comments to fetch when loading more."
  :type 'natnum
  :group 'hnview)

(defcustom hnview-translate-target-language "zh-CN"
  "Target language for translated Hacker News text."
  :type 'string
  :group 'hnview)

(defcustom hnview-translation-prompt-template
  "You are a professional technical translator for Hacker News.

Translate the input into {{target}}.

Requirements:
- Preserve the original meaning, stance, uncertainty, and casual discussion
  tone.
- For Chinese, write natural, idiomatic Simplified Chinese for experienced
  software engineers.  Do not preserve English sentence order when it sounds
  unnatural.
- Prefer concise Chinese phrasing.  Split long English sentences when that
  improves readability.
- Preserve code, commands, URLs, file paths, identifiers, API names, product
  names, quoted text, Markdown-like structure, paragraph breaks, and list
  structure.
- Keep widely used technical terms in English when Chinese translation would
  sound forced.
- Translate comments as forum comments, not formal documentation.
- Do not add explanations, notes, summaries, or Markdown fences.

{{glossary}}
Return only the translation."
  "Prompt template used for Hacker News text translation.
The token `{{target}}' is replaced with
`hnview-translate-target-language'.  The token `{{glossary}}' is replaced
with `hnview-translation-glossary' rendered as prompt text."
  :type 'string
  :group 'hnview)

(defcustom hnview-translation-glossary nil
  "Preferred terminology for Hacker News translation.
Each entry maps a source term to its preferred target-language rendering.
Use identical source and target strings for terms that should stay unchanged."
  :type '(repeat (cons (string :tag "Source term")
                       (string :tag "Preferred rendering")))
  :group 'hnview)

(defcustom hnview-auto-translate-feed nil
  "Whether to automatically translate feed stories after loading."
  :type 'boolean
  :group 'hnview)

(defcustom hnview-auto-translate-thread nil
  "Whether to automatically translate story threads after loading."
  :type 'boolean
  :group 'hnview)

(defcustom hnview-translate-by-default nil
  "Whether hnview buffers should show translations by default.
When non-nil, cached translations are displayed automatically and missing
visible translations are started asynchronously after loading.  The t and T
commands can still switch the current item or visible items back to the
original language in the current buffer."
  :type 'boolean
  :group 'hnview)

(defcustom hnview-translate-backend 'llm
  "Translation backend used by hnview."
  :type '(choice (const :tag "llm.el" llm))
  :group 'hnview)

(defcustom hnview-llm-provider nil
  "Provider object used by `llm.el' for hnview translation."
  :type 'sexp
  :group 'hnview)

(defcustom hnview-state-file
  (locate-user-emacs-file "hnview-state.el")
  "Legacy file where hnview stored bookmarks and translation cache."
  :type 'file
  :group 'hnview)

(defcustom hnview-database-file
  (locate-user-emacs-file "hnview.sqlite")
  "SQLite database file where hnview stores persistent data."
  :type 'file
  :group 'hnview)

(defcustom hnview-translation-cache-ttl-days 90
  "Number of days to keep unused translation cache entries."
  :type 'natnum
  :group 'hnview)

(defcustom hnview-translation-cache-max-entries 10000
  "Maximum number of translation cache entries to keep."
  :type 'natnum
  :group 'hnview)

(defcustom hnview-translation-cache-prune-interval-hours 24
  "Minimum hours between automatic translation cache pruning."
  :type 'natnum
  :group 'hnview)

(defcustom hnview-hn-base-url "https://news.ycombinator.com"
  "Base URL for Hacker News web interactions."
  :type 'string
  :group 'hnview)

(defcustom hnview-username nil
  "Hacker News username used for the reply inbox."
  :type '(choice (const :tag "Not configured" nil)
                 string)
  :group 'hnview)

(defcustom hnview-reply-translate-target-language "English"
  "Target language used when translating reply drafts."
  :type 'string
  :group 'hnview)

(defcustom hnview-inbox-submission-limit 80
  "Number of recent user submissions to scan for replies."
  :type 'natnum
  :group 'hnview)

(defcustom hnview-profile-item-limit 80
  "Number of profile activity items to show."
  :type 'natnum
  :group 'hnview)

(defcustom hnview-profile-submission-scan-limit 240
  "Number of user submissions to scan for profile activity lists."
  :type 'natnum
  :group 'hnview)

(defcustom hnview-vote-up-symbol "△"
  "Symbol displayed for comments upvoted through hnview."
  :type 'string
  :group 'hnview)

(defcustom hnview-comment-expanded-symbol "▾"
  "Symbol displayed for expanded comments with replies."
  :type 'string
  :group 'hnview)

(defcustom hnview-comment-collapsed-symbol "▸"
  "Symbol displayed for collapsed comments with replies."
  :type 'string
  :group 'hnview)

(defcustom hnview-quote-symbol "▮"
  "Symbol displayed before quoted comment text."
  :type 'string
  :group 'hnview)

(defface hnview-date-main
  '((t :inherit variable-pitch :height 1.8 :weight bold))
  "Face for the main date word."
  :group 'hnview)

(defface hnview-date-muted
  '((t :inherit shadow :height 1.2 :weight bold))
  "Face for muted date text."
  :group 'hnview)

(defface hnview-title
  '((t :inherit default :weight bold))
  "Face for story titles."
  :group 'hnview)

(defface hnview-domain
  '((t :foreground "#d98245" :weight normal))
  "Face for story domains."
  :group 'hnview)

(defface hnview-vote
  '((t :inherit hnview-domain :weight normal))
  "Face for vote controls."
  :group 'hnview)

(defface hnview-meta
  '((t :inherit shadow))
  "Face for story metadata."
  :group 'hnview)

(defface hnview-quote
  '((t :inherit shadow :slant italic))
  "Face for quoted comment text."
  :group 'hnview)

(defface hnview-author
  '((t :inherit default :foreground "#d98245" :weight bold))
  "Face for comment author names."
  :group 'hnview)

(defface hnview-index
  '((t :inherit shadow :weight bold))
  "Face for story indexes."
  :group 'hnview)

(defface hnview-divider
  '((t :inherit shadow))
  "Face for section dividers."
  :group 'hnview)

(defface hnview-translation
  '((t :inherit font-lock-string-face))
  "Face for translated text."
  :group 'hnview)

(defface hnview-loading
  '((t :inherit italic))
  "Face for loading text."
  :group 'hnview)

(defconst hnview--api-base "https://hacker-news.firebaseio.com/v0")

(defconst hnview--feeds
  '((top . ("Top" . "topstories"))
    (ask . ("Ask" . "askstories"))
    (show . ("Show" . "showstories"))
    (best . ("Best" . "beststories"))
    (new . ("New" . "newstories"))
    (active . ("Active" . nil))))

(defconst hnview--feed-sections
  '((ask . ((top . ("Top" . (:api "askstories")))
            (new . ("New" . (:web "asknew")))))
    (show . ((top . ("Top" . (:api "showstories")))
             (new . ("New" . (:web "shownew")))))
    (best . ((stories . ("Stories" . (:api "beststories")))
             (comments . ("Comments" . (:web "bestcomments")))))
    (new . ((stories . ("Stories" . (:api "newstories")))
            (comments . ("Comments" . (:web "newcomments")))))))

(defconst hnview--profile-sections
  '((about . "About")
    (stories . "Stories")
    (comments . "Comments")
    (favorites . "Favorites")
    (upvoted . "Upvoted")
    (hidden . "Hidden")))

(defvar hnview--item-cache (make-hash-table :test #'eql))
(defvar hnview--translations (make-hash-table :test #'equal))
(defvar hnview--pending-translations (make-hash-table :test #'equal))
(defvar hnview--bookmarks (make-hash-table :test #'eql))
(defvar hnview--upvotes (make-hash-table :test #'eql)
  "Item IDs upvoted through hnview in the current Emacs session.")
(defvar hnview--state-loaded-p nil)
(defvar hnview--db nil)

(defvar-local hnview--current-feed 'top)
(defvar-local hnview--current-feed-section nil)
(defvar-local hnview--stories nil)
(defvar-local hnview--thread-root nil)
(defvar-local hnview--loading-message nil)
(defvar-local hnview--error-message nil)
(defvar-local hnview--folded-comments nil)
(defvar-local hnview--hidden-translations nil)
(defvar-local hnview--thread-comment-limit nil)
(defvar-local hnview--inbox-replies nil)
(defvar-local hnview--profile-username nil)
(defvar-local hnview--profile-section 'about)
(defvar-local hnview--profile-user nil)
(defvar-local hnview--profile-items nil)
(defvar-local hnview--reply-parent nil)
(defvar-local hnview--reply-source-buffer nil)
(defvar-local hnview--reply-translated-p nil)
(defvar-local hnview--translate-visible-active-p nil)
(defvar-local hnview--translation-batch-generation 0)

(defvar hnview-feed-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'hnview-refresh)
    (define-key map (kbd "f") #'hnview-switch-feed)
    (define-key map (kbd "s") #'hnview-switch-feed-section)
    (define-key map (kbd "1") #'hnview-top)
    (define-key map (kbd "2") #'hnview-ask)
    (define-key map (kbd "3") #'hnview-show)
    (define-key map (kbd "4") #'hnview-best)
    (define-key map (kbd "5") #'hnview-new)
    (define-key map (kbd "6") #'hnview-active)
    (define-key map (kbd "RET") #'hnview-open-item)
    (define-key map (kbd "o") #'hnview-open-url)
    (define-key map (kbd "e") #'hnview-open-url-eww)
    (define-key map (kbd "b") #'hnview-toggle-bookmark)
    (define-key map (kbd "r") #'hnview-reply-at-point)
    (define-key map (kbd "u") #'hnview-vote-up)
    (define-key map (kbd "t") #'hnview-translate-at-point)
    (define-key map (kbd "T") #'hnview-translate-visible)
    (define-key map (kbd "n") #'hnview-next-item)
    (define-key map (kbd "p") #'hnview-previous-item)
    map)
  "Keymap for `hnview-feed-mode'.")

(defvar hnview-thread-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'hnview-refresh)
    (define-key map (kbd "+") #'hnview-load-more-comments)
    (define-key map (kbd "*") #'hnview-load-all-comments)
    (define-key map (kbd "TAB") #'hnview-toggle-comment-fold)
    (define-key map (kbd "RET") #'hnview-open-url)
    (define-key map (kbd "o") #'hnview-open-url)
    (define-key map (kbd "e") #'hnview-open-url-eww)
    (define-key map (kbd "b") #'hnview-toggle-bookmark)
    (define-key map (kbd "r") #'hnview-reply-at-point)
    (define-key map (kbd "u") #'hnview-vote-up)
    (define-key map (kbd "t") #'hnview-translate-at-point)
    (define-key map (kbd "T") #'hnview-translate-visible)
    (define-key map (kbd "n") #'hnview-next-item)
    (define-key map (kbd "p") #'hnview-previous-item)
    map)
  "Keymap for `hnview-thread-mode'.")

(defvar hnview-inbox-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'hnview-inbox)
    (define-key map (kbd "RET") #'hnview-open-url)
    (define-key map (kbd "o") #'hnview-open-url)
    (define-key map (kbd "e") #'hnview-open-url-eww)
    (define-key map (kbd "r") #'hnview-reply-at-point)
    (define-key map (kbd "u") #'hnview-vote-up)
    (define-key map (kbd "t") #'hnview-translate-at-point)
    (define-key map (kbd "T") #'hnview-translate-visible)
    (define-key map (kbd "n") #'hnview-next-item)
    (define-key map (kbd "p") #'hnview-previous-item)
    map)
  "Keymap for `hnview-inbox-mode'.")

(defvar hnview-profile-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'hnview-refresh)
    (define-key map (kbd "f") #'hnview-profile-switch-section)
    (define-key map (kbd "1") #'hnview-profile-about)
    (define-key map (kbd "2") #'hnview-profile-stories)
    (define-key map (kbd "3") #'hnview-profile-comments)
    (define-key map (kbd "4") #'hnview-profile-favorites)
    (define-key map (kbd "5") #'hnview-profile-upvoted)
    (define-key map (kbd "6") #'hnview-profile-hidden)
    (define-key map (kbd "RET") #'hnview-open-item)
    (define-key map (kbd "o") #'hnview-open-url)
    (define-key map (kbd "e") #'hnview-open-url-eww)
    (define-key map (kbd "b") #'hnview-toggle-bookmark)
    (define-key map (kbd "r") #'hnview-reply-at-point)
    (define-key map (kbd "u") #'hnview-vote-up)
    (define-key map (kbd "t") #'hnview-translate-at-point)
    (define-key map (kbd "T") #'hnview-translate-visible)
    (define-key map (kbd "n") #'hnview-next-item)
    (define-key map (kbd "p") #'hnview-previous-item)
    map)
  "Keymap for `hnview-profile-mode'.")

(defvar hnview-reply-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-t") #'hnview-translate-reply)
    (define-key map (kbd "C-c C-c") #'hnview-submit-reply)
    (define-key map (kbd "C-c C-k") #'hnview-cancel-reply)
    map)
  "Keymap for `hnview-reply-mode'.")

;;; State

(defun hnview--ensure-state-loaded ()
  "Load persisted hnview state if it has not been loaded."
  (unless hnview--state-loaded-p
    (setq hnview--state-loaded-p t)
    (hnview--ensure-db)
    (when (file-readable-p hnview-state-file)
      (with-temp-buffer
        (insert-file-contents hnview-state-file)
        (let ((state (read (current-buffer))))
          (hnview--restore-state state))))
    (hnview--load-db-state)
    (hnview--maybe-prune-translation-cache)))

(defun hnview--ensure-db ()
  "Open and initialize the hnview SQLite database."
  (unless (hnview--db-live-p)
    (make-directory (file-name-directory hnview-database-file) t)
    (setq hnview--db (sqlite-open hnview-database-file))
    (hnview--init-db)))

(defun hnview--db-live-p ()
  "Return non-nil when the SQLite database handle is usable."
  (and hnview--db
       (condition-case nil
           (progn
             (sqlite-select hnview--db "SELECT 1")
             t)
         (error nil))))

(defun hnview--init-db ()
  "Initialize the hnview SQLite database schema."
  (sqlite-execute
   hnview--db
   "CREATE TABLE IF NOT EXISTS translations (
      cache_key TEXT PRIMARY KEY,
      backend TEXT NOT NULL,
      target_language TEXT NOT NULL,
      item_id INTEGER,
      segment TEXT NOT NULL,
      source_hash TEXT NOT NULL,
      source_text TEXT,
      translated_text TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      last_accessed_at INTEGER NOT NULL,
      access_count INTEGER NOT NULL DEFAULT 1
    )")
  (sqlite-execute
   hnview--db
   "CREATE TABLE IF NOT EXISTS bookmarks (
      item_id INTEGER PRIMARY KEY,
      created_at INTEGER NOT NULL
    )")
  (sqlite-execute
   hnview--db
   "CREATE TABLE IF NOT EXISTS cookies (
      host TEXT NOT NULL,
      path TEXT NOT NULL,
      name TEXT NOT NULL,
      value TEXT NOT NULL,
      secure INTEGER NOT NULL DEFAULT 0,
      http_only INTEGER NOT NULL DEFAULT 0,
      host_only INTEGER NOT NULL DEFAULT 1,
      expires_at INTEGER,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (host, path, name)
    )")
  (sqlite-execute
   hnview--db
   "CREATE TABLE IF NOT EXISTS metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )")
  (sqlite-execute
   hnview--db
   "CREATE INDEX IF NOT EXISTS translations_last_accessed_idx
      ON translations(last_accessed_at)"))

(defun hnview--load-db-state ()
  "Load persisted SQLite state into memory."
  (clrhash hnview--translations)
  (clrhash hnview--bookmarks)
  (dolist (row (sqlite-select
                hnview--db
                "SELECT cache_key, translated_text FROM translations"))
    (let ((key (hnview--row-value row 0))
          (translation (hnview--row-value row 1)))
      (puthash key translation hnview--translations)))
  (dolist (row (sqlite-select hnview--db "SELECT item_id FROM bookmarks"))
    (puthash (hnview--row-value row 0) t hnview--bookmarks)))

(defun hnview--row-value (row index)
  "Return ROW value at INDEX for sqlite result rows."
  (if (vectorp row)
      (aref row index)
    (nth index row)))

(defun hnview--restore-state (state)
  "Restore persisted STATE."
  (dolist (cell (plist-get state :translations))
    (puthash (car cell) (cdr cell) hnview--translations)
    (hnview--upsert-translation-row (car cell) nil nil nil nil nil
                                     (cdr cell)))
  (dolist (id (plist-get state :bookmarks))
    (puthash id t hnview--bookmarks)
    (hnview--upsert-bookmark id)))

(defun hnview--save-state ()
  "Persist in-memory bookmarks to SQLite."
  (hnview--ensure-db)
  (sqlite-execute hnview--db "DELETE FROM bookmarks")
  (maphash (lambda (id _value)
             (hnview--upsert-bookmark id))
           hnview--bookmarks))

(defun hnview--upsert-bookmark (id)
  "Persist bookmark ID."
  (sqlite-execute
   hnview--db
   "INSERT INTO bookmarks (item_id, created_at)
    VALUES (?, ?)
    ON CONFLICT(item_id) DO NOTHING"
   (list id (hnview--unix-time))))

(defun hnview--delete-bookmark (id)
  "Delete bookmark ID."
  (sqlite-execute hnview--db "DELETE FROM bookmarks WHERE item_id = ?"
                  (list id)))

(defun hnview--upsert-cookie (cookie)
  "Persist COOKIE plist in SQLite."
  (hnview--ensure-db)
  (sqlite-execute
   hnview--db
   "INSERT INTO cookies
      (host, path, name, value, secure, http_only, host_only,
       expires_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(host, path, name) DO UPDATE SET
      value = excluded.value,
      secure = excluded.secure,
      http_only = excluded.http_only,
      host_only = excluded.host_only,
      expires_at = excluded.expires_at,
      updated_at = excluded.updated_at"
   (list (plist-get cookie :host)
         (plist-get cookie :path)
         (plist-get cookie :name)
         (plist-get cookie :value)
         (if (plist-get cookie :secure) 1 0)
         (if (plist-get cookie :http-only) 1 0)
         (if (plist-get cookie :host-only) 1 0)
         (plist-get cookie :expires-at)
         (hnview--unix-time))))

(defun hnview--delete-cookie (cookie)
  "Delete COOKIE plist from SQLite."
  (hnview--ensure-db)
  (sqlite-execute
   hnview--db
   "DELETE FROM cookies WHERE host = ? AND path = ? AND name = ?"
   (list (plist-get cookie :host)
         (plist-get cookie :path)
         (plist-get cookie :name))))

(defun hnview--delete-cookies-by-host-name (host name)
  "Delete cookies for HOST with NAME from SQLite."
  (hnview--ensure-db)
  (sqlite-execute
   hnview--db
   "DELETE FROM cookies WHERE host = ? AND name = ?"
   (list host name)))

(defun hnview--stored-cookies ()
  "Return persisted cookies as plists."
  (hnview--ensure-db)
  (let ((now (hnview--unix-time)))
    (sqlite-execute hnview--db
                    "DELETE FROM cookies WHERE expires_at IS NOT NULL
                       AND expires_at <= ?"
                    (list now))
    (mapcar
     (lambda (row)
       (list :host (hnview--row-value row 0)
             :path (hnview--row-value row 1)
             :name (hnview--row-value row 2)
             :value (hnview--row-value row 3)
             :secure (= (hnview--row-value row 4) 1)
             :http-only (= (hnview--row-value row 5) 1)
             :host-only (= (hnview--row-value row 6) 1)
             :expires-at (hnview--row-value row 7)))
     (sqlite-select
      hnview--db
      "SELECT host, path, name, value, secure, http_only, host_only, expires_at
         FROM cookies"))))

(defun hnview--unix-time ()
  "Return the current Unix time as an integer."
  (floor (float-time)))

(defun hnview--metadata (key)
  "Return metadata value for KEY."
  (when-let* ((row (car (sqlite-select
                         hnview--db
                         "SELECT value FROM metadata WHERE key = ?"
                         (list key)))))
    (hnview--row-value row 0)))

(defun hnview--set-metadata (key value)
  "Set metadata KEY to VALUE."
  (sqlite-execute
   hnview--db
   "INSERT INTO metadata (key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value"
   (list key value)))

(defun hnview--hash-alist (hash)
  "Return HASH as an alist."
  (let (items)
    (maphash (lambda (key value)
               (push (cons key value) items))
             hash)
    items))

(defun hnview--hash-keys (hash)
  "Return keys of HASH."
  (let (keys)
    (maphash (lambda (key _value)
               (push key keys))
             hash)
    keys))

;;; Data fetching

(defun hnview--feed-label (feed)
  "Return display label for FEED."
  (or (car (alist-get feed hnview--feeds))
      (symbol-name feed)))

(defun hnview--feed-endpoint (feed)
  "Return Hacker News API endpoint for FEED."
  (cdr (alist-get feed hnview--feeds)))

(defun hnview--feed-sections (feed)
  "Return sub-sections for FEED."
  (alist-get feed hnview--feed-sections))

(defun hnview--feed-default-section (feed)
  "Return the default sub-section for FEED."
  (caar (hnview--feed-sections feed)))

(defun hnview--feed-section-label (feed section)
  "Return display label for FEED SECTION."
  (or (car (alist-get section (hnview--feed-sections feed)))
      (symbol-name section)))

(defun hnview--feed-source (feed section)
  "Return source plist for FEED SECTION."
  (if-let* ((sections (hnview--feed-sections feed)))
      (or (cdr (alist-get (or section (hnview--feed-default-section feed))
                          sections))
          (user-error "Unknown section for %s: %s"
                      (hnview--feed-label feed) section))
    (list :api (hnview--feed-endpoint feed))))

(defun hnview--feed-context-label (feed &optional section)
  "Return display context label for FEED and optional SECTION."
  (let ((label (hnview--feed-label feed)))
    (if (hnview--feed-sections feed)
        (format "%s:%s"
                label
                (hnview--feed-section-label
                 feed (or section (hnview--feed-default-section feed))))
      label)))

(defun hnview--profile-section-label (section)
  "Return display label for profile SECTION."
  (or (alist-get section hnview--profile-sections)
      (symbol-name section)))

(defun hnview--profile-mode-name (section)
  "Return profile mode name for SECTION."
  (format "hnview-profile:%s" (hnview--profile-section-label section)))

(defun hnview--url-json (url callback)
  "Fetch URL as JSON, then call CALLBACK with ERROR and DATA."
  (hnview--request
   'get url nil
   (lambda (error body)
     (if error
         (funcall callback error nil)
       (condition-case err
           (funcall callback nil
                    (json-parse-string body
                                       :object-type 'plist
                                       :array-type 'list
                                       :null-object nil
                                       :false-object nil))
         (error (funcall callback (error-message-string err) nil)))))))

(defun hnview--url-text (url callback &optional method fields)
  "Fetch URL as text, then call CALLBACK with ERROR and BODY.
When METHOD is POST, submit FIELDS as an application/x-www-form-urlencoded
request body."
  (hnview--request
   (if (equal method "POST") 'post 'get)
   url
   fields
   callback))

(defun hnview--post-form (url fields callback)
  "POST FIELDS to URL, then call CALLBACK with ERROR and BODY."
  (hnview--url-text url callback "POST" fields))

(defun hnview--encode-form-fields (fields)
  "Return FIELDS encoded as an application/x-www-form-urlencoded string."
  (url-build-query-string
   (mapcar (lambda (field)
             (list (car field) (or (cdr field) "")))
           fields)))

(defun hnview--request (method url fields callback)
  "Request METHOD URL with optional form FIELDS, then call CALLBACK."
  (hnview--ensure-plz)
  (let* ((post-p (eq method 'post))
         (body (when post-p
                 (hnview--encode-form-fields fields)))
         (cookie-jar (make-temp-file "hnview-cookies"))
         (headers (hnview--request-headers
                   url
                   (when post-p
                     '(("Content-Type" . "application/x-www-form-urlencoded")))))
         (plz-curl-default-args
          (append (if (boundp 'plz-curl-default-args)
                      plz-curl-default-args
                    nil)
                  (list "--cookie-jar" cookie-jar))))
    (plz method url
      :headers headers
      :body body
      :as 'response
      :then (lambda (response)
              (unwind-protect
                  (progn
                    (hnview--store-response-cookies url response)
                    (hnview--store-cookie-jar cookie-jar)
                    (funcall callback nil (plz-response-body response)))
                (hnview--delete-cookie-jar cookie-jar)))
      :else (lambda (error)
              (unwind-protect
                  (progn
                    (when-let* ((response (plz-error-response error)))
                      (hnview--store-response-cookies url response))
                    (hnview--store-cookie-jar cookie-jar)
                    (funcall callback (hnview--plz-error-message error) nil))
                (hnview--delete-cookie-jar cookie-jar))))))

(defun hnview--ensure-plz ()
  "Ensure `plz' is available."
  (unless (fboundp 'plz)
    (condition-case err
        (unless (require 'plz nil t)
          (user-error "Plz.el is required for hnview HTTP requests"))
      (error
       (user-error "Plz.el could not be loaded: %s"
                   (error-message-string err))))))

(defun hnview--request-headers (url &optional extra-headers)
  "Return request headers for URL with EXTRA-HEADERS."
  (append '(("User-Agent" . "hnview/0.1 Emacs"))
          extra-headers
          (when-let* ((cookie (hnview--cookie-header url)))
            `(("Cookie" . ,cookie)))))

(defun hnview--plz-error-message (error)
  "Return a user-facing message for plz ERROR."
  (cond
   ((and (plz-error-response error)
         (= (plz-response-status (plz-error-response error)) 429))
    "HN rate-limited this request (HTTP 429); wait before trying again")
   ((plz-error-message error)
    (plz-error-message error))
   ((plz-error-response error)
    (format "HTTP %s" (plz-response-status (plz-error-response error))))
   ((plz-error-curl-error error)
    (format "%s" (cdr (plz-error-curl-error error))))
   (t
    "HTTP request failed")))

(defun hnview--store-response-cookies (url response)
  "Store Set-Cookie headers from RESPONSE for URL."
  (dolist (header (hnview--response-set-cookie-headers response))
    (when-let* ((cookie (hnview--parse-set-cookie url header)))
      (if (hnview--expired-cookie-p cookie)
          (hnview--delete-cookie cookie)
        (hnview--upsert-cookie cookie)))))

(defun hnview--store-cookie-jar (file)
  "Store cookies from curl cookie jar FILE."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((cookie (hnview--parse-cookie-jar-line
                             (buffer-substring (line-beginning-position)
                                               (line-end-position)))))
          (if (hnview--expired-cookie-p cookie)
              (hnview--delete-cookie cookie)
            (hnview--upsert-cookie cookie)))
        (forward-line 1)))))

(defun hnview--delete-cookie-jar (file)
  "Delete curl cookie jar FILE."
  (when (and file (file-exists-p file))
    (ignore-errors (delete-file file))))

(defun hnview--parse-cookie-jar-line (line)
  "Parse one Netscape cookie jar LINE into a cookie plist."
  (let ((http-only nil))
    (cond
     ((string-prefix-p "#HttpOnly_" line)
      (setq http-only t)
      (setq line (string-remove-prefix "#HttpOnly_" line)))
     ((or (string-empty-p line)
          (string-prefix-p "#" line))
      (setq line nil)))
    (when line
      (let* ((fields (split-string line "\t"))
             (domain (nth 0 fields))
             (tailmatch (nth 1 fields))
             (path (nth 2 fields))
             (secure (nth 3 fields))
             (expires (nth 4 fields))
             (name (nth 5 fields))
             (value (nth 6 fields))
             (host (string-remove-prefix "." (downcase (or domain ""))))
             (expires-at (string-to-number (or expires "0"))))
        (when (and (= (length fields) 7)
                   (not (string-empty-p host))
                   (not (string-empty-p (or name ""))))
          (list :host host
                :path (if (string-empty-p (or path "")) "/" path)
                :name name
                :value (or value "")
                :secure (string= secure "TRUE")
                :http-only http-only
                :host-only (string= tailmatch "FALSE")
                :expires-at (unless (zerop expires-at) expires-at)))))))

(defun hnview--response-set-cookie-headers (response)
  "Return Set-Cookie header values from RESPONSE."
  (mapcar #'cdr
          (cl-remove-if-not
           (lambda (header)
             (eq (car header) 'set-cookie))
           (plz-response-headers response))))

(defun hnview--parse-set-cookie (url header)
  "Parse Set-Cookie HEADER received from URL."
  (let* ((parts (split-string header ";" t "[ \t\r\n]*"))
         (pair (car parts))
         (host (hnview--url-host url))
         (path (hnview--default-cookie-path url))
         (host-only t)
         (secure nil)
         (http-only nil)
         expires-at)
    (when (and pair (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" pair))
      (let ((name (string-trim (match-string 1 pair)))
            (value (match-string 2 pair)))
        (dolist (attribute (cdr parts))
          (let* ((split (split-string attribute "="))
                 (key (downcase (string-trim (car split))))
                 (raw-value (mapconcat #'identity (cdr split) "="))
                 (attribute-value (string-trim raw-value)))
            (cond
             ((string= key "domain")
              (setq host (string-remove-prefix "."
                                               (downcase attribute-value)))
              (setq host-only nil))
             ((string= key "path")
              (setq path (if (string-empty-p attribute-value)
                             "/"
                           attribute-value)))
             ((string= key "max-age")
              (let ((seconds (string-to-number attribute-value)))
                (setq expires-at (+ (hnview--unix-time) seconds))))
             ((string= key "expires")
              (setq expires-at
                    (hnview--parse-cookie-expires attribute-value)))
             ((string= key "secure")
              (setq secure t))
             ((string= key "httponly")
              (setq http-only t)))))
        (unless (or (string-empty-p name) (string-empty-p host))
          (list :host host
                :path path
                :name name
                :value value
                :secure secure
                :http-only http-only
                :host-only host-only
                :expires-at expires-at))))))

(defun hnview--parse-cookie-expires (value)
  "Parse cookie expiry VALUE into a Unix timestamp."
  (condition-case nil
      (floor (float-time (date-to-time value)))
    (error nil)))

(defun hnview--expired-cookie-p (cookie)
  "Return non-nil when COOKIE is expired."
  (when-let* ((expires-at (plist-get cookie :expires-at)))
    (<= expires-at (hnview--unix-time))))

(defun hnview--cookie-header (url)
  "Return Cookie header value for URL, or nil."
  (let* ((host (hnview--url-host url))
         (path (hnview--url-path url))
         (secure (equal (hnview--url-scheme url) "https"))
         (pairs
          (cl-loop for cookie in (hnview--stored-cookies)
                   when (hnview--cookie-matches-url-p cookie host path secure)
                   collect (format "%s=%s"
                                   (plist-get cookie :name)
                                   (plist-get cookie :value)))))
    (unless (null pairs)
      (string-join pairs "; "))))

(defun hnview--hn-user-cookie-p ()
  "Return non-nil when a Hacker News user cookie is stored."
  (cl-some
   (lambda (cookie)
     (and (string= (plist-get cookie :name) "user")
          (not (string-empty-p (or (plist-get cookie :value) "")))
          (hnview--cookie-matches-url-p
           cookie "news.ycombinator.com" "/" t)))
   (hnview--stored-cookies)))

(defun hnview--cookie-matches-url-p (cookie host path secure)
  "Return non-nil when COOKIE should be sent to HOST PATH SECURE."
  (and (or (not (plist-get cookie :secure)) secure)
       (hnview--cookie-domain-match-p cookie host)
       (hnview--cookie-path-match-p (plist-get cookie :path) path)))

(defun hnview--cookie-domain-match-p (cookie host)
  "Return non-nil when COOKIE applies to HOST."
  (let ((cookie-host (plist-get cookie :host)))
    (if (plist-get cookie :host-only)
        (string= host cookie-host)
      (or (string= host cookie-host)
          (string-suffix-p (concat "." cookie-host) host)))))

(defun hnview--cookie-path-match-p (cookie-path request-path)
  "Return non-nil when COOKIE-PATH applies to REQUEST-PATH."
  (or (string= cookie-path request-path)
      (and (string-prefix-p cookie-path request-path)
           (or (string-suffix-p "/" cookie-path)
               (let ((index (length cookie-path)))
                 (and (< index (length request-path))
                      (eq (aref request-path index) ?/)))))))

(defun hnview--url-scheme (url)
  "Return URL scheme in lowercase."
  (downcase (or (url-type (url-generic-parse-url url)) "")))

(defun hnview--url-host (url)
  "Return URL host in lowercase."
  (downcase (or (url-host (url-generic-parse-url url)) "")))

(defun hnview--url-path (url)
  "Return URL path without query or fragment."
  (let* ((parsed (url-generic-parse-url url))
         (filename (or (url-filename parsed) "/"))
         (path (car (split-string filename "[?#]" t))))
    (if (or (null path) (string-empty-p path))
        "/"
      path)))

(defun hnview--default-cookie-path (url)
  "Return the default cookie path for URL."
  (let ((path (hnview--url-path url)))
    (or (and (string-prefix-p "/" path)
             (file-name-directory path))
        "/")))

(defun hnview--fetch-feed (feed section limit callback)
  "Fetch FEED SECTION with LIMIT items, then call CALLBACK with ERROR and ITEMS."
  (if (eq feed 'active)
      (hnview--fetch-active-stories limit callback)
    (let ((source (hnview--feed-source feed section)))
      (cond
       ((plist-get source :api)
        (hnview--fetch-api-feed (plist-get source :api) limit callback))
       ((plist-get source :web)
        (hnview--fetch-web-feed (plist-get source :web) limit callback))
       (t
        (user-error "Unknown feed source for %s"
                    (hnview--feed-context-label feed section)))))))

(defun hnview--fetch-api-feed (endpoint limit callback)
  "Fetch API ENDPOINT with LIMIT items, then call CALLBACK."
  (unless endpoint
    (user-error "Unknown API feed endpoint"))
  (hnview--url-json
   (format "%s/%s.json" hnview--api-base endpoint)
   (lambda (error ids)
     (if error
         (funcall callback error nil)
       (hnview--fetch-items (hnview--take ids limit) callback)))))

(defun hnview--fetch-web-feed (path limit callback)
  "Fetch HN web feed PATH with LIMIT items, then call CALLBACK."
  (hnview--url-text
   (hnview--hn-url path)
   (lambda (error html)
     (cond
      (error
       (funcall callback error nil))
      ((hnview--hn-error-message html)
       (funcall callback (hnview--hn-error-message html) nil))
      (t
       (hnview--fetch-items
        (hnview--take (hnview--parse-hn-list-item-ids html) limit)
        callback))))))

(defun hnview--fetch-item (id callback)
  "Fetch Hacker News item ID, then call CALLBACK with ERROR and ITEM."
  (if-let* ((cached (gethash id hnview--item-cache)))
      (funcall callback nil cached)
    (hnview--url-json
     (format "%s/item/%s.json" hnview--api-base id)
     (lambda (error item)
       (if error
           (funcall callback error nil)
         (when item
           (puthash id item hnview--item-cache))
         (funcall callback nil item))))))

(defun hnview--fetch-items (ids callback)
  "Fetch IDS, then call CALLBACK with ERROR and ITEMS."
  (if (null ids)
      (funcall callback nil nil)
    (let* ((count (length ids))
           (pending count)
           (items (make-vector count nil))
           (failed nil))
      (cl-loop for id in ids
               for index from 0
               do (let ((item-index index))
                    (hnview--fetch-item
                     id
                     (lambda (error item)
                       (unless failed
                         (if error
                             (progn
                               (setq failed error)
                               (funcall callback error nil))
                           (aset items item-index item)
                           (cl-decf pending)
                           (when (zerop pending)
                             (funcall callback nil
                                      (delq nil (hnview--vector-list items)))))))))))))

(defun hnview--fetch-active-stories (limit callback)
  "Fetch recently active stories up to LIMIT, then call CALLBACK."
  (hnview--url-json
   (format "%s/updates.json" hnview--api-base)
   (lambda (error data)
     (if error
         (funcall callback error nil)
       (hnview--collect-active-stories
        (plist-get data :items) limit callback)))))

(defun hnview--collect-active-stories (ids limit callback)
  "Collect active story roots from IDS up to LIMIT, then call CALLBACK."
  (let ((queue (hnview--take ids 160))
        (seen (make-hash-table :test #'eql))
        (stories nil))
    (cl-labels
        ((step ()
           (if (or (null queue) (>= (length stories) limit))
               (funcall callback nil (nreverse stories))
             (let ((id (pop queue)))
               (hnview--fetch-item
                id
                (lambda (_error item)
                  (hnview--fetch-story-root
                   item 0
                   (lambda (story)
                     (when-let* ((story-id (plist-get story :id)))
                       (unless (gethash story-id seen)
                         (puthash story-id t seen)
                         (push story stories)))
                     (step)))))))))
      (step))))

(defun hnview--fetch-story-root (item depth callback)
  "Find the root story for ITEM up to DEPTH, then call CALLBACK."
  (cond
   ((not item) (funcall callback nil))
   ((> depth 20) (funcall callback nil))
   ((member (plist-get item :type) '("story" "job"))
    (funcall callback item))
   ((plist-get item :parent)
    (hnview--fetch-item
     (plist-get item :parent)
     (lambda (_error parent)
       (hnview--fetch-story-root parent (1+ depth) callback))))
   (t (funcall callback nil))))

(defun hnview--fetch-user (username callback)
  "Fetch Hacker News USERNAME, then call CALLBACK with ERROR and USER."
  (hnview--url-json
   (format "%s/user/%s.json" hnview--api-base
           (url-hexify-string username))
   callback))

(defun hnview--fetch-profile-section (username section callback)
  "Fetch USERNAME profile SECTION, then call CALLBACK with ERROR USER ITEMS."
  (hnview--fetch-user
   username
   (lambda (error user)
     (cond
      (error
       (funcall callback error nil nil))
      ((null user)
       (funcall callback (format "HN user not found: %s" username) nil nil))
      ((eq section 'about)
       (funcall callback nil user nil))
      ((memq section '(stories comments))
       (hnview--fetch-profile-submissions user section callback))
      ((memq section '(favorites upvoted hidden))
       (hnview--fetch-profile-web-list username section user callback))
      (t
       (funcall callback (format "Unknown profile section: %s" section)
                user nil))))))

(defun hnview--fetch-profile-submissions (user section callback)
  "Fetch USER submitted items for profile SECTION, then call CALLBACK."
  (hnview--fetch-items
   (hnview--take (plist-get user :submitted)
                 hnview-profile-submission-scan-limit)
   (lambda (error items)
     (if error
         (funcall callback error user nil)
       (funcall callback nil user
                (hnview--take
                 (cl-remove-if-not
                  (lambda (item)
                    (hnview--profile-submission-p
                     item section (plist-get user :id)))
                  items)
                 hnview-profile-item-limit))))))

(defun hnview--profile-submission-p (item section username)
  "Return non-nil when ITEM belongs in USERNAME profile SECTION."
  (and item
       (equal (plist-get item :by) username)
       (pcase section
         ('stories (member (plist-get item :type) '("story" "job" "poll")))
         ('comments (equal (plist-get item :type) "comment"))
         (_ nil))))

(defun hnview--fetch-profile-web-list (username section user callback)
  "Fetch USERNAME profile web list SECTION for USER, then call CALLBACK."
  (hnview--fetch-profile-web-list-pages
   username section
   (lambda (error pages)
     (if error
         (funcall callback error user nil)
       (hnview--fetch-items
        (hnview--take (hnview--profile-web-list-item-ids pages)
                      hnview-profile-item-limit)
        (lambda (items-error items)
          (funcall callback items-error user items)))))))

(defun hnview--fetch-profile-web-list-pages (username section callback)
  "Fetch USERNAME profile web list SECTION pages, then call CALLBACK."
  (let* ((urls (hnview--profile-web-list-urls username section))
         (pending (length urls))
         (pages (make-vector (length urls) nil))
         (errors nil))
    (cl-loop for url in urls
             for index from 0
             do (let ((page-index index))
                  (hnview--url-text
                   url
                   (lambda (error html)
                     (cond
                      (error
                       (push error errors))
                      ((hnview--profile-web-list-error html section)
                       (push (hnview--profile-web-list-error html section)
                             errors))
                      (t
                       (aset pages page-index html)))
                     (cl-decf pending)
                     (when (zerop pending)
                       (let ((found-pages (delq nil (hnview--vector-list pages))))
                         (funcall callback
                                  (unless found-pages (car errors))
                                  found-pages)))))))))

(defun hnview--profile-web-list-item-ids (pages)
  "Return unique HN item ids from profile web list PAGES."
  (let (ids)
    (dolist (page pages)
      (dolist (id (hnview--parse-hn-list-item-ids page))
        (unless (member id ids)
          (push id ids))))
    (nreverse ids)))

(defun hnview--profile-web-list-url (username section)
  "Return Hacker News web URL for USERNAME profile SECTION."
  (car (hnview--profile-web-list-urls username section)))

(defun hnview--profile-web-list-urls (username section)
  "Return Hacker News web URLs for USERNAME profile SECTION."
  (pcase section
    ('favorites (list (hnview--hn-url "favorites" `(("id" . ,username)))
                      (hnview--hn-url
                       "favorites" `(("id" . ,username) ("comments" . "t")))))
    ('upvoted (list (hnview--hn-url "upvoted" `(("id" . ,username)))
                    (hnview--hn-url
                     "upvoted" `(("id" . ,username) ("comments" . "t")))))
    ('hidden (list (hnview--hn-url "hidden")))
    (_ (error "Unsupported profile web section: %s" section))))

(defun hnview--profile-web-list-error (html section)
  "Return an error for profile SECTION HTML, or nil."
  (cond
   ((string-match-p "Can't display that" html)
    (format "HN cannot display %s for this user"
            (hnview--profile-section-label section)))
   ((hnview--hn-error-message html))))

(defun hnview--parse-hn-list-item-ids (html)
  "Return HN item ids from an HN list page HTML."
  (let ((start 0)
        ids)
    (while (string-match "<tr[^>]*class=['\"][^'\"]*\\bathing\\b[^'\"]*['\"][^>]*id=['\"]\\([0-9]+\\)['\"]"
                         html start)
      (push (string-to-number (match-string 1 html)) ids)
      (setq start (match-end 0)))
    (setq start 0)
    (while (string-match "<tr[^>]*id=['\"]\\([0-9]+\\)['\"][^>]*class=['\"][^'\"]*\\bathing\\b[^'\"]*['\"]"
                         html start)
      (let ((id (string-to-number (match-string 1 html))))
        (unless (member id ids)
          (push id ids)))
      (setq start (match-end 0)))
    (nreverse ids)))

(defun hnview--fetch-inbox-replies (username limit callback)
  "Fetch replies to USERNAME submissions up to LIMIT, then call CALLBACK."
  (hnview--fetch-user
   username
   (lambda (error user)
     (if error
         (funcall callback error nil)
       (hnview--fetch-items
        (hnview--take (plist-get user :submitted) limit)
        (lambda (items-error items)
          (if items-error
              (funcall callback items-error nil)
            (hnview--fetch-replies-for-items
             (hnview--replyable-items items username)
             callback))))))))

(defun hnview--replyable-items (items username)
  "Return ITEMS by USERNAME that can have replies."
  (cl-remove-if-not
   (lambda (item)
     (and item
          (equal (plist-get item :by) username)
          (plist-get item :kids)))
   items))

(defun hnview--fetch-replies-for-items (items callback)
  "Fetch direct replies for ITEMS, then call CALLBACK."
  (if (null items)
      (funcall callback nil nil)
    (let ((pending (length items))
          (replies nil)
          (failed nil))
      (dolist (parent items)
        (hnview--fetch-items
         (plist-get parent :kids)
         (lambda (error children)
           (unless failed
             (if error
                 (progn
                   (setq failed error)
                   (funcall callback error nil))
               (dolist (child (hnview--visible-comments children))
                 (push (plist-put (copy-sequence child)
                                  :hnview-parent parent)
                       replies))
               (cl-decf pending)
               (when (zerop pending)
                 (funcall callback nil
                          (sort replies
                                (lambda (a b)
                                  (> (or (plist-get a :time) 0)
                                     (or (plist-get b :time) 0))))))))))))))

(defun hnview--fetch-story-tree (story callback &optional limit)
  "Fetch comments for STORY, then call CALLBACK with ERROR and ROOT.
LIMIT is the maximum number of comments to fetch."
  (let ((remaining (list (or limit hnview-comment-fetch-limit))))
    (hnview--fetch-tree story
                         (lambda (root)
                           (funcall callback nil root))
                         remaining)))

(defun hnview--fetch-tree (item callback remaining)
  "Fetch comment tree for ITEM, then call CALLBACK with the result.
REMAINING is a mutable one-item list containing the fetch budget."
  (let* ((copy (copy-sequence item))
         (kids (plist-get item :kids))
         (take-count (min (length kids) (max 0 (car remaining)))))
    (if (or (null kids) (zerop take-count))
        (progn
          (when (and kids (zerop take-count))
            (setq copy (plist-put copy :hnview-truncated t)))
          (funcall callback copy))
      (cl-decf (car remaining) take-count)
      (hnview--fetch-items
       (hnview--take kids take-count)
       (lambda (_error children)
         (hnview--fetch-tree-list
          (hnview--visible-comments children)
          (lambda (trees)
            (setq copy (plist-put copy :hnview-children trees))
            (when (> (length kids) take-count)
              (setq copy (plist-put copy :hnview-truncated t)))
            (funcall callback copy))
          remaining))))))

(defun hnview--fetch-tree-list (items callback remaining)
  "Fetch comment trees for ITEMS, then call CALLBACK with REMAINING budget."
  (if (null items)
      (funcall callback nil)
    (let* ((count (length items))
           (pending count)
           (results (make-vector count nil)))
      (cl-loop for item in items
               for index from 0
               do (let ((item-index index))
                    (hnview--fetch-tree
                     item
                     (lambda (tree)
                       (aset results item-index tree)
                       (cl-decf pending)
                       (when (zerop pending)
                         (funcall callback (hnview--vector-list results))))
                     remaining))))))

(defun hnview--vector-list (vector)
  "Return VECTOR contents as a list."
  (cl-loop for item across vector collect item))

(defun hnview--visible-comments (items)
  "Return visible comment ITEMS."
  (cl-remove-if (lambda (item)
                  (or (not item)
                      (plist-get item :dead)
                      (plist-get item :deleted)))
                items))

(defun hnview--take (list count)
  "Return at most COUNT items from LIST."
  (let (result)
    (while (and list (> count 0))
      (push (pop list) result)
      (cl-decf count))
    (nreverse result)))

;;; Hacker News forms

(defun hnview--hn-url (path &optional params)
  "Return an absolute Hacker News URL for PATH and PARAMS."
  (let ((url (format "%s/%s"
                     (string-remove-suffix "/" hnview-hn-base-url)
                     (string-remove-prefix "/" path))))
    (if params
        (concat url "?" (hnview--encode-form-fields params))
      url)))

(defun hnview--hn-action-url (action)
  "Return an absolute Hacker News URL for form ACTION."
  (let ((base (string-remove-suffix "/" hnview-hn-base-url))
        (action (or action "")))
    (cond
     ((string-match-p "\\`https?://" action) action)
     ((string-prefix-p "//" action) (concat "https:" action))
     ((string-prefix-p "/" action) (concat base action))
     ((string-empty-p action) base)
     (t (concat base "/" action)))))

(defun hnview--auth-source-search-entry (&optional username)
  "Return an auth-source entry for Hacker News USERNAME."
  (or (and username
           (car (auth-source-search :host "news.ycombinator.com"
                                    :user username
                                    :require '(:secret)
                                    :max 1)))
      (car (auth-source-search :host "news.ycombinator.com"
                               :require '(:secret)
                               :max 1))))

(defun hnview--auth-source-pass-data (&optional username)
  "Return parsed password-store data for Hacker News USERNAME."
  (when (require 'auth-source-pass nil t)
    (when-let* ((finder (intern-soft "auth-source-pass--find-match"))
                ((fboundp finder)))
      (ignore-errors
        (funcall finder "news.ycombinator.com" username nil)))))

(defun hnview--auth-source-pass-user (data)
  "Return the user name from password-store DATA."
  (or (cdr (assoc "login" data))
      (cdr (assoc "user" data))
      (cdr (assoc "username" data))))

(defun hnview--auth-source-secret-value (secret)
  "Return the value of auth-source SECRET."
  (if (functionp secret)
      (funcall secret)
    secret))

(defun hnview--auth-source-credentials (&optional username)
  "Return Hacker News credentials for USERNAME from auth-source."
  (let* ((entry (hnview--auth-source-search-entry username))
         (entry-user (or (plist-get entry :user)
                         (plist-get entry :login)
                         (plist-get entry :account)))
         (entry-secret (plist-get entry :secret))
         (pass-data (unless (and entry-secret (or username entry-user))
                      (hnview--auth-source-pass-data username)))
         (user (or username entry-user
                   (hnview--auth-source-pass-user pass-data)))
         (secret (or entry-secret
                     (cdr (assq 'secret pass-data)))))
    (when (and user secret)
      (cons user (hnview--auth-source-secret-value secret)))))

(defun hnview--parse-forms (html)
  "Parse HTML and return form plists."
  (unless (fboundp 'libxml-parse-html-region)
    (error "This Emacs was built without libxml HTML parsing"))
  (with-temp-buffer
    (insert html)
    (let ((dom (libxml-parse-html-region (point-min) (point-max))))
      (mapcar #'hnview--parse-form (dom-by-tag dom 'form)))))

(defun hnview--parse-form (form)
  "Parse FORM dom node into a plist."
  (list :action (dom-attr form 'action)
        :method (or (dom-attr form 'method) "get")
        :fields (hnview--form-fields form)))

(defun hnview--dom-text (node)
  "Return NODE text using the available dom helper."
  (funcall (if (fboundp 'dom-inner-text) 'dom-inner-text 'dom-text)
           node))

(defun hnview--form-fields (form)
  "Return input and textarea fields from FORM."
  (let (fields)
    (dolist (input (dom-by-tag form 'input))
      (when-let* ((name (dom-attr input 'name)))
        (push (cons name (or (dom-attr input 'value) "")) fields)))
    (dolist (textarea (dom-by-tag form 'textarea))
      (when-let* ((name (dom-attr textarea 'name)))
        (push (cons name (or (hnview--dom-text textarea) "")) fields)))
    (nreverse fields)))

(defun hnview--form-field (form name)
  "Return FORM field NAME."
  (cdr (assoc name (plist-get form :fields))))

(defun hnview--form-set-field (form name value)
  "Return FORM with field NAME set to VALUE."
  (let ((copy (copy-sequence form))
        (fields (cl-remove name (plist-get form :fields)
                           :key #'car :test #'string=)))
    (plist-put copy :fields (append fields (list (cons name value))))))

(defun hnview--comment-form (html)
  "Return the first comment form in HTML."
  (cl-find-if (lambda (form)
                (hnview--form-field form "text"))
              (hnview--parse-forms html)))

(defun hnview--hn-error-message (html)
  "Return a user-facing Hacker News error from HTML, if one is obvious."
  (setq html (or html ""))
  (cond
   ((string= (string-trim html) "Sorry.")
    "HN refused this request, likely due to rate limiting; wait before trying again")
   ((string-match-p "You have to be logged in" html)
    "HN login required; run M-x hnview-login")
   ((and (string-match-p "<b>Login</b>" html)
         (string-match-p "name=\"acct\"" html))
    "HN login required; run M-x hnview-login")
   ((string-match-p "Bad login" html)
    "HN rejected the login")
   ((string-match-p "form expired" html)
    "HN form expired; try again")
   ((string-match-p "You're submitting too fast" html)
    "HN rate-limited this submission")))

(defun hnview--login-success-p (html username)
  "Return non-nil when HTML looks like a successful login for USERNAME."
  (and (string-match-p "logout" html)
       (string-match-p
        (regexp-quote (format "user?id=%s" username))
        html)))

(defun hnview--fetch-reply-form (parent callback)
  "Fetch the Hacker News reply form for PARENT, then call CALLBACK."
  (let ((id (plist-get parent :id)))
    (unless id
      (user-error "No reply target"))
    (hnview--url-text
     (hnview--hn-url "reply" `(("id" . ,(number-to-string id))))
     (lambda (error html)
       (cond
        (error (funcall callback error nil))
        ((hnview--hn-error-message html)
         (funcall callback (hnview--hn-error-message html) nil))
        ((hnview--comment-form html)
         (funcall callback nil (hnview--comment-form html)))
        (t
         (funcall callback "HN did not return a reply form" nil)))))))

(defun hnview--submit-comment-form (form text callback)
  "Submit TEXT through Hacker News comment FORM, then call CALLBACK."
  (let* ((form (hnview--form-set-field form "text" text))
         (url (hnview--hn-action-url (plist-get form :action))))
    (hnview--post-form
     url (plist-get form :fields)
     (lambda (error html)
       (cond
        (error (funcall callback error nil))
        ((hnview--hn-error-message html)
         (funcall callback (hnview--hn-error-message html) nil))
        (t (funcall callback nil html)))))))

(defun hnview--submit-reply (parent text callback)
  "Submit TEXT as a reply to PARENT, then call CALLBACK."
  (hnview--fetch-reply-form
   parent
   (lambda (error form)
     (if error
         (funcall callback error nil)
       (hnview--submit-comment-form form text callback)))))

(defun hnview--vote-url (item direction)
  "Return Hacker News vote URL for ITEM and DIRECTION."
  (let ((id (plist-get item :id)))
    (unless id
      (user-error "No item to vote on"))
    (format "%s?id=%s&how=%s&goto=%s"
            (hnview--hn-action-url "vote")
            (url-hexify-string (number-to-string id))
            (url-hexify-string (symbol-name direction))
            (url-hexify-string
             (format "item?id=%s"
                     (or (plist-get hnview--thread-root :id)
                         id))))))

(defun hnview--vote-item (item direction callback)
  "Vote on ITEM in DIRECTION, then call CALLBACK."
  (hnview--url-text
   (hnview--vote-url item direction)
   (lambda (error html)
     (cond
      (error (funcall callback error nil))
      ((hnview--hn-error-message html)
       (funcall callback (hnview--hn-error-message html) nil))
      (t (funcall callback nil html))))))

;;; Formatting

(defun hnview--domain (story)
  "Return the display domain for STORY."
  (if-let* ((url (plist-get story :url)))
      (let ((host (url-host (url-generic-parse-url url))))
        (replace-regexp-in-string "\\`www\\." "" (or host "news.ycombinator.com")))
    "news.ycombinator.com"))

(defun hnview--relative-time (unix-time &optional now)
  "Return relative display text for UNIX-TIME compared with NOW."
  (let* ((now (or now (float-time)))
         (seconds (max 0 (- now unix-time)))
         (minutes (floor (/ seconds 60)))
         (hours (floor (/ minutes 60)))
         (days (floor (/ hours 24))))
    (cond
     ((< seconds 60) "just now")
     ((< minutes 60) (format "%d minute%s ago" minutes (hnview--plural minutes)))
     ((< hours 24) (format "%d hour%s ago" hours (hnview--plural hours)))
     (t (format "%d day%s ago" days (hnview--plural days))))))

(defun hnview--plural (count)
  "Return plural suffix for COUNT."
  (if (= count 1) "" "s"))

(defun hnview--story-meta (story)
  "Return metadata line for STORY."
  (string-join
   (cons (hnview--domain story) (hnview--story-meta-parts story))
   " - "))

(defun hnview--story-meta-parts (story)
  "Return non-domain metadata parts for STORY."
  (delq nil
        (list (when (plist-member story :score)
                (format "%s points" (plist-get story :score)))
              (plist-get story :by)
              (when (plist-member story :time)
                (hnview--relative-time (plist-get story :time)))
              (format "%s comments" (or (plist-get story :descendants) 0)))))

(defun hnview--comment-meta (comment)
  "Return metadata line for COMMENT."
  (string-join
   (delq nil
         (list (plist-get comment :by)
               (when (plist-member comment :time)
                 (hnview--relative-time (plist-get comment :time)))))
   " • "))

(defun hnview--comment-descendant-count (comment)
  "Return the number of descendants below COMMENT."
  (let ((children (plist-get comment :hnview-children)))
    (+ (length children)
       (cl-loop for child in children
                sum (hnview--comment-descendant-count child)))))

(defun hnview--html-to-text (html)
  "Convert Hacker News HTML string HTML to plain text."
  (if (string-empty-p (or html ""))
      ""
    (with-temp-buffer
      (insert html)
      (let ((shr-use-fonts nil)
            (shr-width 78))
        (shr-render-region (point-min) (point-max)))
      (hnview--normalize-paragraphs (buffer-string)))))

(defun hnview--normalize-paragraphs (text)
  "Normalize TEXT so only blank lines create hard paragraph breaks."
  (let ((text (string-trim (or text ""))))
    (if (string-empty-p text)
        ""
      (string-join
       (mapcar #'hnview--normalize-paragraph
               (split-string text "\n[ \t]*\n+" t))
       "\n\n"))))

(defun hnview--normalize-paragraph (paragraph)
  "Return PARAGRAPH with internal hard line breaks collapsed."
  (string-join
   (split-string paragraph "\n+" t "[ \t]+")
   " "))

(defun hnview--date-parts ()
  "Return current date parts for the feed header."
  (let* ((decoded (decode-time))
         (day (number-to-string (decoded-time-day decoded))))
    (list (format-time-string "%A")
          day
          (format-time-string "%B")
          (format-time-string "%Y"))))

;;; Translation

(defun hnview--translation-segments (item)
  "Return translatable segments for ITEM."
  (pcase (plist-get item :type)
    ("comment"
     (hnview--non-empty-segments
      `((text . ,(hnview--html-to-text (plist-get item :text))))))
    (_
     (hnview--non-empty-segments
      `((title . ,(plist-get item :title))
        (text . ,(hnview--html-to-text (plist-get item :text))))))))

(defun hnview--non-empty-segments (segments)
  "Return non-empty SEGMENTS."
  (cl-remove-if (lambda (segment)
                  (string-empty-p (or (cdr segment) "")))
                segments))

(defun hnview--translation-key (item text &optional segment)
  "Return cache key for ITEM, TEXT, and SEGMENT."
  (format "%s:%s:%s:%s:%s"
          hnview-translate-backend
          hnview-translate-target-language
          (hnview--translation-style-hash)
          (format "%s:%s" (or (plist-get item :id) "region")
                  (or segment 'item))
          (secure-hash 'sha1 text)))

(defun hnview--translation-style-hash ()
  "Return a hash for translation style settings."
  (secure-hash
   'sha1
   (prin1-to-string
    (list hnview-translation-prompt-template
          hnview-translation-glossary))))

(defun hnview--translation-source-hash (text)
  "Return source hash for translation TEXT."
  (secure-hash 'sha1 text))

(defun hnview--cached-translation (item segment text)
  "Return cached translation for ITEM SEGMENT and TEXT, if any."
  (let ((key (hnview--translation-key item text segment)))
    (when-let* ((translation (gethash key hnview--translations)))
      (hnview--touch-translation key)
      translation)))

(defun hnview--touch-translation (key)
  "Record a cache hit for translation KEY."
  (when (hnview--db-live-p)
    (sqlite-execute
     hnview--db
     "UPDATE translations
      SET last_accessed_at = ?, access_count = access_count + 1
      WHERE cache_key = ?"
     (list (hnview--unix-time) key))))

(defun hnview--translation-pending-p (item segment text)
  "Return non-nil when ITEM SEGMENT TEXT is being translated."
  (let ((key (hnview--translation-key item text segment)))
    (gethash key hnview--pending-translations)))

(defun hnview--translated-segment-p (item segment)
  "Return non-nil when ITEM SEGMENT has a cached translation."
  (when-let* ((text (cdr (assq segment (hnview--translation-segments item)))))
    (hnview--cached-translation item segment text)))

(defun hnview--fully-translated-p (item)
  "Return non-nil when every segment of ITEM has a translation."
  (let ((segments (hnview--translation-segments item)))
    (and segments
         (cl-every (lambda (segment)
                     (hnview--translated-segment-p item (car segment)))
                   segments))))

(defun hnview--visible-translation-p (item)
  "Return non-nil when ITEM has a visible translation."
  (cl-some (lambda (segment)
             (and (hnview--translated-segment-p item (car segment))
                  (hnview--translation-visible-state-p item (car segment))))
           (hnview--translation-segments item)))

(defun hnview--active-translation-p (item)
  "Return non-nil when ITEM has visible or pending translation state."
  (cl-some (lambda (segment)
             (pcase-let ((`(,name . ,text) segment))
               (and (hnview--translation-visible-state-p item name)
                    (or (hnview--cached-translation item name text)
                        (hnview--translation-pending-p item name text)))))
           (hnview--translation-segments item)))

(defun hnview--needs-translation-p (item)
  "Return non-nil when ITEM has untranslated, non-pending text."
  (cl-some (lambda (segment)
             (pcase-let ((`(,name . ,text) segment))
               (not (or (hnview--cached-translation item name text)
                        (hnview--translation-pending-p item name text)))))
           (hnview--translation-segments item)))

(defun hnview--translate-item (item callback)
  "Translate ITEM, then call CALLBACK with ERROR and TRANSLATION."
  (let ((segments (hnview--translation-segments item)))
    (if (null segments)
        (funcall callback "No text to translate" nil)
      (hnview--translate-segments item segments callback))))

(defun hnview--translate-segments (item segments callback)
  "Translate ITEM SEGMENTS, then call CALLBACK."
  (let ((pending 0)
        (failed nil)
        (started nil))
    (dolist (segment segments)
      (pcase-let ((`(,name . ,text) segment))
        (unless (or (hnview--cached-translation item name text)
                    (hnview--translation-pending-p item name text))
          (setq started t)
          (cl-incf pending)
          (hnview--translate-segment
           item name text
           (lambda (error _translation)
             (when error
               (setq failed (or failed error)))
             (cl-decf pending)
             (when (zerop pending)
               (funcall callback failed t)))))))
    (unless started
      (funcall callback nil t))))

(defun hnview--translate-segment (item segment text callback)
  "Translate ITEM SEGMENT TEXT, then call CALLBACK."
  (let ((key (hnview--translation-key item text segment)))
    (puthash key t hnview--pending-translations)
    (force-mode-line-update t)
    (hnview--translate-text
     text
       (lambda (error translation)
         (remhash key hnview--pending-translations)
         (force-mode-line-update t)
         (when translation
           (puthash key translation hnview--translations)
           (hnview--persist-translation item segment text translation))
         (funcall callback error translation)))))

(defun hnview--persist-translation (item segment source translation)
  "Persist ITEM SEGMENT SOURCE TRANSLATION."
  (hnview--ensure-db)
  (hnview--upsert-translation-row
   (hnview--translation-key item source segment)
   hnview-translate-backend
   hnview-translate-target-language
   (plist-get item :id)
   segment
   source
   translation))

(defun hnview--upsert-translation-row
    (key backend target-language item-id segment source translation)
  "Upsert KEY for BACKEND, TARGET-LANGUAGE, ITEM-ID, SEGMENT, SOURCE, TRANSLATION."
  (let ((now (hnview--unix-time))
        (source-text (or source ""))
        (segment-name (format "%s" (or segment "legacy"))))
    (sqlite-execute
     hnview--db
     "INSERT INTO translations
        (cache_key, backend, target_language, item_id, segment,
         source_hash, source_text, translated_text, created_at,
         last_accessed_at, access_count)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
      ON CONFLICT(cache_key) DO UPDATE SET
        translated_text = excluded.translated_text,
        last_accessed_at = excluded.last_accessed_at,
        access_count = translations.access_count + 1"
     (list key
           (format "%s" (or backend "legacy"))
           (or target-language hnview-translate-target-language)
           item-id
           segment-name
           (hnview--translation-source-hash source-text)
           source-text
           translation
           now
           now))))

(defun hnview--maybe-prune-translation-cache ()
  "Prune translation cache when the prune interval has elapsed."
  (let* ((last (string-to-number
                (or (hnview--metadata "last_translation_prune_at") "0")))
         (interval (* hnview-translation-cache-prune-interval-hours
                      3600))
         (now (hnview--unix-time)))
    (when (or (zerop last) (> (- now last) interval))
      (hnview-prune-translation-cache))))

(defun hnview-prune-translation-cache ()
  "Prune old and excess translation cache entries."
  (interactive)
  (hnview--ensure-db)
  (let ((cutoff (- (hnview--unix-time)
                   (* hnview-translation-cache-ttl-days 86400))))
    (when (> hnview-translation-cache-ttl-days 0)
      (sqlite-execute
       hnview--db
       "DELETE FROM translations WHERE last_accessed_at < ?"
       (list cutoff)))
    (when (> hnview-translation-cache-max-entries 0)
      (sqlite-execute
       hnview--db
       "DELETE FROM translations
        WHERE cache_key NOT IN (
          SELECT cache_key FROM translations
          ORDER BY last_accessed_at DESC
          LIMIT ?
        )"
       (list hnview-translation-cache-max-entries))))
  (sqlite-execute hnview--db "PRAGMA optimize")
  (hnview--set-metadata "last_translation_prune_at"
                         (number-to-string (hnview--unix-time)))
  (hnview--load-db-state)
  (when (called-interactively-p 'interactive)
    (message "Pruned hnview translation cache")))

(defun hnview-clear-translation-cache ()
  "Clear all cached translations."
  (interactive)
  (hnview--ensure-db)
  (sqlite-execute hnview--db "DELETE FROM translations")
  (clrhash hnview--translations)
  (when (called-interactively-p 'interactive)
    (message "Cleared hnview translation cache")))

(defun hnview--translate-text (text callback &optional target-language)
  "Translate TEXT to TARGET-LANGUAGE, then call CALLBACK."
  (pcase hnview-translate-backend
    ('llm (hnview--translate-text-llm text callback target-language))
    (_ (funcall callback "Unsupported translation backend" nil))))

(defun hnview--translate-text-llm (text callback &optional target-language)
  "Translate TEXT to TARGET-LANGUAGE through `llm.el', then call CALLBACK."
  (cond
   ((not (require 'llm nil t))
    (funcall callback "llm.el is not installed" nil))
   (t
    (condition-case err
        (let ((provider (hnview--llm-provider)))
          (if (not provider)
              (funcall
               callback
               "hnview-llm-provider is not configured; run M-x hnview-translation-status"
               nil)
            (let ((prompt (llm-make-chat-prompt
                           text
                           :context (hnview--translation-system-prompt
                                     target-language)
                           :temperature 0.1)))
              (llm-chat-async
               provider
               prompt
               (lambda (response)
                 (if (stringp response)
                     (funcall callback nil (string-trim response))
                   (funcall
                    callback
                    (format "Translation failed: unexpected llm response %S"
                            response)
                    nil)))
               (lambda (type message)
                 (funcall callback (format "%s: %s" type message) nil))))))
      (error
       (funcall callback
                (format "llm.el translation error: %s"
                        (error-message-string err))
                nil))))))

(defun hnview--llm-provider ()
  "Return the configured llm provider object."
  (if (functionp hnview-llm-provider)
      (funcall hnview-llm-provider)
    hnview-llm-provider))

;;;###autoload
(defun hnview-translation-status ()
  "Show hnview translation configuration status."
  (interactive)
  (let ((message
         (cond
          ((not (require 'llm nil t))
           "llm.el is not installed or not on load-path")
          (t
           (condition-case err
               (let ((provider (hnview--llm-provider)))
                 (if provider
                     (format "Translation backend: %s, target: %s, provider: %S"
                             hnview-translate-backend
                             hnview-translate-target-language
                             provider)
                   "hnview-llm-provider is not configured"))
             (error
              (format "hnview-llm-provider failed: %s"
                      (error-message-string err))))))))
    (if (called-interactively-p 'interactive)
        (message "%s" message)
      message)))

(defun hnview--translation-system-prompt (&optional target-language)
  "Return the system prompt for translation to TARGET-LANGUAGE."
  (let* ((glossary (hnview--translation-glossary-prompt))
         (prompt (string-replace
                  "{{target}}"
                  (or target-language hnview-translate-target-language)
                  hnview-translation-prompt-template)))
    (if (string-match-p (regexp-quote "{{glossary}}") prompt)
        (string-replace "{{glossary}}" glossary prompt)
      (string-join (delq nil (list prompt
                                   (unless (string-empty-p glossary)
                                     glossary)))
                   "\n\n"))))

(defun hnview--translation-glossary-prompt ()
  "Return a prompt fragment for `hnview-translation-glossary'."
  (let ((lines (delq nil
                     (mapcar #'hnview--translation-glossary-entry-prompt
                             hnview-translation-glossary))))
    (if lines
        (concat "Glossary:\n" (string-join lines "\n"))
      "")))

(defun hnview--translation-glossary-entry-prompt (entry)
  "Return a prompt line for glossary ENTRY."
  (let* ((source (car-safe entry))
         (target (cdr-safe entry))
         (target (if (and (consp target) (null (cdr target)))
                     (car target)
                   target)))
    (when (and (stringp source)
               (not (string-empty-p source))
               (stringp target)
               (not (string-empty-p target)))
      (format "- %s => %s"
              (hnview--translation-glossary-one-line source)
              (hnview--translation-glossary-one-line target)))))

(defun hnview--translation-glossary-one-line (text)
  "Return TEXT collapsed to one line for prompt glossary use."
  (string-trim (replace-regexp-in-string "[\n\r]+" " " text)))

;;; Rendering helpers

(defun hnview--insert (text face &rest properties)
  "Insert TEXT with FACE and PROPERTIES."
  (let ((start (point)))
    (insert text)
    (add-text-properties start (point) `(face ,face ,@properties))))

(defun hnview--insert-line (text face &rest properties)
  "Insert TEXT with FACE and PROPERTIES followed by a newline."
  (apply #'hnview--insert text face properties)
  (insert "\n"))

(defun hnview--original-key (item segment)
  "Return visibility key for ITEM SEGMENT."
  (format "%s:%s" (or (plist-get item :id) "region") segment))

(defun hnview--ensure-hidden-translations ()
  "Ensure translation visibility overrides exist for the current buffer."
  (unless hnview--hidden-translations
    (setq-local hnview--hidden-translations
                (make-hash-table :test #'equal))))

(defun hnview--translation-hidden-p (item segment)
  "Return non-nil when ITEM SEGMENT translation is hidden."
  (not (hnview--translation-visible-state-p item segment)))

(defun hnview--translation-visible-state-p (item segment)
  "Return non-nil when ITEM SEGMENT should show translation."
  (hnview--ensure-hidden-translations)
  (let ((override (gethash (hnview--original-key item segment)
                           hnview--hidden-translations)))
    (cond
     ((eq override 'translated) t)
     ((or (eq override 'original) (eq override t)) nil)
     (t hnview-translate-by-default))))

(defun hnview--set-translation-hidden (item segment hidden)
  "Set ITEM SEGMENT translation visibility according to HIDDEN."
  (hnview--ensure-hidden-translations)
  (let ((key (hnview--original-key item segment)))
    (if hidden
        (puthash key 'original hnview--hidden-translations)
      (puthash key 'translated hnview--hidden-translations))))

(defun hnview--set-item-translation-hidden (item hidden)
  "Set translation visibility for every segment of ITEM according to HIDDEN."
  (dolist (segment (hnview--translation-segments item))
    (hnview--set-translation-hidden item (car segment) hidden)))

(defun hnview--insert-title-segment (item source)
  "Insert ITEM title SOURCE."
  (let ((translation (when (hnview--translation-visible-state-p item 'title)
                       (hnview--cached-translation item 'title source))))
    (if translation
        (hnview--insert-line translation 'hnview-title 'hnview-item item)
      (hnview--insert-line source 'hnview-title 'hnview-item item))))

(defun hnview--insert-text-segment (item segment source indent face)
  "Insert ITEM SEGMENT SOURCE at INDENT with FACE."
  (let* ((visible (hnview--translation-visible-state-p item segment))
         (translation (when visible
                        (hnview--cached-translation item segment source))))
    (cond
     (translation
      (hnview--insert-translated-lines item translation indent face))
     ((and visible (hnview--translation-pending-p item segment source))
      (hnview--insert-source-lines item source indent face))
     (t
      (hnview--insert-source-lines item source indent face)))))

(defun hnview--insert-translated-lines (item text indent face)
  "Insert translated TEXT for ITEM at INDENT with FACE."
  (hnview--insert-normalized-lines item text indent face))

(defun hnview--insert-source-lines (item text indent face)
  "Insert source TEXT for ITEM at INDENT with FACE."
  (hnview--insert-normalized-lines item text indent face))

(defun hnview--insert-normalized-lines (item text indent face)
  "Insert normalized TEXT for ITEM at INDENT with FACE."
  (dolist (line (split-string (hnview--normalize-paragraphs text) "\n"))
    (let ((start (point)))
      (if (string-empty-p line)
          (insert "\n")
        (hnview--insert-rendered-text-line item line indent face))
      (add-text-properties start (point) `(hnview-item ,item)))))

(defun hnview--insert-rendered-text-line (item line indent face)
  "Insert ITEM text LINE at INDENT with FACE, rendering quotes specially."
  (if-let* ((quote (hnview--quote-line-text line)))
      (progn
        (insert (make-string indent ?\s))
        (hnview--insert (concat hnview-quote-symbol " ")
                         'hnview-quote 'hnview-item item)
        (hnview--insert-line quote 'hnview-quote 'hnview-item item))
    (insert (make-string indent ?\s))
    (hnview--insert-line line face 'hnview-item item)))

(defun hnview--quote-line-text (line)
  "Return LINE without quote prefix, or nil when LINE is not a quote."
  (when (string-match "\\`[ \t]*>[ \t]?" line)
    (substring line (match-end 0))))


(defun hnview--render-header ()
  "Render the feed date header."
  (pcase-let ((`(,weekday ,day ,month ,year) (hnview--date-parts)))
    (hnview--insert weekday 'hnview-date-main)
    (insert "   ")
    (hnview--insert day 'hnview-date-muted)
    (insert " ")
    (hnview--insert month 'hnview-date-muted)
    (insert "   ")
    (hnview--insert year 'hnview-date-muted)
    (insert "\n\n"))
  (hnview--insert-line (make-string 72 ?-) 'hnview-divider)
  (insert "\n"))

(defun hnview--render-feed ()
  "Render the current feed buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (hnview--render-header)
    (cond
     (hnview--loading-message
      (hnview--insert-line hnview--loading-message 'hnview-loading))
     (hnview--error-message
      (hnview--insert-line hnview--error-message 'error))
     (t
      (cl-loop for story in hnview--stories
               for index from 1
               do (hnview--insert-feed-item story index))))
    (goto-char (point-min))))

(defun hnview--insert-feed-item (item index)
  "Insert feed ITEM at INDEX."
  (pcase (plist-get item :type)
    ((or "story" "job" "poll")
     (hnview--insert-story item index))
    ("comment"
     (hnview--insert-profile-comment item index))
    (_
     (hnview--insert-story item index))))

(defun hnview--insert-story (story index)
  "Insert STORY at INDEX."
  (let ((start (point))
        (title (or (plist-get story :title) "(untitled)")))
    (hnview--insert (format "%2d. " index) 'hnview-index)
    (if (gethash (plist-get story :id) hnview--bookmarks)
        (hnview--insert "* " 'hnview-domain)
      (insert "  "))
    (hnview--insert-title-segment story title)
    (hnview--insert-story-meta-line story 6)
    (insert "\n")
    (add-text-properties start (point) `(hnview-item ,story))))

(defun hnview--insert-story-meta-line (story indent)
  "Insert STORY metadata line with INDENT spaces."
  (let ((parts (hnview--story-meta-parts story)))
    (insert (make-string indent ?\s))
    (hnview--insert (hnview--domain story) 'hnview-domain
                     'hnview-item story)
    (when parts
      (hnview--insert " - " 'hnview-meta 'hnview-item story)
      (hnview--insert (string-join parts " - ") 'hnview-meta
                       'hnview-item story))
    (insert "\n")))

(defun hnview--render-thread ()
  "Render the current thread buffer."
  (let ((inhibit-read-only t)
        (story hnview--thread-root))
    (erase-buffer)
    (if hnview--loading-message
        (hnview--insert-line hnview--loading-message 'hnview-loading)
      (hnview--render-story-header story)
      (insert "\n")
      (hnview--insert-line (make-string 72 ?-) 'hnview-divider)
      (insert "\n")
      (dolist (comment (plist-get story :hnview-children))
        (hnview--insert-comment comment 0))
      (when (hnview--tree-truncated-p story)
        (hnview--insert-line
         (format "More comments available. Press + to load %d more, or * to load all."
                 hnview-comment-fetch-step)
         'hnview-meta)))
    (goto-char (point-min))))

(defun hnview--render-inbox ()
  "Render the current inbox buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (hnview--insert-line
     (format "Replies for %s" (or hnview-username "unconfigured"))
     'hnview-title)
    (insert "\n")
    (cond
     (hnview--loading-message
      (hnview--insert-line hnview--loading-message 'hnview-loading))
     (hnview--error-message
      (hnview--insert-line hnview--error-message 'error))
     ((null hnview--inbox-replies)
      (hnview--insert-line "No replies found." 'hnview-meta))
     (t
      (dolist (reply hnview--inbox-replies)
        (hnview--insert-inbox-reply reply))))
    (goto-char (point-min))))

(defun hnview--render-profile ()
  "Render the current profile buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (hnview--render-profile-header)
    (cond
     (hnview--loading-message
      (hnview--insert-line hnview--loading-message 'hnview-loading))
     (hnview--error-message
      (hnview--insert-line hnview--error-message 'error))
     ((eq hnview--profile-section 'about)
      (hnview--render-profile-about))
     ((null hnview--profile-items)
      (hnview--insert-line "No items found." 'hnview-meta))
     (t
      (cl-loop for item in hnview--profile-items
               for index from 1
               do (hnview--insert-profile-item item index))))
    (goto-char (point-min))))

(defun hnview--render-profile-header ()
  "Render the current profile header."
  (hnview--insert-line (or hnview--profile-username "HN user") 'hnview-date-main)
  (when hnview--profile-user
    (let ((parts (delq nil
                       (list
                        (when (plist-member hnview--profile-user :created)
                          (format "Joined %s"
                                  (hnview--relative-time
                                   (plist-get hnview--profile-user :created))))
                        (when (plist-member hnview--profile-user :karma)
                          (format "%s Karma"
                                  (plist-get hnview--profile-user :karma)))))))
      (when parts
        (hnview--insert-line (string-join parts " • ") 'hnview-meta))))
  (insert "\n"))

(defun hnview--render-profile-about ()
  "Render the current profile about section."
  (if-let* ((about (hnview--html-to-text
                    (plist-get hnview--profile-user :about))))
      (if (string-empty-p about)
          (hnview--insert-line "No about text." 'hnview-meta)
        (hnview--insert-profile-about-text about))
    (hnview--insert-line "No about text." 'hnview-meta)))

(defun hnview--insert-profile-about-text (text)
  "Insert profile about TEXT without item properties."
  (dolist (line (split-string (hnview--normalize-paragraphs text) "\n"))
    (if (string-empty-p line)
        (insert "\n")
      (hnview--insert-line line 'default))))

(defun hnview--insert-profile-item (item index)
  "Insert profile ITEM at INDEX."
  (pcase (plist-get item :type)
    ((or "story" "job" "poll")
     (hnview--insert-story item index))
    ("comment"
     (hnview--insert-profile-comment item index))
    (_
     (hnview--insert-story item index))))

(defun hnview--insert-profile-comment (comment index)
  "Insert profile COMMENT at INDEX."
  (let ((start (point)))
    (hnview--insert (format "%2d. " index) 'hnview-index)
    (if (gethash (plist-get comment :id) hnview--bookmarks)
        (hnview--insert "* " 'hnview-domain)
      (insert "  "))
    (hnview--insert-comment-meta-line comment 0)
    (hnview--insert-comment-text comment 6)
    (insert "\n")
    (add-text-properties start (point) `(hnview-item ,comment))))

(defun hnview--insert-inbox-reply (reply)
  "Insert inbox REPLY."
  (let* ((parent (plist-get reply :hnview-parent))
         (parent-title (or (plist-get parent :title)
                           (hnview--html-to-text (plist-get parent :text))
                           "item"))
         (start (point)))
    (hnview--insert-line
     (format "%s replied %s"
             (or (plist-get reply :by) "someone")
             (if (plist-member reply :time)
                 (hnview--relative-time (plist-get reply :time))
               ""))
     'hnview-meta 'hnview-item reply)
    (hnview--insert-line
     (format "to: %s" (truncate-string-to-width parent-title 72 nil nil t))
     'hnview-meta 'hnview-item reply)
    (hnview--insert-comment-text reply 0)
    (add-text-properties start (point) `(hnview-item ,reply))))

(defun hnview--tree-truncated-p (item)
  "Return non-nil when ITEM's fetched comment tree is truncated."
  (or (plist-get item :hnview-truncated)
      (cl-some #'hnview--tree-truncated-p
               (plist-get item :hnview-children))))

(defun hnview--render-story-header (story)
  "Render STORY header in a thread buffer."
  (let ((title (or (plist-get story :title) "(untitled)")))
    (hnview--insert-title-segment story title)
    (hnview--insert-story-meta-line story 0)
    (when-let* ((text (hnview--html-to-text (plist-get story :text))))
      (unless (string-empty-p text)
        (insert "\n")
        (hnview--insert-text-segment story 'text text 0 'default)))))

(defun hnview--insert-comment (comment depth)
  "Insert COMMENT at DEPTH."
  (let* ((id (plist-get comment :id))
         (children (plist-get comment :hnview-children))
         (folded (and children hnview--folded-comments
                      (gethash id hnview--folded-comments)))
         (indent (* depth 2)))
    (insert (make-string indent ?\s))
    (hnview--insert-comment-fold-control comment folded)
    (insert " ")
    (hnview--insert-comment-status-markers comment)
    (let ((text-indent (current-column)))
      (hnview--insert-comment-meta-line
       comment depth
       (when folded
         (hnview--comment-descendant-count comment)))
      (unless folded
        (hnview--insert-comment-text comment text-indent)
        (dolist (child children)
          (hnview--insert-comment child (1+ depth)))))))

(defun hnview--insert-comment-status-markers (comment)
  "Insert local status markers for COMMENT before the author."
  (let ((id (plist-get comment :id)))
    (when (gethash id hnview--bookmarks)
      (hnview--insert "*" 'hnview-domain 'hnview-item comment)
      (insert " "))
    (when (gethash id hnview--upvotes)
      (hnview--insert hnview-vote-up-symbol 'hnview-vote
                       'hnview-item comment
                       'hnview-comment-id id)
      (insert " "))))

(defun hnview--insert-comment-meta-line (comment depth &optional more-count)
  "Insert COMMENT metadata at DEPTH with optional MORE-COUNT."
  (let ((parts (delq nil
                     (list (when (plist-member comment :time)
                             (hnview--relative-time
                              (plist-get comment :time)))
                           (when (and more-count (> more-count 0))
                             (format "%d more" more-count)))))
        (properties (list 'hnview-item comment
                          'hnview-comment-id (plist-get comment :id)
                          'hnview-depth depth))
        (first t))
    (when-let* ((author (plist-get comment :by)))
      (apply #'hnview--insert author 'hnview-author properties)
      (setq first nil))
    (dolist (part parts)
      (unless first
        (apply #'hnview--insert " • " 'hnview-meta properties))
      (apply #'hnview--insert part 'hnview-meta properties)
      (setq first nil))
    (insert "\n")))

(defun hnview--insert-comment-fold-control (comment folded)
  "Insert COMMENT fold control according to FOLDED."
  (if (plist-get comment :hnview-children)
      (hnview--insert
       (if folded
           hnview-comment-collapsed-symbol
         hnview-comment-expanded-symbol)
       'hnview-meta
       'hnview-item comment
       'hnview-comment-id (plist-get comment :id)
       'help-echo "Press TAB to fold or unfold this comment")
    (insert " ")))

(defun hnview--insert-comment-text (comment indent)
  "Insert COMMENT text with INDENT spaces."
  (let ((text (hnview--html-to-text (plist-get comment :text))))
    (unless (string-empty-p text)
      (hnview--insert-text-segment comment 'text text indent 'default))
    (let ((start (point)))
      (insert "\n")
      (add-text-properties start (point) `(hnview-item ,comment)))))

;;; Navigation

(defun hnview--item-at-point ()
  "Return hnview item at point."
  (hnview--line-property 'hnview-item))

(defun hnview--line-property (property)
  "Return PROPERTY at point or on the current line."
  (or (get-text-property (point) property)
      (save-excursion
        (let ((end (line-end-position)))
          (goto-char (line-beginning-position))
          (catch 'found
            (while (< (point) end)
              (when-let* ((value (get-text-property (point) property)))
                (throw 'found value))
              (forward-char 1))
            nil)))))

(defun hnview--story-at-point ()
  "Return story at point."
  (let ((item (hnview--item-at-point)))
    (unless (member (plist-get item :type) '("story" "job"))
      (user-error "No story at point"))
    item))

(defun hnview--point-state ()
  "Return state for restoring point within the current hnview item."
  (when-let* ((item (hnview--item-at-point))
              (id (plist-get item :id)))
    (let ((line-start (line-beginning-position))
          (column (current-column)))
      (save-excursion
        (hnview--goto-item-id id)
        (list :item-id id
              :line-offset (count-lines (line-beginning-position) line-start)
              :column column)))))

(defun hnview--rerender-current-buffer (&optional preserve-item)
  "Render current hnview buffer.
When PRESERVE-ITEM is non-nil, restore point after render.
If PRESERVE-ITEM is a point state from `hnview--point-state', use that state.
Otherwise, preserve the current item and relative line and column."
  (let ((state (cond
                ((and (listp preserve-item)
                      (plist-member preserve-item :item-id))
                 preserve-item)
                (preserve-item
                 (hnview--point-state)))))
    (cond
     ((derived-mode-p 'hnview-feed-mode) (hnview--render-feed))
     ((derived-mode-p 'hnview-thread-mode) (hnview--render-thread))
     ((derived-mode-p 'hnview-inbox-mode) (hnview--render-inbox)))
    (when state
      (hnview--restore-point-state state))))

(defun hnview--restore-point-state (state)
  "Restore point from STATE produced by `hnview--point-state'."
  (let ((id (plist-get state :item-id))
        (line-offset (or (plist-get state :line-offset) 0))
        (column (or (plist-get state :column) 0)))
    (when id
      (hnview--goto-item-id id)
      (let ((last-good (line-beginning-position)))
        (catch 'done
          (dotimes (_ line-offset)
            (if (zerop (forward-line 1))
                (if (equal (plist-get (hnview--item-at-point) :id) id)
                    (setq last-good (line-beginning-position))
                  (goto-char last-good)
                  (throw 'done nil))
              (goto-char last-good)
              (throw 'done nil))))
        (move-to-column column)))))

(defun hnview--goto-item-id (id)
  "Move point to the first rendered hnview item with ID."
  (goto-char (point-min))
  (catch 'found
    (while (< (point) (point-max))
      (when-let* ((item (get-text-property (point) 'hnview-item)))
        (when (equal (plist-get item :id) id)
          (throw 'found t)))
      (goto-char (or (next-single-property-change
                      (point) 'hnview-item nil (point-max))
                     (point-max))))))

(defun hnview-next-item ()
  "Move point to the next hnview item."
  (interactive)
  (let ((pos (next-single-property-change (point) 'hnview-item)))
    (if pos
        (goto-char pos)
      (user-error "No next item"))))

(defun hnview-previous-item ()
  "Move point to the previous hnview item."
  (interactive)
  (let ((pos (previous-single-property-change (point) 'hnview-item)))
    (if pos
        (goto-char pos)
      (user-error "No previous item"))))

;;; Commands

;;;###autoload
(defun hnview ()
  "Open the hnview Top feed."
  (interactive)
  (hnview-open-feed 'top))

;;;###autoload
(defun hnview-login (&optional username password)
  "Log in to Hacker News as USERNAME using PASSWORD.
When PASSWORD is nil, read credentials from auth-source.  Credentials are not
stored by hnview; HN cookies are stored in the hnview SQLite database."
  (interactive)
  (let* ((credentials
          (or (when (and username password)
                (cons username password))
              (hnview--auth-source-credentials
               (or username hnview-username))))
         (user (car credentials))
         (secret (cdr credentials)))
    (unless (and user secret)
      (user-error
       "No HN credentials found in auth-source for news.ycombinator.com"))
    (hnview--delete-cookies-by-host-name "news.ycombinator.com" "user")
    (message "Logging in to Hacker News...")
    (hnview--post-form
     (hnview--hn-url "login")
     `(("acct" . ,user) ("pw" . ,secret) ("goto" . "news"))
     (lambda (error html)
       (cond
        (error (message "%s" error))
        ((or (hnview--login-success-p html user)
             (hnview--hn-user-cookie-p))
         (setq hnview-username user)
         (message "Logged in to Hacker News as %s" user))
        ((hnview--hn-error-message html)
         (message "%s" (hnview--hn-error-message html)))
        (t
         (message "HN login did not complete")))))))

;;;###autoload
(defun hnview-inbox (&optional username)
  "Open the reply inbox for USERNAME."
  (interactive)
  (let ((name (or username
                  hnview-username
                  (read-string "HN username: "))))
    (unless (and name (not (string-empty-p name)))
      (user-error "HN username is not configured"))
    (hnview--ensure-state-loaded)
    (let ((buffer (get-buffer-create (format "*hnview: inbox %s*" name))))
      (switch-to-buffer buffer)
      (hnview-inbox-mode)
      (setq-local hnview-username name)
      (setq-local hnview--loading-message "Loading replies...")
      (setq-local hnview--error-message nil)
      (setq-local hnview--inbox-replies nil)
      (hnview--render-inbox)
      (hnview--fetch-inbox-replies
       name hnview-inbox-submission-limit
       (lambda (error replies)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq-local hnview--loading-message nil)
             (setq-local hnview--error-message error)
             (setq-local hnview--inbox-replies replies)
             (hnview--render-inbox)
             (hnview--maybe-auto-translate buffer))))))))

;;;###autoload
(defun hnview-profile (&optional username section)
  "Open the Hacker News profile for USERNAME at SECTION."
  (interactive)
  (let ((name (or username
                  hnview-username
                  (read-string "HN username: "))))
    (unless (and name (not (string-empty-p name)))
      (user-error "HN username is not configured"))
    (hnview--open-profile name (or section 'about))))

(defun hnview--open-profile (username section)
  "Open USERNAME profile SECTION."
  (hnview--ensure-state-loaded)
  (let ((buffer (get-buffer-create (format "*hnview: profile %s*" username))))
    (switch-to-buffer buffer)
    (hnview-profile-mode)
    (setq-local hnview--profile-username username)
    (setq-local hnview--profile-section section)
    (setq-local mode-name (hnview--profile-mode-name section))
    (setq-local hnview--loading-message
                (format "Loading %s..."
                        (hnview--profile-section-label section)))
    (setq-local hnview--error-message nil)
    (setq-local hnview--profile-items nil)
    (hnview--render-profile)
    (hnview--fetch-profile-section
     username section
     (lambda (error user items)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (and (equal hnview--profile-username username)
                      (eq hnview--profile-section section))
             (setq-local hnview--loading-message nil)
             (setq-local hnview--error-message error)
             (setq-local hnview--profile-user user)
             (setq-local hnview--profile-items items)
             (hnview--render-profile)
             (hnview--maybe-auto-translate buffer))))))))

(defun hnview-profile-switch-section ()
  "Switch the current profile section."
  (interactive)
  (unless (derived-mode-p 'hnview-profile-mode)
    (user-error "Not in an hnview profile buffer"))
  (let* ((choices (mapcar (lambda (section)
                            (cons (cdr section) (car section)))
                          hnview--profile-sections))
         (default (hnview--profile-section-label hnview--profile-section))
         (choice (completing-read "Section: " choices nil t nil nil default)))
    (hnview--open-profile hnview--profile-username
                          (cdr (assoc choice choices)))))

(defun hnview--profile-open-current-user-section (section)
  "Open current profile user SECTION."
  (if (derived-mode-p 'hnview-profile-mode)
      (hnview--open-profile hnview--profile-username section)
    (hnview-profile nil section)))

(defun hnview-profile-about ()
  "Open the current profile About section."
  (interactive)
  (hnview--profile-open-current-user-section 'about))

(defun hnview-profile-stories ()
  "Open the current profile Stories section."
  (interactive)
  (hnview--profile-open-current-user-section 'stories))

(defun hnview-profile-comments ()
  "Open the current profile Comments section."
  (interactive)
  (hnview--profile-open-current-user-section 'comments))

(defun hnview-profile-favorites ()
  "Open the current profile Favorites section."
  (interactive)
  (hnview--profile-open-current-user-section 'favorites))

(defun hnview-profile-upvoted ()
  "Open the current profile Upvoted section."
  (interactive)
  (hnview--profile-open-current-user-section 'upvoted))

(defun hnview-profile-hidden ()
  "Open the current profile Hidden section."
  (interactive)
  (hnview--profile-open-current-user-section 'hidden))

;;;###autoload
(defun hnview-open-feed (feed &optional section)
  "Open hnview FEED with optional SECTION."
  (interactive (list (hnview--read-feed)))
  (hnview--ensure-state-loaded)
  (let* ((section (or section (hnview--feed-default-section feed)))
         (context (hnview--feed-context-label feed section))
         (buffer (get-buffer-create (format "*hnview: %s*" context))))
    (switch-to-buffer buffer)
    (hnview-feed-mode)
    (setq-local hnview--current-feed feed)
    (setq-local hnview--current-feed-section section)
    (hnview--set-mode-name context)
    (setq-local hnview--loading-message "Loading items...")
    (setq-local hnview--error-message nil)
    (setq-local hnview--stories nil)
    (hnview--render-feed)
    (hnview--fetch-feed
     feed section hnview-feed-limit
     (lambda (error stories)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (and (eq hnview--current-feed feed)
                      (eq hnview--current-feed-section section))
             (setq-local hnview--loading-message nil)
             (setq-local hnview--error-message error)
             (setq-local hnview--stories stories)
             (hnview--render-feed)
             (hnview--maybe-auto-translate buffer))))))))

(defun hnview--read-feed ()
  "Read a Hacker News feed from the minibuffer."
  (let* ((choices (mapcar (lambda (feed)
                            (cons (hnview--feed-label (car feed))
                                  (car feed)))
                          hnview--feeds))
         (default (hnview--feed-label hnview--current-feed))
         (choice (completing-read "Feed: " choices nil t nil nil default)))
    (cdr (assoc choice choices))))

(defun hnview-switch-feed ()
  "Switch the current hnview feed."
  (interactive)
  (hnview-open-feed (hnview--read-feed)))

(defun hnview--read-feed-section ()
  "Read a sub-section for the current hnview feed."
  (let ((sections (hnview--feed-sections hnview--current-feed)))
    (unless sections
      (user-error "No sections for %s" (hnview--feed-label hnview--current-feed)))
    (let* ((choices (mapcar (lambda (section)
                              (cons (car (cdr section)) (car section)))
                            sections))
           (default (hnview--feed-section-label
                     hnview--current-feed
                     (or hnview--current-feed-section
                         (hnview--feed-default-section hnview--current-feed))))
           (choice (completing-read "Section: " choices nil t nil nil default)))
      (cdr (assoc choice choices)))))

(defun hnview-switch-feed-section ()
  "Switch the current hnview feed sub-section."
  (interactive)
  (hnview-open-feed hnview--current-feed (hnview--read-feed-section)))

;;;###autoload
(defun hnview-top ()
  "Open the Hacker News Top feed."
  (interactive)
  (hnview-open-feed 'top))

;;;###autoload
(defun hnview-ask ()
  "Open the Hacker News Ask feed."
  (interactive)
  (hnview-open-feed 'ask))

;;;###autoload
(defun hnview-show ()
  "Open the Hacker News Show feed."
  (interactive)
  (hnview-open-feed 'show))

;;;###autoload
(defun hnview-best ()
  "Open the Hacker News Best feed."
  (interactive)
  (hnview-open-feed 'best))

;;;###autoload
(defun hnview-new ()
  "Open the Hacker News New feed."
  (interactive)
  (hnview-open-feed 'new))

;;;###autoload
(defun hnview-active ()
  "Open the hnview Active feed."
  (interactive)
  (hnview-open-feed 'active))

(defun hnview-refresh ()
  "Refresh the current hnview buffer."
  (interactive)
  (cond
   ((derived-mode-p 'hnview-feed-mode)
    (hnview-open-feed hnview--current-feed hnview--current-feed-section))
   ((derived-mode-p 'hnview-thread-mode)
    (let ((story hnview--thread-root)
          (limit hnview--thread-comment-limit))
      (unless story
        (user-error "No story in this buffer"))
      (hnview--open-thread story limit)))
   ((derived-mode-p 'hnview-profile-mode)
    (hnview--open-profile hnview--profile-username hnview--profile-section))
   (t (user-error "Not in an hnview buffer"))))

(defun hnview-open-thread ()
  "Open the story thread at point."
  (interactive)
  (hnview--open-thread (hnview--story-at-point)))

(defun hnview-open-item ()
  "Open the item at point."
  (interactive)
  (let ((item (hnview--item-at-point)))
    (unless item
      (user-error "No item at point"))
    (if (member (plist-get item :type) '("story" "job" "poll"))
        (hnview--open-thread item)
      (browse-url (hnview--item-url item)))))

(defun hnview-load-more-comments ()
  "Load more comments in the current thread."
  (interactive)
  (unless (derived-mode-p 'hnview-thread-mode)
    (user-error "Not in a thread buffer"))
  (unless hnview--thread-root
    (user-error "No story in this buffer"))
  (hnview--open-thread
   hnview--thread-root
   (+ (or hnview--thread-comment-limit hnview-comment-fetch-limit)
      hnview-comment-fetch-step)))

(defun hnview-load-all-comments ()
  "Load all comments in the current thread."
  (interactive)
  (unless (derived-mode-p 'hnview-thread-mode)
    (user-error "Not in a thread buffer"))
  (unless hnview--thread-root
    (user-error "No story in this buffer"))
  (hnview--open-thread
   hnview--thread-root
   (max (or (plist-get hnview--thread-root :descendants) 100000)
        hnview-comment-fetch-limit)))

(defun hnview--open-thread (story &optional comment-limit)
  "Open STORY thread with COMMENT-LIMIT comments."
  (let ((buffer (get-buffer-create
                 (format "*hnview: %s*"
                         (truncate-string-to-width
                          (or (plist-get story :title) "thread") 40)))))
    (switch-to-buffer buffer)
    (hnview-thread-mode)
    (setq-local hnview--loading-message "Loading comments...")
    (setq-local hnview--thread-root story)
    (setq-local hnview--thread-comment-limit
                (or comment-limit
                    hnview--thread-comment-limit
                    hnview-comment-fetch-limit))
    (setq-local hnview--folded-comments
                (or hnview--folded-comments (make-hash-table :test #'eql)))
    (hnview--render-thread)
    (hnview--fetch-story-tree
     story
     (lambda (_error root)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq-local hnview--loading-message nil)
           (setq-local hnview--thread-root root)
           (hnview--render-thread)
           (hnview--maybe-auto-translate buffer))))
     hnview--thread-comment-limit)))

(defun hnview-open-url ()
  "Open the URL for the item at point in the system browser."
  (interactive)
  (browse-url (hnview--item-url (or (hnview--item-at-point)
                                     hnview--thread-root))))

(defun hnview-open-url-eww ()
  "Open the URL for the item at point in EWW."
  (interactive)
  (eww (hnview--item-url (or (hnview--item-at-point)
                              hnview--thread-root))))

(defun hnview--item-url (item)
  "Return the best URL for ITEM."
  (unless item
    (user-error "No item at point"))
  (or (plist-get item :url)
      (format "https://news.ycombinator.com/item?id=%s"
              (plist-get item :id))))

(defun hnview--set-mode-name (context)
  "Set the current buffer mode name with CONTEXT."
  (setq-local mode-name (format "hnview %s" context))
  (force-mode-line-update))

(defun hnview--enable-translation-mode-line ()
  "Show pending translation state in this buffer's mode line."
  (setq-local mode-line-process
              '(:eval (hnview--translation-mode-line-status))))

(defun hnview--translation-mode-line-status ()
  "Return mode line text for pending translations in this buffer."
  (let ((count (hnview--buffer-pending-translation-count)))
    (when (> count 0)
      (format " Translating:%d" count))))

(defun hnview--buffer-pending-translation-count ()
  "Return the number of pending translation segments visible in this buffer."
  (let ((count 0))
    (dolist (item (hnview--visible-buffer-items))
      (dolist (segment (hnview--translation-segments item))
        (pcase-let ((`(,name . ,text) segment))
          (when (hnview--translation-pending-p item name text)
            (cl-incf count)))))
    count))

(defun hnview-toggle-bookmark ()
  "Toggle bookmark for the item at point."
  (interactive)
  (hnview--ensure-state-loaded)
  (let* ((item (hnview--item-at-point))
         (id (plist-get item :id)))
    (unless id
      (user-error "No item at point"))
    (if (gethash id hnview--bookmarks)
        (progn
          (remhash id hnview--bookmarks)
          (hnview--delete-bookmark id)
          (message "Removed bookmark"))
      (puthash id t hnview--bookmarks)
      (hnview--upsert-bookmark id)
      (message "Bookmarked"))
    (hnview--rerender-current-buffer)))

(defun hnview-vote-up ()
  "Upvote the item at point."
  (interactive)
  (hnview--vote-up-item (hnview--item-at-point)))

(defun hnview--vote-up-item (item)
  "Upvote ITEM."
  (hnview--vote-current-item item 'up))

(defun hnview--vote-current-item (item direction)
  "Vote on ITEM in DIRECTION and report the result."
  (unless item
    (user-error "No item at point"))
  (let ((buffer (current-buffer))
        (id (plist-get item :id)))
    (message "%svoting HN item %s..."
             (if (eq direction 'up) "Up" "Down")
             id)
    (hnview--vote-item
     item direction
     (lambda (error _html)
       (if error
           (message "%s" error)
         (when (eq direction 'up)
           (hnview--mark-upvoted id))
         (message "%svoted HN item %s"
                  (if (eq direction 'up) "Up" "Down")
                  id)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (hnview--rerender-current-buffer t))))))))

(defun hnview--mark-upvoted (id)
  "Record a session-local upvote marker for ID."
  (when id
    (puthash id t hnview--upvotes)))

(defun hnview-toggle-comment-fold ()
  "Toggle folding for the comment at point."
  (interactive)
  (unless (derived-mode-p 'hnview-thread-mode)
    (user-error "Not in a thread buffer"))
  (let ((comment (hnview--item-at-point)))
    (unless (and comment (equal (plist-get comment :type) "comment"))
      (user-error "No comment at point"))
    (unless (plist-get comment :hnview-children)
      (user-error "Comment has no replies"))
    (hnview--toggle-comment-id (plist-get comment :id))))

(defun hnview--toggle-comment-id (id)
  "Toggle folding for comment ID."
  (unless id
    (user-error "No comment at point"))
  (unless hnview--folded-comments
    (setq-local hnview--folded-comments (make-hash-table :test #'eql)))
  (if (gethash id hnview--folded-comments)
      (remhash id hnview--folded-comments)
    (puthash id t hnview--folded-comments))
  (hnview--render-thread)
  (hnview--goto-item-id id))

(defun hnview-reply-at-point ()
  "Compose a Hacker News reply to the item at point."
  (interactive)
  (let ((parent (or (hnview--item-at-point)
                    hnview--thread-root)))
    (unless (plist-get parent :id)
      (user-error "No item at point"))
    (let ((source (current-buffer))
          (buffer (get-buffer-create
                   (format "*hnview reply: %s*"
                           (plist-get parent :id)))))
      (pop-to-buffer buffer)
      (hnview-reply-mode)
      (setq-local hnview--reply-parent parent)
      (setq-local hnview--reply-source-buffer source)
      (setq-local hnview--reply-translated-p nil)
      (setq-local header-line-format
                  (format
                   "Reply to HN item %s | C-c C-t translate to %s | C-c C-c submit | C-c C-k cancel"
                   (plist-get parent :id)
                   hnview-reply-translate-target-language))
      (erase-buffer)
      (message "Write your reply; C-c C-t translates it, C-c C-c submits it, C-c C-k cancels."))))

(defun hnview--reply-buffer-text ()
  "Return the current reply buffer text."
  (string-trim (buffer-substring-no-properties (point-min) (point-max))))

(defun hnview-translate-reply ()
  "Translate the current reply draft to `hnview-reply-translate-target-language'."
  (interactive)
  (unless (derived-mode-p 'hnview-reply-mode)
    (user-error "Not in an hnview reply buffer"))
  (let ((text (hnview--reply-buffer-text))
        (buffer (current-buffer)))
    (when (string-empty-p text)
      (user-error "Reply draft is empty"))
    (message "Translating reply...")
    (hnview--translate-text
     text
     (lambda (error translation)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if error
               (message "%s" error)
             (erase-buffer)
             (insert translation)
             (goto-char (point-min))
             (setq-local hnview--reply-translated-p t)
             (message "Translated reply to %s"
                      hnview-reply-translate-target-language)))))
     hnview-reply-translate-target-language)))

(defun hnview-submit-reply ()
  "Submit the current reply draft to Hacker News."
  (interactive)
  (unless (derived-mode-p 'hnview-reply-mode)
    (user-error "Not in an hnview reply buffer"))
  (let ((text (hnview--reply-buffer-text))
        (parent hnview--reply-parent)
        (buffer (current-buffer)))
    (when (string-empty-p text)
      (user-error "Reply draft is empty"))
    (unless (plist-get parent :id)
      (user-error "No reply target"))
    (unless (y-or-n-p (format "Submit reply to HN item %s? "
                              (plist-get parent :id)))
      (user-error "Reply not submitted"))
    (message "Submitting reply...")
    (hnview--submit-reply
     parent text
     (lambda (error _html)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if error
               (message "%s" error)
             (message "Submitted reply to HN item %s"
                      (plist-get parent :id))
             (kill-buffer buffer))))))))

(defun hnview-cancel-reply ()
  "Cancel the current Hacker News reply draft."
  (interactive)
  (unless (derived-mode-p 'hnview-reply-mode)
    (user-error "Not in an hnview reply buffer"))
  (let ((source hnview--reply-source-buffer)
        (buffer (current-buffer)))
    (when (or (string-empty-p (hnview--reply-buffer-text))
              (y-or-n-p "Discard reply draft? "))
      (kill-buffer buffer)
      (when (buffer-live-p source)
        (pop-to-buffer source))
      (message "Cancelled reply"))))

(defun hnview-translate-at-point ()
  "Toggle translation for the hnview item at point."
  (interactive)
  (hnview--ensure-state-loaded)
  (let ((item (hnview--item-at-point))
        (state (hnview--point-state))
        (buffer (current-buffer)))
    (unless item
      (user-error "No item at point"))
    (cond
     ((or (hnview--fully-translated-p item)
          (hnview--active-translation-p item))
      (hnview--set-item-translation-hidden
       item (hnview--active-translation-p item))
      (hnview--rerender-current-buffer state))
     (t
      (hnview--set-item-translation-hidden item nil)
      (hnview--translate-item
       item
       (lambda (error _translation)
         (when error
           (message "%s" error))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (hnview--rerender-current-buffer state)))))))))

(defun hnview-translate-visible ()
  "Toggle translation for visible hnview titles and comments."
  (interactive)
  (hnview--ensure-state-loaded)
  (let ((items (hnview--visible-buffer-items))
        (state (hnview--point-state))
        (buffer (current-buffer)))
    (unless items
      (user-error "No visible items"))
    (cl-incf hnview--translation-batch-generation)
    (if (or hnview--translate-visible-active-p
            (cl-some #'hnview--active-translation-p items))
        (progn
          (setq-local hnview--translate-visible-active-p nil)
          (dolist (item items)
            (hnview--set-item-translation-hidden item t))
          (hnview--rerender-current-buffer state))
      (setq-local hnview--translate-visible-active-p t)
      (dolist (item items)
        (hnview--set-item-translation-hidden item nil))
      (hnview--rerender-current-buffer state)
      (when-let* ((pending-items
                   (cl-remove-if-not #'hnview--needs-translation-p items)))
        (hnview--translate-items pending-items buffer state
                                 hnview--translation-batch-generation)))))

(defun hnview--translate-items (items buffer &optional point-state generation)
  "Translate ITEMS for BUFFER without blocking the current command.
When POINT-STATE is non-nil, use it while rerendering BUFFER.
When GENERATION is non-nil, stop scheduling items if that visible translation
generation is no longer active."
  (let ((queue (copy-sequence items)))
    (cl-labels
        ((step ()
           (when (and queue
                      (buffer-live-p buffer)
                      (hnview--translation-batch-active-p buffer generation))
             (let ((item (pop queue)))
               (with-current-buffer buffer
                 (hnview--set-item-translation-hidden item nil))
               (hnview--translate-item
                item
                (lambda (error _translation)
                  (when error
                    (message "%s" error))
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (hnview--rerender-current-buffer
                       (or point-state t)))))))
             (when queue
               (run-at-time 0 nil #'step)))))
      (run-at-time 0 nil #'step))))

(defun hnview--translation-batch-active-p (buffer generation)
  "Return non-nil when BUFFER still accepts GENERATION work."
  (or (null generation)
      (with-current-buffer buffer
        (and hnview--translate-visible-active-p
             (= generation hnview--translation-batch-generation)))))

(defun hnview--maybe-auto-translate (buffer)
  "Auto-translate BUFFER when enabled."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (or hnview-translate-by-default
                (and (derived-mode-p 'hnview-feed-mode)
                     hnview-auto-translate-feed)
                (and (or (derived-mode-p 'hnview-thread-mode)
                         (derived-mode-p 'hnview-inbox-mode)
                         (derived-mode-p 'hnview-profile-mode))
                     hnview-auto-translate-thread))
        (hnview--translate-items (hnview--visible-buffer-items) buffer)))))

(defun hnview--visible-buffer-items ()
  "Return unique hnview items visible in the current buffer."
  (let ((seen (make-hash-table :test #'eql))
        (items nil))
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (when-let* ((item (get-text-property (point) 'hnview-item))
                    (id (plist-get item :id)))
          (unless (gethash id seen)
            (puthash id t seen)
            (push item items)))
        (goto-char (or (next-single-property-change (point) 'hnview-item)
                       (point-max)))))
    (nreverse items)))

;;; Modes

(define-derived-mode hnview-feed-mode special-mode "hnview-feed"
  "Major mode for hnview feed buffers."
  (setq-local truncate-lines t)
  (hnview--enable-translation-mode-line)
  (setq-local hnview--hidden-translations
              (make-hash-table :test #'equal)))

(define-derived-mode hnview-thread-mode special-mode "hnview-thread"
  "Major mode for hnview thread buffers."
  (setq-local truncate-lines nil)
  (hnview--enable-translation-mode-line)
  (setq-local hnview--hidden-translations
              (make-hash-table :test #'equal)))

(define-derived-mode hnview-inbox-mode special-mode "hnview-inbox"
  "Major mode for hnview inbox buffers."
  (setq-local truncate-lines nil)
  (hnview--enable-translation-mode-line)
  (setq-local hnview--hidden-translations
              (make-hash-table :test #'equal)))

(define-derived-mode hnview-profile-mode special-mode "hnview-profile"
  "Major mode for hnview profile buffers."
  (setq-local truncate-lines nil)
  (setq-local mode-name (hnview--profile-mode-name hnview--profile-section))
  (hnview--enable-translation-mode-line)
  (setq-local hnview--hidden-translations
              (make-hash-table :test #'equal)))

(define-derived-mode hnview-reply-mode text-mode "hnview-reply"
  "Major mode for composing Hacker News replies."
  (setq-local require-final-newline nil))

(provide 'hnview)

;;; hnview.el ends here
