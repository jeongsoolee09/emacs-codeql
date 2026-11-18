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
quick evaluated), :module, :provenance and :handler, whose outcome
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
      (should (equal (parse "p") '(nil (predicate . "p") nil)))
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
                       '((predicate "p" 1))))))
    (should (equal (codeql--session-clean-message
                    "ERROR: oops (/s.ql:1,1-2)\nWARNING: unused predicate 'p' (/s.ql:3,1-2)\n")
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
                   "Defined q/0.\nERROR: oops (in p/1)\nRolled back p/1."))))

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
    (codeql-test--repl-output start)))

(defun codeql-test--repl-output (start)
  "Return what the current REPL buffer printed after START, without the prompt."
  (string-remove-suffix
   codeql-repl-prompt
   (buffer-substring-no-properties
    (save-excursion (goto-char start) (forward-line 1) (point))
    (point-max))))

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
      (should (button-at (- (point-max) (length codeql-repl-prompt) 2))))
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
    (should (equal (codeql-test--repl-enter ":count") "Usage: :count PREDICATE\n"))
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

(provide 'emacs-codeql-test)
;;; emacs-codeql-test.el ends here
