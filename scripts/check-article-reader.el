;;; check-article-reader.el --- Local article extraction checks -*- lexical-binding: t; -*-

;; This script is intentionally local-only: it caches downloaded HTML under a
;; gitignored directory and checks hnview's extraction against compact rules.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'hnview)

(declare-function plz "plz")

(defconst hnview-article-check-root-directory
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name default-directory))))
  "Repository root directory for article reader checks.")

(defconst hnview-article-check-cache-directory
  (expand-file-name
   (or (getenv "HNVIEW_ARTICLE_CHECK_CACHE")
       "test/local-fixtures/articles")
   hnview-article-check-root-directory)
  "Directory used for local article HTML cache.")

(defconst hnview-article-check-cases
  '((:name "apnews-poland"
     :url "https://apnews.com/article/poland-economy-growth-g20-gdp-26fe06e120398410f8d773ba5661e7aa"
     :file "apnews-poland.html"
     :source-class "richtextstorybody richtextbody"
     :byline "Claudia Ciobanu, David Mchugh"
     :contains ("POZNAN, Poland (AP)"
                "A generation ago, Poland rationed sugar and flour")
     :excludes ("TOP STORIES"
                "SECTIONS"
                "UAE reports drone and missile attack")
     :min-images 1)
    (:name "theverge-canvas"
     :url "https://www.theverge.com/tech/926458/canvas-shinyhunters-breach"
     :file "theverge-canvas.html"
     :source-class "hnview-json-ld-article"
     :byline "Emma Roth, Jess Weatherbed"
     :contains ("The Instructure-owned learning management platform"
                "ShinyHunters has breached Instructure")
     :excludes ("A massive outage of the learning platform started"
                "by Emma Roth and Jess Weatherbed"
                "Skip to main content")
     :max-images 1)
    (:name "jefftk-vulnerability-cultures"
     :url "https://www.jefftk.com/p/ai-is-breaking-two-vulnerability-cultures"
     :file "jefftk-vulnerability-cultures.html"
     :source-class "pt"
     :contains ("A week ago the"
                "Copy Fail vulnerability came out"
                "It's interesting to see the tension here")
     :excludes ("Jeff Kaufman"
                "Posts RSS"
                "Contact"
                "More Posts"
                "Recent posts on blogs I like")))
  "Article reader checks that use local cached HTML.")

(defun hnview-article-check--arg-p (arg)
  "Return non-nil when command line ARG was provided."
  (member arg command-line-args-left))

(defun hnview-article-check--arg-number (prefix default)
  "Return numeric argument with PREFIX, or DEFAULT."
  (catch 'value
    (dolist (arg command-line-args-left default)
      (when (string-prefix-p prefix arg)
        (throw 'value
               (string-to-number
                (string-remove-prefix prefix arg)))))))

(defun hnview-article-check--cache-file (case)
  "Return the local cache file for CASE."
  (expand-file-name (plist-get case :file)
                    hnview-article-check-cache-directory))

(defun hnview-article-check--fetch (case)
  "Fetch CASE URL into its local cache file."
  (let ((url (plist-get case :url))
        (file (hnview-article-check--cache-file case)))
    (hnview-article-check--fetch-url url file)))

(defun hnview-article-check--fetch-url (url file)
  "Fetch URL into FILE."
  (let ((temporary-file (make-temp-file "hnview-article-check")))
    (make-directory (file-name-directory file) t)
    (delete-file temporary-file)
    (message "Fetching %s" url)
    (unwind-protect
        (progn
          (hnview-article-check--plz
           url
           :as `(file ,temporary-file))
          (rename-file temporary-file file t))
      (when (file-exists-p temporary-file)
        (delete-file temporary-file))))
  file)

(defun hnview-article-check--html (case fetch)
  "Return cached HTML for CASE, fetching first when FETCH is non-nil."
  (let ((file (hnview-article-check--cache-file case)))
    (when (or fetch (not (file-readable-p file)))
      (unless fetch
        (user-error "Missing %s; rerun with --fetch" file))
      (hnview-article-check--fetch case))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun hnview-article-check--fail (case format-string &rest args)
  "Signal a readable check failure for CASE using FORMAT-STRING and ARGS."
  (error "%s: %s"
         (plist-get case :name)
         (apply #'format format-string args)))

(defun hnview-article-check--assert-text (case text)
  "Assert CASE contains and excludes the expected TEXT snippets."
  (dolist (snippet (plist-get case :contains))
    (unless (string-match-p (regexp-quote snippet) text)
      (hnview-article-check--fail case "missing text: %s" snippet)))
  (dolist (snippet (plist-get case :excludes))
    (when (string-match-p (regexp-quote snippet) text)
      (hnview-article-check--fail case "unexpected text: %s" snippet))))

(defun hnview-article-check--assert-metadata (case article content)
  "Assert metadata expectations for CASE against ARTICLE and CONTENT."
  (when-let* ((expected (plist-get case :source-class)))
    (let ((actual (hnview--readability-attribute-text content)))
      (unless (equal actual expected)
        (hnview-article-check--fail
         case "source class %S, expected %S" actual expected))))
  (when-let* ((expected (plist-get case :byline)))
    (let ((actual (plist-get article :byline)))
      (unless (equal actual expected)
        (hnview-article-check--fail
         case "byline %S, expected %S" actual expected)))))

(defun hnview-article-check--assert-images (case content)
  "Assert image-count expectations for CASE against CONTENT."
  (let ((images (length (dom-by-tag content 'img))))
    (when-let* ((minimum (plist-get case :min-images)))
      (when (< images minimum)
        (hnview-article-check--fail
         case "images %d, expected at least %d" images minimum)))
    (when-let* ((maximum (plist-get case :max-images)))
      (when (> images maximum)
        (hnview-article-check--fail
         case "images %d, expected at most %d" images maximum)))))

(defun hnview-article-check-run (&optional fetch)
  "Run local article reader checks.
When FETCH is non-nil, refresh the local HTML cache before checking."
  (let ((passed 0))
    (dolist (case hnview-article-check-cases)
      (let* ((html (hnview-article-check--html case fetch))
             (article (hnview--readability-extract
                       html (plist-get case :url)))
             (content (plist-get article :content-dom))
             (text (hnview--readability-node-text content)))
        (hnview-article-check--assert-metadata case article content)
        (hnview-article-check--assert-images case content)
        (hnview-article-check--assert-text case text)
        (cl-incf passed)
        (message "ok: %s" (plist-get case :name))))
    (message "Article reader checks passed: %d" passed)))

(defun hnview-article-check--json-url (url)
  "Return parsed JSON from URL."
  (json-parse-string
   (hnview-article-check--plz url :as 'string)
   :object-type 'plist
   :array-type 'list
   :null-object nil
   :false-object nil))

(defun hnview-article-check--plz (url &rest args)
  "Fetch URL synchronously through plz with ARGS."
  (hnview--ensure-plz)
  (condition-case err
      (apply #'plz 'get url
             :headers (hnview-article-check--headers)
             :then 'sync
             :timeout 30
             args)
    (error
     (error "Could not fetch %s: %s" url (error-message-string err)))))

(defun hnview-article-check--headers ()
  "Return HTTP headers for article diagnostics."
  '(("User-Agent" . "Mozilla/5.0 (compatible; hnview article checker)")))

(defun hnview-article-check--hn-item (id)
  "Return Hacker News item ID as a plist."
  (hnview-article-check--json-url
   (format "https://hacker-news.firebaseio.com/v0/item/%s.json" id)))

(defun hnview-article-check--hn-top-stories (limit)
  "Return up to LIMIT Hacker News top stories that have external URLs."
  (let ((ids (hnview-article-check--json-url
              "https://hacker-news.firebaseio.com/v0/topstories.json"))
        stories)
    (catch 'done
      (dolist (id ids)
        (let ((item (hnview-article-check--hn-item id)))
          (when-let* ((url (plist-get item :url)))
            (when (and (equal (plist-get item :type) "story")
                       (string-match-p "\\`https?://" url))
              (push item stories)
              (when (>= (length stories) limit)
                (throw 'done nil)))))))
    (nreverse stories)))

(defun hnview-article-check--story-cache-file (story)
  "Return local cache file for HN STORY."
  (let* ((id (plist-get story :id))
         (url (plist-get story :url))
         (hash (substring (secure-hash 'sha1 url) 0 10)))
    (expand-file-name
     (format "hn-top-%s-%s.html" id hash)
     hnview-article-check-cache-directory)))

(defun hnview-article-check--story-host (story)
  "Return host for HN STORY URL."
  (condition-case nil
      (hnview--url-host (plist-get story :url))
    (error "")))

(defun hnview-article-check--suspicious-snippets ()
  "Return text snippets that suggest article extraction failed."
  '("Skip to main content"
    "Subscribe to continue"
    "Enable JavaScript"
    "JavaScript is disabled"
    "Access Denied"
    "Just a moment"
    "Checking your browser"
    "Sign in to continue"))

(defun hnview-article-check--warnings (article content text)
  "Return warning strings for extracted ARTICLE CONTENT and TEXT."
  (let (warnings)
    (when (< (length text) hnview-article-min-text-length)
      (push (format "short text (%d chars)" (length text)) warnings))
    (dolist (snippet (hnview-article-check--suspicious-snippets))
      (when (string-match-p (regexp-quote snippet) text)
        (push (format "contains %S" snippet) warnings)))
    (when (> (length (dom-by-tag content 'img)) 12)
      (push (format "many images (%d)" (length (dom-by-tag content 'img)))
            warnings))
    (unless (plist-get article :title)
      (push "missing title" warnings))
    (nreverse warnings)))

(defun hnview-article-check--run-story (story fetch)
  "Run article extraction diagnostics for HN STORY.
When FETCH is non-nil, refresh the cached HTML."
  (let* ((url (plist-get story :url))
         (file (hnview-article-check--story-cache-file story))
         (title (or (plist-get story :title) ""))
         (host (hnview-article-check--story-host story)))
    (condition-case err
        (progn
          (when (or fetch (not (file-readable-p file)))
            (hnview-article-check--fetch-url url file))
          (let* ((html (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))
                 (article (hnview--readability-extract html url))
                 (content (plist-get article :content-dom))
                 (text (hnview--readability-node-text content))
                 (warnings
                  (hnview-article-check--warnings article content text))
                 (status (if warnings "warn" "ok")))
            (message "%s: %s %s len=%d images=%d source=%S title=%s"
                     status
                     (plist-get story :id)
                     host
                     (length text)
                     (length (dom-by-tag content 'img))
                     (hnview--readability-attribute-text content)
                     title)
            (dolist (warning warnings)
              (message "  - %s" warning))
            (list :status status
                  :warnings warnings)))
      (error
       (message "fail: %s %s title=%s error=%s"
                (plist-get story :id) host title
                (error-message-string err))
       (list :status "fail"
             :warnings (list (error-message-string err)))))))

(defun hnview-article-check-run-hn-top (&optional fetch limit)
  "Run article extraction diagnostics against current HN top stories.
When FETCH is non-nil, refresh cached HTML.  LIMIT is the number of external
stories to check."
  (let* ((limit (or limit 30))
         (stories (hnview-article-check--hn-top-stories limit))
         (ok 0)
         (warn 0)
         (fail 0))
    (message "Checking %d Hacker News top stories" (length stories))
    (dolist (story stories)
      (pcase (plist-get (hnview-article-check--run-story story fetch) :status)
        ("ok" (cl-incf ok))
        ("warn" (cl-incf warn))
        (_ (cl-incf fail))))
    (message "HN top article checks: ok=%d warn=%d fail=%d"
             ok warn fail)))

(when (and noninteractive
           (not (bound-and-true-p byte-compile-current-file)))
  (if (hnview-article-check--arg-p "--hn-top")
      (hnview-article-check-run-hn-top
       (hnview-article-check--arg-p "--fetch")
       (hnview-article-check--arg-number "--limit=" 30))
    (hnview-article-check-run (hnview-article-check--arg-p "--fetch"))))

;;; check-article-reader.el ends here
