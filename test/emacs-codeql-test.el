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
                   (lambda (_bqrs _set _offsets _page _size style)
                     (codeql-test--raw-org style))))
          (with-current-buffer buffer
            (should (= (codeql-results-org-ql "(regexp \"foo\")") 1))
            (should (eq (plist-get codeql--raw-results-pagination :style) 'outline))
            (should (= (length (codeql-test--result-properties buffer)) 2))
            (codeql-results-toggle-raw-style)
            (should (eq (plist-get codeql--raw-results-pagination :style) 'table))
            (should-not (codeql-test--result-properties buffer))))))))

(provide 'emacs-codeql-test)
;;; emacs-codeql-test.el ends here
