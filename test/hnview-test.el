;;; hnview-test.el --- Tests for hnview -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for hnview.

;;; Code:

(require 'ert)
(require 'hnview)

(defmacro hnview-test-with-db (&rest body)
  "Run BODY with an isolated hnview SQLite database."
  (declare (indent 0))
  `(let* ((file (make-temp-file "hnview-test" nil ".sqlite"))
          (hnview-database-file file)
          (hnview-state-file (make-temp-file "hnview-state"))
          (hnview--db nil)
          (hnview--translations (make-hash-table :test #'equal))
          (hnview--bookmarks (make-hash-table :test #'eql))
          (hnview--upvotes (make-hash-table :test #'eql))
          (hnview--state-loaded-p nil))
     (unwind-protect
         (progn ,@body)
       (when hnview--db
         (ignore-errors (sqlite-close hnview--db)))
       (when (file-exists-p file)
         (delete-file file))
       (when (file-exists-p hnview-state-file)
         (delete-file hnview-state-file)))))

(ert-deftest hnview-domain-removes-www ()
  "Story domains should omit leading www."
  (should (equal (hnview--domain '(:url "https://www.example.com/a"))
                 "example.com")))

(ert-deftest hnview-relative-time-formats-units ()
  "Relative time should use specific time units."
  (should (equal (hnview--relative-time 1000 1030) "just now"))
  (should (equal (hnview--relative-time 1000 1120) "2 minutes ago"))
  (should (equal (hnview--relative-time 1000 8200) "2 hours ago")))

(ert-deftest hnview-vector-list-converts-vector ()
  "Vector conversion should preserve element order."
  (should (equal (hnview--vector-list [a b c]) '(a b c))))

(ert-deftest hnview-feed-mode-has-feed-switch-keys ()
  "Feed buffers should switch feeds through key bindings."
  (should (eq (lookup-key hnview-feed-mode-map (kbd "f"))
              #'hnview-switch-feed))
  (should (eq (lookup-key hnview-feed-mode-map (kbd "e"))
              #'hnview-open-url-eww))
  (should (eq (lookup-key hnview-feed-mode-map (kbd "r"))
              #'hnview-reply-at-point))
  (should (eq (lookup-key hnview-feed-mode-map (kbd "u"))
              #'hnview-vote-up))
  (should (eq (lookup-key hnview-feed-mode-map (kbd "1"))
              #'hnview-top))
  (should (eq (lookup-key hnview-feed-mode-map (kbd "7"))
              #'hnview-active)))

(ert-deftest hnview-thread-mode-has-comment-loading-keys ()
  "Thread buffers should expose comment loading commands."
  (should (eq (lookup-key hnview-thread-mode-map (kbd "+"))
              #'hnview-load-more-comments))
  (should (eq (lookup-key hnview-thread-mode-map (kbd "*"))
              #'hnview-load-all-comments))
  (should (eq (lookup-key hnview-thread-mode-map (kbd "r"))
              #'hnview-reply-at-point))
  (should (eq (lookup-key hnview-thread-mode-map (kbd "u"))
              #'hnview-vote-up))
  (should (eq (lookup-key hnview-thread-mode-map (kbd "TAB"))
              #'hnview-toggle-comment-fold)))

(ert-deftest hnview-inbox-mode-has-navigation-keys ()
  "Inbox buffers should expose navigation and refresh commands."
  (should (eq (lookup-key hnview-inbox-mode-map (kbd "g"))
              #'hnview-inbox))
  (should (eq (lookup-key hnview-inbox-mode-map (kbd "RET"))
              #'hnview-open-url))
  (should (eq (lookup-key hnview-inbox-mode-map (kbd "r"))
              #'hnview-reply-at-point))
  (should (eq (lookup-key hnview-inbox-mode-map (kbd "u"))
              #'hnview-vote-up)))

(ert-deftest hnview-reply-mode-has-compose-keys ()
  "Reply buffers should expose translation and submission commands."
  (should (eq (lookup-key hnview-reply-mode-map (kbd "C-c C-t"))
              #'hnview-translate-reply))
  (should (eq (lookup-key hnview-reply-mode-map (kbd "C-c C-c"))
              #'hnview-submit-reply))
  (should (eq (lookup-key hnview-reply-mode-map (kbd "C-c C-k"))
              #'hnview-cancel-reply)))

(ert-deftest hnview-item-url-prefers-original-url ()
  "Story URL lookup should prefer original story URLs."
  (should (equal (hnview--item-url '(:id 1 :url "https://example.com"))
                 "https://example.com")))

(ert-deftest hnview-item-url-falls-back-to-hn-item ()
  "Story URL lookup should fall back to Hacker News items."
  (should (equal (hnview--item-url '(:id 1))
                 "https://news.ycombinator.com/item?id=1")))

(ert-deftest hnview-open-url-eww-opens-item-url ()
  "Opening in EWW should use the item URL at point."
  (let ((story '(:id 1 :type "story" :url "https://example.com"))
        (opened nil))
    (cl-letf (((symbol-function 'eww)
               (lambda (url &rest _args)
                 (setq opened url))))
      (with-temp-buffer
        (hnview--insert-story story 1)
        (goto-char (point-min))
        (hnview-open-url-eww)))
    (should (equal opened "https://example.com"))))

(ert-deftest hnview-translation-key-uses-target-language ()
  "Translation keys should change when target language changes."
  (let* ((item '(:id 1 :type "story" :title "Hello"))
         (hnview-translate-target-language "zh-CN")
         (first (hnview--translation-key item "Hello"))
         (hnview-translate-target-language "ja-JP")
         (second (hnview--translation-key item "Hello")))
    (should-not (equal first second))))

(ert-deftest hnview-sqlite-persists-translation-cache ()
  "SQLite should persist translation cache rows."
  (hnview-test-with-db
    (let ((story '(:id 42 :type "story" :title "A title")))
      (hnview--ensure-db)
      (hnview--persist-translation story 'title "A title" "一个标题")
      (clrhash hnview--translations)
      (hnview--load-db-state)
      (should (equal (hnview--cached-translation story 'title "A title")
                     "一个标题")))))

(ert-deftest hnview-sqlite-prune-removes-old-cache ()
  "Pruning should remove expired translation cache rows."
  (hnview-test-with-db
    (let ((hnview-translation-cache-ttl-days 1)
          (story '(:id 42 :type "story" :title "A title")))
      (hnview--ensure-db)
      (hnview--persist-translation story 'title "A title" "一个标题")
      (sqlite-execute
       hnview--db
       "UPDATE translations SET last_accessed_at = ?"
       (list (- (hnview--unix-time) (* 2 86400))))
      (hnview-prune-translation-cache)
      (should-not (hnview--cached-translation story 'title "A title")))))

(ert-deftest hnview-sqlite-prune-enforces-max-entries ()
  "Pruning should keep only the newest cache entries."
  (hnview-test-with-db
    (let ((hnview-translation-cache-ttl-days 0)
          (hnview-translation-cache-max-entries 1)
          (first '(:id 1 :type "story" :title "First"))
          (second '(:id 2 :type "story" :title "Second")))
      (hnview--ensure-db)
      (hnview--persist-translation first 'title "First" "第一")
      (hnview--persist-translation second 'title "Second" "第二")
      (sqlite-execute
       hnview--db
       "UPDATE translations SET last_accessed_at = ? WHERE item_id = ?"
       (list (- (hnview--unix-time) 10) 1))
      (hnview-prune-translation-cache)
      (should-not (hnview--cached-translation first 'title "First"))
      (should (equal (hnview--cached-translation second 'title "Second")
                     "第二")))))

(ert-deftest hnview-sqlite-clear-removes-cache ()
  "Clearing the cache should remove all cached translations."
  (hnview-test-with-db
    (let ((story '(:id 42 :type "story" :title "A title")))
      (hnview--ensure-db)
      (hnview--persist-translation story 'title "A title" "一个标题")
      (hnview-clear-translation-cache)
      (should-not (hnview--cached-translation story 'title "A title")))))

(ert-deftest hnview-sqlite-persists-cookie-header ()
  "SQLite cookies should be available as request headers."
  (hnview-test-with-db
    (hnview--upsert-cookie
     '(:host "news.ycombinator.com" :path "/" :name "user"
       :value "abc" :secure t :http-only t :host-only t))
    (should (equal (hnview--cookie-header
                    "https://news.ycombinator.com/item?id=1")
                   "user=abc"))
    (should-not (hnview--cookie-header
                 "http://news.ycombinator.com/item?id=1"))))

(ert-deftest hnview-cookie-path-matches-request-path ()
  "Cookie path matching should avoid unrelated prefix matches."
  (hnview-test-with-db
    (hnview--upsert-cookie
     '(:host "news.ycombinator.com" :path "/foo" :name "user"
       :value "abc" :secure t :http-only t :host-only t))
    (should (equal (hnview--cookie-header
                    "https://news.ycombinator.com/foo/bar")
                   "user=abc"))
    (should-not (hnview--cookie-header
                 "https://news.ycombinator.com/foobar"))))

(ert-deftest hnview-set-cookie-parser-handles-hn-cookie ()
  "Set-Cookie parsing should preserve HN cookie attributes."
  (let ((cookie (hnview--parse-set-cookie
                 "https://news.ycombinator.com/login"
                 "user=abc; Path=/; Secure; HttpOnly; Max-Age=3600")))
    (should (equal (plist-get cookie :host) "news.ycombinator.com"))
    (should (equal (plist-get cookie :path) "/"))
    (should (equal (plist-get cookie :name) "user"))
    (should (equal (plist-get cookie :value) "abc"))
    (should (plist-get cookie :secure))
    (should (plist-get cookie :http-only))
    (should (plist-get cookie :host-only))
    (should (> (plist-get cookie :expires-at) (hnview--unix-time)))))

(ert-deftest hnview-plz-request-sends-and-stores-sqlite-cookies ()
  "plz requests should send stored cookies and store response cookies."
  (hnview-test-with-db
    (hnview--upsert-cookie
     '(:host "news.ycombinator.com" :path "/" :name "session"
       :value "old" :secure t :http-only t :host-only t))
    (let ((headers nil)
          (result nil)
          (error nil))
      (cl-letf (((symbol-function 'plz)
                 (lambda (_method _url &rest args)
                   (setq headers (plist-get args :headers))
                   (funcall
                    (plist-get args :then)
                    'fake-response)))
                ((symbol-function 'plz-response-body)
                 (lambda (_response) "ok"))
                ((symbol-function 'plz-response-headers)
                 (lambda (_response)
                   '((set-cookie . "user=abc; Path=/; Secure; HttpOnly")))))
        (hnview--url-text
         "https://news.ycombinator.com/login"
         (lambda (err body)
           (setq error err)
           (setq result body))))
      (should-not error)
      (should (equal result "ok"))
      (should (equal (cdr (assoc "Cookie" headers)) "session=old"))
      (let ((cookies (split-string
                      (hnview--cookie-header
                       "https://news.ycombinator.com/item?id=1")
                      "; ")))
        (should (member "session=old" cookies))
        (should (member "user=abc" cookies))))))

(ert-deftest hnview-ensure-plz-reports-load-errors ()
  "Missing or broken plz should produce a user-facing error."
  (let ((original-fboundp (symbol-function 'fboundp))
        (original-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (symbol)
                 (if (eq symbol 'plz)
                     nil
                   (funcall original-fboundp symbol))))
              ((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'plz)
                     (error "load failure")
                   (funcall original-require feature filename noerror)))))
      (should-error (hnview--ensure-plz) :type 'user-error))))

(ert-deftest hnview-hn-url-builds-query-url ()
  "HN URL helpers should build absolute URLs."
  (let ((hnview-hn-base-url "https://news.ycombinator.com"))
    (should (equal (hnview--hn-url "reply" '(("id" . "42")))
                   "https://news.ycombinator.com/reply?id=42"))
    (should (equal (hnview--hn-action-url "comment")
                   "https://news.ycombinator.com/comment"))))

(ert-deftest hnview-comment-form-parses-hidden-fields ()
  "Comment form parsing should preserve HN hidden fields."
  (let* ((html "<html><body><form action=\"comment\" method=\"post\"><input type=\"hidden\" name=\"parent\" value=\"1\"><input type=\"hidden\" name=\"hmac\" value=\"abc\"><textarea name=\"text\"></textarea><input type=\"submit\" value=\"reply\"></form></body></html>")
         (form (hnview--comment-form html)))
    (should (equal (plist-get form :action) "comment"))
    (should (equal (hnview--form-field form "parent") "1"))
    (should (equal (hnview--form-field form "hmac") "abc"))
    (should (equal (hnview--form-field form "text") ""))))

(ert-deftest hnview-form-set-field-replaces-existing-value ()
  "Setting a form field should keep other HN fields intact."
  (let* ((form '(:action "comment" :fields
                 (("parent" . "1") ("hmac" . "abc") ("text" . ""))))
         (updated (hnview--form-set-field form "text" "hello")))
    (should (equal (hnview--form-field updated "parent") "1"))
    (should (equal (hnview--form-field updated "hmac") "abc"))
    (should (equal (hnview--form-field updated "text") "hello"))))

(ert-deftest hnview-login-success-detects-user-and-logout ()
  "Login success detection should require username and logout markers."
  (should (hnview--login-success-p
           "<a href=\"user?id=alice\">alice</a><a href=\"logout?auth=x\">logout</a>"
           "alice"))
  (should-not (hnview--login-success-p
               "<a href=\"login\">login</a>"
               "alice")))

(ert-deftest hnview-submit-reply-posts-parsed-comment-form ()
  "Reply submission should fetch a reply form and post text through it."
  (let ((posted-url nil)
        (posted-fields nil)
        (result nil)
        (error nil)
        (hnview-hn-base-url "https://news.ycombinator.com"))
    (cl-letf (((symbol-function 'hnview--url-text)
               (lambda (url callback &optional _method _fields)
                 (should (equal url
                                "https://news.ycombinator.com/reply?id=1"))
                 (funcall callback nil
                          "<form action=\"comment\" method=\"post\"><input type=\"hidden\" name=\"parent\" value=\"1\"><input type=\"hidden\" name=\"hmac\" value=\"abc\"><textarea name=\"text\"></textarea></form>")))
              ((symbol-function 'hnview--post-form)
               (lambda (url fields callback)
                 (setq posted-url url)
                 (setq posted-fields fields)
                 (funcall callback nil "<html>ok</html>"))))
      (hnview--submit-reply
       '(:id 1 :type "comment") "hello"
       (lambda (err html)
         (setq error err)
         (setq result html))))
    (should-not error)
    (should (equal result "<html>ok</html>"))
    (should (equal posted-url "https://news.ycombinator.com/comment"))
    (should (equal (cdr (assoc "parent" posted-fields)) "1"))
    (should (equal (cdr (assoc "hmac" posted-fields)) "abc"))
    (should (equal (cdr (assoc "text" posted-fields)) "hello"))))

(ert-deftest hnview-vote-url-includes-direction-and-goto ()
  "Vote URLs should include item ID, direction, and thread goto."
  (let ((hnview-hn-base-url "https://news.ycombinator.com")
        (hnview--thread-root '(:id 10 :type "story")))
    (should (equal (hnview--vote-url '(:id 42 :type "comment") 'up)
                   "https://news.ycombinator.com/vote?id=42&how=up&goto=item%3Fid%3D10"))))

(ert-deftest hnview-vote-item-reports-login-page ()
  "Voting should report HN login pages as login-required errors."
  (let ((error nil))
    (cl-letf (((symbol-function 'hnview--url-text)
               (lambda (_url callback)
                 (funcall callback nil
                          "<html><body><b>Login</b><input name=\"acct\"></body></html>"))))
      (hnview--vote-item
       '(:id 42 :type "comment") 'up
       (lambda (err _html)
         (setq error err))))
    (should (equal error "HN login required; run M-x hnview-login"))))

(ert-deftest hnview-vote-up-marks-comment-after-hn-success ()
  "Successful HN upvotes should show a session-local comment marker."
  (let* ((comment '(:id 42 :type "comment" :by "alice" :text "hello"))
         (story `(:id 10 :type "story" :title "Story"
                  :hnview-children (,comment)))
         (hnview--upvotes (make-hash-table :test #'eql))
         (voted nil))
    (cl-letf (((symbol-function 'hnview--vote-item)
               (lambda (item direction callback)
                 (setq voted (list item direction))
                 (funcall callback nil "<html>ok</html>"))))
      (with-temp-buffer
        (hnview-thread-mode)
        (setq-local hnview--thread-root story)
        (hnview--render-thread)
        (goto-char (point-min))
        (search-forward "alice")
        (hnview-vote-up)
        (should (equal voted (list comment 'up)))
        (should (gethash 42 hnview--upvotes))
        (should (string-match-p "△ alice" (buffer-string)))))))

(ert-deftest hnview-login-posts-auth-source-credentials ()
  "Login should submit HN credentials from explicit arguments."
  (let ((posted-fields nil)
        (hnview-username nil))
    (cl-letf (((symbol-function 'hnview--post-form)
               (lambda (_url fields callback)
                 (setq posted-fields fields)
                 (funcall callback nil
                          "<a href=\"user?id=alice\">alice</a><a href=\"logout?auth=x\">logout</a>"))))
      (hnview-login "alice" "secret"))
    (should (equal hnview-username "alice"))
    (should (equal (cdr (assoc "acct" posted-fields)) "alice"))
    (should (equal (cdr (assoc "pw" posted-fields)) "secret"))))

(ert-deftest hnview-login-uses-auth-source-credentials ()
  "Interactive login should read credentials from auth-source."
  (let ((posted-fields nil)
        (hnview-username nil))
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (should (equal (plist-get args :host)
                                "news.ycombinator.com"))
                 (list (list :user "alice"
                             :secret (lambda () "secret")))))
              ((symbol-function 'read-passwd)
               (lambda (&rest _args)
                 (error "read-passwd should not be called")))
              ((symbol-function 'hnview--post-form)
               (lambda (_url fields callback)
                 (setq posted-fields fields)
                 (funcall callback nil
                          "<a href=\"user?id=alice\">alice</a><a href=\"logout?auth=x\">logout</a>"))))
      (hnview-login))
    (should (equal hnview-username "alice"))
    (should (equal (cdr (assoc "acct" posted-fields)) "alice"))
    (should (equal (cdr (assoc "pw" posted-fields)) "secret"))))

(ert-deftest hnview-translation-segments-split-story-title-and-text ()
  "Story translation should operate on title and text separately."
  (should (equal (hnview--translation-segments
                  '(:id 1 :type "story" :title "Title" :text "Body"))
                 '((title . "Title") (text . "Body")))))

(ert-deftest hnview-html-to-text-collapses-soft-wrapped-lines ()
  "HTML conversion should let Emacs do visual wrapping for paragraphs."
  (let* ((words (make-list 35 "word"))
         (html (string-join words " "))
         (text (hnview--html-to-text html)))
    (should-not (string-match-p "\n" text))
    (should (equal text html))))

(ert-deftest hnview-html-to-text-preserves-blank-line-paragraphs ()
  "HTML conversion should keep blank lines as paragraph separators."
  (should (equal (hnview--html-to-text "First paragraph<p>Second paragraph")
                 "First paragraph\n\nSecond paragraph")))

(ert-deftest hnview-insert-translated-lines-collapses-soft-wraps ()
  "Translated comments should follow the same paragraph layout as originals."
  (with-temp-buffer
    (hnview--insert-translated-lines
     '(:id 1 :type "comment") "first line\nsecond line\n\nthird line"
     4 'default)
    (should (equal (buffer-string)
                   "    first line second line\n\n    third line\n"))))

(ert-deftest hnview-comment-quote-lines-render-as-quotes ()
  "Comment quote markers should render as quote blocks."
  (with-temp-buffer
    (hnview--insert-source-lines
     '(:id 1 :type "comment") "> quoted line\n\nreply line" 4 'default)
    (should (equal (buffer-string)
                   "    ▮ quoted line\n\n    reply line\n"))
    (goto-char (point-min))
    (should (search-forward "▮" nil t))
    (should (eq (get-text-property (match-beginning 0) 'face)
                'hnview-quote))
    (should-not (search-forward "> quoted" nil t))))

(ert-deftest hnview-insert-story-adds-item-property ()
  "Rendered stories should carry the hnview item text property."
  (let ((story '(:id 42 :type "story" :title "A title"
                 :url "https://example.com" :score 5
                 :by "alice" :time 1000 :descendants 3)))
    (with-temp-buffer
      (hnview--insert-story story 1)
      (goto-char (point-min))
      (should (search-forward "A title" nil t))
      (should (equal (get-text-property (point) 'hnview-item) story)))))

(ert-deftest hnview-insert-story-shows-bookmark-marker ()
  "Bookmarked stories should carry a compact marker."
  (let ((story '(:id 42 :type "story" :title "A title"))
        (hnview--bookmarks (make-hash-table :test #'eql)))
    (puthash 42 t hnview--bookmarks)
    (with-temp-buffer
      (hnview--insert-story story 1)
      (should (string-match-p " 1\\. \\* A title" (buffer-string))))))

(ert-deftest hnview-insert-comment-shows-bookmark-marker ()
  "Bookmarked comments should carry a compact marker."
  (let ((comment '(:id 42 :type "comment" :by "alice" :text "hello"))
        (hnview--bookmarks (make-hash-table :test #'eql)))
    (puthash 42 t hnview--bookmarks)
    (with-temp-buffer
      (hnview--insert-comment comment 0)
      (should (string-match-p "\\* alice" (buffer-string))))))

(ert-deftest hnview-comment-author-aligns-with-text ()
  "Comment metadata should start in the same column as comment text."
  (let ((comment '(:id 42 :type "comment" :by "alice" :text "hello")))
    (with-temp-buffer
      (hnview--insert-comment comment 0)
      (goto-char (point-min))
      (search-forward "alice")
      (let ((author-column (save-excursion
                             (goto-char (match-beginning 0))
                             (current-column))))
        (search-forward "hello")
        (should (= author-column
                   (save-excursion
                     (goto-char (match-beginning 0))
                     (current-column))))))))

(ert-deftest hnview-parent-comment-author-aligns-with-text ()
  "Parent comment metadata should align with text after vote controls."
  (let ((comment '(:id 42 :type "comment" :by "alice" :text "hello"
                   :hnview-children
                   ((:id 43 :type "comment" :by "bob" :text "child")))))
    (with-temp-buffer
      (hnview--insert-comment comment 0)
      (goto-char (point-min))
      (search-forward "alice")
      (let ((author-column (save-excursion
                             (goto-char (match-beginning 0))
                             (current-column))))
        (search-forward "hello")
        (should (= author-column
                   (save-excursion
                     (goto-char (match-beginning 0))
                     (current-column))))))))

(ert-deftest hnview-story-domain-uses-domain-face ()
  "Rendered story domains should use the domain face."
  (let ((story '(:id 42 :type "story" :title "A title"
                 :url "https://example.com" :score 5)))
    (with-temp-buffer
      (hnview--insert-story story 1)
      (goto-char (point-min))
      (should (search-forward "example.com" nil t))
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'hnview-domain))
      (should (search-forward "5 points" nil t))
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'hnview-meta)))))

(ert-deftest hnview-domain-face-is-orange-and-normal ()
  "Domain links should be orange and not bold."
  (should (equal (face-attribute 'hnview-domain :foreground nil)
                 "#d98245"))
  (should (eq (face-attribute 'hnview-domain :weight nil)
              'normal)))

(ert-deftest hnview-story-domain-aligns-with-title ()
  "Rendered story domains should start in the same column as titles."
  (let ((story '(:id 42 :type "story" :title "A title"
                 :url "https://example.com" :score 5)))
    (with-temp-buffer
      (hnview--insert-story story 1)
      (goto-char (point-min))
      (search-forward "A title")
      (let ((title-column (save-excursion
                            (goto-char (match-beginning 0))
                            (current-column))))
        (search-forward "example.com")
        (should (= title-column
                   (save-excursion
                     (goto-char (match-beginning 0))
                     (current-column))))))))

(ert-deftest hnview-translated-story-title-replaces-original ()
  "Translated story titles should replace originals in place."
  (let* ((story '(:id 42 :type "story" :title "A title"))
         (hnview--translations (make-hash-table :test #'equal))
         (hnview--hidden-translations (make-hash-table :test #'equal)))
    (puthash (hnview--translation-key story "A title" 'title)
             "一个标题" hnview--translations)
    (with-temp-buffer
      (hnview--insert-story story 1)
      (goto-char (point-min))
      (should (search-forward "一个标题" nil t))
      (should-not (search-forward "显示原文" nil t))
      (should-not (search-forward "A title" nil t)))))

(ert-deftest hnview-hidden-story-translation-shows-original ()
  "Hidden story translations should render the original title."
  (let* ((story '(:id 42 :type "story" :title "A title"))
         (hnview--translations (make-hash-table :test #'equal))
         (hnview--hidden-translations (make-hash-table :test #'equal)))
    (puthash (hnview--translation-key story "A title" 'title)
             "一个标题" hnview--translations)
    (hnview--set-item-translation-hidden story t)
    (with-temp-buffer
      (hnview--insert-story story 1)
      (goto-char (point-min))
      (should (search-forward "A title" nil t))
      (should-not (search-forward "一个标题" nil t))
      (should-not (search-forward "显示原文" nil t)))))

(ert-deftest hnview-maybe-auto-translate-feed-calls-translator ()
  "Auto-translation should translate feed items when enabled."
  (let ((hnview-auto-translate-feed t)
        (called nil))
    (cl-letf (((symbol-function 'hnview--translate-items)
               (lambda (items _buffer)
                 (setq called items))))
      (with-temp-buffer
        (hnview-feed-mode)
        (setq-local hnview--stories
                    '((:id 1 :type "story" :title "A title")))
        (hnview--render-feed)
        (hnview--maybe-auto-translate (current-buffer))
        (should (equal called hnview--stories))))))

(ert-deftest hnview-fetch-tree-marks-budget-truncation ()
  "Comment tree fetching should mark nodes truncated when budget is gone."
  (let ((result nil))
    (hnview--fetch-tree
     '(:id 1 :type "story" :title "A title" :kids (2))
     (lambda (tree)
       (setq result tree))
     (list 0))
    (should (plist-get result :hnview-truncated))))

(ert-deftest hnview-tree-truncated-detects-descendant-truncation ()
  "Thread rendering should detect descendant truncation."
  (should (hnview--tree-truncated-p
           '(:id 1 :hnview-children
             ((:id 2 :hnview-truncated t))))))

(ert-deftest hnview-replyable-items-keep-user-items-with-kids ()
  "Inbox scanning should keep user items that have replies."
  (should (equal (hnview--replyable-items
                  '((:id 1 :by "alice" :kids (3))
                    (:id 2 :by "bob" :kids (4))
                    (:id 3 :by "alice"))
                  "alice")
                 '((:id 1 :by "alice" :kids (3))))))

(ert-deftest hnview-cancel-reply-kills-empty-draft ()
  "Cancelling an empty reply draft should kill the reply buffer."
  (let ((buffer (generate-new-buffer "*hnview test reply*")))
    (unwind-protect
        (with-current-buffer buffer
          (hnview-reply-mode)
          (hnview-cancel-reply)
          (should-not (buffer-live-p buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest hnview-render-inbox-inserts-replies ()
  "Inbox rendering should show replies."
  (let ((hnview-username "alice")
        (hnview--inbox-replies
         '((:id 2 :type "comment" :by "bob" :text "hi"
            :hnview-parent (:id 1 :type "comment" :by "alice"
                             :text "parent")))))
    (with-temp-buffer
      (hnview-inbox-mode)
      (hnview--render-inbox)
      (goto-char (point-min))
      (should (search-forward "bob replied" nil t))
      (should (search-forward "hi" nil t)))))

(ert-deftest hnview-set-item-translation-hidden-toggles-all-segments ()
  "Item translation visibility should apply to every segment."
  (let ((story '(:id 42 :type "story" :title "A title" :text "Body"))
        (hnview--hidden-translations (make-hash-table :test #'equal)))
    (hnview--set-item-translation-hidden story t)
    (should (hnview--translation-hidden-p story 'title))
    (should (hnview--translation-hidden-p story 'text))
    (hnview--set-item-translation-hidden story nil)
    (should-not (hnview--translation-hidden-p story 'title))
    (should-not (hnview--translation-hidden-p story 'text))))

(ert-deftest hnview-toggle-translation-at-point-hides-cached-translation ()
  "Toggling a cached translation should hide it."
  (let ((story '(:id 42 :type "story" :title "A title"))
        (hnview--translations (make-hash-table :test #'equal))
        (hnview--state-loaded-p t))
    (with-temp-buffer
      (hnview-feed-mode)
      (puthash (hnview--translation-key story "A title" 'title)
               "一个标题" hnview--translations)
      (setq-local hnview--stories (list story))
      (hnview--render-feed)
      (goto-char (point-min))
      (search-forward "一个标题")
      (hnview-translate-at-point)
      (should (hnview--translation-hidden-p story 'title))
      (goto-char (point-min))
      (search-forward "A title")
      (hnview-translate-at-point)
      (should-not (hnview--translation-hidden-p story 'title)))))

(ert-deftest hnview-toggle-translation-preserves-current-item ()
  "Toggling translation should not move point back to the first item."
  (let ((first '(:id 1 :type "story" :title "First"))
        (second '(:id 2 :type "story" :title "Second"))
        (hnview--translations (make-hash-table :test #'equal))
        (hnview--state-loaded-p t))
    (with-temp-buffer
      (hnview-feed-mode)
      (puthash (hnview--translation-key second "Second" 'title)
               "第二" hnview--translations)
      (setq-local hnview--stories (list first second))
      (hnview--render-feed)
      (goto-char (point-min))
      (search-forward "第二")
      (hnview-translate-at-point)
      (should (equal (plist-get (hnview--item-at-point) :id) 2)))))

(ert-deftest hnview-translate-visible-hides-visible-translations ()
  "T should hide visible translations for every visible item."
  (let ((first '(:id 1 :type "story" :title "First"))
        (second '(:id 2 :type "story" :title "Second"))
        (hnview--translations (make-hash-table :test #'equal))
        (hnview--state-loaded-p t))
    (puthash (hnview--translation-key first "First" 'title)
             "第一" hnview--translations)
    (puthash (hnview--translation-key second "Second" 'title)
             "第二" hnview--translations)
    (with-temp-buffer
      (hnview-feed-mode)
      (setq-local hnview--stories (list first second))
      (hnview--render-feed)
      (goto-char (point-min))
      (search-forward "第二")
      (hnview-translate-visible)
      (should (hnview--translation-hidden-p first 'title))
      (should (hnview--translation-hidden-p second 'title))
      (should (equal (plist-get (hnview--item-at-point) :id) 2))
      (should (save-excursion
                (goto-char (point-min))
                (and (search-forward "First" nil t)
                     (search-forward "Second" nil t))))
      (should-not (save-excursion
                    (goto-char (point-min))
                    (search-forward "第一" nil t))))))

(ert-deftest hnview-translate-visible-shows-hidden-cached-translations ()
  "T should show cached translations when all visible translations are hidden."
  (let ((first '(:id 1 :type "story" :title "First"))
        (second '(:id 2 :type "story" :title "Second"))
        (hnview--translations (make-hash-table :test #'equal))
        (hnview--state-loaded-p t))
    (puthash (hnview--translation-key first "First" 'title)
             "第一" hnview--translations)
    (puthash (hnview--translation-key second "Second" 'title)
             "第二" hnview--translations)
    (with-temp-buffer
      (hnview-feed-mode)
      (setq-local hnview--stories (list first second))
      (hnview--set-item-translation-hidden first t)
      (hnview--set-item-translation-hidden second t)
      (hnview--render-feed)
      (goto-char (point-min))
      (search-forward "Second")
      (hnview-translate-visible)
      (should-not (hnview--translation-hidden-p first 'title))
      (should-not (hnview--translation-hidden-p second 'title))
      (should (equal (plist-get (hnview--item-at-point) :id) 2))
      (should (save-excursion
                (goto-char (point-min))
                (and (search-forward "第一" nil t)
                     (search-forward "第二" nil t)))))))

(ert-deftest hnview-translate-visible-schedules-missing-translations ()
  "T should schedule missing translations instead of starting them inline."
  (let ((story '(:id 1 :type "story" :title "First"))
        (hnview--translations (make-hash-table :test #'equal))
        (hnview--state-loaded-p t)
        scheduled
        translated)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_secs _repeat function &rest args)
                 (push (lambda () (apply function args)) scheduled)
                 'timer))
              ((symbol-function 'hnview--translate-item)
               (lambda (_item _callback)
                 (setq translated t))))
      (with-temp-buffer
        (hnview-feed-mode)
        (setq-local hnview--stories (list story))
        (hnview--render-feed)
        (goto-char (point-min))
        (search-forward "First")
        (hnview-translate-visible)
        (should scheduled)
        (should-not translated)
        (funcall (pop scheduled))
        (should translated)))))

(ert-deftest hnview-toggle-comment-translation-preserves-body-position ()
  "Toggling comment translation should keep point in the comment body."
  (let* ((comment '(:id 1 :type "comment" :by "alice"
                    :text "hello world with enough trailing words"))
         (story `(:id 10 :type "story" :title "Story"
                  :hnview-children (,comment)))
         (hnview--translations (make-hash-table :test #'equal))
         (hnview--hidden-translations (make-hash-table :test #'equal))
         (hnview--state-loaded-p t))
    (puthash (hnview--translation-key
              comment "hello world with enough trailing words" 'text)
             "translated text" hnview--translations)
    (with-temp-buffer
      (hnview-thread-mode)
      (setq-local hnview--thread-root story)
      (setq-local hnview--hidden-translations hnview--hidden-translations)
      (hnview--render-thread)
      (goto-char (point-min))
      (search-forward "translated")
      (forward-char 4)
      (let ((column (current-column)))
        (hnview-translate-at-point)
        (should (equal (plist-get (hnview--item-at-point) :id) 1))
        (should (= (current-column) column))
        (should (save-excursion
                  (beginning-of-line)
                  (search-forward "hello world with enough trailing words"
                                  (line-end-position) t)))))))

(ert-deftest hnview-toggle-comment-translation-works-on-comment-blank-line ()
  "Toggling comment translation should work from paragraph blank lines."
  (let* ((html "<p>first</p><p>second</p>")
         (source (hnview--html-to-text html))
         (comment `(:id 1 :type "comment" :by "alice" :text ,html))
         (story `(:id 10 :type "story" :title "Story"
                  :hnview-children (,comment)))
         (hnview--translations (make-hash-table :test #'equal))
         (hnview--hidden-translations (make-hash-table :test #'equal))
         (hnview--state-loaded-p t))
    (puthash (hnview--translation-key comment source 'text)
             "uno\n\ndos" hnview--translations)
    (with-temp-buffer
      (hnview-thread-mode)
      (setq-local hnview--thread-root story)
      (setq-local hnview--hidden-translations hnview--hidden-translations)
      (hnview--render-thread)
      (goto-char (point-min))
      (search-forward "uno")
      (forward-line 1)
      (should (looking-at-p "$"))
      (should (equal (plist-get (hnview--item-at-point) :id) 1))
      (hnview-translate-at-point)
      (should (looking-at-p "$"))
      (should (equal (plist-get (hnview--item-at-point) :id) 1))
      (should (save-excursion
                (goto-char (point-min))
                (search-forward "first" nil t))))))

(ert-deftest hnview-translated-comment-replaces-original ()
  "Translated comments should replace original text in place."
  (let* ((comment '(:id 1 :type "comment" :by "alice" :text "hello"))
         (hnview--translations (make-hash-table :test #'equal))
         (hnview--hidden-translations (make-hash-table :test #'equal)))
    (puthash (hnview--translation-key comment "hello" 'text)
             "你好" hnview--translations)
    (with-temp-buffer
      (hnview--insert-comment comment 0)
      (goto-char (point-min))
      (should (search-forward "你好" nil t))
      (should-not (search-forward "显示原文" nil t))
      (should-not (search-forward "hello" nil t)))))

(ert-deftest hnview-header-starts-with-date-not-feed-label ()
  "The feed header should start with the date, not a feed label."
  (let ((hnview--current-feed 'top))
    (with-temp-buffer
      (hnview--render-header)
      (goto-char (point-min))
      (should (looking-at (format-time-string "%A")))
      (should-not (search-forward "Top" nil t)))))

(ert-deftest hnview-comments-hide-upvote-symbol-by-default ()
  "Comments should keep upvote as a keyboard action by default."
  (let ((comment '(:id 1 :type "comment" :by "alice" :text "parent"
                   :hnview-children
                   ((:id 2 :type "comment" :by "bob" :text "child"))))
        (hnview--upvotes (make-hash-table :test #'eql)))
    (with-temp-buffer
      (hnview--insert-comment comment 0)
      (goto-char (point-min))
      (should (search-forward "▾" nil t))
      (should-not (button-at (match-beginning 0)))
      (should-not (search-forward "△" nil t))
      (should-not (search-forward "▽" nil t))
      (should-not (string-match-p "\\[[+-]\\]" (buffer-string)))
      (should (search-forward "child" nil t)))))

(ert-deftest hnview-upvoted-comment-shows-status-before-author ()
  "Comments upvoted through hnview should show a compact status marker."
  (let ((comment '(:id 1 :type "comment" :by "alice" :text "parent"
                   :hnview-children
                   ((:id 2 :type "comment" :by "bob" :text "child"))))
        (hnview--upvotes (make-hash-table :test #'eql)))
    (puthash 1 t hnview--upvotes)
    (with-temp-buffer
      (hnview--insert-comment comment 0)
      (should (string-match-p "▾ △ alice" (buffer-string))))))

(ert-deftest hnview-comment-author-uses-bold-face ()
  "Comment authors should use the dedicated bold author face."
  (let ((comment '(:id 1 :type "comment" :by "alice" :text "hello")))
    (with-temp-buffer
      (hnview--insert-comment comment 0)
      (goto-char (point-min))
      (should (search-forward "alice" nil t))
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'hnview-author)))))

(ert-deftest hnview-author-face-uses-domain-orange ()
  "Comment authors should use the same orange as story domains."
  (should (equal (face-attribute 'hnview-author :foreground nil)
                 (face-attribute 'hnview-domain :foreground nil))))

(ert-deftest hnview-folded-comment-hides-children ()
  "Folded comments should show a compact inline more summary."
  (let ((comment '(:id 1 :type "comment" :by "alice" :text "parent"
                   :time 1000
                   :hnview-children
                   ((:id 2 :type "comment" :by "bob" :text "child"
                     :hnview-children
                     ((:id 3 :type "comment" :by "cyd" :text "grandchild"))))))
        (hnview--folded-comments (make-hash-table :test #'eql)))
    (puthash 1 t hnview--folded-comments)
    (cl-letf (((symbol-function 'hnview--relative-time)
               (lambda (_unix-time &optional _now)
                 "3 hours ago")))
      (with-temp-buffer
        (hnview--insert-comment comment 0)
        (should (string-match-p "▸" (buffer-string)))
        (should (string-match-p "alice • 3 hours ago • 2 more"
                                (buffer-string)))
        (should-not (string-match-p "replies hidden" (buffer-string)))
        (should-not (string-match-p "child" (buffer-string)))))))

(ert-deftest hnview-toggle-comment-fold-preserves-current-comment ()
  "Keyboard folding should keep point on the toggled comment."
  (let ((story '(:id 10 :type "story" :title "Story"
                 :hnview-children
                 ((:id 1 :type "comment" :by "alice" :text "parent"
                   :hnview-children
                   ((:id 2 :type "comment" :by "bob" :text "child"))))))
        (hnview--folded-comments (make-hash-table :test #'eql)))
    (with-temp-buffer
      (hnview-thread-mode)
      (setq-local hnview--thread-root story)
      (setq-local hnview--folded-comments hnview--folded-comments)
      (hnview--render-thread)
      (goto-char (point-min))
      (search-forward "alice")
      (hnview-toggle-comment-fold)
      (should (equal (plist-get (hnview--item-at-point) :id) 1))
      (should (string-match-p "1 more" (buffer-string))))))

(ert-deftest hnview-translate-text-llm-uses-provider ()
  "LLM translation should call the configured provider."
  (let ((hnview-llm-provider 'fake-provider)
        (called nil)
        (result nil)
        (error nil))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (eq feature 'llm)))
              ((symbol-function 'llm-make-chat-prompt)
               (lambda (text &rest args)
                 (setq called (list text args))
                 'fake-prompt))
              ((symbol-function 'llm-chat-async)
               (lambda (provider prompt response-callback _error-callback
                         &optional _multi-output)
                 (should (eq provider 'fake-provider))
                 (should (eq prompt 'fake-prompt))
                 (funcall response-callback " translated "))))
      (hnview--translate-text-llm
       "source"
       (lambda (err translation)
         (setq error err)
         (setq result translation))))
    (should (equal called '("source" (:context
                                     "Translate Hacker News text into zh-CN. Preserve code, URLs, paragraph breaks, Markdown-like structure, quotes, and technical terms when appropriate. Return only the translation."
                                     :temperature 0.1))))
    (should-not error)
    (should (equal result "translated"))))

(ert-deftest hnview-translate-text-llm-supports-provider-factory ()
  "LLM translation should accept a provider factory function."
  (let ((hnview-llm-provider (lambda () 'fake-provider))
        (result nil)
        (error nil))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (eq feature 'llm)))
              ((symbol-function 'llm-make-chat-prompt)
               (lambda (_text &rest _args)
                 'fake-prompt))
              ((symbol-function 'llm-chat-async)
               (lambda (provider _prompt response-callback _error-callback
                         &optional _multi-output)
                 (should (eq provider 'fake-provider))
                 (funcall response-callback " translated "))))
      (hnview--translate-text-llm
       "source"
       (lambda (err translation)
         (setq error err)
         (setq result translation))))
    (should-not error)
    (should (equal result "translated"))))

(ert-deftest hnview-translation-status-reports-missing-provider ()
  "Translation status should report missing providers."
  (let ((hnview-llm-provider nil))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (eq feature 'llm))))
      (should (equal (hnview-translation-status)
                     "hnview-llm-provider is not configured")))))

(ert-deftest hnview-translate-reply-replaces-draft-with-target-language ()
  "Reply translation should replace the draft with target-language text."
  (let ((called nil)
        (hnview-reply-translate-target-language "English"))
    (cl-letf (((symbol-function 'hnview--translate-text)
               (lambda (text callback &optional target-language)
                 (setq called (list text target-language))
                 (funcall callback nil "English reply"))))
      (with-temp-buffer
        (hnview-reply-mode)
        (insert "中文回复")
        (hnview-translate-reply)
        (should (equal called '("中文回复" "English")))
        (should (equal (buffer-string) "English reply"))
        (should hnview--reply-translated-p)))))

(provide 'hnview-test)

;;; hnview-test.el ends here
