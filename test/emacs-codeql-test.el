;;; emacs-codeql-test.el --- Tests for emacs-codeql results buffers -*- lexical-binding: t -*-

;;; Commentary:

;; Run from the repository root with:
;;
;;   emacs -Q --batch -L . -l test/emacs-codeql-test.el -f ert-run-tests-batch-and-exit
;;
;; The org-ql tests are skipped unless org-ql can be loaded, add its
;; directory and those of its dependencies with more -L arguments.  No
;; CodeQL CLI or query server is needed: results are rendered from
;; synthetic SARIF and bqrs data, and the query server is stubbed out.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-element)
(require 'emacs-codeql)

(defconst codeql-test--src-root
  (file-name-as-directory (make-temp-file "codeql-test-src" t))
  "A stand-in for the extracted source archive of a database.")

;; the sources that result locations point into, as the archive holds them
(let ((src (expand-file-name "src" codeql-test--src-root)))
  (make-directory src t)
  (dolist (file '("app.js" "db.js"))
    (with-temp-file (expand-file-name file src)
      (dotimes (i 12) (insert (format "line %d of %s\n" (1+ i) file))))))

(defconst codeql-test--sarif
  "[{\"ruleId\": \"js/xss\",
     \"message\": {\"text\": \"Cross-site [scripting](1) from *user* input :tag:\"},
     \"locations\": [{\"physicalLocation\": {
        \"artifactLocation\": {\"uri\": \"file:/src/app.js\"},
        \"region\": {\"startLine\": 3, \"startColumn\": 5, \"endColumn\": 10}}}],
     \"relatedLocations\": [{\"id\": 1, \"message\": {\"text\": \"scripting\"},
        \"physicalLocation\": {
          \"artifactLocation\": {\"uri\": \"file:/src/db.js\"},
          \"region\": {\"startLine\": 7, \"startColumn\": 1, \"endColumn\": 4}}}],
     \"codeFlows\": [{\"threadFlows\": [{\"locations\": [
        {\"location\": {\"message\": {\"text\": \"source\"}, \"physicalLocation\": {
           \"artifactLocation\": {\"uri\": \"file:/src/db.js\"},
           \"region\": {\"startLine\": 7, \"startColumn\": 1, \"endColumn\": 4}}}},
        {\"location\": {\"message\": {\"text\": \"sink\"}, \"physicalLocation\": {
           \"artifactLocation\": {\"uri\": \"file:/src/app.js\"},
           \"region\": {\"startLine\": 3, \"startColumn\": 5, \"endColumn\": 10}}}}]}]}]},
    {\"ruleId\": \"js/sql-injection\",
     \"message\": {\"text\": \"SQL injection\\n* not a heading\"},
     \"locations\": [{\"physicalLocation\": {
        \"artifactLocation\": {\"uri\": \"file:/src/db.js\"},
        \"region\": {\"startLine\": 10, \"startColumn\": 2, \"endColumn\": 6}}}]}]"
  "Two SARIF results: a path-problem with a related location, and a problem.")

(defconst codeql-test--raw-columns
  "[{\"name\": \"call\", \"kind\": \"Entity\"},
    {\"name\": \"callee name\", \"kind\": \"String\"},
    {\"kind\": \"Integer\"}]"
  "The columns of `codeql-test--raw-tuples'.")

(defconst codeql-test--raw-tuples
  "[[{\"label\": \"foo(x)\", \"url\": {\"uri\": \"file:/src/app.js\",
       \"startLine\": 4, \"startColumn\": 2, \"endLine\": 4, \"endColumn\": 7}},
     \"foo\", 3],
    [{\"label\": \"bar(y)\", \"url\": {\"uri\": \"file:/src/db.js\",
       \"startLine\": 9, \"startColumn\": 1, \"endLine\": 9, \"endColumn\": 6}},
     \"TODO [#A] *b* | [[codeql:/etc/passwd]]\\n:x:\", 1]]"
  "Raw result tuples, including a value that looks like org markup.")

(defun codeql-test--results-buffers ()
  "Return the live CodeQL results buffers."
  (seq-filter (lambda (b) (string-prefix-p "* codeql-org-results:" (buffer-name b)))
              (buffer-list)))

(defmacro codeql-test--with-query-buffer (&rest body)
  "Run BODY in a stand-in query buffer, cleaning up the buffers it creates."
  (declare (indent 0) (debug t))
  `(let ((query-buffer (generate-new-buffer " *codeql-test-query*"))
         (before (buffer-list)))
     (unwind-protect
         (save-window-excursion
           (with-current-buffer query-buffer
             (setq major-mode 'ql-tree-sitter-mode)
             (setq codeql--database-source-archive-zip "src.zip"
                   codeql--database-source-archive-root codeql-test--src-root
                   codeql--database-source-location-prefix "/src")
             ,@body))
       (dolist (b (buffer-list))
         (unless (memq b before)
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b))))))

(defun codeql-test--new-results-buffer (thunk)
  "Call THUNK and return the results buffer it created."
  (let ((before (codeql-test--results-buffers)))
    (funcall thunk)
    (or (seq-find (lambda (b) (not (memq b before))) (codeql-test--results-buffers))
        (error "No results buffer was created"))))

(defun codeql-test--render-sarif (provenance)
  "Render `codeql-test--sarif' from PROVENANCE, return its results buffer."
  (let* ((results (json-parse-string codeql-test--sarif :object-type 'alist))
         (org-data (codeql--sarif-results-to-org results 0 (length results)))
         (query-buffer (current-buffer)))
    (codeql-test--new-results-buffer
     (lambda ()
       (codeql--org-render-sarif-results
        org-data query-buffer "#+QUERY_KIND: path-problem\n" "Test.ql"
        (list :provenance provenance :database "/dbs/js-db" :query-kind "path-problem"))))))

(defun codeql-test--raw-org (style)
  "Return org data of `codeql-test--raw-tuples' in STYLE."
  (codeql--query-results-to-org
   (codeql--raw-tuples-to-query-results
    (alist-get 'tuples (json-parse-string
                        (format "{\"tuples\": %s}" codeql-test--raw-tuples)
                        :object-type 'alist)))
   (if (eq style 'outline) 'raw-outline 'raw)
   (json-parse-string codeql-test--raw-columns :object-type 'alist)
   0 "#select"))

(defun codeql-test--render-raw (provenance style)
  "Render `codeql-test--raw-tuples' from PROVENANCE in STYLE."
  (let ((org-data (codeql-test--raw-org style))
        (query-buffer (current-buffer)))
    (codeql-test--new-results-buffer
     (lambda ()
       (codeql--org-render-raw-query-results
        org-data query-buffer "#+QUERY_KIND: raw\n" "Raw.ql"
        (list :kind 'raw :page 0 :page-size 2 :total-rows 2 :offsets nil
              :result-set "#select" :result-sets '(((name . "#select") (rows . 2)))
              :style style :footer "#+QUERY_KIND: raw\n")
        (list :provenance provenance :database "/dbs/js-db" :query-kind "raw"))))))

(defun codeql-test--headlines (buffer)
  "Return (LEVEL CODEQL_KIND) of each headline of BUFFER."
  (with-current-buffer buffer
    (org-element-map (org-element-parse-buffer 'headline) 'headline
      (lambda (h)
        (list (org-element-property :level h)
              (org-element-property :CODEQL_KIND h))))))

(defun codeql-test--goto-heading (regexp)
  "Move to the start of the first heading of the current buffer matching REGEXP."
  (goto-char (point-min))
  (re-search-forward (concat "^\\*+ " regexp))
  (beginning-of-line))

(defun codeql-test--src-block-value (buffer)
  "Return the value of the first src block of BUFFER, as org reads it."
  (with-current-buffer buffer
    (org-element-map (org-element-parse-buffer) 'src-block
      (lambda (b) (org-element-property :value b))
      nil t)))

(defun codeql-test--links (buffer type)
  "Return the paths of the TYPE links in BUFFER."
  (with-current-buffer buffer
    (org-element-map (org-element-parse-buffer) 'link
      (lambda (l) (when (equal (org-element-property :type l) type)
                    (org-element-property :path l))))))

(defun codeql-test--result-properties (buffer)
  "Return the properties of the result headings of BUFFER, an alist each."
  (with-current-buffer buffer
    (org-map-entries (lambda () (org-entry-properties nil 'standard))
                     "CODEQL_KIND=\"result\"")))

;;; Org compatibility

(ert-deftest codeql-test-results-buffer-is-org ()
  "Problem results form an org document with the documented structure."
  (codeql-test--with-query-buffer
    (let ((buffer (codeql-test--render-sarif '(:kind file :path "/q/Test.ql"))))
      (with-current-buffer buffer
        (should (derived-mode-p 'org-mode))
        (should (eq major-mode 'codeql-results-mode))
        (should buffer-read-only))
      (should (equal (codeql-test--headlines buffer)
                     '((1 "query-source") (2 nil)
                       (1 "results") (2 "result") (3 nil) (2 "result")
                       (1 nil)))))))

(ert-deftest codeql-test-problem-properties ()
  "Problem results carry their metadata as heading properties."
  (codeql-test--with-query-buffer
    (let* ((buffer (codeql-test--render-sarif '(:kind file :path "/q/Test.ql")))
           (props (codeql-test--result-properties buffer))
           (xss (car props))
           (sql (cadr props)))
      (should (= (length props) 2))
      (should (equal (cdr (assoc "CODEQL_RULE_ID" xss)) "js/xss"))
      (should (equal (cdr (assoc "CODEQL_QUERY_KIND" xss)) "path-problem"))
      (should (equal (cdr (assoc "CODEQL_RESULT" xss)) "1"))
      (should (equal (cdr (assoc "CODEQL_FILE" xss)) "/src/app.js"))
      (should (equal (cdr (assoc "CODEQL_LINE" xss)) "3"))
      (should (equal (cdr (assoc "CODEQL_COLUMN" xss)) "5"))
      (should (equal (cdr (assoc "CODEQL_PATHS" xss)) "1"))
      (should (equal (cdr (assoc "CODEQL_MESSAGE" xss))
                     "Cross-site scripting from *user* input :tag:"))
      (should (equal (cdr (assoc "CODEQL_QUERY_KIND" sql)) "problem"))
      (should (equal (cdr (assoc "CODEQL_RESULT" sql)) "2"))
      (should (equal (cdr (assoc "CODEQL_FILE" sql)) "/src/db.js"))
      ;; the line break of the message is collapsed
      (should (equal (cdr (assoc "CODEQL_MESSAGE" sql)) "SQL injection * not a heading")))))

(ert-deftest codeql-test-raw-outline-properties ()
  "Raw result rows shown as headings carry their columns as properties."
  (codeql-test--with-query-buffer
    (let* ((buffer (codeql-test--render-raw '(:kind file :path "/q/Raw.ql") 'outline))
           (props (codeql-test--result-properties buffer)))
      (should (equal (codeql-test--headlines buffer)
                     '((1 "query-source") (2 nil)
                       (1 "results") (2 "result") (2 "result")
                       (1 nil))))
      (should (= (length props) 2))
      (let ((row (car props)))
        (should (equal (cdr (assoc "CODEQL_QUERY_KIND" row)) "raw"))
        (should (equal (cdr (assoc "CODEQL_RESULT_SET" row)) "#select"))
        (should (equal (cdr (assoc "CODEQL_ROW" row)) "1"))
        (should (equal (cdr (assoc "CODEQL_FILE" row)) "/src/app.js"))
        (should (equal (cdr (assoc "CODEQL_LINE" row)) "4"))
        (should (equal (cdr (assoc "CODEQL_COL_CALL" row)) "foo(x)"))
        (should (equal (cdr (assoc "CODEQL_COL_CALLEE_NAME" row)) "foo"))
        (should (equal (cdr (assoc "CODEQL_COL_COL3" row)) "3"))))))

(ert-deftest codeql-test-raw-table-style ()
  "Raw results shown as a table stay a table under the Results heading."
  (codeql-test--with-query-buffer
    (let ((buffer (codeql-test--render-raw '(:kind file :path "/q/Raw.ql") 'table)))
      (should (equal (codeql-test--headlines buffer)
                     '((1 "query-source") (2 nil) (1 "results") (1 nil))))
      (with-current-buffer buffer
        (codeql-test--goto-heading "Results$")
        (should (re-search-forward "^| call " nil t))
        (should (org-at-table-p))))))

;;; Provenance

(ert-deftest codeql-test-file-provenance ()
  "Results of a query file link to that file in the Query Source section."
  (codeql-test--with-query-buffer
    (let* ((path "/tmp/we[ird] dir/my_query%20.ql")
           (buffer (codeql-test--render-sarif (list :kind 'file :path path))))
      (should (equal (codeql-test--links buffer "file") (list path)))
      (should-not (codeql-test--src-block-value buffer))
      (with-current-buffer buffer
        (codeql-test--goto-heading "Query Source")
        (should (equal (org-entry-get nil "CODEQL_EVALUATION") "query"))
        (should (equal (org-entry-get nil "CODEQL_QUERY") path))
        (should (equal (org-entry-get nil "CODEQL_DATABASE") "/dbs/js-db"))
        ;; following the link visits the query
        (let (visited)
          (cl-letf (((symbol-function 'find-file-other-window)
                     (lambda (file &rest _) (setq visited file)))
                    ((symbol-function 'find-file)
                     (lambda (file &rest _) (setq visited file))))
            (codeql-test--goto-heading "Originating Query")
            (re-search-forward "\\[\\[")
            (let ((org-link-frame-setup '((file . find-file))))
              (org-open-at-point)))
          (should (equal visited path)))))))

(ert-deftest codeql-test-quick-eval-provenance ()
  "Quick evaluation results hold the exact code that was evaluated."
  (codeql-test--with-query-buffer
    (let* ((source "  from int x\n* where x in [1 .. 5]\n#+end_src\n,select x  ")
           (buffer (codeql-test--render-sarif
                    (list :kind 'quick-eval :path "/q/Test.ql" :source source
                          :line 3 :column 5))))
      (should (equal (codeql-test--src-block-value buffer) (concat source "\n")))
      ;; the code doesn't break the structure of the document
      (should (equal (mapcar #'car (codeql-test--headlines buffer)) '(1 2 2 1 2 3 2 1)))
      (with-current-buffer buffer
        (codeql-test--goto-heading "Query Source")
        (should (equal (org-entry-get nil "CODEQL_EVALUATION") "quick-eval")))
      ;; besides the snippet, the query it came from is linked, at its position
      (should (equal (codeql-test--links buffer "file") '("/q/Test.ql" "/q/Test.ql"))))))

(ert-deftest codeql-test-quick-eval-provenance-without-file ()
  "Code evaluated without a query file only shows that code."
  (codeql-test--with-query-buffer
    (let ((buffer (codeql-test--render-sarif
                   '(:kind quick-eval :source "select 1"))))
      (should (equal (codeql-test--src-block-value buffer) "select 1\n"))
      (should-not (codeql-test--links buffer "file")))))

(ert-deftest codeql-test-capture-provenance ()
  "Provenance is captured from the query buffer when the run is requested."
  (with-temp-buffer
    (insert "from int x\nwhere x in [1 .. 5]\nselect x\n")
    (setq-local transient-mark-mode t)
    (should (equal (codeql--query-provenance "/q/A.ql" nil)
                   '(:kind file :path "/q/A.ql")))
    (goto-char (point-min))
    (forward-line 1)
    (set-mark (point))
    (end-of-line)
    (activate-mark)
    (let ((provenance (codeql--query-provenance "/q/A.ql" t)))
      (should (equal (plist-get provenance :source) "where x in [1 .. 5]"))
      (should (equal (plist-get provenance :line) 2))
      (should (equal (plist-get provenance :column) 1))
      (should-not (plist-get provenance :at-point))
      (should-not (plist-get provenance :count)))
    (deactivate-mark)
    (goto-char (point-min))
    (forward-line 1)
    (forward-char 7)
    (let ((provenance (codeql--query-provenance "/q/A.ql" 'count)))
      (should (equal (plist-get provenance :source) "x"))
      (should (plist-get provenance :at-point))
      (should (plist-get provenance :count)))))

(defmacro codeql-test--with-stubbed-server (calls &rest body)
  "Run BODY with the query server stubbed out.

Requests are pushed onto CALLS as (BQRS-PATH SUCCESS-FN) instead of being
sent, and `codeql-load-bqrs' pushes (:loaded BQRS-PATH PROVENANCE)."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'codeql--query-server-current-or-error) (lambda () 'server))
             ((symbol-function 'codeql--query-server-next-progress-id) (lambda () 1))
             ((symbol-function 'codeql--query-server-jsonrpc-register-request) #'ignore)
             ((symbol-function 'codeql--query-server2-handle-message) #'ignore)
             ((symbol-function 'codeql-query-server-active-database) (lambda () "/dbs/js-db"))
             ((symbol-function 'codeql--file-truename) #'identity)
             ((symbol-function 'codeql--jsonrpc-async-request)
              (lambda (_connection _method params &rest args)
                (push (list (plist-get (plist-get params :body) :outputPath)
                            (plist-get args :success-fn))
                      ,calls)
                (list 1 nil)))
             ((symbol-function 'codeql-load-bqrs)
              (lambda (bqrs-path &rest args)
                (push (list :loaded bqrs-path (nth 9 args)) ,calls))))
     (let ((codeql-query-server "query-server2")
           (codeql-evaluator-log nil))
       ,@body)))

(ert-deftest codeql-test-provenance-survives-edits ()
  "Editing the query while it runs doesn't change what its results show."
  (codeql-test--with-query-buffer
    (let ((calls nil)
          (dir (make-temp-file "codeql-test-state" t)))
      (insert "predicate p(int x) { x = 1 }\nfrom int x where p(x) select x\n")
      (setq-local transient-mark-mode t)
      (setq codeql--active-database "/dbs/js-db/"
            codeql--completed-query-history (make-hash-table :test #'equal))
      (goto-char (point-min))
      (set-mark (point))
      (end-of-line)
      (activate-mark)
      (codeql-test--with-stubbed-server calls
        (cl-letf (((symbol-function 'codeql--resolve-query-paths) (lambda (&rest _) t))
                  ((symbol-function 'codeql--query-info) #'ignore))
          (let ((codeql-tmp-dir dir)
                (codeql-results-dir dir))
            (codeql--query-server-run-query-from-path "/q/A.ql" t)))
        ;; the user edits the query before the run completes
        (deactivate-mark)
        (erase-buffer)
        (insert "select 42\n")
        (pcase-let ((`(,bqrs ,success) (car calls)))
          (with-temp-file bqrs (insert "results"))
          (funcall success nil)
          (pcase-let ((`(:loaded ,loaded ,provenance) (car calls)))
            (should (equal loaded bqrs))
            (should (equal (plist-get provenance :source) "predicate p(int x) { x = 1 }"))
            (should (equal (plist-get provenance :path) "/q/A.ql"))))
        ;; and the query history remembers it too
        (should (equal (plist-get (car (hash-table-values codeql--completed-query-history))
                                  :provenance)
                       (nth 2 (car calls))))))))

(ert-deftest codeql-test-overlapping-runs ()
  "Runs that complete out of order each keep their own provenance."
  (codeql-test--with-query-buffer
    (let ((calls nil)
          (dir (make-temp-file "codeql-test-state" t)))
      (setq codeql--active-database "/dbs/js-db/"
            codeql--completed-query-history (make-hash-table :test #'equal))
      (codeql-test--with-stubbed-server calls
        (let ((first (make-temp-file (expand-file-name "a" dir) nil ".bqrs" "x"))
              (second (make-temp-file (expand-file-name "b" dir) nil ".bqrs" "x")))
          (codeql--query-server-request-run
           (current-buffer) nil first "/q/A.ql" nil nil "/dbs/js-db" nil nil nil nil
           '(:kind file :path "/q/A.ql"))
          (codeql--query-server-request-run
           (current-buffer) nil second "/q/A.ql" nil nil "/dbs/js-db" t nil nil nil
           '(:kind quick-eval :path "/q/A.ql" :source "p(x)"))
          ;; the second run completes first
          (let ((requests (copy-sequence calls)))
            (dolist (request requests)
              (funcall (nth 1 request) nil)))
          (let ((loaded (seq-filter (lambda (call) (eq (car call) :loaded)) calls)))
            (should (equal (cadr (assoc first (mapcar #'cdr loaded)))
                           '(:kind file :path "/q/A.ql")))
            (should (equal (plist-get (nth 2 (cl-find second loaded :key #'cadr :test #'equal))
                                      :source)
                           "p(x)"))))))))

(ert-deftest codeql-test-results-buffers-are-independent ()
  "Results buffers rendered back to back each show their own query source."
  (codeql-test--with-query-buffer
    (let ((a (codeql-test--render-sarif '(:kind file :path "/q/A.ql")))
          (b (codeql-test--render-sarif '(:kind quick-eval :path "/q/B.ql" :source "p(x)"))))
      (should-not (eq a b))
      (should (equal (codeql-test--links a "file") '("/q/A.ql")))
      (should-not (codeql-test--src-block-value a))
      (should (equal (codeql-test--src-block-value b) "p(x)\n")))))

;;; Folding

(defun codeql-test--check-initial-visibility (buffer)
  "Check that only the Query Source section and drawers are folded in BUFFER."
  (with-current-buffer buffer
    (codeql-test--goto-heading "Query Source")
    (should-not (invisible-p (point)))
    (codeql-test--goto-heading "Originating Query")
    (should (invisible-p (point)))
    (codeql-test--goto-heading "Results$")
    (should-not (invisible-p (point)))
    (forward-line 1)
    ;; property drawers show as just their first line
    (should (looking-at-p ":PROPERTIES:"))
    (should (invisible-p (line-end-position)))
    (re-search-forward "^\\*\\* ")
    (should-not (invisible-p (point)))
    (codeql-test--goto-heading "Results Footer")
    (should-not (invisible-p (point)))
    (forward-line 1)
    (should-not (invisible-p (point)))))

(ert-deftest codeql-test-initial-folding ()
  "The Query Source section starts folded, the results don't."
  (codeql-test--with-query-buffer
    (let ((buffer (codeql-test--render-sarif
                   '(:kind quick-eval :path "/q/Test.ql" :source "p(x)"))))
      (with-current-buffer buffer
        ;; point is at the results
        (should (looking-at-p "\\* Results$")))
      (codeql-test--check-initial-visibility buffer)
      (with-current-buffer buffer
        ;; and org can unfold the section as usual
        (codeql-test--goto-heading "Query Source")
        (if (fboundp 'org-fold-show-subtree) (org-fold-show-subtree) (org-show-subtree))
        (codeql-test--goto-heading "Evaluated Code")
        (should-not (invisible-p (point)))))))

(ert-deftest codeql-test-refresh-keeps-structure ()
  "Showing another page refolds the Query Source and keeps the provenance."
  (codeql-test--with-query-buffer
    (let ((buffer (codeql-test--render-raw
                   '(:kind quick-eval :path "/q/Raw.ql" :source "p(x)") 'outline)))
      (with-current-buffer buffer
        (codeql-test--goto-heading "Query Source")
        (if (fboundp 'org-fold-show-subtree) (org-fold-show-subtree) (org-show-subtree))
        (codeql--raw-results-fill-buffer (with-current-buffer query-buffer
                                           (codeql-test--raw-org 'outline))
                                         (codeql--raw-results-pagination-footer)))
      (codeql-test--check-initial-visibility buffer)
      (should (equal (codeql-test--src-block-value buffer) "p(x)\n"))
      (should (= (length (codeql-test--result-properties buffer)) 2)))))

(ert-deftest codeql-test-saved-results-fold-on-open ()
  "Saved results reopen with the Query Source section folded."
  (codeql-test--with-query-buffer
    (let* ((buffer (codeql-test--render-sarif '(:kind file :path "/q/Test.ql")))
           (file (make-temp-file "codeql-test" nil ".bqrs.org"
                                 (with-current-buffer buffer (buffer-string)))))
      (with-current-buffer (find-file-noselect file)
        (unwind-protect
            (progn
              (should (eq major-mode 'codeql-results-mode))
              (codeql-test--goto-heading "Originating Query")
              (should (invisible-p (point)))
              (should (= (length (codeql--results-alerts)) 2)))
          (kill-buffer))))))

;;; Navigation

(ert-deftest codeql-test-problem-alerts ()
  "Problem result headings remain alerts, located at their problem."
  (codeql-test--with-query-buffer
    (let ((buffer (codeql-test--render-sarif '(:kind file :path "/q/Test.ql"))))
      (with-current-buffer buffer
        (let ((alerts (codeql--results-alerts)))
          (should (= (length alerts) 2))
          (let ((locations (codeql--alert-locations (aref alerts 0))))
            ;; location, related location, then the path steps
            (should (string-match-p "/src/app\\.js::3:5" (car (aref locations 0))))
            (should (string-match-p "/src/db\\.js::7:1" (car (aref locations 1))))
            (should (string-match-p "Cross-site scripting"
                                    (codeql--alert-message (aref alerts 0))))
            (should (equal (codeql--alert-location-text (aref alerts 0) 1)
                           "Related location \"scripting\"")))
          (should (string-match-p "/src/db\\.js::10:2"
                                  (car (aref (codeql--alert-locations (aref alerts 1)) 0)))))))))

(ert-deftest codeql-test-raw-alerts ()
  "Raw result rows are alerts both as headings and as table rows."
  (codeql-test--with-query-buffer
    (dolist (style '(outline table))
      (let ((buffer (codeql-test--render-raw '(:kind file :path "/q/Raw.ql") style)))
        (with-current-buffer buffer
          (let ((alerts (codeql--results-alerts)))
            (should (= (length alerts) 2))
            (should (string-match-p "/src/app\\.js::4:2"
                                    (car (aref (codeql--alert-locations (aref alerts 0)) 0))))
            (should (string-match-p "/src/db\\.js::9:1"
                                    (car (aref (codeql--alert-locations (aref alerts 1)) 0))))))))))

(ert-deftest codeql-test-follow-result-link ()
  "Following the link of a result visits its location in the source archive."
  (codeql-test--with-query-buffer
    (pcase-dolist (`(,render . ,line)
                   (list (cons (lambda () (codeql-test--render-sarif '(:kind file :path "/q/T.ql"))) 3)
                         (cons (lambda () (codeql-test--render-raw '(:kind file :path "/q/R.ql") 'outline)) 4)))
      (let ((buffer (funcall render)))
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "\\[\\[codeql:[^]]*/app\\.js::")
          (let ((codeql-highlight-visited-location nil))
            (cl-letf (((symbol-function 'codeql-xref-backend) #'ignore))
              (org-open-at-point)))
          (with-current-buffer (window-buffer (selected-window))
            (should (equal (buffer-file-name)
                           (expand-file-name "src/app.js" codeql-test--src-root)))
            (should (= (line-number-at-pos) line))))))))

(ert-deftest codeql-test-diagnostics ()
  "Result headings still give the diagnostics of their locations."
  (codeql-test--with-query-buffer
    (dolist (render (list (lambda () (codeql-test--render-sarif '(:kind file :path "/q/T.ql")))
                          (lambda () (codeql-test--render-raw '(:kind file :path "/q/R.ql") 'outline))))
      (with-current-buffer (funcall render)
        (let* ((diagnostics (codeql--diagnostics-collect))
               (app (gethash (codeql--diagnostics-file-key
                              (expand-file-name "src/app.js" codeql-test--src-root))
                             diagnostics)))
          (should (seq-find (lambda (d) (eq (nth 4 d) :warning)) app)))))))

(ert-deftest codeql-test-legacy-saved-results ()
  "Results saved before results had properties still have their alerts."
  (with-temp-buffer
    (insert "* ≔ [js/xss] XSS ... [[codeql:/a/src/app.js::3:5][app.js]]:3:5\n"
            "** Path #0\n"
            "   1. src [[codeql:/a/src/db.js::7:1][x]]\n"
            "* ≔ [js/sql] SQL ... [[codeql:/a/src/db.js::10:2][db.js]]:10:2\n"
            "\n* Results Footer\n#+QUERY_KIND: path-problem\n")
    (codeql-results-mode)
    (let ((alerts (codeql--results-alerts)))
      (should (= (length alerts) 2))
      (should (= (length (codeql--alert-locations (aref alerts 0))) 2)))))

;;; Path graphs

(defconst codeql-test--paths-results
  (concat "* Results\n:PROPERTIES:\n:CODEQL_KIND: results\n:END:\n"
          "** ≔ [js/xss] XSS ... [[codeql:/a/src/app.js::3:5][app.js]]:3:5\n"
          ":PROPERTIES:\n:CODEQL_KIND: result\n:CODEQL_QUERY_KIND: path-problem\n:END:\n"
          "*** Path #0\n"
          "   1. src [[codeql:/a/src/db.js::7:1][req.query]]      [[codeql:/a/src/db.js::7:1][db.js]]:7:1\n"
          "   2. ... [[codeql:/a/src/db.js::8:3][name]]           [[codeql:/a/src/db.js::8:3][db.js]]:8:3\n"
          "   3. snk [[codeql:/a/src/app.js::3:5][html]]          [[codeql:/a/src/app.js::3:5][app.js]]:3:5\n"
          "*** Path #1\n"
          "   1. src [[codeql:/a/src/db.js::9:1][req.body]]       [[codeql:/a/src/db.js::9:1][db.js]]:9:1\n"
          "   2. ... [[codeql:/a/src/db.js::8:3][name]]           [[codeql:/a/src/db.js::8:3][db.js]]:8:3\n"
          "   3. ... [[codeql:/a/src/db.js::8:3][name]]           [[codeql:/a/src/db.js::8:3][db.js]]:8:3\n"
          "   4. snk [[codeql:/a/src/app.js::3:5][html]]          [[codeql:/a/src/app.js::3:5][app.js]]:3:5\n"
          "** ≔ [js/sql] SQL ... [[codeql:/a/src/db.js::10:2][db.js]]:10:2\n"
          ":PROPERTIES:\n:CODEQL_KIND: result\n:CODEQL_QUERY_KIND: problem\n:END:\n"
          "* Results Footer\n#+QUERY_KIND: path-problem\n")
  "A results buffer with a path-problem result whose two paths join.")

(ert-deftest codeql-test-results-paths ()
  "The paths of a result are read from its Path headings."
  (with-temp-buffer
    (insert codeql-test--paths-results)
    (codeql-results-mode)
    (let* ((alert (aref (codeql--results-alerts) 0))
           (paths (codeql--results-paths (codeql--alert-start alert)
                                         (codeql--alert-end alert))))
      (should (equal (mapcar (lambda (path) (mapcar #'cdr path)) paths)
                     '(("req.query" "name" "html") ("req.body" "name" "name" "html"))))
      (should (equal (car (car (car paths))) "/a/src/db.js::7:1"))
      (pcase-let ((`(,nodes . ,edges) (codeql--paths-to-graph paths)))
        ;; shared steps are one node, and repeated steps no loop
        (should (equal (mapcar #'car nodes) '("req.query" "name" "html" "req.body")))
        (should (equal (mapcar #'cdr nodes)
                       '("/a/src/db.js::7:1" "/a/src/db.js::8:3"
                         "/a/src/app.js::3:5" "/a/src/db.js::9:1")))
        (should (equal edges '((0 . 1) (1 . 2) (3 . 1))))))))

(ert-deftest codeql-test-results-path-graph ()
  "The paths of the result at point are shown as a graph."
  (with-temp-buffer
    (insert codeql-test--paths-results)
    (codeql-results-mode)
    (let (shown selected)
      (cl-letf (((symbol-function 'codeql--show-graph)
                 (lambda (dot-path nodes &rest _)
                   (setq shown (list (with-temp-buffer
                                       (insert-file-contents dot-path)
                                       (buffer-string))
                                     nodes))))
                ((symbol-function 'get-buffer) (lambda (_) (current-buffer)))
                ((symbol-function 'codeql--graph-text-p) (lambda () t))
                ((symbol-function 'codeql--graph-select) (lambda (id) (setq selected id))))
        ;; on the second path's step shared with the first one
        (goto-char (point-min))
        (re-search-forward "req\\.body")
        (forward-line 1)
        (codeql-results-path-graph)
        (should (string-match-p "3 -> 1;" (car shown)))
        (should (= (length (nth 1 shown)) 4))
        (should (eql selected 1))
        ;; a result without paths
        (re-search-forward "js/sql")
        (should-error (codeql-results-path-graph) :type 'user-error)))))

;;; Escaping

(ert-deftest codeql-test-escaping ()
  "Arbitrary paths, messages, values and code keep the document intact."
  (codeql-test--with-query-buffer
    (let* ((path "/tmp/a]]b/[x] *q*.ql")
           (source "#+end_src\n* Results\n:END:\n")
           (buffer (codeql-test--render-raw
                    (list :kind 'quick-eval :path path :source source)
                    'outline)))
      (should (equal (codeql-test--headlines buffer)
                     '((1 "query-source") (2 nil) (2 nil)
                       (1 "results") (2 "result") (2 "result")
                       (1 nil))))
      (should (equal (codeql-test--links buffer "file") (list path)))
      (should (equal (codeql-test--src-block-value buffer) source))
      (with-current-buffer buffer
        (codeql-test--goto-heading "2\\. ")
        ;; neither a todo keyword, a priority nor tags
        (should-not (org-get-todo-state))
        (should-not (org-get-tags nil t))
        (let ((value (org-entry-get nil "CODEQL_COL_CALLEE_NAME")))
          ;; single line, and no link that navigation could pick up
          (should-not (string-match-p "\n" value))
          (should-not (string-match-p "\\[\\[codeql:" value))
          (should (string-match-p "TODO \\[#A\\] \\*b\\*" value)))
        ;; the codeql: text of a value is not a location
        (should (= (length (codeql--alert-locations (aref (codeql--results-alerts) 1))) 1))))))

(ert-deftest codeql-test-property-helpers ()
  (should (equal (codeql--org-property-name "callee name") "CALLEE_NAME"))
  (should (equal (codeql--org-property-name "#") "UNNAMED"))
  (should-not (codeql--org-property-value "  "))
  (should-not (codeql--org-property-value nil))
  (should (equal (codeql--org-property-value 42) "42"))
  (should (equal (codeql--org-safe-heading "** 1. a :b:") "** 1. a :b:\u200b"))
  (should (equal (codeql--org-safe-heading "** 1. a:b:3") "** 1. a:b:3")))

;;; org-ql

(defmacro codeql-test--with-org-ql (&rest body)
  "Run BODY when org-ql is available, skip the test otherwise."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (and (require 'org-ql nil t) (require 'org-ql-search nil t)))
     ,@body))

(defun codeql-test--org-ql (buffer query)
  "Return the CODEQL_RESULT or CODEQL_ROW of the results in BUFFER matching QUERY."
  (org-ql-select buffer (codeql--results-org-ql-query query)
    :action (lambda () (or (org-entry-get nil "CODEQL_RESULT")
                           (org-entry-get nil "CODEQL_ROW")))))

(ert-deftest codeql-test-org-ql-queries ()
  "org-ql queries match results by their properties and text."
  (codeql-test--with-org-ql
    (codeql-test--with-query-buffer
      (let ((problems (codeql-test--render-sarif '(:kind quick-eval :source "p(x)")))
            (rows (codeql-test--render-raw '(:kind file :path "/q/R.ql") 'outline)))
        ;; an empty query matches the results only
        (should (equal (codeql-test--org-ql problems "") '("1" "2")))
        (should (equal (codeql-test--org-ql problems "(property \"CODEQL_RULE_ID\" \"js/xss\")")
                       '("1")))
        (should (equal (codeql-test--org-ql problems "property:CODEQL_LINE=10") '("2")))
        (should (equal (codeql-test--org-ql problems "(property \"CODEQL_FILE\" \"/src/db.js\")")
                       '("2")))
        (should (equal (codeql-test--org-ql problems "(regexp \"SQL\")") '("2")))
        ;; the snippet of the Query Source section isn't a result
        (should-not (codeql-test--org-ql problems "(regexp \"p(x)\")"))
        (should (equal (codeql-test--org-ql rows "(property \"CODEQL_COL_CALLEE_NAME\" \"foo\")")
                       '("1")))
        (should (equal (codeql-test--org-ql rows "(and (property \"CODEQL_QUERY_KIND\" \"raw\") (regexp \"bar\"))")
                       '("2")))))))

(ert-deftest codeql-test-org-ql-command ()
  "`codeql-results-org-ql' shows matching results in place or in a view."
  (codeql-test--with-org-ql
    (codeql-test--with-query-buffer
      (let ((buffer (codeql-test--render-sarif '(:kind file :path "/q/T.ql"))))
        (with-current-buffer buffer
          (should (= (codeql-results-org-ql "(property \"CODEQL_RULE_ID\" \"js/sql-injection\")") 1))
          ;; the sparse tree shows the match and hides the other result
          (codeql-test--goto-heading "≔ \\[js/sql-injection\\]")
          (should-not (invisible-p (point)))
          (codeql-test--goto-heading "≔ \\[js/xss\\]")
          (should (invisible-p (point)))
          (codeql-results-org-ql "" t)
          (should (get-buffer-window (seq-find (lambda (b) (string-prefix-p "*Org QL View" (buffer-name b)))
                                               (buffer-list)))))))))

(ert-deftest codeql-test-org-ql-switches-tables-to-headings ()
  "Searching raw results shown as a table shows them as headings first."
  (codeql-test--with-org-ql
    (codeql-test--with-query-buffer
      (let ((buffer (codeql-test--render-raw '(:kind file :path "/q/R.ql") 'table)))
        (cl-letf (((symbol-function 'codeql--raw-results-page-to-org)
                   (lambda (_bqrs _set _offsets _page _size style &rest _)
                     (codeql-test--raw-org style))))
          (with-current-buffer buffer
            (should (= (codeql-results-org-ql "(regexp \"foo\")") 1))
            (should (eq (plist-get codeql--raw-results-pagination :style) 'outline))
            (should (= (length (codeql-test--result-properties buffer)) 2))
            (codeql-results-toggle-raw-style)
            (should (eq (plist-get codeql--raw-results-pagination :style) 'table))
            (should-not (codeql-test--result-properties buffer))))))))

;;; Table operations on raw results

(defconst codeql-test--table-tuples
  "[[{\"label\": \"foo(x)\", \"url\": {\"uri\": \"file:/src/app.js\",
       \"startLine\": 4, \"startColumn\": 2, \"endLine\": 4, \"endColumn\": 7}},
     \"foo\", 3],
    [{\"label\": \"bar(y)\", \"url\": {\"uri\": \"file:/src/db.js\",
       \"startLine\": 9, \"startColumn\": 1, \"endLine\": 9, \"endColumn\": 6}},
     \"bar\", 10],
    [{\"label\": \"baz(z)\", \"url\": {\"uri\": \"file:/src/db.js\",
       \"startLine\": 11, \"startColumn\": 1, \"endLine\": 11, \"endColumn\": 6}},
     \"baz\", 1]]"
  "Three raw result tuples of the columns `codeql-test--raw-columns'.")

(defmacro codeql-test--with-table (bindings &rest body)
  "Run BODY in a raw results buffer of `codeql-test--table-tuples'.

BINDINGS are extra `cl-letf' bindings.  Decoding the bqrs returns the
tuples, `decodes' counts whole result set decodes and `cli' collects the
other CLI commands, as lists of their arguments."
  (declare (indent 1) (debug t))
  `(codeql-test--with-query-buffer
     (let* ((decodes 0)
            (cli nil)
            (columns (json-parse-string codeql-test--raw-columns :object-type 'alist))
            (result-sets (list `((name . "#select") (rows . 3) (columns . ,columns)))))
       (cl-letf (((symbol-function 'codeql--bqrs-to-json)
                  (lambda (_path _entities &optional _set rows _start)
                    (unless rows (cl-incf decodes))
                    (format "{\"columns\": %s, \"tuples\": %s}"
                            codeql-test--raw-columns codeql-test--table-tuples)))
                 ((symbol-function 'codeql--cli-command-to-string)
                  (lambda (args) (push args cli) ""))
                 ,@bindings)
         (let* ((query-buffer (current-buffer))
                (setup (codeql--raw-results-setup
                        "/r/q.bqrs" result-sets (car result-sets) "#+QUERY_KIND: raw\n"
                        nil 'table))
                (buffer (codeql-test--new-results-buffer
                         (lambda ()
                           (codeql--org-render-raw-query-results
                            (cdr setup) query-buffer "#+QUERY_KIND: raw\n" "T.ql" (car setup)
                            (list :provenance '(:kind file :path "/q/T.ql")
                                  :database "/dbs/js-db" :query-kind "raw"))))))
           (setq decodes 0)
           (with-current-buffer buffer
             ,@body))))))

(defun codeql-test--table-rows ()
  "Return the cells of the rows of the results table of the current buffer."
  (save-excursion
    (codeql-test--goto-heading "Results$")
    (re-search-forward "^|")
    (let ((rows (org-table-to-lisp)))
      (mapcar (lambda (row) (mapcar #'substring-no-properties row))
              (cl-remove-if-not #'listp rows)))))

(ert-deftest codeql-test-raw-condition ()
  "Filter conditions compare numbers numerically and anything else as strings."
  (should (codeql--raw-results-condition-p 10 ">" "9"))
  (should-not (codeql--raw-results-condition-p "10" "<" "9"))
  (should (codeql--raw-results-condition-p "10" "<" "9x"))
  (should (codeql--raw-results-condition-p 3 "=" "3.0"))
  (should (codeql--raw-results-condition-p "foo" "!=" "bar"))
  (should (codeql--raw-results-condition-p "abc" "<=" "abd"))
  (should (codeql--raw-results-condition-p "foo(x)" "~" "^fo+("))
  (should (codeql--raw-results-condition-p "foo(x)" "!~" "bar"))
  (should (equal (codeql--raw-results-cell-value '((label . "f()") (url . nil))) "f()"))
  (should (equal (codeql--raw-results-cell-value :false) "false")))

(ert-deftest codeql-test-raw-sort-keys ()
  "Sorting by several keys sorts the whole result set with all of them."
  (codeql-test--with-table ()
    (codeql-results-sort '((2 . "desc") (1 . "asc")))
    (let ((args (seq-find (lambda (args) (member "--format=bqrs" args)) cli)))
      (should (member "--sort-key=2,1" args))
      (should (member "--sort-direction=desc,asc" args)))
    (should (equal (plist-get codeql--raw-results-pagination :sort) '((2 . "desc") (1 . "asc"))))
    (should (string-match-p "^#\\+RESULTS_SORT: column 3 (Integer) desc, callee name asc$"
                            (buffer-string)))
    ;; a single column, as before
    (codeql-results-sort 1 "desc")
    (should (equal (plist-get codeql--raw-results-pagination :sort) '((1 . "desc"))))
    (codeql-results-sort nil)
    (should-not (plist-get codeql--raw-results-pagination :sort))
    (should-error (codeql-results-sort '((7 . "asc"))) :type 'user-error)
    (should-error (codeql-results-sort '((0 . "up"))) :type 'user-error)))

(ert-deftest codeql-test-raw-filter ()
  "Filtering shows the rows that meet all conditions and pages through them."
  (codeql-test--with-table ()
    (should (= (length (codeql-test--table-rows)) 4))
    (codeql-results-filter '((2 ">=" "3")))
    (should (= decodes 1))
    (should (equal (mapcar #'cadr (cdr (codeql-test--table-rows))) '("foo" "bar")))
    (should (string-match-p "^#\\+RESULTS_FILTER: column 3 (Integer) >= 3$" (buffer-string)))
    (should (string-match-p "^#\\+RESULTS_ROWS: 1-2 of 2 (filtered from 3)$" (buffer-string)))
    ;; the decoded rows are reused for another filter of the same order
    (codeql-results-filter '((2 ">=" "3") (0 "~" "^bar")))
    (should (= decodes 1))
    (should (equal (mapcar #'cadr (cdr (codeql-test--table-rows))) '("bar")))
    ;; a filter no row meets leaves the results as they are
    (should (equal (cadr (should-error (codeql-results-filter '((1 "=" "no pe")))
                                       :type 'user-error))
                   "No rows of #select meet callee name = \"no pe\""))
    (should (= (plist-get codeql--raw-results-pagination :total-rows) 1))
    (should-error (codeql-results-filter '((1 "~" "[")))  :type 'user-error)
    (should-error (codeql-results-filter '((1 "<>" "x"))) :type 'user-error)
    ;; filtered rows are paged too
    (let ((codeql-max-raw-results 1))
      (codeql-results-filter '((2 ">=" "3")))
      (should (= (codeql--raw-results-pages codeql--raw-results-pagination) 2))
      (should (equal (mapcar #'cadr (cdr (codeql-test--table-rows))) '("foo")))
      (codeql-results-next-page)
      (should (equal (mapcar #'cadr (cdr (codeql-test--table-rows))) '("bar"))))
    (codeql-results-filter nil)
    (should (= (plist-get codeql--raw-results-pagination :total-rows) 3))
    (should-not (string-match-p "RESULTS_FILTER" (buffer-string)))))

(ert-deftest codeql-test-raw-project ()
  "Projecting shows the chosen columns in the chosen order, in both styles."
  (codeql-test--with-table ()
    (codeql-results-project '(2 1))
    (should (equal (car (codeql-test--table-rows)) '("Integer" "callee name")))
    (should (equal (cadr (codeql-test--table-rows)) '("3" "foo")))
    (should (string-match-p "^#\\+RESULTS_COLUMNS: column 3 (Integer), callee name$" (buffer-string)))
    ;; with a filter on a column that isn't shown
    (codeql-results-filter '((0 "~" "^ba")))
    (should (equal (cdr (codeql-test--table-rows)) '(("10" "bar") ("1" "baz"))))
    (codeql-results-toggle-raw-style)
    (let ((props (codeql-test--result-properties (current-buffer))))
      (should (= (length props) 2))
      (should (equal (cdr (assoc "CODEQL_COL_CALLEE_NAME" (car props))) "bar"))
      (should-not (assoc "CODEQL_COL_CALL" (car props))))
    (codeql-results-toggle-raw-style)
    ;; all columns in their order is no projection
    (codeql-results-project '(0 1 2))
    (should-not (plist-get codeql--raw-results-pagination :projection))
    (should-error (codeql-results-project '(3)) :type 'user-error)
    (codeql-results-reset)
    (should-not (plist-get codeql--raw-results-pagination :where))
    (should (= (length (codeql-test--table-rows)) 4))))

(ert-deftest codeql-test-raw-ops-elsewhere ()
  "Table operations explain where they apply."
  (codeql-test--with-query-buffer
    (with-current-buffer (codeql-test--render-sarif '(:kind file :path "/q/P.ql"))
      (should (string-prefix-p "Only raw (table) results"
                               (cadr (should-error (codeql-results-filter nil) :type 'user-error))))))
  (with-temp-buffer
    (should (equal (cadr (should-error (codeql-results-sort nil) :type 'user-error))
                   "Not a CodeQL raw results buffer"))))

(ert-deftest codeql-test-raw-large-confirm ()
  "Sorting or filtering large result sets asks for confirmation first."
  (let (asked answer)
    (codeql-test--with-table
        (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) answer)))
      (let ((codeql-results-large-threshold 2))
        (should-error (codeql-results-filter '((2 ">" "1"))) :type 'user-error)
        (should (= decodes 0))
        (should (string-match-p "has 3 rows: filtering decodes them all into memory"
                                (car asked)))
        (setq answer t)
        (codeql-results-filter '((2 ">" "1")))
        (should (= decodes 1))
        ;; refining the filter reuses the decoded rows, without asking
        (setq asked nil)
        (codeql-results-filter '((2 ">" "5")))
        (should-not asked)
        ;; and so does a filter after one no row met
        (should-error (codeql-results-filter '((1 "=" "nope"))) :type 'user-error)
        (codeql-results-filter '((1 "=" "bar")))
        (should-not asked)
        (should (= decodes 1))
        ;; a new order needs sorting and decoding again
        (codeql-results-sort '((2 . "asc")))
        (should (string-match-p "sorting them may take a while, and filtering" (car asked)))
        ;; projections don't
        (setq asked nil)
        (codeql-results-project '(1))
        (should-not asked))
      (let ((codeql-results-large-threshold nil))
        (setq answer nil)
        (codeql-results-sort '((1 . "asc")))
        (should (equal (plist-get codeql--raw-results-pagination :sort) '((1 . "asc"))))))))

;;; Provenance of loaded SARIF and variant analysis results

(defconst codeql-test--sarif-file
  (format "{\"runs\": [{
     \"tool\": {\"driver\": {\"name\": \"CodeQL\", \"semanticVersion\": \"2.19.0\",
                           \"rules\": [{\"id\": \"js/unused\", \"name\": \"js/unused\"}]},
              \"extensions\": [{\"name\": \"codeql/javascript-queries\",
                \"rules\": [{\"id\": \"js/xss\",
                             \"shortDescription\": {\"text\": \"Cross-site scripting\"},
                             \"properties\": {\"name\": \"Client-side XSS\"}},
                            {\"id\": \"js/sql-injection\", \"name\": \"js/sql-injection\"}]}]},
     \"versionControlProvenance\": [{\"repositoryUri\": \"https://github.com/octo/app\",
                                     \"revisionId\": \"c0ffee\"}],
     \"results\": %s}]}"
          codeql-test--sarif)
  "A SARIF file of `codeql-test--sarif' that describes its tool and rules.")

(defun codeql-test--load-sarif (sarif-path &optional provenance)
  "Load SARIF-PATH like `codeql-load-sarif' does, return its results buffer."
  (codeql-test--new-results-buffer
   (lambda ()
     (setq codeql--active-database "/dbs/js-db/")
     (codeql-load-sarif sarif-path nil provenance))))

(defun codeql-test--query-source-properties (buffer)
  "Return the properties of the Query Source heading of BUFFER."
  (with-current-buffer buffer
    (codeql-test--goto-heading "Query Source")
    (org-entry-properties nil 'standard)))

(ert-deftest codeql-test-sarif-provenance ()
  "Loaded SARIF results describe the SARIF file in their Query Source section."
  (codeql-test--with-query-buffer
    (let* ((dir (make-temp-file "codeql-test-sarif" t))
           (sarif (expand-file-name "out.sarif" dir)))
      (with-temp-file sarif (insert codeql-test--sarif-file))
      (let* ((buffer (codeql-test--load-sarif sarif))
             (props (codeql-test--query-source-properties buffer)))
        (should (equal (codeql-test--headlines buffer)
                       '((1 "query-source") (2 nil) (2 nil)
                         (1 "results") (2 "result") (3 nil) (2 "result")
                         (1 nil))))
        (should (equal (cdr (assoc "CODEQL_EVALUATION" props)) "sarif"))
        (should (equal (cdr (assoc "CODEQL_SARIF" props)) sarif))
        (should (equal (cdr (assoc "CODEQL_TOOL" props)) "CodeQL 2.19.0"))
        (should (equal (cdr (assoc "CODEQL_DATABASE" props)) "/dbs/js-db"))
        (should (equal (cdr (assoc "CODEQL_REPOSITORY_URI" props)) "https://github.com/octo/app"))
        (should (equal (cdr (assoc "CODEQL_REVISION_ID" props)) "c0ffee"))
        (should-not (assoc "CODEQL_QUERY" props))
        (should (equal (codeql-test--links buffer "file") (list sarif)))
        (with-current-buffer buffer
          (codeql-test--goto-heading "Results$")
          (should (equal (org-entry-get nil "CODEQL_QUERY_KIND") "path-problem"))
          ;; only the rules that results were reported for, from any tool component
          (codeql-test--goto-heading "Rules$")
          (should (equal (string-replace
                          "\u200b" ""
                          (buffer-substring-no-properties
                           (line-beginning-position 2) (progn (org-end-of-subtree) (point))))
                         "- js/sql-injection\n- js/xss: Client-side XSS")))))))

(ert-deftest codeql-test-sarif-provenance-precedence ()
  "Provenance passed to `codeql-load-sarif' takes precedence over the SARIF's."
  (codeql-test--with-query-buffer
    (let* ((dir (make-temp-file "codeql-test-sarif" t))
           (sarif (expand-file-name "out.sarif" dir)))
      (with-temp-file sarif (insert codeql-test--sarif-file))
      (let ((props (codeql-test--query-source-properties
                    (codeql-test--load-sarif sarif '(:kind mrva :run 42 :session "s1")))))
        (should (equal (cdr (assoc "CODEQL_EVALUATION" props)) "variant-analysis"))
        (should (equal (cdr (assoc "CODEQL_MRVA_RUN" props)) "42"))
        (should (equal (cdr (assoc "CODEQL_SARIF" props)) sarif))))))

(defmacro codeql-test--with-mrva (pack-query &rest body)
  "Run BODY with a state dir, gh and downloads stubbed out for gh-mrva.

The query pack of run 42 holds PACK-QUERY as queries/Xss.ql, unless it
is nil.  `gh' calls are pushed onto `calls'."
  (declare (indent 1) (debug t))
  `(let* ((codeql-state-dir (file-name-as-directory (make-temp-file "codeql-test-state" t)))
          (pack (expand-file-name "pack" codeql-state-dir))
          (archive (expand-file-name "pack.tgz" codeql-state-dir))
          (calls nil))
     (when ,pack-query
       (make-directory (expand-file-name "queries" pack) t)
       (make-directory (expand-file-name ".codeql/libraries/dep" pack) t)
       (with-temp-file (expand-file-name "queries/Xss.ql" pack) (insert ,pack-query))
       (with-temp-file (expand-file-name ".codeql/libraries/dep/Xss.ql" pack) (insert "dep"))
       (with-temp-file (expand-file-name "qlpack.yml" pack) (insert "name: q\n"))
       (should (eql 0 (call-process "tar" nil nil nil "-czf" archive "-C" pack "."))))
     (cl-letf (((symbol-function 'codeql--gh)
                (lambda (&rest args)
                  (push args calls)
                  (pcase args
                    (`("mrva" "list" "--json")
                     "[{\"name\": \"s1\", \"controller\": \"octo/controller\"}]")
                    (`("api" ,_)
                     (if (file-exists-p archive)
                         "{\"query_pack_url\": \"https://objects.example.com/pack?sig=1\"}"
                       (error "HTTP 404"))))))
               ((symbol-function 'url-copy-file)
                (lambda (url file &rest _)
                  (should (equal url "https://objects.example.com/pack?sig=1"))
                  (copy-file archive file t)))
               ((symbol-function 'message) #'ignore))
       ,@body)))

(ert-deftest codeql-test-mrva-provenance ()
  "Variant analysis results hold the whole query as it was submitted."
  (codeql-test--with-mrva "from int x\nselect x\n"
    (let* ((local (expand-file-name "Xss.ql" codeql-state-dir))
           (repo `((nwo . "octo/app") (run_id . 42) (query . ,local))))
      (with-temp-file local (insert "edited since"))
      (let ((provenance (codeql--mrva-provenance "s1" repo)))
        (should (equal (plist-get provenance :kind) 'mrva))
        (should (equal (plist-get provenance :controller) "octo/controller"))
        (should (equal (plist-get provenance :repository) "octo/app"))
        (should (equal (plist-get provenance :path) local))
        (should (equal (plist-get provenance :source) "from int x\nselect x\n"))
        (should (plist-get provenance :source-submitted))
        (should (member '("api" "repos/octo/controller/code-scanning/codeql/variant-analyses/42")
                        calls)))
      ;; the pack is fetched once
      (setq calls nil)
      (should (equal (plist-get (codeql--mrva-provenance "s1" repo) :source)
                     "from int x\nselect x\n"))
      (should-not (assoc "api" calls))
      ;; and shown in the results
      (codeql-test--with-query-buffer
        (let* ((sarif (expand-file-name "octo_app_42.sarif" codeql-state-dir))
               (buffer (progn (with-temp-file sarif (insert codeql-test--sarif-file))
                              (codeql-test--load-sarif
                               sarif (codeql--mrva-provenance "s1" repo))))
               (props (codeql-test--query-source-properties buffer)))
          (should (equal (cdr (assoc "CODEQL_EVALUATION" props)) "variant-analysis"))
          (should (equal (cdr (assoc "CODEQL_QUERY" props)) local))
          (should (equal (cdr (assoc "CODEQL_MRVA_SESSION" props)) "s1"))
          (should (equal (cdr (assoc "CODEQL_MRVA_RUN" props)) "42"))
          (should (equal (cdr (assoc "CODEQL_MRVA_CONTROLLER" props)) "octo/controller"))
          (should (equal (cdr (assoc "CODEQL_MRVA_REPOSITORY" props)) "octo/app"))
          (should (equal (cdr (assoc "CODEQL_SARIF" props)) sarif))
          (should (equal (codeql-test--src-block-value buffer) "from int x\nselect x\n"))
          (with-current-buffer buffer
            (codeql-test--goto-heading "Submitted Query")
            (should (looking-at-p ".*\n.*as submitted to octo/controller"))))))))

(ert-deftest codeql-test-mrva-provenance-fallback ()
  "Without the query pack, the query file as it is now is shown, and said so."
  (codeql-test--with-mrva nil
    (let* ((local (expand-file-name "Xss.ql" codeql-state-dir))
           (repo `((nwo . "octo/app") (run_id . 42) (query . ,local))))
      (let ((provenance (codeql--mrva-provenance "s1" repo)))
        (should-not (plist-get provenance :source)))
      (with-temp-file local (insert "select 1\n"))
      (let ((provenance (codeql--mrva-provenance "s1" repo)))
        (should (equal (plist-get provenance :source) "select 1\n"))
        (should-not (plist-get provenance :source-submitted))
        (should (string-match-p
                 "could not be fetched, this is the query file as it is now"
                 (codeql--results-query-source-org (list :provenance provenance))))))))

(ert-deftest codeql-test-quick-eval-predicate-provenance ()
  "Quick evaluation of the enclosing predicate records the predicate name."
  (with-temp-buffer
    (insert "predicate isSmall(int x) {\n  x in [1 .. 5]\n}\n")
    (goto-char (point-min))
    (search-forward "[1")
    (cl-letf (((symbol-function 'codeql--enclosing-predicate-name-position)
               (lambda (&rest _) 11)))
      (let ((provenance (codeql--query-provenance "/q/A.ql" 'predicate)))
        (should (equal (plist-get provenance :source) "isSmall"))
        (should (plist-get provenance :predicate))
        (should (equal (plist-get provenance :line) 1))
        (should (equal (plist-get provenance :column) 11))
        (should (string-match-p "Quick evaluation of the enclosing predicate at"
                                (codeql--results-query-source-org
                                 (list :provenance provenance))))))))

;;; Result handlers

(ert-deftest codeql-test-result-handler ()
  "A result handler gets the outcome of a run instead of a results buffer."
  (codeql-test--with-query-buffer
    (let* ((calls nil)
           (outcomes nil)
           (handler (lambda (outcome) (push outcome outcomes)))
           (dir (make-temp-file "codeql-test-state" t)))
      (setq codeql--active-database "/dbs/js-db/"
            codeql--completed-query-history (make-hash-table :test #'equal))
      (codeql-test--with-stubbed-server calls
        (let ((full (make-temp-file (expand-file-name "a" dir) nil ".bqrs" "x"))
              (check (make-temp-file (expand-file-name "b" dir) nil ".bqrs" "x"))
              (empty (make-temp-file (expand-file-name "c" dir) nil ".bqrs")))
          (codeql--query-server-request-run
           (current-buffer) nil full "/q/A.ql" nil nil "/dbs/js-db" nil nil nil nil
           '(:kind file :path "/q/A.ql") handler)
          (codeql--query-server-request-run
           (current-buffer) nil check "/q/A.ql" nil nil "/dbs/js-db" nil nil nil nil
           '(:kind session :session "default" :check t) handler)
          (codeql--query-server-request-run
           (current-buffer) nil empty "/q/A.ql" nil nil "/dbs/js-db" nil nil nil nil
           '(:kind file :path "/q/A.ql") handler)
          (dolist (request (reverse calls))
            (funcall (nth 1 request) nil))
          (should-not (assq :loaded calls))
          (should (equal (mapcar (lambda (o) (list (plist-get o :status) (plist-get o :bqrs-path)))
                                 (reverse outcomes))
                         `((results ,full) (results ,check) (empty ,empty))))
          (should (equal (plist-get (car (last outcomes)) :provenance)
                         '(:kind file :path "/q/A.ql")))
          ;; definition checks of sessions stay out of the query history
          (should (equal (mapcar (lambda (run) (plist-get run :bqrs-path))
                                 (hash-table-values codeql--completed-query-history))
                         (list full))))))))

(ert-deftest codeql-test-explicit-quick-eval-region ()
  "`codeql--quick-eval-region' says what to quick evaluate, without a region."
  (with-temp-buffer
    (insert "predicate p(int x) { x = 1 }\nselect 1\n")
    (setq-local transient-mark-mode t)
    (goto-char (point-max))
    (let ((codeql--quick-eval-region (cons 11 12)))
      (let ((provenance (codeql--query-provenance "/q/A.ql" t)))
        (should (equal (plist-get provenance :source) "p"))
        (should (equal (plist-get provenance :column) 11)))
      (let ((target (plist-get (codeql--query-target "/q/A.ql" 'count) :quickEval)))
        (should (equal (plist-get (plist-get target :quickEvalPos) :line) 1))
        (should (equal (plist-get (plist-get target :quickEvalPos) :column) 11))
        (should (equal (plist-get (plist-get target :quickEvalPos) :endColumn) 12))
        (should (plist-get target :countOnly))))))

;;; Sessions

(defun codeql-test--session-available-p ()
  "Return non-nil if sessions can parse CodeQL here."
  (require 'treesit nil t)
  (codeql--session-treesit-p))

(defun codeql-test--definition (text &optional verified)
  "Return the session definition that TEXT makes, VERIFIED or not."
  (let ((definition (car (plist-get (codeql--session-parse text nil) :definitions))))
    (if verified (codeql--session-verified definition) definition)))

(defvar codeql-test--outcomes nil
  "The outcomes of session evaluations, the last one first.")

(defmacro codeql-test--with-session (runs &rest body)
  "Run BODY with `session', a CodeQL session in a stand-in pack.

The session uses no query server: the query runs it requests are pushed
onto RUNS as plists of :file, :quick-eval, :target (the code that is
quick evaluated) and the :target-line it starts on, :module, :provenance
and :handler, whose outcome
reaches `codeql-test--outcomes'."
  (declare (indent 1) (debug t))
  `(let ((root (make-temp-file "codeql-test-pack" t))
         (,runs nil)
         (codeql-test--outcomes nil)
         (codeql-session-check-definitions nil))
     (with-temp-file (expand-file-name "qlpack.yml" root)
       (insert "name: test/pack\nversion: 0.0.1\n"))
     (cl-letf (((symbol-function 'codeql--buffer-local-init-hook) #'ignore)
               ((symbol-function 'codeql-query-server-cancel-query) #'ignore)
               ((symbol-function 'codeql--query-server-run-query-from-path)
                (lambda (file quick-eval &optional _template _src-filename _src-buffer provenance)
                  (let ((bounds (codeql--quick-eval-bounds)))
                    (push (list :file file
                                :quick-eval quick-eval
                                :target (buffer-substring-no-properties (car bounds) (cdr bounds))
                                :target-line (save-excursion
                                               (goto-char (car bounds))
                                               (buffer-substring-no-properties
                                                (line-beginning-position) (line-end-position)))
                                :module (buffer-substring-no-properties (point-min) (point-max))
                                :provenance provenance
                                :handler codeql--query-result-handler)
                          ,runs)))))
       (let ((session (codeql--session-get root)))
         (unwind-protect
             (progn
               (with-current-buffer (codeql--session-buffer session)
                 (setq codeql--query-server 'server
                       codeql--active-database "/dbs/js-db/"))
               (setf (codeql--session-definitions session)
                     (codeql--session-default-definitions "javascript"))
               ,@body)
           (when (buffer-live-p (codeql--session-buffer session))
             (with-current-buffer (codeql--session-buffer session)
               (setq codeql--query-server nil)))
           (codeql--session-kill session)
           (delete-directory root t))))))

(defun codeql-test--session-eval (session input &rest args)
  "Evaluate INPUT in SESSION, with ARGS for `codeql--session-eval'."
  (apply #'codeql--session-eval session input
         (lambda (outcome) (push outcome codeql-test--outcomes))
         :frontend "test" args))

(defun codeql-test--finish-run (run &rest outcome)
  "Report OUTCOME for the query RUN, see `codeql-test--with-session'.

OUTCOME gets the :provenance of RUN."
  (funcall (plist-get run :handler)
           (append outcome (list :provenance (plist-get run :provenance)))))

(defun codeql-test--compile-error (run text)
  "Return a compiler error message for the line of RUN's module with TEXT."
  (let ((line (with-temp-buffer
                (insert (plist-get run :module))
                (goto-char (point-min))
                (search-forward text)
                (line-number-at-pos))))
    (format "ERROR: could not resolve something (%s:%d,1-5)\nWARNING: unused predicate 'q' (%s:1,1-2)\n"
            (plist-get run :file) line (plist-get run :file))))

(defun codeql-test--session-keys (session)
  "Return the keys of the definitions of SESSION."
  (mapcar (lambda (definition) (plist-get definition :key))
          (codeql--session-definitions session)))

(ert-deftest codeql-test-session-parse ()
  "Input is split into definitions and what to evaluate."
  (skip-unless (codeql-test--session-available-p))
  (let ((definitions (list (codeql-test--definition "predicate p(int x) { x = 1 }")
                           (codeql-test--definition "int f() { result = 1 }"))))
    (cl-flet ((parse (input)
                (let ((parsed (codeql--session-parse input definitions)))
                  (list (mapcar (lambda (d) (plist-get d :key)) (plist-get parsed :definitions))
                        (plist-get parsed :action)
                        (plist-get parsed :guess)))))
      (should (equal (parse "predicate p(int x, string s) { x = s.length() }")
                     '(((predicate "p" 2)) nil nil)))
      (should (equal (parse "int g() { result = 1 }\nclass C extends int { C() { this = 1 } }")
                     '(((predicate "g" 0) (type "C")) nil nil)))
      (should (equal (parse "import javascript\nmodule M { predicate q() { any() } }\nnewtype T = A()")
                     '(((import "import javascript") (module "M") (type "T")) nil nil)))
      (should (equal (parse "predicate q() { any() }\nselect 1")
                     '(((predicate "q" 0)) (select . "select 1") nil)))
      (should (equal (parse "from int x where x = 1 select x")
                     '(nil (select . "from int x where x = 1 select x") nil)))
      (should (equal (parse "1 + 2") '(nil (expression . "1 + 2") nil)))
      (should (equal (parse "f()") '(nil (expression . "f()") nil)))
      (should (equal (parse "exists(int x | x = 1)")
                     '(nil (formula . "exists(int x | x = 1)") nil)))
      (should (equal (parse "p(1)") '(nil (formula . "p(1)") nil)))
      (should (equal (parse "/* a */ p(1) // b") '(nil (formula . "/* a */ p(1) // b") nil)))
      ;; calls of predicates the session doesn't know might be either
      (should (equal (parse "foo(1)") '(nil (expression . "foo(1)") t)))
      (should (equal (parse "\"a\".length()") '(nil (expression . "\"a\".length()") t)))
      ;; a predicate of the session is quick evaluated
      (should (equal (parse "p") '(nil (predicate "p" . 1) nil)))
      (should (equal (parse "p / 1") '(nil (predicate "p" . 1) nil)))
      (should-error (parse "p/2") :type 'user-error)
      ;; the values of a type are selected
      (should (equal (parse " Integers\n") '(nil (type . "Integers") nil)))
      (should (equal (parse "DataFlow::Node") '(nil (type . "DataFlow::Node") nil)))
      (should (equal (parse "foo") '(nil (expression . "foo") nil)))
      ;; broken queries are left to the compiler to explain
      (should (equal (parse "select 1 +") '(nil (select . "select 1 +") nil))))))

(ert-deftest codeql-test-session-merge ()
  "New definitions replace those with the same key in place."
  (let* ((a (list :key "a" :text "a1" :verified t))
         (b (list :key "b" :text "b1"))
         (definitions (list a b))
         (merged (codeql--session-merge definitions (list (list :key "a" :text "a2")
                                                          (list :key "c" :text "c1")))))
    (should (equal (mapcar (lambda (d) (plist-get d :text)) definitions) '("a1" "b1")))
    (should (equal (mapcar (lambda (d) (plist-get d :text)) merged) '("a2" "b1" "c1")))))

(ert-deftest codeql-test-session-merge-remembers-previous ()
  "A redefinition remembers the last replaced definition that compiled."
  (let* ((a (list :key "a" :text "a1" :verified t))
         (once (codeql--session-merge (list a) (list (list :key "a" :text "a2"))))
         (twice (codeql--session-merge once (list (list :key "a" :text "a3")))))
    (should (eq (plist-get (car once) :previous) a))
    (should (eq (plist-get (car twice) :previous) a))
    (let ((verified (codeql--session-verified (car twice))))
      (should (plist-get verified :verified))
      (should-not (plist-member verified :previous))
      (should-not (plist-get (car twice) :verified)))))

(ert-deftest codeql-test-session-kept-definitions ()
  "Definitions with errors are rolled back unless they compiled before."
  (let* ((good (list :key "good" :verified t))
         (old (list :key "re" :text "old" :verified t))
         (new (list :key "new"))
         (re (car (codeql--session-merge (list old) (list (list :key "re" :text "new")))))
         (definitions (list good re new)))
    ;; failures that aren't about the definitions keep them all
    (should (equal (codeql--session-kept-definitions definitions nil) definitions))
    ;; an unverified definition with errors is dropped
    (should (equal (codeql--session-kept-definitions definitions '("new"))
                   (list good re)))
    ;; a broken redefinition leaves the one it replaced
    (should (equal (codeql--session-kept-definitions definitions '("re"))
                   (list good old new)))
    ;; errors in a verified definition roll back all unverified ones
    (should (equal (codeql--session-kept-definitions definitions '("good"))
                   (list good old)))))

(ert-deftest codeql-test-session-module ()
  "The query module has the definitions, then the code of the action."
  (let ((definitions (list (list :key '(import "import javascript") :text "import javascript")
                           (list :key '(predicate "p" 1)
                                 :text "predicate p(int x) {\n  x = 1\n}"))))
    (cl-flet ((action-code (action)
                (let ((module (codeql--session-module "s" definitions action)))
                  (when-let ((start (text-property-any 0 (length module)
                                                       'codeql-session-action t module)))
                    (substring-no-properties
                     module start (next-single-property-change start 'codeql-session-action
                                                               module (length module)))))))
      (should (equal (action-code '(select . "select 1")) "select 1"))
      (should (equal (action-code '(expression . "1 + 2")) "select\n1 + 2"))
      (should (string-match-p "\\`from boolean holds\nwhere\n  if (\nexists(int x | p(x))\n"
                              (action-code '(formula . "exists(int x | p(x))"))))
      (should (equal (action-code '(predicate . "p")) "select 1"))
      (should (equal (action-code '(type . "Integers")) "from Integers integers\nselect integers"))
      (should (equal (action-code '(type . "DataFlow::Node")) "from DataFlow::Node node\nselect node"))
      (should (equal (action-code '(type . "Module")) "from Module module_\nselect module_"))
      (should (string-suffix-p "\nselect count(C c)\n"
                               (codeql--session-module "s" nil '(type . "C") t)))
      (should (equal (action-code '(check)) "select 1"))
      (should-not (action-code nil)))
    (with-temp-buffer
      (insert (codeql--session-module "s" definitions '(expression . "p(_)")))
      (should (string-prefix-p "// The query module of CodeQL session s"
                               (buffer-string)))
      (let ((lines (codeql--session-definition-lines)))
        (should (equal lines '(((import "import javascript") 3 3)
                               ((predicate "p" 1) 5 7))))
        (should (equal (codeql--session-error-keys
                        (concat "ERROR: could not resolve x (/p/.codeql-session/s.ql:6,3-4)\n"
                                "ERROR: could not resolve y (/p/.codeql-session/s.ql:10,1-2)\n"
                                "ERROR: could not resolve z (/p/Other.ql:3,1-2)\n")
                        "/p/.codeql-session/s.ql" lines)
                       '((predicate "p" 1))))
        ;; locations can span lines
        (should (equal (codeql--session-error-keys
                        "ERROR: ’this’ is not bound (/p/.codeql-session/s.ql:5,3-7,4)\n"
                        "/p/.codeql-session/s.ql" lines)
                       '((predicate "p" 1))))))
    (should (equal (codeql--session-clean-message
                    (concat "ERROR: oops (/s.ql:1,1-2)\nWARNING: unused predicate 'p' (/s.ql:3,1-2)\n"
                            "WARNING: unused class ’C’ (/s.ql:4,7-8)\n"
                            "WARNING: unused datatype ’T’ (/s.ql:5,9-10)\n"))
                   "ERROR: oops (/s.ql:1,1-2)\n"))))

(ert-deftest codeql-test-session-buffer ()
  "A session lives in a hidden buffer of its pack, and goes with it."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (let* ((buffer (codeql--session-buffer session))
           (file (buffer-file-name buffer))
           (dir (file-name-directory file)))
      (should (string-prefix-p " " (buffer-name buffer)))
      (should (equal (expand-file-name "default.ql" (expand-file-name ".codeql-session" root))
                     file))
      (should (equal (with-temp-buffer
                       (insert-file-contents (expand-file-name ".gitignore" dir))
                       (buffer-string))
                     "*\n"))
      (should (eq (codeql--session-get root) session))
      (should-not (eq (codeql--session-get root "other") session))
      (codeql--session-kill (codeql--session-get root "other"))
      (with-current-buffer buffer
        (setq codeql--query-server nil))
      (codeql--session-kill session)
      (should-not (buffer-live-p buffer))
      (should-not (file-exists-p file))
      (let ((again (codeql--session-get root)))
        (should-not (eq again session))
        (setq session again)))))

(ert-deftest codeql-test-session-no-language-server ()
  "The hidden buffer of a session neither starts nor joins a language server."
  (skip-unless (and (codeql-test--session-available-p) (require 'eglot nil t)))
  (codeql-test--with-session runs
    (let (skipped)
      (cl-letf (((symbol-function 'codeql--buffer-local-init-hook)
                 (lambda ()
                   (setq codeql--lsp-inhibited codeql--inhibit-lsp)
                   (setq skipped (codeql--eglot-ensure-skip-p))))
                ;; a language server of the project is running
                ((symbol-function 'eglot-current-server)
                 (lambda () (and (derived-mode-p 'ql-tree-sitter-mode) 'server)))
                ((symbol-function 'eglot--managed-mode)
                 (lambda (&rest _) (error "Managed by eglot"))))
        (let ((other (codeql--session-get root "lsp")))
          (unwind-protect
              (with-current-buffer (codeql--session-buffer other)
                (should codeql--lsp-inhibited)
                (should skipped)
                (should (codeql--eglot-ensure-skip-p))
                (eglot--maybe-activate-editing-mode)
                (should-not (memq #'codeql--lsp-connect-after-command post-command-hook)))
            (codeql--session-kill other)))))))

(ert-deftest codeql-test-session-definitions ()
  "Definitions are kept without being compiled, unless that is asked for."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (codeql-test--session-eval session "predicate p(int x) { x = 1 }")
    (should-not runs)
    (let ((outcome (car codeql-test--outcomes)))
      (should (eq (plist-get outcome :status) 'defined))
      (should (equal (plist-get outcome :definitions) '("p/1"))))
    (should (equal (codeql-test--session-keys session)
                   '((import "import javascript") (predicate "p" 1))))
    (let ((codeql-session-check-definitions t))
      (codeql-test--session-eval session "predicate q() { p(1) }")
      (let ((run (car runs)))
        (should (string-suffix-p "predicate q() { p(1) }\n\nselect 1\n" (plist-get run :module)))
        (should (plist-get (plist-get run :provenance) :check))
        (codeql-test--finish-run run :status 'results)))
    (should (eq (plist-get (car codeql-test--outcomes) :status) 'defined))
    (should (seq-every-p (lambda (d) (plist-get d :verified))
                         (codeql--session-definitions session)))))

(ert-deftest codeql-test-session-expression ()
  "An expression is selected in a module with the session's definitions."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (codeql-test--session-eval session "predicate p(int x) { x = 1 }")
    (codeql-test--session-eval session "count(int x | p(x))")
    (let* ((run (car runs))
           (provenance (plist-get run :provenance)))
      (should (equal (plist-get run :file)
                     (buffer-file-name (codeql--session-buffer session))))
      (should-not (plist-get run :quick-eval))
      (should (equal (plist-get run :target) "select\ncount(int x | p(x))"))
      (should (string-match-p "^predicate p(int x) { x = 1 }$" (plist-get run :module)))
      (should (equal (plist-get provenance :kind) 'session))
      (should (equal (plist-get provenance :session) "default"))
      (should (equal (plist-get provenance :frontend) "test"))
      (should (equal (plist-get provenance :input) "count(int x | p(x))"))
      (should (equal (plist-get provenance :module) (plist-get run :module)))
      (should (codeql--session-pending session))
      (should-error (codeql-test--session-eval session "1") :type 'user-error)
      (codeql-test--finish-run run :status 'results :bqrs-path "/r.bqrs")
      (should-not (codeql--session-pending session))
      (let ((outcome (car codeql-test--outcomes)))
        (should (eq (plist-get outcome :status) 'results))
        (should (eq (plist-get outcome :action) 'expression))
        (should (eq (plist-get outcome :session) session))
        (should (equal (plist-get outcome :bqrs-path) "/r.bqrs")))
      (should (seq-every-p (lambda (d) (plist-get d :verified))
                           (codeql--session-definitions session))))))

(ert-deftest codeql-test-session-errors-drop-definitions ()
  "Definitions that the compiler reports errors in are rolled back."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (codeql-test--session-eval session "predicate p(int x) { x = 1 }")
    (codeql-test--session-eval session "count(int x | p(x))")
    (codeql-test--finish-run (car runs) :status 'results)
    ;; a broken definition and a broken redefinition of one that compiled
    (codeql-test--session-eval session "predicate broken() { nope() }")
    (codeql-test--session-eval session "predicate p(int x) { x = nope }")
    (codeql-test--session-eval session "1 + 2")
    (let ((run (car runs)))
      (codeql-test--finish-run
       run :status 'error
       :message (concat (codeql-test--compile-error run "nope()")
                        (codeql-test--compile-error run "x = nope"))))
    (let ((outcome (car codeql-test--outcomes)))
      (should (eq (plist-get outcome :status) 'error))
      (should (equal (sort (plist-get outcome :dropped) #'string<) '("broken/0" "p/1")))
      (should-not (string-match-p "WARNING" (plist-get outcome :message))))
    (should (equal (codeql-test--session-keys session)
                   '((import "import javascript") (predicate "p" 1))))
    (should (equal (plist-get (cadr (codeql--session-definitions session)) :text)
                   "predicate p(int x) { x = 1 }"))
    ;; errors elsewhere keep the definitions
    (codeql-test--session-eval session "predicate q() { any() }\nselect nope")
    (let ((run (car runs)))
      (codeql-test--finish-run run :status 'error
                               :message (codeql-test--compile-error run "select nope")))
    (should-not (plist-get (car codeql-test--outcomes) :dropped))
    (should (member '(predicate "q" 0) (codeql-test--session-keys session)))))

(ert-deftest codeql-test-session-retry-as-formula ()
  "A call that doesn't compile as an expression is retried as a formula."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (codeql-test--session-eval session "foo(1)")
    (codeql-test--finish-run (car runs) :status 'error :message "ERROR: not an expression\n")
    (should-not codeql-test--outcomes)
    (should (equal (length runs) 2))
    (should (string-match-p "\\`from boolean holds" (plist-get (car runs) :target)))
    (codeql-test--finish-run (car runs) :status 'results)
    (should (eq (plist-get (car codeql-test--outcomes) :action) 'formula))
    ;; when both fail, the error is that of the expression
    (codeql-test--session-eval session "bar(1)")
    (codeql-test--finish-run (car runs) :status 'error :message "expression error\n")
    (codeql-test--finish-run (car runs) :status 'error :message "formula error\n")
    (let ((outcome (car codeql-test--outcomes)))
      (should (eq (plist-get outcome :action) 'expression))
      (should (equal (plist-get outcome :message) "expression error\n")))))

(ert-deftest codeql-test-session-quick-eval ()
  "A predicate of the session is quick evaluated by name."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (codeql-test--session-eval session "predicate p(int x) { x = 1 }")
    (codeql-test--session-eval session "p")
    (let ((run (car runs)))
      (should (eq (plist-get run :quick-eval) t))
      (should (equal (plist-get run :target) "p"))
      (should (string-suffix-p "\nselect 1\n" (plist-get run :module)))
      (codeql-test--finish-run run :status 'results))
    (codeql-test--session-eval session "p" :count t)
    (should (eq (plist-get (car runs) :quick-eval) 'count))
    (should (plist-get (plist-get (car runs) :provenance) :count))))

(ert-deftest codeql-test-session-quick-eval-overloaded ()
  "Predicates with the same name and different arities are told apart."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (codeql-test--session-eval session "predicate p(int x) { x = 1 }\npredicate p(int x, int y) { x = y }")
    (should (equal (cadr (should-error (codeql-test--session-eval session "p") :type 'user-error))
                   "Predicate p is overloaded, enter one of p/1, p/2"))
    (should-not runs)
    (codeql-test--session-eval session "p/2")
    (should (equal (plist-get (car runs) :target) "p"))
    (should (equal (plist-get (car runs) :target-line) "predicate p(int x, int y) { x = y }"))
    (codeql-test--finish-run (car runs) :status 'results)
    (codeql-test--session-eval session "p/1" :count t)
    (should (equal (plist-get (car runs) :target-line) "predicate p(int x) { x = 1 }"))
    (should (eq (plist-get (car runs) :quick-eval) 'count))))

(ert-deftest codeql-test-session-cancel ()
  "Canceling reports the evaluation as canceled, and ignores its outcome."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (codeql-test--session-eval session "predicate q() { any() }\nselect 1")
    (codeql--session-cancel session)
    (should-not (codeql--session-pending session))
    (let ((outcome (car codeql-test--outcomes)))
      (should (eq (plist-get outcome :status) 'error))
      (should (plist-get outcome :cancelled)))
    (codeql-test--finish-run (car runs) :status 'results)
    (should (equal (length codeql-test--outcomes) 1))
    ;; it wasn't the definitions that failed
    (should (member '(predicate "q" 0) (codeql-test--session-keys session)))))

(ert-deftest codeql-test-session-eval-sync ()
  "A synchronous evaluation waits for and returns the outcome."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (run-at-time 0.1 nil (lambda ()
                           (codeql-test--finish-run (car runs) :status 'results
                                                    :bqrs-path "/r.bqrs")))
    (let ((outcome (codeql--session-eval-sync session "1 + 2")))
      (should (eq (plist-get outcome :status) 'results))
      (should (equal (plist-get outcome :bqrs-path) "/r.bqrs")))))

(ert-deftest codeql-test-session-provenance ()
  "The Query Source of session results shows the input and the module."
  (codeql-test--with-query-buffer
    (let* ((module "// module\n\nimport javascript\n\nselect\n1 + 2\n")
           (buffer (codeql-test--render-raw
                    (list :kind 'session :session "default" :frontend "REPL"
                          :input "1 + 2" :action 'expression :module module)
                    'table)))
      (with-current-buffer buffer
        (codeql-test--goto-heading "Query Source")
        (should (equal (org-entry-get nil "CODEQL_EVALUATION") "session"))
        (should (equal (org-entry-get nil "CODEQL_SESSION") "default"))
        (should (equal (org-element-map (org-element-parse-buffer) 'src-block
                         (lambda (b) (org-element-property :value b)))
                       (list "1 + 2\n" module)))
        (should (equal (mapcar #'car (codeql-test--headlines buffer))
                       '(1 2 2 1 1)))))))

;;; Sessions, continued

(ert-deftest codeql-test-session-describe-errors ()
  "Compiler errors tell where they are in terms of the session."
  (let ((definitions (list (list :key '(import "import javascript") :text "import javascript")
                           (list :key '(predicate "p" 1) :name "p" :arity 1 :kind 'predicate
                                 :text "predicate p(int x) {\n  x = nope\n}")))
        (lines '(((import "import javascript") 3 3) ((predicate "p" 1) 5 7))))
    (should (equal (codeql--session-describe-errors
                    "ERROR: unbound (/p/.codeql-session/s.ql:5,3-7,4)\n"
                    "/p/.codeql-session/s.ql" definitions lines)
                   "ERROR: unbound (in p/1, line 1)\n"))
    (should (equal (codeql--session-describe-errors
                    (concat "ERROR: could not resolve nope (/p/.codeql-session/s.ql:6,7-11)\n"
                            "ERROR: unexpected input (/p/.codeql-session/s.ql:10,1-2)\n"
                            "ERROR: elsewhere (/p/Other.ql:6,1-2)\n")
                    "/p/.codeql-session/s.ql" definitions lines)
                   (concat "ERROR: could not resolve nope (in p/1, line 2)\n"
                           "ERROR: unexpected input (in the input)\n"
                           "ERROR: elsewhere (/p/Other.ql:6,1-2)\n")))))

(ert-deftest codeql-test-session-errors-are-described ()
  "Session error outcomes describe the locations, and keep the compiler's message."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (codeql-test--session-eval session "predicate broken() { nope() }")
    (codeql-test--session-eval session "1 + 2")
    (let* ((run (car runs))
           (message (codeql-test--compile-error run "nope()")))
      (codeql-test--finish-run run :status 'error :message message)
      (let ((outcome (car codeql-test--outcomes)))
        (should (equal (plist-get outcome :message)
                       "ERROR: could not resolve something (in broken/0)\n"))
        (should (equal (plist-get outcome :compiler-message) message))
        (should (equal (plist-get outcome :dropped) '("broken/0")))))))

;; The query server reports locations that span lines, and quotes names with ’.
(ert-deftest codeql-test-session-types ()
  "A type name selects its values, and a broken class is rolled back."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-session runs
    (codeql-test--session-eval session "class Integers extends int {\n  Integers() {\n    this > 0\n  }\n}")
    (codeql-test--session-eval session "Integers")
    (let* ((run (car runs))
           (file (plist-get run :file))
           (line (with-temp-buffer
                   (insert (plist-get run :module))
                   (goto-char (point-min))
                   (search-forward "Integers() {")
                   (line-number-at-pos))))
      (should (equal (plist-get run :target) "from Integers integers\nselect integers"))
      (should (eq (plist-get (plist-get run :provenance) :action) 'type))
      (codeql-test--finish-run
       run :status 'error
       :message (format (concat "ERROR: The characteristic predicate for ’default::Integers’ does "
                                "not bind ’this’ to a value. (%s:%d,3-%d,4)\n"
                                "WARNING: unused class ’Integers’ (%s:%d,7-15)\n")
                        file line (+ line 2) file (1- line))))
    (let ((outcome (car codeql-test--outcomes)))
      (should (equal (plist-get outcome :message)
                     (concat "ERROR: The characteristic predicate for ’default::Integers’ does "
                             "not bind ’this’ to a value. (in Integers, line 2)\n")))
      (should (equal (plist-get outcome :dropped) '("Integers"))))
    (should-not (assoc '(type "Integers") (mapcar #'list (codeql-test--session-keys session))))
    (codeql-test--session-eval session "Integers" :count t)
    (should (equal (plist-get (car runs) :target) "select count(Integers integers)"))
    (should (plist-get (plist-get (car runs) :provenance) :count))))

;;; REPL

(ert-deftest codeql-test-repl-input-complete ()
  "Input is sent when it is complete, and continued on a new line otherwise."
  (dolist (input '("1 + 2" "select 1" "from int x where x = 1 select x"
                   "predicate p(int x) { x = 1 }" "\"a(\"" "p(1) // and" "p(1) /* ( */" ":defs" ""
                   "count(int x | x = [1 .. 3])"))
    (should (codeql-repl--input-complete-p input)))
  (dolist (input '("predicate p(int x) {" "count(int x |" "1 +" "x = 1 and"
                   "from int x" "from int x\nwhere x = 1" "\"unterminated" "/* comment"
                   "class C extends" "import"))
    (should-not (codeql-repl--input-complete-p input))))

(ert-deftest codeql-test-repl-cell ()
  "Result values are shown as text, and locations as buttons that visit them."
  (should (equal (codeql-repl--cell t) "true"))
  (should (equal (codeql-repl--cell :false) "false"))
  (should (equal (codeql-repl--cell 42) "42"))
  (should (equal (codeql-repl--cell 1.5) "1.5"))
  (should (equal (codeql-repl--cell "a\nb") "a b"))
  (should (equal (codeql-repl--cell '((label . "no location"))) "no location"))
  (let* ((codeql--source-link-prefix-box (list nil))
         (cell (cl-letf (((symbol-function 'codeql--source-link-prefix) (lambda () "")))
                 (codeql-repl--cell
                  '((label . "call")
                    (url . ((uri . "file:///src/a.js") (startLine . 3) (startColumn . 2)
                            (endLine . 3) (endColumn . 5))))))))
    (should (equal (substring-no-properties cell) "call"))
    (should (eq (get-text-property 0 'action cell) #'codeql-repl--visit))
    (should (string-prefix-p "/src/a.js::3:2" (get-text-property 0 'codeql-link cell)))))

(ert-deftest codeql-test-repl-button-return ()
  "RET pushes REPL buttons, also when a keymap such as Evil's binds <return>."
  (let* ((codeql--source-link-prefix-box (list nil))
         (cell (cl-letf (((symbol-function 'codeql--source-link-prefix) (lambda () "")))
                 (codeql-repl--cell
                  '((label . "call")
                    (url . ((uri . "file:///src/a.js") (startLine . 3) (startColumn . 2)
                            (endLine . 3) (endColumn . 5)))))))
         (shadow (let ((map (make-sparse-keymap)))
                   ;; like evil-collection's comint bindings in normal state
                   (define-key map (kbd "RET") #'comint-send-input)
                   (define-key map [return] #'comint-send-input)
                   map))
         (emulation-mode-map-alists (list (list (cons t shadow))))
         visited)
    (cl-letf (((symbol-function 'codeql--org-open-file-link)
               (lambda (link) (setq visited link))))
      (with-temp-buffer
        (insert "x " cell " y")
        (goto-char 4)
        (should (eq (key-binding (kbd "RET")) #'push-button))
        (should (eq (key-binding [return]) #'push-button))
        (call-interactively (key-binding [return]))
        (should (string-prefix-p "/src/a.js::3:2" visited))
        ;; elsewhere RET is left alone
        (goto-char (point-max))
        (should (eq (key-binding [return]) #'comint-send-input))))))

(ert-deftest codeql-test-repl-table ()
  "Results are aligned in a table, with headers when they say something."
  (let ((codeql-repl-max-column-width 6))
    (cl-flet ((table (columns rows)
                (substring-no-properties (codeql-repl--table columns rows))))
      ;; a single value is shown bare, even when its column has a name
      (should (equal (table '(((kind . "Integer"))) '(("3"))) "3"))
      (should (equal (table '(((name . "holds") (kind . "Boolean"))) '(("true"))) "true"))
      (should (equal (table '(((kind . "Integer"))) '(("1") ("22"))) " 1\n22"))
      ;; numbers are aligned to the right, long cells are truncated
      (should (equal (table '(((name . "s") (kind . "String")) ((name . "n") (kind . "Integer")))
                            '(("abc" "7") ("abcdefghij" "123")))
                     "s      │   n\n───────┼────\nabc    │   7\nabcde… │ 123"))
      ;; columns without names are numbered
      (should (equal (table '(((kind . "Integer")) ((kind . "Integer"))) '(("1" "2")))
                     "[0] │ [1]\n────┼────\n  1 │   2")))))

(ert-deftest codeql-test-repl-format-outcome ()
  "Outcomes are printed as what was defined, what failed and was rolled back."
  (cl-flet ((text (outcome)
              (let ((codeql-repl--started nil))
                (substring-no-properties (codeql-repl--format-outcome outcome)))))
    (should (equal (text '(:status defined :definitions ("p/1" "q/0"))) "Defined p/1, q/0."))
    (should (equal (text '(:status defined)) "Nothing new was defined."))
    (should (equal (text '(:status empty)) "No results."))
    (should (equal (text '(:status error :cancelled t)) "Canceled."))
    (should (equal (text '(:status error :message "ERROR: oops (in p/1)\n"
                                   :definitions ("p/1" "q/0") :dropped ("p/1")))
                   "Defined q/0.\nERROR: oops (in p/1)\nRolled back p/1."))
    (should (equal (text '(:status defined :definitions ("p/1" "C" "D" "q/0" "r/0")
                                   :redefined ("C" "D") :unchanged ("p/1") :repeated ("q/0")))
                   (concat "Defined q/0, r/0.\n"
                           "Redefined C, D, which replaces the previous definitions.\n"
                           "p/1 was already defined like that.\n"
                           "q/0 is defined more than once in the input, the last definition counts.")))
    ;; a rolled back redefinition didn't replace anything
    (should (equal (text '(:status error :message "ERROR: oops (in C)\n"
                                   :definitions ("C") :redefined ("C") :dropped ("C")))
                   "ERROR: oops (in C)\nRolled back C."))))

(ert-deftest codeql-test-session-changes ()
  "Entered definitions are told apart as new, redefined, unchanged and repeated."
  (skip-unless (codeql-test--session-available-p))
  (let* ((p (codeql-test--definition "predicate p(int x) { x = 1 }" t))
         (c (codeql-test--definition "class C extends int { C() { this = 1 } }" t))
         (definitions (list p c))
         (entered (plist-get (codeql--session-parse
                              (concat "predicate p(int x) {\n  x = 1\n}\n"
                                      "class C extends int { C() { this = 2 } }\n"
                                      "predicate p(int x, int y) { x = y }\n"
                                      "predicate q() { any() }\npredicate q() { none() }")
                              definitions)
                             :definitions))
         (changes (codeql--session-changes definitions entered)))
    (should (equal (plist-get changes :redefined) '("C")))
    (should (equal (plist-get changes :unchanged) '("p/1")))
    (should (equal (plist-get changes :repeated) '("q/0")))
    ;; what is unchanged isn't merged, and stays verified
    (should (equal (mapcar (lambda (d) (plist-get d :key)) (plist-get changes :new))
                   '((type "C") (predicate "p" 2) (predicate "q" 0) (predicate "q" 0))))
    (let ((merged (codeql--session-merge definitions (plist-get changes :new))))
      (should (eq (car merged) p))
      (should (equal (plist-get (car (last merged)) :text) "predicate q() { none() }")))))

(defmacro codeql-test--with-repl (runs &rest body)
  "Run BODY in a REPL buffer of a CodeQL session, see `codeql-test--with-session'.

`codeql--session-decode' returns `codeql-test--decoded'."
  (declare (indent 1) (debug t))
  `(codeql-test--with-session ,runs
     (let ((codeql-repl-history-file nil)
           (codeql-test--decoded nil))
       (with-current-buffer (codeql--session-buffer session)
         (setq codeql--active-database-language "javascript"))
       (cl-letf (((symbol-function 'codeql--session-ensure) (lambda (s &rest _) s))
                 ((symbol-function 'codeql--session-decode)
                  (lambda (&rest _) codeql-test--decoded)))
         (let ((repl (codeql-repl--start root "default")))
           (unwind-protect
               (with-current-buffer repl
                 ,@body)
             (with-current-buffer repl
               (setq codeql-repl--session nil))
             (kill-buffer repl)))))))

(defvar codeql-test--decoded nil
  "What the REPL decodes results to in `codeql-test--with-repl'.")

(defun codeql-test--repl-enter (input)
  "Enter INPUT in the current REPL buffer, and return the output it prints."
  (let ((start (point-max)))
    (codeql-repl--enter input)
    (codeql-test--repl-output start (1+ (cl-count ?\n input)))))

(defun codeql-test--repl-output (start &optional lines)
  "Return what the current REPL buffer printed after START, without the prompt.
The first LINES lines (default 1) after START are the echoed input."
  (string-remove-suffix
   codeql-repl-prompt
   (buffer-substring-no-properties
    (save-excursion (goto-char start) (forward-line (or lines 1)) (point))
    (point-max))))

(ert-deftest codeql-test-repl-redefinitions ()
  "The REPL warns when definitions replace others, or repeat in the input."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-repl runs
    (should (equal (codeql-test--repl-enter
                    "class Integers extends int { Integers() { this in [1 .. 9] } }")
                   "Defined Integers.\n"))
    (should (equal (codeql-test--repl-enter
                    "class Integers extends int {\n  Integers() { this in [1 .. 9] }\n}")
                   "Integers was already defined like that.\n"))
    (should (equal (codeql-test--repl-enter
                    "class Integers extends int { Integers() { this in [1 .. 5] } }")
                   "Redefined Integers, which replaces the previous definition.\n"))
    (should (eq (get-text-property (- (point-max) (length codeql-repl-prompt) 2) 'font-lock-face)
                'warning))
    (should (equal (codeql-test--repl-enter "predicate q() { any() }\npredicate q() { none() }")
                   (concat "Defined q/0.\nq/0 is defined more than once in the input, "
                           "the last definition counts.\n")))
    (should (equal (codeql-test--session-keys session)
                   '((import "import javascript") (type "Integers") (predicate "q" 0))))))

(ert-deftest codeql-test-repl-round-trip ()
  "Input is evaluated in the session of the REPL, which prints the outcome."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-repl runs
    (should (string-match-p "\\`CodeQL REPL, session default of " (buffer-string)))
    (should (string-suffix-p codeql-repl-prompt (buffer-string)))
    (should (equal (codeql-test--repl-enter "predicate p(int x) { x = [1 .. 3] }")
                   "Defined p/1.\n"))
    (let ((start (point-max)))
      (should (equal (codeql-test--repl-enter "count(int x | p(x))") ""))
      (should (equal (plist-get (car runs) :target) "select\ncount(int x | p(x))"))
      (should (equal (plist-get (plist-get (car runs) :provenance) :frontend) "REPL"))
      ;; the outcome is printed before a new prompt
      (setq codeql-test--decoded '((((kind . "Integer"))) ((3)) 1))
      (codeql-test--finish-run (car runs) :status 'results :bqrs-path "/r.bqrs")
      (should (string-match-p "\\`3\n1 result in [0-9.]+s \\[results\\]\n\\'"
                              (codeql-test--repl-output start)))
      (should (eq (plist-get codeql-repl--outcome :status) 'results))
      (should (button-at (- (point-max) (length codeql-repl-prompt) 2)))
      (should (eq (get-char-property (- (point-max) (length codeql-repl-prompt) 2) 'keymap)
                  codeql-repl-button-map)))
    ;; one evaluation at a time
    (codeql-test--repl-enter "1 + 2")
    (should (string-match-p "\\`An evaluation is running" (codeql-test--repl-enter "2 + 3")))
    (should (equal (codeql-test--repl-enter ":cancel") "Canceled.\n"))
    (should-not (codeql--session-pending session))))

(ert-deftest codeql-test-repl-commands ()
  "REPL commands, which can be abbreviated, act on the session."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-repl runs
    (codeql-test--repl-enter "predicate p(int x) { x = 1 }\nint f() { result = 2 }")
    (should (equal (codeql-test--repl-enter ":defs")
                   (concat "import javascript\npredicate p/1 (not compiled yet)\n"
                           "predicate f/0 (not compiled yet)\n")))
    (should (equal (codeql-test--repl-enter ":de f") "int f() { result = 2 }\n"))
    (should (equal (codeql-test--repl-enter ":undef p") "Removed p/1.\n"))
    (should (equal (codeql-test--repl-enter ":undef p") "No definition named p\n"))
    (should (equal (codeql-test--repl-enter ":reset") "Removed all definitions.\n"))
    (should (equal (codeql-test--session-keys session) '((import "import javascript"))))
    (should (equal (codeql-test--repl-enter ":nope") "Unknown command :nope, :help lists them\n"))
    (should (equal (codeql-test--repl-enter ":c")
                   "Ambiguous command :c, it may be :count :cancel :clear\n"))
    (should (equal (codeql-test--repl-enter ":cancel") "No evaluation is running.\n"))
    (should (equal (codeql-test--repl-enter ":count") "Usage: :count PREDICATE[/ARITY]|TYPE\n"))
    (should (string-match-p "^  :help +list the REPL commands$"
                            (codeql-test--repl-enter ":help")))
    (should (string-match-p "\\`/dbs/js-db/ (javascript)" (codeql-test--repl-enter ":db")))
    (codeql-test--repl-enter "predicate q() { any() }")
    (codeql-test--repl-enter ":count q")
    (should (eq (plist-get (car runs) :quick-eval) 'count))
    (codeql-test--repl-enter ":cancel")
    (codeql-test--repl-enter ":clear")
    (should (equal (buffer-string) codeql-repl-prompt))))

(ert-deftest codeql-test-repl-completion ()
  "Commands are completed after a colon, and definitions and keywords otherwise."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-repl runs
    (codeql-test--repl-enter "predicate manyArgs(int x) { x = 1 }")
    (insert ":de")
    (let ((capf (codeql-repl--completion-at-point)))
      (should (equal (all-completions "de" (nth 2 capf)) '("defs"))))
    (comint-kill-input)
    (insert "exists(int x | man")
    (let ((capf (codeql-repl--completion-at-point)))
      (should (equal (buffer-substring (nth 0 capf) (nth 1 capf)) "man"))
      (should (equal (all-completions "man" (nth 2 capf)) '("manyArgs")))
      (should (member "exists" (all-completions "ex" (nth 2 capf)))))))

(ert-deftest codeql-test-repl-overloads ()
  "A bare name of overloaded predicates asks which one to evaluate."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-repl runs
    (codeql-test--repl-enter "predicate p(int x) { x = 1 }\npredicate p(int x, int y) { x = y and p(x) }")
    (let ((asked nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (setq asked (list prompt (mapcar #'car collection)
                                     (mapcar (plist-get completion-extra-properties
                                                        :annotation-function)
                                             '("p/1" "p/2"))))
                   "p/2")))
        (should (equal (codeql-test--repl-enter "p") "Evaluating p/2.\n")))
      (should (equal asked '("Predicate p is overloaded, evaluate: " ("p/1" "p/2")
                             ("  predicate p(int x)" "  predicate p(int x, int y)"))))
      (should (equal (plist-get (car runs) :target-line)
                     "predicate p(int x, int y) { x = y and p(x) }"))
      (should (equal (plist-get (plist-get (car runs) :provenance) :input) "p/2"))
      (codeql-test--finish-run (car runs) :status 'empty))
    ;; quitting explains the ambiguity instead
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
      (should (equal (codeql-test--repl-enter "p")
                     "Predicate p is overloaded, enter one of p/1, p/2\n"))
      (should (equal (length runs) 1)))
    ;; :count asks as well, NAME/ARITY doesn't
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "p/1")))
      (should (equal (codeql-test--repl-enter ":count p") "Counting p/1.\n")))
    (should (eq (plist-get (car runs) :quick-eval) 'count))
    (codeql-test--finish-run (car runs) :status 'empty)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "Asked"))))
      (codeql-test--repl-enter "p/1")
      (should (equal (plist-get (car runs) :target-line) "predicate p(int x) { x = 1 }")))))

(ert-deftest codeql-test-repl-completion-overloads ()
  "Overloaded predicates are completed as NAME/ARITY too, with their signatures."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-repl runs
    (codeql-test--repl-enter
     "/** Doc. */\npredicate p(int x) { x = 1 }\npredicate p(int x, int y) { x = y }")
    (codeql-test--repl-enter "class C extends int {\n  C() { this = 1 }\n}")
    (insert "p")
    (let* ((capf (codeql-repl--completion-at-point))
           (annotate (plist-get (nthcdr 3 capf) :annotation-function)))
      (should (equal (all-completions "p" (nth 2 capf)) '("p" "p/1" "p/2" "predicate")))
      (should (equal (funcall annotate "p") "  p/1, p/2"))
      (should (equal (funcall annotate "p/1") "  predicate p(int x)"))
      (should (equal (funcall annotate "C") "  class C extends int"))
      (should (equal (funcall annotate "predicate") "  keyword")))
    (insert "/")
    (let ((capf (codeql-repl--completion-at-point)))
      (should (equal (buffer-substring (nth 0 capf) (nth 1 capf)) "p/"))
      (should (equal (all-completions "p/" (nth 2 capf)) '("p/1" "p/2"))))))

(ert-deftest codeql-test-repl-continuation ()
  "Incomplete input continues on an indented line, despite earlier output."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-repl runs
    (codeql-repl--print "unbalanced output ))")
    (insert "exists(int x |")
    (codeql-repl-return)
    (should-not runs)
    (insert "x = 1")
    (should (string-suffix-p "exists(int x |\n  x = 1" (buffer-string)))
    (insert ")")
    (codeql-repl-return)
    (should (equal (plist-get (plist-get (car runs) :provenance) :input)
                   "exists(int x |\n  x = 1)"))))

(ert-deftest codeql-test-repl-history ()
  "The input history keeps multi-line inputs whole."
  (skip-unless (codeql-test--session-available-p))
  (let ((file (make-temp-file "codeql-repl-history")))
    (unwind-protect
        (progn
          (codeql-test--with-repl runs
            (setq-local comint-input-ring-file-name file)
            (codeql-test--repl-enter "predicate p(int x) {\n  x = 1\n}")
            (codeql-test--repl-enter ":defs")
            (codeql-repl--write-history))
          (with-temp-buffer
            (setq-local comint-input-ring-separator "\n\0\n"
                        comint-input-ring-file-name file)
            (comint-read-input-ring)
            (should (equal (ring-elements comint-input-ring)
                           '(":defs" "predicate p(int x) {\n  x = 1\n}")))))
      (delete-file file))))

;;; Org Babel

(require 'ob-codeql)

(defvar codeql-test--decoded-rows nil
  "The number of rows that `codeql-test--with-babel' was asked to decode.")

(defmacro codeql-test--with-babel (runs &rest body)
  "Run BODY with source blocks evaluated in a CodeQL pack at `root'.

See `codeql-test--with-session'.  `codeql--session-decode' returns
`codeql-test--decoded'."
  (declare (indent 1) (debug t))
  `(codeql-test--with-session ,runs
     (let ((codeql-test--decoded nil)
           (codeql-test--decoded-rows nil)
           (org-confirm-babel-evaluate nil))
       (with-current-buffer (codeql--session-buffer session)
         (setq codeql--active-database-language "javascript"))
       (cl-letf (((symbol-function 'codeql--session-ensure) (lambda (s &rest _) s))
                 ((symbol-function 'codeql--session-decode)
                  (lambda (_session _path rows)
                    (setq codeql-test--decoded-rows rows)
                    codeql-test--decoded))
                 ((symbol-function 'codeql--source-link-prefix) (lambda () "")))
         (unwind-protect
             (progn ,@body)
           (let ((anonymous (gethash (cons (file-name-as-directory root)
                                           ob-codeql--anonymous-session)
                                     codeql--sessions)))
             (when anonymous
               (codeql--session-kill anonymous))))))))

(defun codeql-test--babel (root block &optional finish)
  "Evaluate the source BLOCK in an org buffer in ROOT.

FINISH, when non-nil, is called to finish the query run of BLOCK while
it is awaited.  Return (VALUE . TEXT) of the result value and of the
org text after the block."
  (with-temp-buffer
    (setq default-directory (file-name-as-directory root))
    (org-mode)
    (insert block "\n")
    (goto-char (point-min))
    (when finish
      (run-at-time 0.05 nil finish))
    (let ((value (org-babel-execute-src-block)))
      (goto-char (point-min))
      (re-search-forward "^[ \t]*#\\+end_src\n")
      (cons value (buffer-substring-no-properties (point) (point-max))))))

(ert-deftest codeql-test-babel-cell ()
  "Values become org table cells, and locations codeql links."
  (let ((codeql--source-link-prefix-box (list nil)))
    (cl-letf (((symbol-function 'codeql--source-link-prefix) (lambda () "")))
      (should (equal (ob-codeql--cell t) "true"))
      (should (equal (ob-codeql--cell :false) "false"))
      (should (equal (ob-codeql--cell 42) 42))
      (should (equal (ob-codeql--cell "a|b\nc") "a¦b c"))
      (should (equal (ob-codeql--cell '((label . "*bold*"))) "\u200b*\u200bbold\u200b*\u200b"))
      (should (equal (ob-codeql--cell
                      '((label . "a|b")
                        (url . ((uri . "file:///src/a.js") (startLine . 3) (startColumn . 2)
                                (endLine . 3) (endColumn . 5)))))
                     "[[codeql:/src/a.js::3:2:3:5][a¦b]]")))))

(ert-deftest codeql-test-babel-results ()
  "Results become a table under the names of the columns, or one value."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-babel runs
    (setq codeql-test--decoded
          '((((name . "x") (kind . "Integer")) ((kind . "String")))
            ([1 "a|b"] [2 "c"])
            3))
    (let ((result (codeql-test--babel
                   root "#+begin_src codeql :limit 2\nfrom int x select x, \"a|b\"\n#+end_src"
                   (lambda () (codeql-test--finish-run (car runs) :status 'results
                                                       :bqrs-path "/r.bqrs")))))
      (should (equal (car result) '(("x" "String") hline (1 "a¦b") (2 "c"))))
      (should (string-match-p "\\`\n#\\+RESULTS:\n| x | String |\n|---\\+--------|\n| 1 | a¦b    |\n"
                              (cdr result)))
      (should (equal codeql-test--decoded-rows 2))
      (should (equal (plist-get (plist-get (car runs) :provenance) :frontend) "Org Babel")))
    ;; a single value is returned as is, strings with their lines
    (setq codeql-test--decoded '((((kind . "String"))) (["a|b\nc"]) 1))
    (should (equal (cdr (codeql-test--babel
                         root "#+begin_src ql\n\"a|b\\nc\"\n#+end_src"
                         (lambda () (codeql-test--finish-run (car runs) :status 'results
                                                             :bqrs-path "/r.bqrs"))))
                   "\n#+RESULTS:\n: a|b\n: c\n"))
    (should (equal codeql-test--decoded-rows ob-codeql-default-limit))
    ;; predicates can be counted
    (codeql-test--babel root "#+begin_src codeql :session\npredicate p(int x) { x = 1 }\n#+end_src")
    (should (equal (car (codeql-test--babel
                         root "#+begin_src codeql :session :count yes\np\n#+end_src"
                         (lambda () (codeql-test--finish-run (car runs) :status 'empty))))
                   nil))
    (should (eq (plist-get (car runs) :quick-eval) 'count))))

(ert-deftest codeql-test-babel-sessions ()
  "Blocks without a :session forget their definitions, others share a session."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-babel runs
    (let ((block "#+begin_src codeql%s\npredicate p() { any() }\n#+end_src")
          (use "#+begin_src codeql%s\npredicate q() { p() }\n#+end_src"))
      (should (equal (car (codeql-test--babel root (format block ""))) "Defined p/0."))
      (should (equal (car (codeql-test--babel root (format use ""))) "Defined q/0."))
      (let ((keys (codeql-test--session-keys (codeql--session-get root "org-babel"))))
        (should (member '(predicate "q" 0) keys))
        (should-not (member '(predicate "p" 0) keys)))
      (should (equal (car (codeql-test--babel root (format block " :session"))) "Defined p/0."))
      (should (equal (car (codeql-test--babel root (format block " :session")))
                     "p/0 was already defined like that."))
      (should (equal (car (codeql-test--babel root (format use " :session default")))
                     "Defined q/0."))
      ;; the session of a name is that of the REPL
      (should (equal (codeql-test--session-keys session)
                     '((import "import javascript") (predicate "p" 0) (predicate "q" 0))))
      (should (equal (car (codeql-test--babel root (format block " :session other")))
                     "Defined p/0."))
      (let ((other (codeql--session-get root "other")))
        (should-not (eq other session))
        (codeql--session-kill other))
      (should-error (codeql-test--babel root (format block " :var x=1")) :type 'user-error))))

(ert-deftest codeql-test-babel-errors ()
  "Failed evaluations show the error, and what was rolled back."
  (skip-unless (codeql-test--session-available-p))
  (codeql-test--with-babel runs
    (let ((result (codeql-test--babel
                   root "#+begin_src codeql :session\npredicate broken() { nope() }\nselect 1\n#+end_src"
                   (lambda ()
                     (let ((run (car runs)))
                       (codeql-test--finish-run
                        run :status 'error
                        :message (codeql-test--compile-error run "nope()")))))))
      (should-not (car result))
      (with-current-buffer org-babel-error-buffer-name
        (should (string-match-p "could not resolve something (in broken/0)\nRolled back broken/0\\."
                                (buffer-string))))
      (should-not (member '(predicate "broken" 0) (codeql-test--session-keys session))))))

(ert-deftest codeql-test-babel-root ()
  "Blocks are evaluated in their pack, or in that of the language of a database."
  (let ((pack (make-temp-file "codeql-test-pack" t))
        (outside (make-temp-file "codeql-test-outside" t))
        (database (make-temp-file "codeql-test-db" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "qlpack.yml" pack)
            (insert "name: test/pack\nversion: 0.0.1\n"))
          (with-temp-file (expand-file-name "codeql-database.yml" database)
            (insert "---\nsourceLocationPrefix: \"/src\"\nprimaryLanguage: \"javascript\"\n"))
          (should (equal (codeql--database-language database) "javascript"))
          (should-not (codeql--database-language outside))
          (let ((default-directory (file-name-as-directory pack)))
            (should (equal (ob-codeql--root nil nil) (cons (file-name-as-directory pack) nil))))
          (let ((default-directory (file-name-as-directory outside)))
            (should (equal (ob-codeql--root `((:pack . ,pack)) "/db")
                           (cons (file-name-as-directory pack) "/db")))
            (cl-letf (((symbol-function 'codeql--session-fallback-root)
                       (lambda (language) (format "/fallback/%s/" language))))
              (should (equal (ob-codeql--root nil database)
                             (cons "/fallback/javascript/" database)))
              (should-error (ob-codeql--root nil nil) :type 'user-error)
              (should-error (ob-codeql--root nil outside) :type 'user-error))))
      (dolist (directory (list pack outside database))
        (delete-directory directory t)))))

(ert-deftest codeql-test-session-fallback-root ()
  "The pack of sessions outside of packs depends on the library of the language."
  (let* ((codeql-state-dir (make-temp-file "codeql-test-state" t))
         (codeql-use-gh-codeql-extension-when-available nil)
         (codeql-cli "codeql")
         (commands nil))
    (unwind-protect
        (cl-letf (((symbol-function 'codeql--shell-command-to-string)
                   (lambda (command)
                     (push command commands)
                     (let ((root (car (last (split-string-shell-command command)))))
                       (write-region "" nil (expand-file-name "codeql-pack.lock.yml" root) nil 0))
                     "")))
          (let ((root (codeql--session-fallback-root "python")))
            (should (equal root (expand-file-name "sessions/python/" codeql-state-dir)))
            (should (equal (with-temp-buffer
                             (insert-file-contents (expand-file-name "qlpack.yml" root))
                             (buffer-string))
                           (concat "name: emacs-codeql/python-session\nversion: 0.0.1\n"
                                   "dependencies:\n  codeql/python-all: \"*\"\n")))
            (should (string-match-p "\\`codeql pack install " (car commands)))
            ;; installed once
            (should (equal (codeql--session-fallback-root "python") root))
            (should (equal (length commands) 1))))
      (delete-directory codeql-state-dir t))))

;;; Query x-ray

(defconst codeql-test--xray-source
  '("/** A query. */"
    "import javascript"
    ""
    "module Inner {"
    "  pragma[noinline]"
    "  predicate big(File f, int n) { n = f.getNumberOfLines() and f.getBaseName() = \"{\" }"
    ""
    "  class Big extends File {"
    "    int n;"
    "    Big() { big(this, n) }"
    "    // a member { with a brace"
    "    int lines() {"
    "      result = n"
    "    }"
    "  }"
    "}"
    ""
    "newtype TKind = TA() or TB(int i) { i = [1 .. 2] }"
    ""
    "query predicate files(Inner::Big b, int n) { n = b.lines() }"
    ""
    "int unused(int x, Map<int, int>::T y) { x = 1 and result = 2 }"
    ""
    "from Inner::Big b"
    "where b.lines() > 100"
    "select b, b.lines()"
    ""
    "predicate after() { any() }")
  "Deep.ql, the query of the x-ray tests, a definition of each kind.")

(defconst codeql-test--xray-dil
  '("overlayLocal"
    "`Lib::helper/1#11`(int x)"
    "{"
    "  x = 1"
    "}"
    ""
    "`Deep::Inner::big/2#0154355b`("
    "  /* Files::File */ interned unique entity f,"
    "  int n"
    ")"
    "{"
    "  `Lib::helper/1#11`(n)"
    "}"
    ""
    "#select(int b, int n)"
    "{"
    "  `Deep::Inner::big/2#0154355b`(b, n)"
    "}")
  "The DIL of Deep.ql.")

(defconst codeql-test--xray-ra
  '("LOAD RELATION: files(unique entity id, cached string name)"
    "EVALUATE NONRECURSIVE RELATION:"
    "  `Lib::helper/1#11`(int x) :- "
    "    {1} r1 = CONSTANT(int)[1]"
    "    return r1"
    ""
    "EVALUATE RECURSIVE LAYER:"
    "  rec `Deep::Inner::Big.lines/0#dispred#77`(int this, int result) :- "
    "    [[[ BASE CASE ]]]"
    "    {2} r1 = SCAN `Deep::Inner::big/2#0154355b` OUTPUT In.0, In.1"
    "    return r1"
    ""
    "  rec `Other::q/1#22`(int x) :- "
    "    {2} r1 = SCAN `Deep::Inner::Big.lines/0#dispred#77#prev_delta` OUTPUT In.1, In.0"
    "    return r1"
    ""
    "EVALUATE NONRECURSIVE RELATION:"
    "  #select(int b, int n) :- "
    "    {2} r1 = SCAN `Deep::Inner::Big.lines/0#dispred#77` OUTPUT In.0 'b', In.1 'n'"
    "    return r1")
  "The RA of Deep.ql.")

(defconst codeql-test--xray-inst
  '("import javascript"
    "module Flow = TaintTracking::Global<Config>;"
    "module Graph = PathGraph<Flow::PathNode,"
    "  Flow::PathGraph>;"
    "from Flow::PathNode n"
    "select n")
  "Inst.ql, instantiating parameterized modules.")

(defconst codeql-test--xray-g "TaintTracking::Global<Lib::Config>::Flow")

(defconst codeql-test--xray-inst-dil
  (let ((g codeql-test--xray-g))
    (list (format "`%s::p/0#1`()" g)
          "{ }"
          ""
          (format "`Lib::PathGraph<%s::PathNode,%s::PathGraph>::edges/2#2`(int a, int b)" g g)
          "{ }"
          ""
          (format "`Impl::Sens<%s::Input>::q/0#3`()" g)
          "{ }"
          ""
          "`TaintTracking::Global<Lib::Other>::Flow::p/0#4`()"
          "{ }"
          ""
          (format "#select(/* Lib::PathGraph<%s::PathNode, %s::PathGraph>::Node */ int n)" g g)
          "{ `TaintTracking::Global<Lib::Other>::Flow::p/0#4`() }"))
  "The DIL of Inst.ql.")

(defconst codeql-test--xray-inst-ra
  (let ((g codeql-test--xray-g))
    (list "EVALUATE NONRECURSIVE RELATION:"
          (format "  `Impl::Sens<%s::Input>::q/0#3`() :- " g)
          "    return r1"
          ""
          "EVALUATE NONRECURSIVE RELATION:"
          (format "  `num#%s::p/0#9`(int x) :- " g)
          "    return r1"
          ""
          "EVALUATE NONRECURSIVE RELATION:"
          "  #select(int n) :- "
          "    return r1"
          ""
          "EVALUATE NONRECURSIVE RELATION:"
          "  `num#TaintTracking::Global<Lib::Other>::Flow::p/0#8`() :- "
          "    return r1"))
  "The RA of Inst.ql.")

(defun codeql-test--xray-summary (defs)
  "Return DEFS as strings of their kinds, keys and rows."
  (mapcar (lambda (def)
            (format "%s %s %d-%d" (codeql-xray-def-kind def)
                    (string-join (codeql-xray-def-keys def) ",")
                    (codeql-xray-def-srow def) (codeql-xray-def-erow def)))
          defs))

(ert-deftest codeql-test-xray-outline ()
  "The definitions of a query and the keys of their relations are found."
  (let ((defs (codeql-xray--outline codeql-test--xray-source)))
    (should (equal (codeql-test--xray-summary defs)
                   '("predicate Inner::big/2 4-5"
                     "class Inner::Big 7-14"
                     "predicate Inner::Big.lines/0 11-13"
                     "newtype TKind,TA,TB 17-17"
                     "predicate files/2,query:files 19-19"
                     "predicate unused/2 21-21"
                     "select #select 23-25"
                     "predicate after/0 27-27")))
    ;; the characteristic predicate is part of its class
    (should (eq (codeql-xray-def-kind (codeql-xray--def-at defs 9)) 'class))
    (should (eq (codeql-xray-def-kind (codeql-xray--def-at defs 8)) 'class))
    (should (equal (car (codeql-xray-def-keys (codeql-xray--def-at defs 12)))
                   "Inner::Big.lines/0"))
    (should-not (codeql-xray--def-at defs 16))))

(ert-deftest codeql-test-xray-keys ()
  "Relations of the query module are named by their keys, the others not."
  (should (equal (codeql-xray--key "`Deep::Inner::big/2#0154355b`" "Deep") "Inner::big/2"))
  (should (equal (codeql-xray--key "`#Deep::C.p/1#dispred#1234Merge`" "Deep") "C.p/1"))
  (should (equal (codeql-xray--key "project#Deep#ab12cd::p/0#ff" "Deep") "p/0"))
  (should (equal (codeql-xray--key "Deep::M<int, Other::X<Y>>::C#99" "Deep") "M::C"))
  (should (equal (codeql-xray--key "#select#query" "Deep") "#select"))
  (should (equal (codeql-xray--key "edges#query" "Deep") "query:edges"))
  (should-not (codeql-xray--key "`Files::Container.getRelativePath/0#dispred#6933ed0f`" "Deep"))
  (should-not (codeql-xray--key "`DeepLib::p/0#12`" "Deep"))
  (should-not (codeql-xray--key "`NotDeep::p/0#12`" "Deep"))
  ;; a library module named like the query
  (should-not (codeql-xray--key "`DeepQuery::Deep::isSink/1#55`" "Deep")))

(ert-deftest codeql-test-xray-blocks ()
  "The dumps are split into blocks, the RA with all relations of a layer."
  (let ((dil (codeql-xray--blocks codeql-test--xray-dil "DIL"))
        (ra (codeql-xray--blocks codeql-test--xray-ra "RA")))
    (should (equal (mapcar #'codeql-xray-block-first dil) '(0 6 14)))
    (should (equal (mapcar #'codeql-xray-block-names dil)
                   '(("Lib::helper/1#11") ("Deep::Inner::big/2#0154355b") ("#select"))))
    (should (equal (mapcar (lambda (b) (list (codeql-xray-block-first b) (codeql-xray-block-last b)))
                           ra)
                   '((0 0) (1 4) (6 14) (16 19))))
    (should (equal (codeql-xray-block-names (nth 2 ra))
                   '("Deep::Inner::Big.lines/0#dispred#77" "Other::q/1#22")))
    (should-not (codeql-xray-block-names (nth 0 ra)))))

(ert-deftest codeql-test-xray-users-and-map ()
  "Definitions are used by others, and blocks map to their definitions."
  (let* ((defs (codeql-xray--outline codeql-test--xray-source))
         (users (codeql-xray--users codeql-test--xray-source defs)))
    (cl-flet ((names (name)
                (mapcar #'codeql-xray-def-name
                        (gethash (seq-find (lambda (d) (equal (codeql-xray-def-name d) name)) defs)
                                 users))))
      ;; the class itself, with its characteristic predicate, doesn't count
      (should (equal (names "big") '("Big")))
      (should (equal (names "Big") '("files" "select")))
      (should (equal (names "lines") '("files" "select")))
      (should-not (names "unused")))
    (should (equal (mapcar (lambda (m) (car (codeql-xray-def-keys (cdr m))))
                           (codeql-xray--map (codeql-xray--blocks codeql-test--xray-ra "RA")
                                             "Deep" defs))
                   '("Inner::Big.lines/0" "#select")))
    ;; a class compiles to one relation with its characteristic predicate
    (should (eq (codeql-xray-def-kind
                 (cdar (codeql-xray--map (list (codeql-xray-block-create
                                                :first 0 :last 0 :names '("Deep::Inner::Big#33")))
                                         "Deep" defs)))
                'class))))

(ert-deftest codeql-test-xray-instances ()
  "The relations of the modules a query instantiates map to their aliases."
  (let ((defs (codeql-xray--outline codeql-test--xray-inst)))
    (should (equal (mapcar (lambda (d) (format "%s %s %d-%d" (codeql-xray-def-kind d)
                                               (codeql-xray-def-name d)
                                               (codeql-xray-def-srow d) (codeql-xray-def-erow d)))
                           defs)
                   '("instance Flow 1-1" "instance Graph 2-3" "select select 4-5")))
    (should (equal (mapcar #'codeql-xray-def-shape (seq-take defs 2))
                   '("Global<Config>" "PathGraph<PathNode,PathGraph>")))
    (should (equal (codeql-xray--shape "M::Global<Lib::Opt<int>>") "Global<Opt<int>>"))
    ;; named after the instantiated module, through the ones it
    ;; instantiates, but for those of other arguments
    (should (equal (mapcar (lambda (m) (codeql-xray-def-name (cdr m)))
                           (codeql-xray--map (codeql-xray--blocks codeql-test--xray-inst-dil "DIL")
                                             "Inst" defs))
                   '("Flow" "Graph" "Flow" "select")))))

(defmacro codeql-test--with-xray (spec &rest body)
  "Run BODY with an x-ray of a query in the windows of the frame.

SPEC is (STATE SRC KINDS &optional NAME LINES DIL RA): the x-ray STATE
of the query buffer SRC, with a view of each of KINDS left to right, of
Deep.ql or else of the query NAME with LINES compiling to DIL and RA."
  (declare (indent 1))
  (pcase-let ((`(,state ,src ,kinds ,name ,lines ,dil ,ra) spec))
    `(let* ((,src (generate-new-buffer ,(or name "Deep.ql")))
            (,state nil))
       (unwind-protect
           (progn
             (delete-other-windows)
             (switch-to-buffer ,src)
             (insert (string-join ,(or lines 'codeql-test--xray-source) "\n"))
             (setq buffer-file-name (expand-file-name ,(or name "Deep.ql") temporary-file-directory))
             (set-buffer-modified-p nil)
             (setq ,state (codeql-xray-attach ,src ,kinds))
             (let ((w (selected-window)))
               (dolist (view (codeql-xray-views ,state))
                 (setq w (split-window w nil 'right))
                 (set-window-buffer w (codeql-xray--view-buf view))))
             (goto-char (point-min))
             (codeql-xray-show ,state
                               (list :success t
                                     :DIL (vconcat ,(or dil 'codeql-test--xray-dil))
                                     :RA (vconcat ,(or ra 'codeql-test--xray-ra))
                                     :messages (vector (list :severity "WARNING"
                                                             :message "unused predicate 'unused'"))))
             ,@body)
         (when (and ,state (buffer-live-p ,src) (buffer-local-value 'codeql-xray--state ,src))
           (codeql-xray-close ,state))
         (with-current-buffer ,src
           (set-buffer-modified-p nil)
           (setq buffer-file-name nil))
         (kill-buffer ,src)
         (delete-other-windows)))))

(defun codeql-test--xray-view (state n)
  "Return the buffer of the Nth view of STATE."
  (codeql-xray--view-buf (nth n (codeql-xray-views state))))

(defun codeql-test--xray-lines (buffer)
  "Return the lines shown in BUFFER."
  (with-current-buffer buffer
    (split-string (string-remove-suffix "\n" (buffer-string)) "\n")))

(defun codeql-test--xray-marks (buffer kind)
  "Return the x-ray overlays of KIND in BUFFER, as strings of rows and faces."
  (with-current-buffer buffer
    (let ((row (lambda (pos) (save-excursion (goto-char pos) (1- (line-number-at-pos))))))
      (mapcar (lambda (ov)
                (if-let* ((note (overlay-get ov 'after-string)))
                    (format "%d %s" (funcall row (overlay-start ov)) (string-trim note))
                  (let ((end (overlay-end ov)))
                    (format "%d-%d %s" (funcall row (overlay-start ov))
                            (if (save-excursion (goto-char end) (bolp))
                                (1- (funcall row end))
                              (funcall row end))
                            (overlay-get ov 'face)))))
              (sort (seq-filter (lambda (ov) (eq (overlay-get ov 'codeql-xray) kind))
                                (overlays-in (point-min) (point-max)))
                    (lambda (a b) (< (overlay-start a) (overlay-start b))))))))

(defun codeql-test--xray-goto (buffer line &optional col)
  "Select the window of BUFFER at the 1-based LINE and column COL."
  (select-window (get-buffer-window buffer))
  (goto-char (point-min))
  (forward-line (1- line))
  (move-to-column (or col 0)))

(defun codeql-test--xray-move (buffer line &optional col)
  "Move to LINE and COL of BUFFER like a command does."
  (codeql-test--xray-goto buffer line col)
  (run-hooks 'post-command-hook))

(defun codeql-test--xray-line (&optional offset)
  "Return the line OFFSET lines from point."
  (save-excursion
    (forward-line (or offset 0))
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(ert-deftest codeql-test-xray-view ()
  "Only the code of the query is shown, colored like its definitions."
  (codeql-test--with-xray (state src '("DIL"))
    (let ((buf (codeql-test--xray-view state 0)))
      (should (equal (codeql-test--xray-lines buf)
                     '("`Deep::Inner::big/2#0154355b`("
                       "  /* Files::File */ interned unique entity f,"
                       "  int n"
                       ")"
                       "{"
                       "  `Lib::helper/1#11`(n)"
                       "}"
                       ""
                       "#select(int b, int n)"
                       "{"
                       "  `Deep::Inner::big/2#0154355b`(b, n)"
                       "}")))
      (should (equal (codeql-test--xray-marks buf 'base)
                     '("0-6 codeql-xray-1" "8-11 codeql-xray-3")))
      (let ((marks (codeql-test--xray-marks src 'base)))
        ;; big has DIL, lines has only RA, and both keep their colors in either
        (dolist (mark '("4-5 codeql-xray-1" "11-13 codeql-xray-2" "23-25 codeql-xray-3"
                        ;; lines is used by files, without DIL, and the select clause
                        "11 no DIL: inlined into select"
                        "21 no DIL: unused"
                        "27 no DIL: inlined"
                        ;; a class has code when an inner definition has
                        "7 no DIL: inlined into select"))
          (should (member mark marks))))
      (codeql-test--xray-goto buf 1)
      (codeql-xray-other)
      (should (equal (codeql-xray--view-kind (car (codeql-xray-views state))) "RA"))
      (should (equal (car (codeql-test--xray-lines buf)) "EVALUATE RECURSIVE LAYER:"))
      (should-not (member "7 no RA: inlined" (codeql-test--xray-marks src 'base))))))

(ert-deftest codeql-test-xray-active ()
  "The definition at point and its code are highlighted, either way around."
  (codeql-test--with-xray (state src '("DIL"))
    (let ((buf (codeql-test--xray-view state 0)))
      (codeql-test--xray-move src 25)
      (should (equal (codeql-test--xray-marks buf 'active) '("8-11 codeql-xray-active")))
      (should (equal (codeql-test--xray-marks src 'active) '("23-25 codeql-xray-active")))
      (codeql-test--xray-move buf 2)
      (should (equal (codeql-test--xray-marks src 'active) '("4-5 codeql-xray-active")))
      (codeql-xray-visit-definition)
      (should (eq (current-buffer) src))
      (should (= (line-number-at-pos) 5)))))

(ert-deftest codeql-test-xray-peek ()
  "The single view toggles RA and peeks at the relations of the libraries."
  (codeql-test--with-xray (state src '("DIL"))
    (let ((buf (codeql-test--xray-view state 0)))
      (codeql-test--xray-goto buf 1)
      (codeql-xray-other)
      ;; the previous iteration of a recursive relation is the relation
      (codeql-test--xray-goto buf 8 30)
      (codeql-xray-peek)
      (should (= (line-number-at-pos) 1))
      (codeql-xray-other)
      (codeql-test--xray-goto buf 6 6)
      (codeql-xray-peek)
      (should (equal (list (codeql-test--xray-line) (codeql-test--xray-line 1))
                     '("overlayLocal" "`Lib::helper/1#11`(int x)")))
      ;; peeked blocks have no definition in the query
      (should (equal (codeql-test--xray-marks buf 'base)
                     '("0-6 codeql-xray-1" "8-11 codeql-xray-3"))))))

(ert-deftest codeql-test-xray-edits ()
  "The definitions are followed as the query is edited."
  (codeql-test--with-xray (state src '("DIL"))
    (let ((buf (codeql-test--xray-view state 0)))
      (with-current-buffer src
        (goto-char (point-min))
        (insert "\n\n"))
      (codeql-xray--remap state)
      (codeql-xray--render state)
      (should (member "6-7 codeql-xray-1" (codeql-test--xray-marks src 'base)))
      ;; a definition renamed has no code until it compiles again
      (should (member "`Deep::Inner::big/2#0154355b`(" (codeql-test--xray-lines buf)))
      (with-current-buffer src
        (goto-char (point-min))
        (search-forward "big(")
        (replace-match "bigger("))
      (codeql-xray--remap state)
      (codeql-xray--render state)
      (should-not (member "`Deep::Inner::big/2#0154355b`(" (codeql-test--xray-lines buf)))
      (should (timerp (codeql-xray-timer state))))))

(ert-deftest codeql-test-xray-error ()
  "A query that doesn't compile shows why."
  (codeql-test--with-xray (state src '("DIL"))
    (codeql-xray-show state (list :success nil
                                  :messages (vector (list :severity "ERROR"
                                                          :message "could not resolve type Bigg"
                                                          :position (list :line 24 :column 6)))))
    (should (equal (codeql-test--xray-lines (codeql-test--xray-view state 0))
                   '("-- Deep.ql doesn't compile" "error:24:6: could not resolve type Bigg")))
    (should (equal (codeql-xray--decode "oops" "Fatal error\n")
                   '(:success nil :messages [(:severity "ERROR" :message "Fatal error")])))))

(ert-deftest codeql-test-xray-columns ()
  "The columns tell which dumps a definition has no code in, and follow point."
  (codeql-test--with-xray (state src '("DIL" "RA"))
    (let ((dil (codeql-test--xray-view state 0))
          (ra (codeql-test--xray-view state 1)))
      (let ((marks (codeql-test--xray-marks src 'base)))
        (dolist (mark '("11 no DIL: inlined into select"
                        "21 no DIL or RA: unused"
                        ;; the class has RA through lines, but no DIL
                        "7 no DIL: inlined into select"
                        ;; big is inlined into the characteristic predicate of Big
                        "4 no RA: inlined into Big"))
          (should (member mark marks))))
      (codeql-test--xray-move src 25)
      (should (equal (codeql-test--xray-marks dil 'active) '("8-11 codeql-xray-active")))
      (should (equal (codeql-test--xray-marks ra 'active) '("10-13 codeql-xray-active")))
      (codeql-test--xray-move dil 2)
      (should (equal (codeql-test--xray-marks src 'active) '("4-5 codeql-xray-active")))
      ;; big is inlined into the RA of lines
      (should-not (codeql-test--xray-marks ra 'active))
      ;; the code of the same definition in the other dump
      (codeql-test--xray-move dil 10)
      (codeql-xray-other)
      (should (eq (current-buffer) ra))
      (should (= (line-number-at-pos) 11))
      (should (equal (codeql-xray--view-kind (car (codeql-xray-views state))) "DIL"))
      (codeql-xray-other)
      (should (eq (current-buffer) dil))
      (should (= (line-number-at-pos) 9))
      ;; and the same relation of the libraries, peeked at in both
      (codeql-test--xray-goto dil 1)
      (search-forward "`Lib::helper")
      (backward-char 3)
      (codeql-xray-peek)
      (should (equal (codeql-test--xray-line 1) "`Lib::helper/1#11`(int x)"))
      (codeql-xray-other)
      (should (eq (current-buffer) ra))
      (should (equal (codeql-test--xray-line 1) "  `Lib::helper/1#11`(int x) :- ")))))

(ert-deftest codeql-test-xray-same-relation ()
  "The other column shows the same relation of a definition with several."
  (codeql-test--with-xray (state src '("DIL" "RA"))
    (codeql-xray-show state
                      (list :success t
                            :DIL (vconcat codeql-test--xray-dil
                                          '("" "#select#query(int b)" "{" "  #select(b, _)" "}"))
                            :RA (vconcat codeql-test--xray-ra
                                         '("" "EVALUATE NONRECURSIVE RELATION:"
                                           "  #select#query(int b) :- " "    return r1"))))
    (codeql-test--xray-goto (codeql-test--xray-view state 0) 15)
    (codeql-xray-other)
    (should (equal (codeql-test--xray-line 1) "  #select#query(int b) :- "))
    (codeql-xray-other)
    (should (equal (codeql-test--xray-line) "#select#query(int b)"))))

(ert-deftest codeql-test-xray-class-mentions ()
  "The types naming a class inlined into its users are highlighted."
  (codeql-test--with-xray (state src '("DIL" "RA"))
    (let ((dil (codeql-test--xray-view state 0))
          (with-types (vconcat codeql-test--xray-dil)))
      (aset with-types 14 "#select(/* Deep::Inner::Big */ interned unique entity b, int n)")
      (codeql-xray-show state (list :success t :DIL with-types :RA (vconcat codeql-test--xray-ra)))
      (codeql-test--xray-move src 8)
      (with-current-buffer dil
        (let ((found (seq-filter (lambda (ov) (eq (overlay-get ov 'codeql-xray) 'active))
                                 (overlays-in (point-min) (point-max)))))
          (should (= (length found) 1))
          (should (equal (buffer-substring-no-properties (overlay-start (car found))
                                                         (overlay-end (car found)))
                         "/* Deep::Inner::Big */")))))))

(ert-deftest codeql-test-xray-close-view ()
  "Closing a view keeps the others, closing the x-ray all of them."
  (codeql-test--with-xray (state src '("DIL" "RA"))
    (let ((dil (codeql-test--xray-view state 0))
          (win (split-window-right)))
      (set-window-buffer win (codeql-test--xray-view state 1))
      (kill-buffer (codeql-test--xray-view state 1))
      (should-not (window-live-p win))
      (should (equal (mapcar #'codeql-xray--view-buf (codeql-xray-views state)) (list dil)))
      (should (eq (buffer-local-value 'codeql-xray--state src) state))
      (with-current-buffer src
        (codeql-xray))
      (should-not (buffer-live-p dil))
      (should-not (buffer-local-value 'codeql-xray--state src))
      (with-current-buffer src
        (should-not (seq-find (lambda (ov) (overlay-get ov 'codeql-xray))
                              (overlays-in (point-min) (point-max))))
        (should-not (memq #'codeql-xray--source-post-command post-command-hook))))))

(ert-deftest codeql-test-xray-instance-alias ()
  "The relations of an instance in the query are named after its alias."
  (let* ((defs (codeql-xray--outline
                '("module Config implements DataFlow::ConfigSig { }"
                  "module Flow = TaintTracking::Global<Config>;"
                  "select 1")))
         (flow (seq-find (lambda (def) (eq (codeql-xray-def-kind def) 'instance)) defs))
         (blocks (list (codeql-xray-block-create
                        :first 0 :last 1
                        :names '("Paths::Flow::Flow::BooleanCallContext::CcCall#6c5581c4"))
                       (codeql-xray-block-create
                        :first 3 :last 4
                        :names '("Paths::Flow::Flow::S6::flowPath/2#56199763"))
                       (codeql-xray-block-create
                        :first 6 :last 7 :names '("Other::Flow::p/0#1")))))
    (should (equal (codeql-xray-def-keys flow) '("Flow")))
    (should (equal (mapcar (lambda (m) (codeql-xray-def-name (cdr m)))
                           (codeql-xray--map blocks "Paths" defs))
                   '("Flow" "Flow")))))

(defun codeql-test--xray-peers (buffer)
  "Return the 0-based rows of BUFFER marked with the bar of the relation at point."
  (with-current-buffer buffer
    (sort (mapcar (lambda (ov) (save-excursion (goto-char (overlay-start ov))
                                               (1- (line-number-at-pos))))
                  (seq-filter (lambda (ov) (eq (overlay-get ov 'codeql-xray) 'peer))
                              (overlays-in (point-min) (point-max))))
          #'<)))

(ert-deftest codeql-test-xray-follow ()
  "The block of the relation at point is marked in both dumps, as point moves."
  (codeql-test--with-xray (state src '("DIL" "RA") nil nil
                                 (append codeql-test--xray-dil
                                         '("" "#select#query(int b)" "{" "  #select(b, _)" "}"))
                                 (append codeql-test--xray-ra
                                         '("" "EVALUATE NONRECURSIVE RELATION:"
                                           "  #select#query(int b) :- " "    return r1")))
    (let* ((dil (codeql-test--xray-view state 0))
           (ra (codeql-test--xray-view state 1))
           (ra-block (lambda ()
                       (with-current-buffer ra
                         (goto-char (codeql-xray--row-pos (1+ (car (codeql-test--xray-peers ra)))))
                         (codeql-test--xray-line)))))
      (with-current-buffer dil
        (should (= left-margin-width 2)))
      (codeql-test--xray-goto dil 1)
      (re-search-forward "^#select(")
      (let ((row (1- (line-number-at-pos))))
        (run-hooks 'post-command-hook)
        (should (= (car (codeql-test--xray-peers dil)) row)))
      (let ((first (funcall ra-block)))
        (should (string-prefix-p "  #select(" first))
        (select-window (get-buffer-window dil))
        (re-search-forward "^#select#query")
        (run-hooks 'post-command-hook)
        (let ((last (car (last (codeql-xray--view-spans (car (codeql-xray-views state)))))))
          (should (equal (codeql-test--xray-peers dil)
                         (number-sequence (codeql-xray--span-first last)
                                          (codeql-xray--span-last last)))))
        (should (equal (funcall ra-block) "  #select#query(int b) :- "))))))

(ert-deftest codeql-test-xray-diff ()
  "The blocks new or changed since the last compile, and how many are gone."
  (let* ((old ["`M::p/0#aa11`()" "{ x = 1 }" "" "`M::q/0#bb22`()" "{ `M::p/0#aa11`() }"
               "" "`M::r/0#cc`()" "{ }"])
         (new ["`M::p/0#dd33`()" "{ x = 2 }" "" "`M::q/0#ee44`()" "{ `M::p/0#dd33`() }"
               "" "`M::s/0#ff`()" "{ }"])
         (old-blocks (codeql-xray--blocks old "DIL"))
         (blocks (codeql-xray--blocks new "DIL")))
    (should (= (codeql-xray--diff old old-blocks new blocks) 1))
    (should (equal (mapcar #'codeql-xray-block-diff blocks) '(changed nil new)))))

(ert-deftest codeql-test-xray-changes ()
  "The blocks changed since the last compile are marked, counted and gone to."
  (codeql-test--with-xray (state src '("DIL" "RA"))
    (let ((dil (codeql-test--xray-view state 0))
          (ra (codeql-test--xray-view state 1))
          (changed (copy-sequence codeql-test--xray-ra)))
      (setf (nth 18 changed)
            "    {2} r1 = SCAN `Deep::Inner::Big.lines/0#dispred#78` OUTPUT In.1 'b', In.0 'n'")
      (cl-flet ((compile (ra-lines)
                  (codeql-xray-show state (list :success t
                                                :DIL (vconcat codeql-test--xray-dil)
                                                :RA (vconcat ra-lines)))))
        (compile changed)
        (should-not (codeql-test--xray-marks dil 'diff))
        (with-current-buffer ra
          (let ((tags (seq-filter (lambda (ov) (and (eq (overlay-get ov 'codeql-xray) 'diff)
                                                    (overlay-get ov 'after-string)))
                                  (overlays-in (point-min) (point-max)))))
            (should (= (length tags) 1))
            (goto-char (overlay-start (car tags)))
            (should (equal (codeql-test--xray-line 1) "  #select(int b, int n) :- "))
            (should (string-match-p "1 changed" (codeql-xray--header-line)))))
        (codeql-test--xray-goto ra 1)
        (codeql-xray-next-change)
        (should (equal (codeql-test--xray-line 1) "  #select(int b, int n) :- "))
        ;; compiling the same again changes nothing
        (compile changed)
        (should-not (codeql-test--xray-marks ra 'diff))
        (with-current-buffer ra
          (should-not (string-match-p "changed" (codeql-xray--header-line))))))))

(ert-deftest codeql-test-xray-colors ()
  "Each definition has a color of its own, and its code in the dumps the same."
  (let ((lines nil)
        (dil nil))
    (dotimes (i 8)
      (push (format "predicate p%d() { any() }" (1+ i)) lines)
      (setq dil (append dil (list (format "`Many::p%d/0#%d`()" (1+ i) (1+ i)) "{ }" ""))))
    (codeql-test--with-xray (state src '("DIL") "Many.ql" (nreverse lines) dil nil)
      (let* ((faces (lambda (buf)
                      (mapcar (lambda (mark) (cadr (split-string mark " ")))
                              (codeql-test--xray-marks buf 'base))))
             (ql (funcall faces src)))
        (should (= (length ql) 8))
        (should (equal ql (funcall faces (codeql-test--xray-view state 0))))
        (should (= (length (seq-uniq (mapcar (lambda (face) (face-attribute (intern face) :background))
                                             ql)))
                   8))
        (should (equal (codeql-xray--color 7 'light) (codeql-xray--color 7 'light)))
        (should-not (member (codeql-xray--color 7 'dark)
                            (cdr (assq 'dark codeql-xray--palette))))))))

(defmacro codeql-test--with-inst-xray (spec &rest body)
  "Run BODY with the x-ray of Inst.ql, SPEC is (STATE SRC DIL RA)."
  (declare (indent 1))
  (pcase-let ((`(,state ,src ,dil ,ra) spec))
    `(codeql-test--with-xray (,state ,src '("DIL" "RA") "Inst.ql" codeql-test--xray-inst
                                     codeql-test--xray-inst-dil codeql-test--xray-inst-ra)
       (let ((,dil (codeql-test--xray-view ,state 0))
             (,ra (codeql-test--xray-view ,state 1)))
         (ignore ,dil ,ra)
         ,@body))))

(defun codeql-test--xray-folds (buffer)
  "Return the folds of the view BUFFER as their rows and whether they're closed."
  (with-current-buffer buffer
    (mapcar (lambda (fold)
              (list (codeql-xray--fold-first fold) (codeql-xray--fold-last fold)
                    (and (codeql-xray--fold-closed-p fold) t)))
            (codeql-xray--view-folds codeql-xray--this-view))))

(ert-deftest codeql-test-xray-folds ()
  "The relations of an instantiated module fold into one line."
  (codeql-test--with-inst-xray (state src dil ra)
    ;; the code of each definition together, in the order of the query
    (should (equal (codeql-test--xray-folds dil) '((0 4 t) (6 7 t))))
    (should (equal (nth 9 (codeql-test--xray-lines dil))
                   (format "#select(/* Lib::PathGraph<%s::PathNode, %s::PathGraph>::Node */ int n)"
                           codeql-test--xray-g codeql-test--xray-g)))
    (should (equal (substring-no-properties
                    (overlay-get (codeql-xray--fold-overlay
                                  (car (codeql-xray--view-folds
                                        (car (codeql-xray-views state)))))
                                 'display))
                   "▸ Flow  ·  2 blocks  ·  TaintTracking::Global<Config>  ·  o opens"))
    ;; and keeps an open one open
    (codeql-test--xray-goto dil 1)
    (codeql-xray-toggle-fold)
    (codeql-xray-show state (list :success t :DIL (vconcat codeql-test--xray-inst-dil)
                                  :RA (vconcat codeql-test--xray-inst-ra)))
    (should (equal (codeql-test--xray-folds dil) '((0 4 nil) (6 7 t))))))

(ert-deftest codeql-test-xray-fold-costs ()
  "A closed fold sums the costs of its blocks and hides theirs."
  (codeql-test--with-inst-xray (state src dil ra)
    (let ((g codeql-test--xray-g))
      (setf (codeql-xray-costs state)
            (codeql-xray--costs
             (list (list :predicateName (format "%s::p/0#1" g) :millis 30 :resultSize 2)
                   (list :predicateName (format "Impl::Sens<%s::Input>::q/0#3" g)
                         :millis 12 :resultSize 5))))
      (codeql-xray--render state)
      (let ((fold (car (codeql-xray--view-folds (car (codeql-xray-views state))))))
        (should (= (codeql-xray--fold-cost fold) 42))
        (should (string-match-p "blocks  ·  ⏱ 42 ms  ·  Taint" (overlay-get (codeql-xray--fold-overlay fold)
                                                         'display)))
        (should (equal (codeql-test--xray-costs dil 1) '("eol:")))
        (codeql-test--xray-goto dil 1)
        (codeql-xray-toggle-fold)
        (should (equal (codeql-test--xray-costs dil 1) '("eol:⏱ 30 ms · 2 rows")))
        (should (equal (codeql-test--xray-costs dil 4) '("eol:⏱ 12 ms · 5 rows")))))))

(ert-deftest codeql-test-xray-fold-navigation ()
  "A closed fold counts as one block, and the other column opens one."
  (codeql-test--with-inst-xray (state src dil ra)
    (codeql-test--xray-goto dil 1)
    (codeql-xray-next-block)
    (should (= (line-number-at-pos) 7))
    (codeql-xray-next-block)
    (should (string-prefix-p "#select(" (codeql-test--xray-line)))
    (codeql-xray-previous-block)
    (codeql-xray-previous-block)
    (should (= (line-number-at-pos) 1))
    ;; and an open one as its blocks
    (codeql-xray-toggle-fold)
    (codeql-xray-next-block)
    (should (= (line-number-at-pos) 4))
    ;; the same relation in the other dump, named differently, opening its fold
    (goto-char (point-min))
    (codeql-xray-other)
    (should (eq (current-buffer) ra))
    (should (equal (codeql-test--xray-folds ra) '((0 6 nil))))
    (should (equal (codeql-test--xray-line 1)
                   (format "  `num#%s::p/0#9`(int x) :- " codeql-test--xray-g)))))

(ert-deftest codeql-test-xray-follow-strict ()
  "No other block is marked for a relation one dump has, nor for a closed fold."
  (codeql-test--with-xray (state src '("DIL" "RA") "Inst.ql" codeql-test--xray-inst
                                 (append (list (format "`%s::r/0#5`()" codeql-test--xray-g) "{ }" "")
                                         codeql-test--xray-inst-dil)
                                 codeql-test--xray-inst-ra)
    (let ((dil (codeql-test--xray-view state 0))
          (ra (codeql-test--xray-view state 1)))
      (codeql-test--xray-move dil 1)
      (should-not (codeql-test--xray-peers dil))
      (codeql-xray-toggle-fold)
      (run-hooks 'post-command-hook)
      (should (codeql-test--xray-peers dil))
      (should-not (codeql-test--xray-peers ra)))))

(ert-deftest codeql-test-xray-fold-changes ()
  "A fold counts the blocks changed in it, and going to one opens it."
  (codeql-test--with-inst-xray (state src dil ra)
    (let ((changed (copy-sequence codeql-test--xray-inst-ra)))
      (setf (nth 6 changed) "    return r2")
      (codeql-xray-show state (list :success t
                                    :DIL (vconcat codeql-test--xray-inst-dil)
                                    :RA (vconcat changed)))
      (let ((fold (car (codeql-xray--view-folds (nth 1 (codeql-xray-views state))))))
        (should (= (codeql-xray--fold-changed fold) 1))
        (should (codeql-xray--fold-closed-p fold))
        (should (string-match-p "1 changed" (overlay-get (codeql-xray--fold-overlay fold) 'display)))
        (codeql-test--xray-goto ra 1)
        (codeql-xray-next-change)
        (should (equal (codeql-test--xray-line 1)
                       (format "  `num#%s::p/0#9`(int x) :- " codeql-test--xray-g)))
        (should-not (codeql-xray--fold-closed-p fold))))))

(ert-deftest codeql-test-xray-instance-peek ()
  "A relation of the libraries named differently is peeked at in both dumps."
  (codeql-test--with-inst-xray (state src dil ra)
    (codeql-test--xray-goto dil 1)
    (search-forward "Lib::Other")
    (codeql-xray-peek)
    (codeql-xray-other)
    (should (eq (current-buffer) ra))
    (should (equal (codeql-test--xray-line 1)
                   "  `num#TaintTracking::Global<Lib::Other>::Flow::p/0#8`() :- "))))

(ert-deftest codeql-test-xray-instance-mentions ()
  "The types of an instantiated module are highlighted in other code."
  (codeql-test--with-inst-xray (state src dil ra)
    (cl-flet ((mentions ()
                (with-current-buffer dil
                  (mapcar (lambda (ov) (buffer-substring-no-properties
                                        (overlay-start ov) (overlay-end ov)))
                          (seq-filter (lambda (ov)
                                        (and (eq (overlay-get ov 'codeql-xray) 'active)
                                             (not (string-search
                                                   "\n" (buffer-substring (overlay-start ov)
                                                                          (overlay-end ov))))))
                                      (overlays-in (point-min) (point-max)))))))
      (codeql-test--xray-move src 3)
      (should (equal (mentions)
                     (list (format "/* Lib::PathGraph<%s::PathNode, %s::PathGraph>::Node */"
                                   codeql-test--xray-g codeql-test--xray-g))))
      ;; the flow only within the arguments of the type
      (codeql-test--xray-move src 2)
      (should-not (mentions))
      ;; of the code of the last compile
      (let ((plain (vconcat codeql-test--xray-inst-dil)))
        (aset plain 12 (concat "#select(int " (make-string 300 ?n) ")"))
        (codeql-xray-show state (list :success t :DIL plain :RA (vconcat codeql-test--xray-inst-ra))))
      (codeql-test--xray-move src 3)
      (should-not (mentions)))))

(defun codeql-test--xray-costs (buffer row)
  "Return the cost decorations of ROW of the view BUFFER, as strings."
  (with-current-buffer buffer
    (let* ((bol (save-excursion (goto-char (point-min)) (forward-line row) (point)))
           (eol (save-excursion (goto-char bol) (line-end-position)))
           out)
      (dolist (ov (sort (seq-filter (lambda (ov) (eq (overlay-get ov 'codeql-xray) 'cost))
                                    (overlays-in bol (1+ eol)))
                        (lambda (a b) (< (overlay-start a) (overlay-start b)))))
        (when (<= bol (overlay-start ov) eol)
          (if-let* ((over (overlay-get ov 'display)))
              (push (concat "over:" over) out)
            (let ((parts (split-string (or (overlay-get ov 'after-string) "") "\n")))
              (unless (and (equal (car parts) "") (overlay-get ov 'after-string))
                (push (concat "eol:" (string-trim-left (car parts))) out))
              (dolist (line (cdr parts))
                (push (concat "below:" line) out))))))
      (nreverse out))))

(defun codeql-test--xray-row (buffer regexp &optional from)
  "Return the 0-based row of the first line of BUFFER matching REGEXP after FROM."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line (or from 0))
      (re-search-forward regexp)
      (1- (line-number-at-pos)))))

(ert-deftest codeql-test-xray-costs ()
  "The time, rows and tuples of the relations the last run of the query evaluated."
  (codeql-test--with-xray (state src '("DIL" "RA"))
    (let* ((dil (codeql-test--xray-view state 0))
           (ra (codeql-test--xray-view state 1))
           (log (make-temp-file "codeql-test-log"))
           (events nil)
           (run (lambda (summary)
                  (setq events summary)
                  (run-hook-with-args 'codeql-query-run-functions
                                      (list :query-path (buffer-file-name src)
                                            :log-path log)))))
      (unwind-protect
          (cl-letf (((symbol-function 'codeql--evaluator-log-summary-async)
                     (lambda (_ callback) (funcall callback events))))
            (funcall
             run
             (list
              ;; the same plan, on another relation, recursive over two iterations
              (list :predicateName "Deep::Inner::Big.lines/0#dispred#77"
                    :millis 1200 :resultSize 4999
                    :ra '(:base ["    {2} r1 = SCAN `cached_Other::q/1#22` OUTPUT In.0, In.1"
                                 "    return r1"])
                    :pipelineRuns [(:raReference "base" :counts [2000])
                                   (:raReference "base" :counts [2999])])
              ;; the same plan, on the cached relation, named unquoted
              (list :predicateName "#select" :millis 0 :resultSize 7
                    :ra '(:pipeline ["    {2} r1 = SCAN cached_Deep::Inner::Big.lines/0#dispred#77 OUTPUT In.0, In.1"
                                     "    return r1"])
                    ;; -1 for no count
                    :pipelineRuns [(:raReference "pipeline" :counts [7])
                                   (:raReference "pipeline" :counts [-1])])
              ;; another plan, timed with its layer
              (list :predicateName "Other::q/1#22" :evaluationStrategy "IN_LAYER" :resultSize 1
                    :ra '(:pipeline ["    {1} r1 = CONSTANT(int)[2]" "    return r1"])
                    :pipelineRuns [(:raReference "pipeline" :counts [1])])
              ;; the library, not shown
              (list :predicateName "Lib::helper/1#11" :millis 500 :resultSize 1)
              ;; a DIL relation inlined in the RA, not evaluated
              (list :predicateName "Deep::Inner::big/2#0154355b"
                    :evaluationStrategy "SENTINEL_EMPTY")))
            ;; the counts summed over the iterations, over the indentation,
            ;; and the relation the evaluated step reads instead
            (should (equal (codeql-test--xray-costs ra (codeql-test--xray-row ra "SCAN `Deep::Inner::big"))
                           '("over:5.0k"
                             "below:  ≠ {2} r1 = SCAN `cached_Other::q/1#22` OUTPUT In.0, In.1")))
            (let ((select (codeql-test--xray-row
                           ra "SCAN `Deep::Inner::Big.lines/0#dispred#77` OUTPUT")))
              (should (equal (codeql-test--xray-costs ra select) '("over:  7 ")))
              (should (equal (codeql-test--xray-costs ra (1+ select)) '("eol:⏱ <1 ms · 7 rows"))))
            ;; the plan evaluated where the dump has no steps of its shape,
            ;; after the time of the whole layer
            (let ((q (codeql-test--xray-row ra "prev_delta")))
              (should-not (codeql-test--xray-costs ra q))
              (should (equal (codeql-test--xray-costs ra (1+ q))
                             '("eol:⏱ 1.2 s · 5.0k rows"
                               "below:    evaluated with the statistics of the database:"
                               "below:  1 {1} r1 = CONSTANT(int)[2]"
                               "below:    return r1"))))
            ;; the time of the query's own relations of the whole run
            (with-current-buffer ra
              (should (string-match-p "⏱ 1.2 s of 1.7 s" (codeql-xray--header-line))))
            ;; at the end of each definition of the query
            (with-current-buffer src
              (let ((notes (mapcar (lambda (ov)
                                     (cons (line-number-at-pos (overlay-start ov))
                                           (substring-no-properties (overlay-get ov 'after-string))))
                                   (seq-filter (lambda (ov) (eq (overlay-get ov 'codeql-xray) 'cost))
                                               (overlays-in (point-min) (point-max))))))
                (should (member (cons (1+ (cl-position "select b, b.lines()" codeql-test--xray-source
                                                       :test #'equal))
                                      "  ⏱ <1 ms · 7 rows")
                                notes))
                (should (equal (save-excursion
                                 (goto-char (overlay-start
                                             (seq-find (lambda (ov) (eq (overlay-get ov 'codeql-xray) 'cost))
                                                       (overlays-in (point-min) (point-max)))))
                                 (eolp))
                               t))))
            ;; the DIL at the closing brace of the block
            (with-current-buffer dil
              (should (equal (codeql-test--xray-costs dil (- (count-lines (point-min) (point-max)) 1))
                             '("eol:⏱ <1 ms · 7 rows"))))
            (let ((big (codeql-test--xray-row dil "^}" (codeql-test--xray-row dil "big/2"))))
              (should (equal (codeql-test--xray-costs dil big)
                             '("eol:⏱ skipped: an input is empty")))
              ;; a run taking it from the cache
              (funcall run (list (list :predicateName "Deep::Inner::big/2#0154355b"
                                       :evaluationStrategy "CACHACA" :resultSize 3)))
              (should (equal (codeql-test--xray-costs dil big) '("eol:⏱ cached · 3 rows"))))
            ;; quick evaluations and other queries tell nothing
            (funcall run nil)
            (should (codeql-xray-costs state))
            (run-hook-with-args 'codeql-query-run-functions
                                (list :query-path (buffer-file-name src) :log-path log
                                      :quick-eval t))
            (should (codeql-xray-costs state)))
        (delete-file log)))))

(ert-deftest codeql-test-xray-cost-text ()
  "Durations, counts and gutters fit the x-ray."
  (should (equal (mapcar #'codeql-xray--milliseconds '(0 0.5 1 999.9 1000 1700))
                 '("<1 ms" "<1 ms" "1 ms" "999 ms" "1.0 s" "1.7 s")))
  (should (equal (mapcar #'codeql-xray--count '(0 999 1000 4999 9949 9950 123456 2500000 3e9))
                 '("0" "999" "1.0k" "5.0k" "9.9k" "10k" "123k" "2.5M" "3.0G")))
  (should (equal (codeql-xray--pad "7" 4) "  7 "))
  (should (equal (codeql-xray--pad "5.0k" 4) "5.0k"))
  (should-not (codeql-xray--pad "12.3k" 4))
  (should (equal (codeql-xray--skeleton "    {2} r1 = JOIN r0 WITH `M::p/1#ab` ON FIRST 1 OUTPUT Lhs.0, 'x'")
                 "{2} r1 = JOIN r0 WITH ON FIRST OUTPUT"))
  (should (equal (codeql-xray--step-relations
                  "    {2} r1 = JOIN cached_M::q/0#cc WITH `M::p/1#ab` ON FIRST 1 OUTPUT 'a::b'")
                 "M::p/1 M::q/0")))

(defconst codeql-test--hotspots-join
  "    {2} r1 = JOIN x WITH x ON FIRST 1 OUTPUT Lhs.0, Rhs.1"
  "A step of the hotspot tests.")

(defun codeql-test--hotspots-after (lib)
  "Return the events of a run with a hotspot, at line 3 of LIB."
  (list (list :predicateName "D::cached/0#ffffffff" :evaluationStrategy "CACHE_HIT" :resultSize 1)
        (list :predicateName "A::p/1#aaaaaaaa" :raHash "ha" :millis 900 :resultSize 10
              :dependencies '(:x "hx") :position (concat lib ":3,11-3,11")
              :ra (list :pipeline (vector codeql-test--hotspots-join
                                          "    {1} r2 = SCAN r1 OUTPUT In.0" "    return r2"))
              ;; over two iterations
              :pipelineRuns [(:raReference "pipeline" :counts [6000 6])
                             (:raReference "pipeline" :counts [4000 4])])
        (list :predicateName "x" :raHash "hx" :evaluationStrategy "EXTENSIONAL" :resultSize 100)
        (list :predicateName "B::q/0#bbbbbbbb" :millis 5 :resultSize 3 :dependencies '(:x "hx")
              :ra '(:pipeline ["    {1} r1 = SCAN x OUTPUT In.0" "    return r1"])
              :pipelineRuns [(:raReference "pipeline" :counts [3])])
        (list :predicateName "D::empty/0#eeeeeeee" :evaluationStrategy "SENTINEL_EMPTY"
              :dependencies '(:x "hx"))))

(defun codeql-test--hotspots-before ()
  "Return the events of the run before the one of `codeql-test--hotspots-after'."
  (list (list :predicateName "A::p/1#cccccccc" :millis 50 :resultSize 10
              :dependencies '(:x "hx2")
              :ra (list :pipeline (vector codeql-test--hotspots-join "    return r1"))
              :pipelineRuns [(:raReference "pipeline" :counts [20])])
        (list :predicateName "x" :raHash "hx2" :evaluationStrategy "EXTENSIONAL" :resultSize 100)
        (list :predicateName "C::gone/0#dddddddd" :millis 7 :resultSize 1)
        (list :predicateName "D::cached/0#eeeeeeee" :millis 3 :resultSize 1)))

(ert-deftest codeql-test-hotspots-blowups ()
  "The step making the most tuples, and how many times as many as its relation reads or makes."
  (let* ((events (append (codeql-test--hotspots-after "/lib/Lib.qll")
                         ;; the same relation evaluated again, with more
                         ;; tuples from a larger input
                         (list (list :predicateName "A::p/1#ffffffff" :millis 0 :resultSize 0
                                     :dependencies '(:y "hy")
                                     :ra '(:pipeline ["    {1} r1 = SCAN y OUTPUT In.0" "    return r1"])
                                     :pipelineRuns [(:raReference "pipeline" :counts [50000])])
                               (list :predicateName "y" :raHash "hy" :evaluationStrategy "EXTENSIONAL"
                                     :resultSize 100000))))
         (rows (codeql--performance-sort
                (codeql--performance-against (codeql--performance-blowups events)
                                             (codeql--performance-blowups
                                              (codeql-test--hotspots-before))
                                             (codeql--performance-cached events))
                'blowup))
         (names (lambda () (mapcar #'codeql--hotspot-name rows))))
    (should (equal (funcall names) '("A::p/1#aaaaaaaa" "B::q/0#bbbbbbbb"
                                     "C::gone/0#dddddddd" "D::cached/0#eeeeeeee")))
    (let ((a (car rows)))
      ;; the counts summed over the iterations, over the larger of its input
      ;; and its result
      (should (equal (list (codeql--hotspot-peak a) (codeql--hotspot-blowup a) (codeql--hotspot-step a))
                     (list 10000 100.0 codeql-test--hotspots-join)))
      ;; the same relation compiled again, by its name without hashes
      (should (equal (list (codeql--hotspot-peak (codeql--hotspot-before a))
                           (codeql--hotspot-millis (codeql--hotspot-before a)))
                     '(20 50))))
    (should-not (codeql--hotspot-before (nth 1 rows)))
    (should (and (codeql--hotspot-gone (nth 2 rows)) (codeql--hotspot-gone (nth 3 rows))))
    ;; read from the cache
    (should-not (codeql--hotspot-cached (nth 2 rows)))
    (should (codeql--hotspot-cached (nth 3 rows)))
    (should (equal (mapcar #'codeql--performance-times '(100 2.5 0.03)) '("×100" "×2.5" "×0.0")))
    (should (equal (codeql--performance-stable "M::p/1#0a1b2c3d#ff") "M::p/1#ff"))
    (should (equal (codeql--performance-stable "M::p/1#0a1b2c3d") "M::p/1"))
    ;; by time, the relations not evaluated last
    (setq rows (codeql--performance-sort rows 'time))
    (should (equal (funcall names) '("A::p/1#aaaaaaaa" "B::q/0#bbbbbbbb"
                                     "C::gone/0#dddddddd" "D::cached/0#eeeeeeee")))
    ;; by the change, among the others
    (setq rows (codeql--performance-sort rows 'change))
    (should (equal (seq-take (funcall names) 3)
                   '("A::p/1#aaaaaaaa" "C::gone/0#dddddddd" "B::q/0#bbbbbbbb")))))

(ert-deftest codeql-test-hotspots-buffer ()
  "The relations by their blowup beside the run before, going to their QL and RA."
  (let* ((dir (make-temp-file "codeql-test-hotspots" t))
         (lib (expand-file-name "Lib.qll" dir))
         (run (list :query-path "/q/Foo.ql" :log-path "/q/run.jsonl"
                    :timestamp "Fri Nov 27 10:05:00 2026"))
         (previous (list :query-path "/q/Foo.ql" :log-path "/q/previous.jsonl"
                         :timestamp "Fri Nov 27 10:00:00 2026"))
         (buffer nil))
    (with-temp-file lib
      (insert "import javascript\n\npredicate p(int x) { x = 1 }\n"))
    (unwind-protect
        (cl-letf (((symbol-function 'codeql--evaluator-log-summary)
                   (lambda (log-path)
                     (if (equal log-path "/q/run.jsonl")
                         (codeql-test--hotspots-after lib)
                       (codeql-test--hotspots-before)))))
          (delete-other-windows)
          (setq buffer (codeql-query-hotspots run previous))
          (should (eq (current-buffer) buffer))
          (let ((lines (split-string (buffer-string) "\n")))
            (should (string-match-p "Hotspots of Foo.ql at 10:05:00: 1 of 2 blow up ×50 or more"
                                    (nth 0 lines)))
            (should (string-match-p "which computed 1 read from the cache now" (nth 0 lines)))
            (should (string-match-p (concat "\\`\\s-*×100\\s-+10k\\s-+10\\s-+900 ms\\s-+│"
                                            "\\s-+×0.2\\s-+20\\s-+50 ms\\s-+│\\s-+A::p/1#aaaaaaaa")
                                    (nth 1 lines)))
            (should (string-match-p "new" (nth 2 lines)))
            (should (string-match-p "\\`\\s-*gone" (nth 3 lines)))
            (should (string-match-p "\\`\\s-*cached" (nth 4 lines))))
          ;; blowing up, and slower than before
          (goto-char (point-min))
          (forward-line 1)
          (cl-flet ((face-of (text)
                      (save-excursion
                        (search-forward text (line-end-position))
                        (get-text-property (match-beginning 0) 'face))))
            (should (eq (face-of "×100") 'codeql-hotspots-blowup))
            (should (eq (face-of "900 ms") 'codeql-hotspots-slower)))
          ;; the step blowing up in its RA, without an x-ray
          (codeql-hotspots-show-step)
          (with-current-buffer "*codeql-performance-ra*"
            (goto-char (window-point (get-buffer-window (current-buffer))))
            (should (equal (buffer-substring (line-beginning-position) (line-end-position))
                           codeql-test--hotspots-join)))
          ;; its QL, in the window showing it
          (delete-other-windows)
          (let ((lib-win (split-window nil nil 'above)))
            (set-window-buffer lib-win (find-file-noselect lib))
            (split-window nil nil 'below)
            (codeql-hotspots-visit)
            (should (eq (selected-window) lib-win))
            (should (= (line-number-at-pos) 3)))
          ;; sorted by time
          (select-window (get-buffer-window buffer))
          (codeql-hotspots-sort)
          (let ((lines (split-string (buffer-string) "\n")))
            (should (string-match-p "sorted by time" (nth 0 lines)))
            (should (string-match-p "C::gone" (nth 3 lines)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (get-buffer "*codeql-performance-ra*") (kill-buffer "*codeql-performance-ra*"))
      (when-let* ((b (find-buffer-visiting lib))) (kill-buffer b))
      (delete-directory dir t)
      (delete-other-windows))))

(ert-deftest codeql-test-xray-blowups ()
  "The steps blowing up, beside the cost of the run before, and going to them."
  (codeql-test--with-xray (state src '("DIL" "RA"))
    (let* ((ra (codeql-test--xray-view state 1))
           (previous-log (make-temp-file "codeql-test-previous"))
           (run-log (make-temp-file "codeql-test-run"))
           (path (buffer-file-name src))
           (previous (list :query-path path :log-path previous-log
                           :timestamp "Fri Nov 27 10:00:00 2026"))
           (run (list :query-path path :log-path run-log :timestamp "Fri Nov 27 10:05:00 2026"))
           (scan "    {2} r1 = SCAN `cached_Other::q/1#22` OUTPUT In.0, In.1")
           (delta "    {2} r1 = SCAN `Big.lines#prev_delta` OUTPUT In.1, In.0")
           (big (lambda (millis counts q-counts)
                  (list
                   ;; a plan of another shape
                   (list :predicateName "Other::q/1#22" :raHash "hq" :evaluationStrategy "IN_LAYER"
                         :resultSize 10 :dependencies '(:q "hq")
                         :ra (list :pipeline ["    {1} r1 = CONSTANT(int)[2]" "    return r1"]
                                   ;; of the shape of the base case too
                                   :rec (vector delta "    return r1"))
                         :pipelineRuns (vector (list :raReference "pipeline" :counts q-counts)
                                               (list :raReference "rec" :counts [7])))
                   (list :predicateName "Deep::Inner::Big.lines/0#dispred#77" :millis millis
                         :resultSize 20 :dependencies '(:q "hq")
                         :ra (list :base (vector scan "    return r1"))
                         :pipelineRuns (vector (list :raReference "base" :counts counts)))))))
      (unwind-protect
          (cl-letf (((symbol-function 'codeql--evaluator-log-summary-async)
                     (lambda (log-path callback)
                       ;; a regression: 5000 tuples for 20 rows, when there were 20
                       (funcall callback (if (equal log-path run-log)
                                             (funcall big 1200 [5000] [600])
                                           (funcall big 40 [20] [10]))))))
            (with-current-buffer src
              (setq codeql--completed-query-history (make-hash-table :test #'equal))
              (puthash "previous" previous codeql--completed-query-history)
              (puthash "run" run codeql--completed-query-history))
            (run-hook-with-args 'codeql-query-run-functions run)
            (let ((row (codeql-test--xray-row ra "SCAN `Deep::Inner::big"))
                  (last (1+ (codeql-test--xray-row ra "prev_delta"))))
              (with-current-buffer ra
                (let ((over (seq-find (lambda (ov) (eq (overlay-get ov 'codeql-xray) 'cost))
                                      (overlays-in (codeql-xray--row-pos row)
                                                   (1+ (codeql-xray--row-pos row))))))
                  (should (equal (overlay-get over 'display) "5.0k"))
                  (should (eq (get-text-property 0 'face (overlay-get over 'display))
                              'codeql-hotspots-blowup))))
              ;; at the end of the layer
              (let ((costs (codeql-test--xray-costs ra last)))
                (should (equal (car costs)
                               "eol:⏱ 1.2 s · 30 rows · ×250 blowup  was 40 ms · 30 rows"))
                ;; 600 tuples for 10 rows, of the plan evaluated
                (should (equal (nth 2 costs) "below:600 {1} r1 = CONSTANT(int)[2]")))
              (with-current-buffer ra
                (let* ((ov (seq-find (lambda (ov) (overlay-get ov 'after-string))
                                     (overlays-in (codeql-xray--row-pos last)
                                                  (codeql-xray--row-pos (1+ last)))))
                       (text (overlay-get ov 'after-string)))
                  (cl-flet ((face-at (s) (get-text-property (string-search s text) 'face text)))
                    (should (eq (face-at "⏱") 'codeql-xray-cost))
                    (should (eq (face-at " · ×250") 'codeql-hotspots-blowup))
                    (should (eq (face-at "  was") 'codeql-xray-was))
                    (should (eq (face-at "600 ") 'codeql-hotspots-blowup))))
                (should (string-match-p "⏱ 1.2 s of 1.2 s, was 40 ms of 40 ms"
                                        (codeql-xray--header-line))))
              (codeql-test--xray-goto ra 1)
              (codeql-xray-next-blowup)
              (should (= (codeql-xray--current-row) row))
              (codeql-xray-next-blowup)
              (should (= (codeql-xray--current-row) last))
              (codeql-xray-previous-blowup)
              (should (= (codeql-xray--current-row) row))
              ;; the step of the hotspots, from another window
              (select-window (get-buffer-window src))
              (should (codeql-xray-reveal path "Deep::Inner::Big.lines/0#dispred#77" scan))
              (should (eq (current-buffer) ra))
              (should (= (codeql-xray--current-row) row))
              ;; the step it was matched with, of a shape another step has too
              (should (codeql-xray-reveal path "Other::q/1#22" delta))
              (should (= (codeql-xray--current-row) (1- last)))
              ;; a relation of the libraries, peeked at
              (should (codeql-xray-reveal path "Lib::helper/1#11"))
              (should (equal (codeql-test--xray-line 1) "  `Lib::helper/1#11`(int x) :- "))
              (should-not (codeql-xray-reveal "/elsewhere/Other.ql" "Lib::helper/1#11"))))
        (with-current-buffer src
          (setq codeql--completed-query-history nil))
        (delete-file previous-log)
        (delete-file run-log)))))

(ert-deftest codeql-test-xray-command ()
  "The x-ray needs a query and runs `codeql query compile' with its dumps."
  (with-temp-buffer
    (should-error (codeql-xray) :type 'user-error))
  (let* ((dir (make-temp-file "codeql-xray" t))
         (file (expand-file-name "Deep.ql" dir))
         (commands nil)
         (make-process (symbol-function 'make-process)))
    (with-temp-file file
      (insert (string-join codeql-test--xray-source "\n")))
    (unwind-protect
        (with-current-buffer (let ((auto-mode-alist nil)) (find-file-noselect file))
          (setq-local codeql--cli-buffer-local '("codeql"))
          (setq-local codeql--search-paths-buffer-local '("/packs"))
          (delete-other-windows)
          (switch-to-buffer (current-buffer))
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest args)
                       (push (plist-get args :command) commands)
                       (let ((stdout (plist-get args :buffer)))
                         (with-current-buffer stdout
                           (insert (json-serialize
                                    (vector (list :success t
                                                  :messages []
                                                  :DIL (vconcat codeql-test--xray-dil)
                                                  :RA (vconcat codeql-test--xray-ra))))))
                         (let ((proc (funcall make-process :name "true" :command '("true"))))
                           (set-process-sentinel proc #'ignore)
                           (while (process-live-p proc) (accept-process-output proc 0.05))
                           (run-at-time 0 nil (plist-get args :sentinel) proc "finished\n")
                           proc)))))
            (codeql-xray)
            (let ((state codeql-xray--state))
              (should state)
              (should (= (length (window-list)) 3))
              (should (equal (mapcar #'codeql-xray--view-kind (codeql-xray-views state))
                             '("DIL" "RA")))
              (should (equal (car commands)
                             (list "codeql" "query" "compile" "--dump-dil" "--dump-ra"
                                   "--format=json" "--threads=0" "--additional-packs=/packs"
                                   "--" file)))
              (with-timeout (5 (error "The compile didn't finish"))
                (while (not (codeql-xray-result state))
                  (accept-process-output nil 0.05)))
              (should (string-match-p "2 of 3 blocks"
                                      (with-current-buffer (codeql-test--xray-view state 0)
                                        (codeql-xray--header-line))))
              ;; saving compiles again
              (set-buffer-modified-p t)
              (save-buffer)
              (should (= (length commands) 2))
              (codeql-xray)
              (should-not codeql-xray--state)
              (should (= (length (window-list)) 1)))))
      (when-let* ((buf (get-file-buffer file)))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))
      (delete-directory dir t))))

(provide 'emacs-codeql-test)
;;; emacs-codeql-test.el ends here
