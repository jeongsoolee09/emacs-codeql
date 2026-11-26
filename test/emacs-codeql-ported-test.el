;;; emacs-codeql-ported-test.el --- Tests for the features ported from codeql.nvim -*- lexical-binding: t -*-

;;; Commentary:

;; Run from the repository root with:
;;
;;   emacs -Q --batch -L . -l test/emacs-codeql-ported-test.el -f ert-run-tests-batch-and-exit
;;
;; These cover quick evaluation of the enclosing predicate, loading SARIF
;; files, graph results, searching the database source archive,
;; permalinks, `codeql-doctor' and gh-mrva sessions.  No CodeQL CLI,
;; query server or gh is needed: they are stubbed out, or faked with
;; shell scripts.  The quick evaluation tests are skipped unless the ql
;; tree-sitter grammar is installed, and the graph rendering tests unless
;; graphviz is.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tabulated-list)
(require 'xref)
(require 'emacs-codeql)

;; org is loaded lazily, bind its hook dynamically before it is
(defvar org-mode-hook)

(defmacro codeql-ported-test--with-temp-dir (dir &rest body)
  "Run BODY with DIR bound to a new temporary directory, deleted afterwards."
  (declare (indent 1) (debug t))
  `(let ((,dir (file-name-as-directory (make-temp-file "codeql-ported-test" t))))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,dir t))))

(defmacro codeql-ported-test--with-query-buffer (&rest body)
  "Run BODY in a stand-in query buffer, cleaning up the buffers it creates."
  (declare (indent 0) (debug t))
  `(let ((query-buffer (generate-new-buffer " *codeql-ported-test-query*"))
         (before (buffer-list)))
     (unwind-protect
         (save-window-excursion
           (with-current-buffer query-buffer
             (setq major-mode 'ql-tree-sitter-mode)
             ,@body))
       (dolist (b (buffer-list))
         (unless (memq b before)
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (kill-buffer query-buffer))))

(defun codeql-ported-test--write (file contents)
  "Write CONTENTS to FILE, creating its directory, and return FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert contents))
  file)

(defun codeql-ported-test--script (file body)
  "Write the executable shell script FILE that runs BODY, and return FILE."
  (codeql-ported-test--write file (concat "#!/bin/sh\n" body "\n"))
  (set-file-modes file #o755)
  file)

(defun codeql-ported-test--wait (predicate)
  "Process output until PREDICATE returns non-nil, for at most 10 seconds."
  (with-timeout (10 (error "Timed out waiting for an asynchronous process"))
    (while (not (funcall predicate))
      (accept-process-output nil 0.05))))

;;; Quick evaluation of the enclosing predicate

(defconst codeql-ported-test--query
  "import javascript

class Small extends Expr {
  Small() { this.getNumChild() = 1 }

  int size() { result = this.getNumChild() + 1 }
}

predicate isTiny(Small s) { s.size() < 3 }

from Small s
where isTiny(s)
select s
"
  "A query with a characteristic, a member and a classless predicate.")

(defun codeql-ported-test--treesit-p ()
  "Return non-nil if the builtin ql tree-sitter grammar is available."
  (and (require 'treesit nil t)
       (fboundp 'treesit-ready-p)
       (treesit-ready-p 'ql t)))

(defmacro codeql-ported-test--with-query (&rest body)
  "Run BODY in a parsed query buffer of `codeql-ported-test--query'."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (insert codeql-ported-test--query)
     (treesit-parser-create 'ql)
     (setq major-mode 'ql-tree-sitter-mode)
     ,@body))

(defun codeql-ported-test--position (string &optional offset)
  "Return the position of STRING in the current buffer, plus OFFSET."
  (save-excursion
    (goto-char (point-min))
    (+ (search-forward string) (- (length string)) (or offset 0))))

(ert-deftest codeql-ported-test-enclosing-predicate ()
  "The enclosing predicate is found from anywhere in its body."
  (skip-unless (codeql-ported-test--treesit-p))
  (codeql-ported-test--with-query
    (let ((charpred (codeql-ported-test--position "Small() {"))
          (member (codeql-ported-test--position "size() {"))
          (classless (codeql-ported-test--position "isTiny(Small")))
      (should (equal (codeql--enclosing-predicate-name-position
                      (codeql-ported-test--position "getNumChild() = 1"))
                     charpred))
      (should (equal (codeql--enclosing-predicate-name-position
                      (codeql-ported-test--position "+ 1"))
                     member))
      (should (equal (codeql--enclosing-predicate-name-position member) member))
      (should (equal (codeql--enclosing-predicate-name-position
                      (codeql-ported-test--position "< 3"))
                     classless)))))

(ert-deftest codeql-ported-test-outside-predicates ()
  "Imports and the select clause are not in any predicate."
  (skip-unless (codeql-ported-test--treesit-p))
  (codeql-ported-test--with-query
    (should-not (codeql--enclosing-predicate-name-position
                 (codeql-ported-test--position "javascript")))
    (should-not (codeql--enclosing-predicate-name-position
                 (codeql-ported-test--position "select s" 7)))
    (should-not (codeql--enclosing-predicate-name-position
                 (codeql-ported-test--position "isTiny(s)")))))

(ert-deftest codeql-ported-test-quick-eval-predicate ()
  "Quick evaluation picks the region, the enclosing predicate or the query."
  (skip-unless (codeql-ported-test--treesit-p))
  (codeql-ported-test--with-query
    (let (runs)
      (cl-letf (((symbol-function 'codeql-query-server-run-query)
                 (lambda (&optional quick-eval) (push quick-eval runs)))
                ((symbol-function 'message) #'ignore))
        (goto-char (codeql-ported-test--position "< 3"))
        (codeql-query-server-quick-eval-predicate)
        (goto-char (codeql-ported-test--position "select s"))
        (codeql-query-server-quick-eval-predicate)
        (let ((transient-mark-mode t))
          (goto-char (codeql-ported-test--position "s.size()"))
          (push-mark (codeql-ported-test--position "< 3") t t)
          (codeql-query-server-quick-eval-predicate)))
      (should (equal (nreverse runs) '(predicate nil t))))))

;;; Loading SARIF files

(defun codeql-ported-test--sarif (src-root)
  "Return a SARIF document whose uri base SRCROOT is SRC-ROOT."
  (format "{\"runs\": [{
  \"tool\": {\"driver\": {\"rules\": [{\"id\": \"js/xss\"}, {\"id\": \"js/sql-injection\"}]}},
  \"originalUriBaseIds\": {\"SRCROOT\": {\"uri\": \"file://%s\"}},
  \"versionControlProvenance\": [
    {\"repositoryUri\": \"https://github.com/octo/app\"},
    {\"repositoryUri\": \"https://github.com/octo/app\", \"revisionId\": \"c0ffee\"}],
  \"artifacts\": [
    {\"location\": {\"uri\": \"lib/db.js\", \"uriBaseId\": \"SRCROOT\"}},
    {\"location\": {\"uri\": \"gen/bundle.js\"}, \"contents\": {\"text\": \"embedded\\n\"}}],
  \"results\": [
    {\"ruleIndex\": 0, \"message\": {\"text\": \"by index\"},
     \"locations\": [{\"physicalLocation\": {
       \"artifactLocation\": {\"index\": 0}, \"region\": {\"startLine\": 1}}}]},
    {\"rule\": {\"index\": 1}, \"message\": {\"text\": \"embedded\"},
     \"locations\": [{\"physicalLocation\": {
       \"artifactLocation\": {\"uri\": \"gen/bundle.js\"}, \"region\": {\"startLine\": 1}}}]},
    {\"ruleId\": \"js/other\", \"message\": {\"text\": \"relative\"},
     \"relatedLocations\": [{\"physicalLocation\": {
       \"artifactLocation\": {\"uri\": \"\"}}}],
     \"locations\": [{\"physicalLocation\": {
       \"artifactLocation\": {\"uri\": \"app%%20main.js\"}, \"region\": {\"startLine\": 2}}}]}]}]}"
          src-root))

(defun codeql-ported-test--result-uris (result)
  "Return the uris of the locations and related locations of RESULT."
  (mapcar (lambda (location)
            (json-pointer-get location "/physicalLocation/artifactLocation/uri"))
          (append (json-pointer-get result "/locations")
                  (json-pointer-get result "/relatedLocations")
                  nil)))

(defmacro codeql-ported-test--capturing-render (rendered &rest body)
  "Run BODY, pushing the arguments of each SARIF rendering onto RENDERED."
  (declare (indent 1) (debug t))
  `(let ((,rendered nil))
     (cl-letf (((symbol-function 'codeql--render-sarif-results)
                (lambda (&rest args) (push args ,rendered) nil)))
       ,@body)))

(ert-deftest codeql-ported-test-sarif-file-uri-path ()
  "Only absolute file uris have a local path."
  (should (equal (codeql--sarif-file-uri-path "file:///src/a%20b.js") "/src/a b.js"))
  (should (equal (codeql--sarif-file-uri-path "file:/src/a.js") "/src/a.js"))
  (should-not (codeql--sarif-file-uri-path "https://github.com/octo/app"))
  (should-not (codeql--sarif-file-uri-path "src/a.js")))

(ert-deftest codeql-ported-test-sarif-artifacts ()
  "Locations inherit the uri and contents of the artifact they reference."
  (let* ((run (json-parse-string
               "{\"artifacts\": [{\"location\": {\"uri\": \"a.js\", \"uriBaseId\": \"SRC\"},
                                 \"contents\": {\"text\": \"a\"}},
                                {\"location\": {\"uri\": \"b.js\"}}]}"
               :object-type 'alist))
         (by-index '((index . 0)))
         (by-uri '((uri . "b.js"))))
    (should (equal (json-pointer-get (codeql--sarif-artifact-location by-index run) "/uri")
                   "a.js"))
    (should (equal (json-pointer-get (codeql--sarif-artifact-location by-index run)
                                     "/uriBaseId")
                   "SRC"))
    (should (eq (codeql--sarif-artifact-location by-uri run) by-uri))
    (should (equal (codeql--sarif-artifact-location '((index . 7)) run) '((index . 7))))
    (should (equal (codeql--sarif-artifact-contents by-index run) "a"))
    (should (equal (codeql--sarif-artifact-contents '((uri . "a.js")) run) "a"))
    (should-not (codeql--sarif-artifact-contents by-uri run))))

(ert-deftest codeql-ported-test-sarif-resolve-location ()
  "Relative uris resolve against their base id, or the base directory."
  (codeql-ported-test--with-temp-dir dir
    (let* ((run (json-parse-string
                 (format "{\"originalUriBaseIds\": {\"SRC\": {\"uri\": \"file://%ssrc/\"},
                                                    \"REMOTE\": {\"uri\": \"https://x/\"}},
                           \"artifacts\": [{\"location\": {\"uri\": \"gone.js\"},
                                            \"contents\": {\"text\": \"text\"}}]}"
                         dir)
                 :object-type 'alist))
           (base-dir (lambda () (concat dir "checkout/")))
           (artifacts (concat dir "artifacts/")))
      (should (equal (codeql--sarif-resolve-location
                      '((uri . "a.js") (uriBaseId . "SRC")) run base-dir nil)
                     (concat dir "src/a.js")))
      (should (equal (codeql--sarif-resolve-location
                      '((uri . "a.js") (uriBaseId . "REMOTE")) run base-dir nil)
                     (concat dir "checkout/a.js")))
      (should (equal (codeql--sarif-resolve-location
                      '((uri . "lib/a%20b.js")) run base-dir nil)
                     (concat dir "checkout/lib/a b.js")))
      (should (equal (codeql--sarif-resolve-location
                      '((uri . "file:///abs/a.js")) run base-dir nil)
                     "/abs/a.js"))
      (should-not (codeql--sarif-resolve-location '((uri . "")) run base-dir nil))
      (should-not (codeql--sarif-resolve-location '((uri . "file:/")) run base-dir nil))
      ;; the base directory is only asked for when it is needed
      (should (equal (codeql--sarif-resolve-location
                      '((uri . "/abs/a.js")) run (lambda () (error "Asked")) nil)
                     "/abs/a.js"))
      ;; missing files with embedded contents are written to the artifacts dir
      (should (equal (codeql--sarif-resolve-location '((uri . "gone.js")) run base-dir nil)
                     (concat dir "checkout/gone.js")))
      (let ((copy (codeql--sarif-resolve-location '((uri . "gone.js")) run base-dir artifacts)))
        (should (equal copy (concat artifacts "gone.js")))
        (should (equal (with-temp-buffer (insert-file-contents copy) (buffer-string))
                       "text"))))))

(ert-deftest codeql-ported-test-sarif-rule-ids ()
  "Results without a ruleId get one from the rules of their run."
  (let ((run (json-parse-string
              "{\"tool\": {\"driver\": {\"rules\": [{\"id\": \"r0\"}, {\"id\": \"r1\"}]}}}"
              :object-type 'alist))
        (cases '((((ruleIndex . 1)) . "r1")
                 (((rule (index . 0))) . "r0")
                 (((rule (id . "named") (index . 0))) . "named")
                 (((ruleIndex . 9)) . "unknown-rule")
                 ((()) . "unknown-rule")
                 (((ruleId . "kept") (ruleIndex . 0)) . "kept"))))
    (pcase-dolist (`(,result . ,rule-id) cases)
      (let ((result (copy-tree (or result (list (cons 'message "m"))))))
        (codeql--sarif-normalize-rule-id result run)
        (should (equal (alist-get 'ruleId result) rule-id))))))

(ert-deftest codeql-ported-test-load-sarif-checkout ()
  "SARIF results resolve into the source checkout and record provenance."
  (codeql-ported-test--with-temp-dir dir
    (let* ((checkout (concat dir "checkout/"))
           (sarif (codeql-ported-test--write
                   (concat dir "results.sarif")
                   (codeql-ported-test--sarif checkout)))
           (temporary-file-directory (concat dir "tmp/")))
      (make-directory checkout)
      (make-directory temporary-file-directory)
      (codeql-ported-test--with-query-buffer
        (codeql-ported-test--capturing-render rendered
          (codeql-load-sarif sarif checkout)
          (should (= (length rendered) 1))
          (pcase-let* ((`(,results ,buffer ,footer ,marker ,link-prefix) (car rendered))
                       (artifacts (car (directory-files
                                        (concat temporary-file-directory
                                                "codeql-sarif-artifacts")
                                        t "\\`[^.]"))))
            (should (eq buffer query-buffer))
            (should (equal marker "results.sarif"))
            (should (equal link-prefix ""))
            (should (equal (mapcar (lambda (r) (alist-get 'ruleId r)) results)
                           '("js/xss" "js/sql-injection" "js/other")))
            (should (equal (mapcar #'codeql-ported-test--result-uris results)
                           `((,(concat "file://" checkout "lib/db.js"))
                             (,(concat "file://" artifacts "/gen/bundle.js"))
                             (,(concat "file://" checkout "app main.js") ""))))
            (should (equal (with-temp-buffer
                             (insert-file-contents (concat artifacts "/gen/bundle.js"))
                             (buffer-string))
                           "embedded\n"))
            (with-temp-buffer
              (insert footer)
              (should (equal (codeql--results-keyword-values "SARIF_PATH") (list sarif)))
              (should (equal (codeql--results-keyword-values "SOURCE_ROOT") (list checkout)))
              (should (equal (codeql--results-keyword-values "REPOSITORY_URI")
                             '("https://github.com/octo/app")))
              (should (equal (codeql--results-keyword-values "REVISION_ID") '("c0ffee")))
              (should (equal (codeql--results-keyword-values "REPOSITORY_ROOT")
                             (list checkout artifacts))))))))))

(ert-deftest codeql-ported-test-load-sarif-database ()
  "With an active database, relative locations are source archive files."
  (codeql-ported-test--with-temp-dir dir
    (let ((sarif (codeql-ported-test--write
                  (concat dir "results.sarif")
                  "{\"runs\": [{\"versionControlProvenance\": [
                      {\"repositoryUri\": \"https://github.com/octo/app\", \"revisionId\": \"c0ffee\"}],
                    \"results\": [{\"ruleId\": \"js/xss\", \"message\": {\"text\": \"m\"},
                      \"locations\": [{\"physicalLocation\": {
                        \"artifactLocation\": {\"uri\": \"lib/app.js\"}}}]}]}]}")))
      (codeql-ported-test--with-query-buffer
        (setq codeql--active-database "/dbs/js-db/"
              codeql--database-source-archive-zip "src.zip"
              codeql--database-source-archive-root (concat dir "src-root")
              codeql--database-source-location-prefix "/work")
        (codeql-ported-test--capturing-render rendered
          (codeql-load-sarif sarif)
          (pcase-let ((`(,results ,_ ,footer ,_ ,link-prefix) (car rendered)))
            (should-not link-prefix)
            (should (equal (codeql-ported-test--result-uris (aref results 0))
                           '("file:///work/lib/app.js")))
            (with-temp-buffer
              (insert footer)
              (should (equal (codeql--results-keyword-values "SOURCE_ROOT")
                             '("/dbs/js-db")))
              (should (equal (codeql--results-keyword-values "REPOSITORY_ROOT")
                             (list (concat dir "src-root/work")))))))))))

(ert-deftest codeql-ported-test-load-sarif-without-results ()
  "SARIF files without results render nothing."
  (codeql-ported-test--with-temp-dir dir
    (let ((sarif (codeql-ported-test--write (concat dir "empty.sarif")
                                            "{\"runs\": [{\"results\": []}]}")))
      (codeql-ported-test--with-query-buffer
        (codeql-ported-test--capturing-render rendered
          (cl-letf (((symbol-function 'message) #'ignore))
            (codeql-load-sarif sarif dir))
          (should-not rendered))))))

;;; Permalinks

(ert-deftest codeql-ported-test-sarif-provenance ()
  "The first provenance with both a repository and a revision is used."
  (let ((json (json-parse-string
               "{\"runs\": [{\"results\": []},
                            {\"versionControlProvenance\": [
                              {\"repositoryUri\": \"https://github.com/a/b\"},
                              {\"repositoryUri\": \"https://github.com/c/d\", \"revisionId\": \"1\"},
                              {\"repositoryUri\": \"https://github.com/e/f\", \"revisionId\": \"2\"}]}]}"
               :object-type 'alist)))
    (should (equal (codeql--sarif-provenance json) '("https://github.com/c/d" . "1")))
    (should-not (codeql--sarif-provenance '((runs . [((results . []))]))))))

(ert-deftest codeql-ported-test-permalink ()
  "Permalinks are GitHub blob URLs of a line or line range."
  (let ((info '(:repository "https://github.com/octo/app" :revision "c0ffee")))
    (should (equal (codeql--permalink info "src/app.js" 3)
                   "https://github.com/octo/app/blob/c0ffee/src/app.js#L3"))
    (should (equal (codeql--permalink info "src/app.js" 3 7)
                   "https://github.com/octo/app/blob/c0ffee/src/app.js#L3-L7"))
    (should (equal (codeql--permalink info "src/app.js" 3 3)
                   "https://github.com/octo/app/blob/c0ffee/src/app.js#L3"))
    (should (equal (codeql--permalink info "src/app.js" nil)
                   "https://github.com/octo/app/blob/c0ffee/src/app.js"))
    (should (equal (codeql--permalink info "my dir/a#b.js" 1)
                   "https://github.com/octo/app/blob/c0ffee/my%20dir/a%23b.js#L1")))
  (dolist (repository '("https://github.com/octo/app.git"
                        "https://github.com/octo/app/"
                        "git@github.com:octo/app.git"))
    (should (equal (codeql--permalink (list :repository repository :revision "r") "a.js" 1)
                   "https://github.com/octo/app/blob/r/a.js#L1"))))

(ert-deftest codeql-ported-test-permalink-relative-path ()
  "Paths are relative to the longest repository root that contains them."
  (should (equal (codeql--permalink-relative-path "/r/sub/a.js" '("/r" "/r/sub/"))
                 "a.js"))
  (should (equal (codeql--permalink-relative-path "/r/sub/a.js" '("/r/"))
                 "sub/a.js"))
  (should-not (codeql--permalink-relative-path "/rx/a.js" '("/r")))
  (should-not (codeql--permalink-relative-path "/r/a.js" nil)))

(defmacro codeql-ported-test--with-results-buffer (text &rest body)
  "Run BODY in a `codeql-results-mode' buffer of TEXT."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (let ((org-mode-hook nil))
       (codeql-results-mode))
     (goto-char (point-min))
     ,@body))

(ert-deftest codeql-ported-test-permalink-in-results ()
  "Results buffers link the location at or before point on the line."
  (codeql-ported-test--with-results-buffer
      (concat "* result\n"
              "[[codeql:/co/src/a.js::3:5:3:9][a.js:3]] to [[codeql:/co/src/b.js::7:1:9:2][b.js:7]]\n"
              "no location\n"
              "#+REPOSITORY_URI: https://github.com/octo/app\n"
              "#+REVISION_ID: c0ffee\n"
              "#+REPOSITORY_ROOT: /co\n"
              "#+REPOSITORY_ROOT: /tmp/artifacts\n")
    (should (equal (codeql--results-permalink-info)
                   '(:repository "https://github.com/octo/app" :revision "c0ffee"
                                 :roots ("/co" "/tmp/artifacts"))))
    (forward-line 1)
    (should (equal (codeql--permalink-at-point)
                   "https://github.com/octo/app/blob/c0ffee/src/a.js#L3"))
    (search-forward "to")
    (should (equal (codeql--permalink-at-point)
                   "https://github.com/octo/app/blob/c0ffee/src/a.js#L3"))
    (search-forward "b.js")
    (should (equal (codeql--permalink-at-point)
                   "https://github.com/octo/app/blob/c0ffee/src/b.js#L7-L9"))
    (let (killed)
      (cl-letf (((symbol-function 'kill-new) (lambda (s) (setq killed s)))
                ((symbol-function 'message) #'ignore))
        (codeql-copy-permalink))
      (should (equal killed "https://github.com/octo/app/blob/c0ffee/src/b.js#L7-L9")))
    (forward-line 1)
    (should-error (codeql--permalink-at-point) :type 'user-error)))

(ert-deftest codeql-ported-test-permalink-without-provenance ()
  "Results without provenance have no permalinks."
  (codeql-ported-test--with-results-buffer
      "[[codeql:/co/src/a.js::3:5:3:9][a.js:3]]\n"
    (should-not (codeql--results-permalink-info))
    (should-error (codeql--permalink-at-point) :type 'user-error)))

(ert-deftest codeql-ported-test-permalink-in-source ()
  "Source files visited from results link their line or region."
  (codeql-ported-test--with-temp-dir dir
    (with-current-buffer (find-file-noselect
                          (codeql-ported-test--write (concat dir "src/a.js")
                                                     "one\ntwo\nthree\nfour\n"))
      (unwind-protect
          (let ((transient-mark-mode t))
            (should-error (codeql--permalink-at-point) :type 'user-error)
            (setq codeql--permalink-info
                  (list :repository "https://github.com/octo/app" :revision "c0ffee"
                        :roots (list dir)))
            (goto-char (point-min))
            (forward-line 1)
            (should (equal (codeql--permalink-at-point)
                           "https://github.com/octo/app/blob/c0ffee/src/a.js#L2"))
            ;; a region ending at the start of a line doesn't include it
            (push-mark (point) t t)
            (forward-line 2)
            (should (equal (codeql--permalink-at-point)
                           "https://github.com/octo/app/blob/c0ffee/src/a.js#L2-L3"))
            (end-of-line)
            (should (equal (codeql--permalink-at-point)
                           "https://github.com/octo/app/blob/c0ffee/src/a.js#L2-L4"))
            (deactivate-mark)
            (setq codeql--permalink-info
                  (plist-put (copy-sequence codeql--permalink-info) :roots '("/elsewhere")))
            (should-error (codeql--permalink-at-point) :type 'user-error))
        (kill-buffer)))))

;;; gh-mrva

(defmacro codeql-ported-test--with-state-dir (&rest body)
  "Run BODY with `codeql-state-dir' bound to a temporary directory `state'."
  (declare (indent 0) (debug t))
  `(codeql-ported-test--with-temp-dir state
     (let ((codeql-state-dir state))
       ,@body)))

(defmacro codeql-ported-test--with-gh (calls output &rest body)
  "Run BODY with `codeql--gh' returning OUTPUT and pushing its args onto CALLS.

OUTPUT is called with the arguments when it is a function."
  (declare (indent 2) (debug t))
  `(let ((,calls nil))
     (cl-letf (((symbol-function 'codeql--gh)
                (lambda (&rest args)
                  (push args ,calls)
                  (let ((output ,output))
                    (if (functionp output) (apply output args) output)))))
       ,@body)))

(ert-deftest codeql-ported-test-permalink-fetch-file ()
  "Missing gh-mrva sources are fetched from their repository at the revision."
  (codeql-ported-test--with-state-dir
    (let* ((root (codeql--mrva-sources-directory "octo/app" 42))
           (file (concat root "src/my file.js"))
           (info (list :repository "https://github.com/octo/app" :revision "c0ffee"
                       :roots (list root))))
      (should (equal root (concat state "mrva/sources/octo_app_42/")))
      (codeql-ported-test--with-gh calls "contents\n"
        (cl-letf (((symbol-function 'message) #'ignore))
          (should (codeql--permalink-fetch-file file info))
          (should (equal (car calls)
                         '("api" "-H" "Accept: application/vnd.github.raw"
                           "repos/octo/app/contents/src/my%20file.js?ref=c0ffee")))
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                         "contents\n"))
          ;; GitHub Enterprise Server
          (codeql--permalink-fetch-file
           file (plist-put (copy-sequence info)
                           :repository "https://ghe.example.com/octo/app.git"))
          (should (equal (car calls)
                         '("api" "--hostname" "ghe.example.com"
                           "-H" "Accept: application/vnd.github.raw"
                           "repos/octo/app/contents/src/my%20file.js?ref=c0ffee")))
          ;; only below the gh-mrva sources, and for http repositories
          (setq calls nil)
          (should-not (codeql--permalink-fetch-file
                       (concat state "elsewhere/a.js")
                       (list :repository "https://github.com/octo/app" :revision "c0ffee"
                             :roots (list (concat state "elsewhere/")))))
          (should-not (codeql--permalink-fetch-file
                       file (plist-put (copy-sequence info)
                                       :repository "git@github.com:octo/app.git")))
          (should-not (codeql--permalink-fetch-file file nil))
          (should-not calls))))))

(ert-deftest codeql-ported-test-permalink-fetch-file-failure ()
  "Failing fetches leave no file behind."
  (codeql-ported-test--with-state-dir
    (let* ((root (codeql--mrva-sources-directory "octo/app" 42))
           (file (concat root "a.js")))
      (codeql-ported-test--with-gh calls (lambda (&rest _) (error "HTTP 404"))
        (cl-letf (((symbol-function 'message) #'ignore))
          (should-not (codeql--permalink-fetch-file
                       file (list :repository "https://github.com/octo/app"
                                  :revision "c0ffee" :roots (list root))))))
      (should-not (file-exists-p file)))))

(ert-deftest codeql-ported-test-mrva-sessions ()
  "Sessions are listed newest first."
  (codeql-ported-test--with-gh calls
      "[{\"name\": \"old\", \"timestamp\": \"2024-01-01T10:00:00Z\"},
        {\"name\": \"new\", \"timestamp\": \"2024-03-01T10:00:00Z\"},
        {\"name\": \"undated\"}]"
    (should (equal (mapcar (lambda (s) (alist-get 'name s)) (codeql--mrva-sessions))
                   '("new" "old" "undated")))
    (should (equal calls '(("mrva" "list" "--json")))))
  (codeql-ported-test--with-gh calls "null\n"
    (should-not (codeql--mrva-sessions))))

(defconst codeql-ported-test--mrva-status
  "[{\"name\": \"s1\", \"status\": \"completed\",
     \"total_findings_count\": 12, \"total_repositories_with_findings\": 2,
     \"total_successful_scans\": 5, \"total_failed_scans\": 1,
     \"total_skipped_repositories\": 3,
     \"runs\": [{\"id\": 7, \"query_id\": \"q\", \"status\": \"failed\",
                \"failure_reason\": \"boom\"}],
     \"repositories_with_findings\": [
       {\"nwo\": \"octo/small\", \"count\": 10, \"stars\": 9, \"query_id\": \"js/xss\", \"run_id\": 42},
       {\"nwo\": \"octo/big\", \"count\": 2, \"stars\": 10, \"query_id\": \"js/xss\", \"run_id\": 43}]}]"
  "The `gh mrva status --json' of a session.")

(defmacro codeql-ported-test--with-mrva-buffer (&rest body)
  "Run BODY in the `codeql-mrva-mode' buffer of session s1."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (codeql-mrva-mode)
     (setq codeql--mrva-session "s1")
     ,@body))

(ert-deftest codeql-ported-test-mrva-status ()
  "The repositories with findings are listed, those with most stars first."
  (codeql-ported-test--with-mrva-buffer
    (should (equal (codeql--mrva-header-line) "s1: fetching status..."))
    (codeql-ported-test--with-gh calls codeql-ported-test--mrva-status
      (cl-letf (((symbol-function 'message) #'ignore))
        (revert-buffer))
      (should (equal calls '(("mrva" "status" "--json" "--session" "s1")))))
    (should (equal header-line-format
                   "s1: completed, 12 findings in 2 repositories, 5 scans, 1 failed, 3 skipped"))
    (should (equal (sort (mapcar (lambda (entry) (aref (cadr entry) 0)) tabulated-list-entries)
                         #'string<)
                   '("octo/big" "octo/small")))
    (goto-char (point-min))
    (should (equal (alist-get 'nwo (tabulated-list-get-id)) "octo/big"))
    (should (equal (tabulated-list-get-entry) ["octo/big" "2" "10" "js/xss" "43"]))
    (forward-line 1)
    (should (equal (alist-get 'nwo (tabulated-list-get-id)) "octo/small"))
    ;; findings sort numerically too
    (tabulated-list--sort-by-column-name "Findings")
    (goto-char (point-min))
    (should (equal (alist-get 'nwo (tabulated-list-get-id)) "octo/big"))))

(ert-deftest codeql-ported-test-mrva-show-sarif ()
  "SARIF results are loaded for a checkout in the gh-mrva sources."
  (codeql-ported-test--with-state-dir
    (let ((directory (codeql--mrva-directory "s1"))
          (repo '((nwo . "octo/app") (run_id . 42)))
          loaded)
      (codeql-ported-test--write (expand-file-name "octo_app_42.sarif" directory) "{}")
      (codeql-ported-test--with-query-buffer
        (cl-letf (((symbol-function 'codeql-load-sarif)
                   (lambda (&rest args) (push (cons (current-buffer) args) loaded))))
          (with-temp-buffer
            (codeql--mrva-show-results repo directory query-buffer))
          (should (equal (mapcar (lambda (call) (seq-take call 3)) loaded)
                         `((,query-buffer ,(expand-file-name "octo_app_42.sarif" directory)
                                          ,(concat state "mrva/sources/octo_app_42/")))))
          (should (file-directory-p (concat state "mrva/sources/octo_app_42/")))))
      (should-error (codeql--mrva-show-results repo directory (generate-new-buffer " dead"))
                    :type 'error))))

(ert-deftest codeql-ported-test-mrva-show-bqrs ()
  "Raw BQRS results are shown decoded."
  (codeql-ported-test--with-state-dir
    (let ((directory (codeql--mrva-directory "s1"))
          (repo '((nwo . "octo/app") (run_id . 42)))
          commands)
      (codeql-ported-test--write (expand-file-name "octo_app_42.bqrs" directory) "")
      (codeql-ported-test--with-query-buffer
        (cl-letf (((symbol-function 'codeql--cli-command-to-string)
                   (lambda (args) (push args commands) "| col |\n| 1   |\n")))
          (codeql--mrva-show-results repo directory query-buffer)
          (should (equal (car (car commands)) "bqrs"))
          (should (member "decode" (car commands)))
          (with-current-buffer "*codeql-mrva: octo/app 42*"
            (should (derived-mode-p 'special-mode))
            (should (equal (buffer-string) "| col |\n| 1   |\n"))))))))

(ert-deftest codeql-ported-test-mrva-load-results ()
  "Results are downloaded once with gh mrva download, then shown."
  (codeql-ported-test--with-state-dir
    (let* ((gh (codeql-ported-test--script
                (concat state "bin/gh")
                ;; gh mrva download --run RUN --nwo NWO --output-dir DIR
                (concat "echo \"$@\" >> " state "gh.log\n"
                        "touch \"$8/octo_app_$4.sarif\"")))
           (repo '((nwo . "octo/app") (run_id . 42)))
           shown)
      (with-temp-buffer
        (setq codeql--mrva-session "s1")
        (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) gh))
                  ((symbol-function 'codeql--mrva-show-results)
                   (lambda (repo directory &rest _) (push (list repo directory) shown)))
                  ((symbol-function 'message) #'ignore))
          (codeql-mrva-load-results repo)
          (codeql-ported-test--wait (lambda () shown))
          (should (equal shown `((,repo ,(codeql--mrva-directory "s1")))))
          (should (file-exists-p (codeql--mrva-directory "s1" "octo_app_42.sarif")))
          ;; the second time it's cached
          (codeql-mrva-load-results repo)
          (should (= (length shown) 2))))
      (should (equal (with-temp-buffer
                       (insert-file-contents (concat state "gh.log"))
                       (buffer-string))
                     (format "mrva download --run 42 --nwo octo/app --output-dir %s\n"
                             (codeql--mrva-directory "s1")))))))

(ert-deftest codeql-ported-test-mrva-results-not-ready ()
  "Runs that haven't finished are reported, and nothing is shown."
  (codeql-ported-test--with-state-dir
    (let ((gh (codeql-ported-test--script
               (concat state "bin/gh")
               "echo 'Please try again later'"))
          messages shown)
      (with-temp-buffer
        (setq codeql--mrva-session "s1")
        (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) gh))
                  ((symbol-function 'codeql--mrva-show-results)
                   (lambda (&rest _) (setq shown t)))
                  ((symbol-function 'message)
                   (lambda (format &rest args) (push (apply #'format-message format args)
                                                     messages))))
          (codeql-mrva-load-results '((nwo . "octo/app") (run_id . 42)))
          (codeql-ported-test--wait
           (lambda () (member "The results of octo/app are not ready yet" messages)))
          (should-not shown))))))

;;; Graph results

(ert-deftest codeql-ported-test-bqrs-to-dot ()
  "Graph results are interpreted into one dot file per query id."
  (codeql-ported-test--with-temp-dir dir
    (let* ((bqrs (concat dir "results.bqrs"))
           (dot (concat bqrs ".dot.d/rb/print-cfg.dot"))
           commands)
      (cl-letf (((symbol-function 'codeql--cli-command-to-string)
                 (lambda (args)
                   (push args commands)
                   (codeql-ported-test--write dot "digraph {}")
                   "")))
        (should (equal (codeql--bqrs-to-dot bqrs "rb/print-cfg" "graph") dot))
        (should (member "--format=dot" (car commands)))
        (should (member "-t=id=rb/print-cfg" (car commands)))
        (should (member "-t=kind=graph" (car commands)))
        (should (member (format "--output=%s.dot.d" bqrs) (car commands)))
        (should (equal (car (last (car commands))) bqrs))
        ;; no dot file for this id
        (should-not (codeql--bqrs-to-dot bqrs "rb/other" "graph")))
      (cl-letf (((symbol-function 'codeql--cli-command-to-string) #'ignore))
        (should-not (codeql--bqrs-to-dot bqrs "rb/print-cfg" "graph"))))))

(defmacro codeql-ported-test--with-graph-buffer (dot nodes &rest body)
  "Run BODY in the `codeql-graph-mode' buffer of the dot file DOT with NODES."
  (declare (indent 2) (debug t))
  `(codeql-ported-test--with-query-buffer
     (cl-letf (((symbol-function 'switch-to-buffer-other-window) #'ignore)
               ((symbol-function 'message) #'ignore))
       (codeql--show-graph ,dot ,nodes query-buffer)
       (with-current-buffer (format "*codeql-graph: %s*" (file-name-base ,dot))
         ,@body))))

(defun codeql-ported-test--graph-rendered-p ()
  "Return non-nil when the graph of the current buffer has been rendered."
  (not (process-live-p codeql--graph-render-process)))

(defconst codeql-ported-test--dot
  "digraph {\n  compound=true;\n  0[\"label\"=\"a\\\\n b\"; ];\n  1[\"label\"=\"say \\\"hi\\\"\"; ];\n  0 -> 1[];\n}\n"
  "A dot file as written by `codeql bqrs interpret'.")

(defconst codeql-ported-test--graph-nodes
  '(("a\\n      b" . "/arch/src/a.js::1:1:1:3") ("say \"hi\"" . nil))
  "The nodes of `codeql-ported-test--dot', the second has no location.")

(ert-deftest codeql-ported-test-dot-node-labels ()
  "Dot node labels are read by node id, unescaped."
  (codeql-ported-test--with-temp-dir dir
    (should (equal (codeql--dot-node-labels
                    (codeql-ported-test--write (concat dir "g.dot") codeql-ported-test--dot))
                   '("a\\n b" "say \"hi\"")))
    ;; dot files not numbered from 0 like those of bqrs interpret
    (should-not (codeql--dot-node-labels
                 (codeql-ported-test--write (concat dir "h.dot")
                                            "digraph {\n  1[\"label\"=\"a\"; ];\n}\n")))))

(ert-deftest codeql-ported-test-bqrs-graph-nodes ()
  "Graph nodes are the distinct entities of the nodes result set."
  (cl-letf (((symbol-function 'codeql--source-link-prefix) (lambda () "/arch"))
            ((symbol-function 'codeql--bqrs-to-json)
             (lambda (_bqrs entities result-set)
               (should (equal entities "id,url,string"))
               (should (equal result-set "nodes"))
               (json-encode
                `((tuples
                   . [[((id . 1) (label . "f()")
                        (url (uri . "file:///src/a.js") (startLine . 2) (startColumn . 3)
                             (endLine . 2) (endColumn . 5)))
                       "semmle.order" "1"]
                      [((id . 2) (label . "entry")
                        (url (uri . "file:///src/a.js") (startLine . 1) (startColumn . 1)
                             (endLine . 4) (endColumn . 1)))
                       "semmle.label" "entry of f"]
                      [((id . 1) (label . "f()")) "semmle.label" "call to f"]
                      [((id . 3) (label . "nowhere") (url (uri . "file:///")))
                       "semmle.label" "nowhere"]]))))))
    (should (equal (codeql--bqrs-graph-nodes "r.bqrs")
                   '(("call to f" . "/arch/src/a.js::2:3:2:5")
                     ("entry of f" . "/arch/src/a.js::1:1:4:1")
                     ("nowhere"))))))

(ert-deftest codeql-ported-test-graph-match-nodes ()
  "Graph nodes are only known when they match the dot nodes in order."
  (codeql-ported-test--with-temp-dir dir
    (let ((dot (codeql-ported-test--write (concat dir "g.dot") codeql-ported-test--dot)))
      ;; whitespace is collapsed in dot labels
      (should (equal (codeql--graph-match-nodes dot codeql-ported-test--graph-nodes)
                     (vconcat codeql-ported-test--graph-nodes)))
      (should-not (codeql--graph-match-nodes dot (reverse codeql-ported-test--graph-nodes)))
      (should-not (codeql--graph-match-nodes dot (cdr codeql-ported-test--graph-nodes))))))

(ert-deftest codeql-ported-test-parse-image-map ()
  "Graphviz image maps become image :map areas with node tooltips."
  (let ((map (codeql--parse-image-map
              (concat "<map id=\"%1\" name=\"%1\">\n"
                      "<area shape=\"poly\" id=\"0\" href=\"0\" title=\"a\" coords=\"1,2,3,4,5,6\"/>\n"
                      "<area shape=\"rect\" id=\"1\" href=\"1\" title=\"b\" coords=\"1,2,3,4\"/>\n"
                      "<area shape=\"circle\" id=\"2\" href=\"2\" title=\"c\" coords=\"5,6,7\"/>\n"
                      "</map>\n")
              (vconcat codeql-ported-test--graph-nodes))))
    (should (equal map
                   '(((poly . [1 2 3 4 5 6]) "0" (help-echo "a\\n      b\n/arch/src/a.js"))
                     ((rect (1 . 2) 3 . 4) "1" (help-echo "say \"hi\"\nNo location"))
                     ((circle (5 . 6) . 7) "2" (help-echo "c")))))))

(ert-deftest codeql-ported-test-svg-size-to-pixels ()
  "SVG sizes in points become pixels, like the coordinates of image maps."
  (should (equal (codeql--svg-size-to-pixels "<svg width=\"72pt\" height=\"36.5pt\"\n viewBox")
                 "<svg width=\"96\" height=\"49\"\n viewBox")))

(ert-deftest codeql-ported-test-show-graph-as-dot ()
  "Without a graph format, or graphviz for graphs not drawn as text, the dot file is shown."
  (codeql-ported-test--with-temp-dir dir
    (let ((dot (codeql-ported-test--write (concat dir "g.dot") "digraph { a -> b }")))
      (let ((codeql-graph-format nil))
        (codeql-ported-test--with-graph-buffer dot nil
          (should (eq major-mode 'codeql-graph-mode))
          (should (equal (buffer-string) "digraph { a -> b }"))))
      (let ((codeql-graph-format "svg"))
        (cl-letf (((symbol-function 'executable-find) #'ignore))
          ;; graphs are drawn as text instead, unless their nodes are unknown
          (codeql-ported-test--with-graph-buffer dot nil
            (should-not codeql--graph-format)
            (should (string-match-p "\\`This graph can't be drawn as text.*\n\ndigraph"
                                    (buffer-string)))))))))

(ert-deftest codeql-ported-test-show-graph-rendered ()
  "With graphviz, the graph is rendered with an image map of its nodes."
  (skip-unless (executable-find "dot"))
  (codeql-ported-test--with-temp-dir dir
    (let ((dot (codeql-ported-test--write (concat dir "g.dot") codeql-ported-test--dot))
          (codeql-graph-format "svg")
          inserted)
      (cl-letf (((symbol-function 'codeql--graph-insert-image)
                 (lambda (image map) (push (cons image map) inserted) (insert "image")))
                ((symbol-function 'codeql--graph-images-p) (lambda (_format) t)))
        (codeql-ported-test--with-graph-buffer dot codeql-ported-test--graph-nodes
          (should (eq codeql--org-query-buffer query-buffer))
          (should (equal codeql--graph-nodes (vconcat codeql-ported-test--graph-nodes)))
          (codeql-ported-test--wait #'codeql-ported-test--graph-rendered-p)
          (should (equal inserted `((,(concat dir "g.svg") . ,(concat dir "g.cmapx")))))
          (should (equal (buffer-string) "image"))
          ;; areas link to their node ids
          (should (string-match-p "href=\"1\""
                                  (with-temp-buffer
                                    (insert-file-contents (concat dir "g.cmapx"))
                                    (buffer-string))))
          ;; f cycles through png, text and the dot file back to svg
          (codeql-graph-cycle-format)
          (codeql-ported-test--wait #'codeql-ported-test--graph-rendered-p)
          (should (equal (caar inserted) (concat dir "g.png")))
          (codeql-graph-cycle-format)
          (should (equal codeql--graph-format "text"))
          (should (string-prefix-p "  x  a b  a.js:1\n  |\n  o  say \"hi\"\n" (buffer-string)))
          (codeql-graph-cycle-format)
          (should-not codeql--graph-format)
          (should (string-prefix-p "digraph {" (buffer-string)))
          (codeql-graph-cycle-format)
          (should (equal codeql--graph-format "svg"))
          ;; moving before the image is shown doesn't scroll a missing image
          (codeql-graph-next)
          (codeql-graph-forward)
          (codeql-ported-test--wait #'codeql-ported-test--graph-rendered-p)
          (should (= (length inserted) 3)))))))

(ert-deftest codeql-ported-test-graph-insert-image ()
  "Rendered graphs are shown as images with a clickable map of their nodes."
  (skip-unless (and (executable-find "dot") (display-graphic-p)
                    (image-type-available-p 'svg)))
  (codeql-ported-test--with-temp-dir dir
    (let ((dot (codeql-ported-test--write (concat dir "g.dot") codeql-ported-test--dot)))
      (should (zerop (call-process "dot" nil nil nil "-NURL=\\N" "-Tsvg" "-o"
                                   (concat dir "g.svg") "-Tcmapx" "-o" (concat dir "g.cmapx")
                                   dot)))
      (with-temp-buffer
        (setq codeql--graph-nodes (vconcat codeql-ported-test--graph-nodes))
        (codeql--graph-insert-image (concat dir "g.svg") (concat dir "g.cmapx"))
        (let ((image (get-text-property (point-min) 'display)))
          (should (eq (image-property image :type) 'svg))
          (should (equal (mapcar #'cadr (image-property image :map)) '("0" "1"))))))))

(ert-deftest codeql-ported-test-show-graph-render-failure ()
  "When graphviz fails, the dot file is shown instead."
  (skip-unless (executable-find "dot"))
  (codeql-ported-test--with-temp-dir dir
    (let ((dot (codeql-ported-test--write (concat dir "g.dot") "digraph { a -> b }"))
          (codeql-graph-format "no-such-format"))
      (codeql-ported-test--with-graph-buffer dot nil
        (codeql-ported-test--wait #'codeql-ported-test--graph-rendered-p)
        (should-not codeql--graph-format)
        (should (string-match-p "\\`Failed to render graph.*\n\ndigraph" (buffer-string)))))))

(ert-deftest codeql-ported-test-graph-visit-node ()
  "Graph nodes are visited by clicking them or choosing their label."
  (codeql-ported-test--with-temp-dir dir
    (let ((dot (codeql-ported-test--write (concat dir "g.dot") codeql-ported-test--dot))
          (codeql-graph-format nil)
          visited)
      (codeql-ported-test--with-graph-buffer dot codeql-ported-test--graph-nodes
        (cl-letf (((symbol-function 'codeql--org-open-file-link)
                   (lambda (link) (push link visited))))
          (let ((click (lambda (area)
                         (codeql-graph-visit-node-at-mouse
                          `(mouse-1 (,(selected-window) ,area (0 . 0) 0))))))
            (with-selected-window (display-buffer (current-buffer))
              (funcall click "0")
              (should (equal visited '("/arch/src/a.js::1:1:1:3")))
              (should-error (funcall click "1") :type 'user-error)
              ;; clicks outside of nodes
              (funcall click 1)
              (should (equal (length visited) 1))))
          ;; only nodes with locations can be chosen
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt candidates &rest _)
                       (should (= (length candidates) 1))
                       (car (car candidates)))))
            (codeql-graph-visit-node))
          (should (equal visited '("/arch/src/a.js::1:1:1:3" "/arch/src/a.js::1:1:1:3")))
          ;; unknown nodes
          (setq codeql--graph-nodes nil)
          (should-error (codeql-graph-visit-node) :type 'user-error))))))

(defconst codeql-ported-test--diamond-dot
  (concat "digraph {\n  compound=true;\n"
          "  0[\"label\"=\"if (x)\"; ];\n  1[\"label\"=\"then\"; ];\n"
          "  2[\"label\"=\"else\"; ];\n  3[\"label\"=\"join\"; ];\n"
          "  0 -> 1[\"label\"=\"true\"; ];\n  0 -> 2[\"label\"=\"false\"; ];\n"
          "  1 -> 3[];\n  2 -> 3[];\n}\n")
  "A dot file of an if statement, with labelled branches.")

(defconst codeql-ported-test--diamond-nodes
  (cl-loop for label in '("if (x)" "then" "else" "join")
           for line from 1
           collect (cons label (format "/arch/src/a.js::%d:1:%d:3" line line)))
  "The nodes of `codeql-ported-test--diamond-dot'.")

(ert-deftest codeql-ported-test-dot-edges ()
  "Dot edges are read with their labels, unescaped."
  (codeql-ported-test--with-temp-dir dir
    (should (equal (codeql--dot-edges
                    (codeql-ported-test--write
                     (concat dir "g.dot")
                     "digraph {\n  0[\"label\"=\"a\"; ];\n  0 -> 1[];\n  1 -> 0[\"label\"=\"say \\\"hi\\\"\"; ];\n}\n"))
                   '((0 1 nil) (1 0 "say \"hi\""))))))

(ert-deftest codeql-ported-test-graph-text-layout ()
  "Graphs are laid out with forward edges as lanes and back edges listed."
  ;; branches split off and merge back into the lane of their node
  (should (equal (codeql--graph-text-layout [(1 2) (3) (3) nil])
                 '((0 "o-." "| |" nil) (1 "o |" "| |" nil) (2 "| o" "| |" nil)
                   (3 "o-'" nil nil))))
  ;; loops point back up
  (should (equal (codeql--graph-text-layout [(1) (2 3) (1) nil])
                 '((0 "o" "|" nil) (1 "o-." "| |" nil) (2 "o |" "  |" (1))
                   (3 "  o" nil nil))))
  ;; nodes without predecessors come first, then unreachable cycles by id
  (should (equal (codeql--graph-text-layout [nil (0) (3) (2)])
                 '((1 "o" "|" nil) (0 "o" "" nil) (2 "o" "|" nil) (3 "o" nil (2)))))
  (should (equal (codeql--graph-text-layout [(0)]) '((0 "o" nil (0)))))
  ;; lanes pass by nodes they don't end at
  (should (equal (mapcar #'cadr (codeql--graph-text-layout [(1 3) (2) (3) nil]))
                 '("o-." "o |" "o |" "o-'"))))

(ert-deftest codeql-ported-test-show-graph-as-text ()
  "Graphs are drawn as text diagrams with the selected node described."
  (codeql-ported-test--with-temp-dir dir
    (let ((dot (codeql-ported-test--write (concat dir "g.dot") codeql-ported-test--diamond-dot))
          (codeql-graph-format "text"))
      (codeql-ported-test--with-graph-buffer dot codeql-ported-test--diamond-nodes
        (should (string-prefix-p
                 (concat "  x-.  if (x)  a.js:1\n  | |\n  o |  then  a.js:2\n  | |\n"
                         "  | o  else  a.js:3\n  | |\n  o-'  join  a.js:4\n\n"
                         "  if (x)\n  Location: a.js:1\n  Predecessors: none\n"
                         "  Successors: [true] then, [false] else\n")
                 (buffer-substring-no-properties (point-min) (point-max))))
        (should (= (point) 3))
        (should (equal header-line-format '(:eval (codeql--graph-header-line))))
        (should (equal (substring-no-properties (codeql--graph-header-line))
                       " if (x)  a.js:1"))
        ;; graphs with unknown nodes are drawn too
        (setq codeql--graph-nodes nil)
        (revert-buffer)
        (should (string-prefix-p "  x-.  if (x)\n" (buffer-string)))
        (should (string-match-p "Location: unknown" (buffer-string)))))))

(ert-deftest codeql-ported-test-graph-text-navigation ()
  "Text diagrams are navigated like `undo-tree-visualize'."
  (codeql-ported-test--with-temp-dir dir
    (let ((dot (codeql-ported-test--write (concat dir "g.dot") codeql-ported-test--diamond-dot))
          (codeql-graph-format "text")
          visited)
      (codeql-ported-test--with-graph-buffer dot codeql-ported-test--diamond-nodes
        (cl-letf (((symbol-function 'codeql--org-open-file-link)
                   (lambda (link) (push link visited))))
          (should (= codeql--graph-selected 0))
          (codeql-graph-next)
          (should (equal (list codeql--graph-selected codeql--graph-trail) '(1 (0))))
          (should (looking-at "x |  then"))
          (should-error (codeql-graph-backward) :type 'user-error)
          (codeql-graph-forward)
          (should (equal (list codeql--graph-selected codeql--graph-trail) '(2 (0))))
          (should-error (codeql-graph-forward) :type 'user-error)
          (codeql-graph-next)
          (should (equal (list codeql--graph-selected codeql--graph-trail) '(3 (2 0))))
          (should-error (codeql-graph-next) :type 'user-error)
          ;; back the way we came
          (codeql-graph-previous)
          (should (equal (list codeql--graph-selected codeql--graph-trail) '(2 (0))))
          (codeql-graph-previous)
          (should (= codeql--graph-selected 0))
          (should-error (codeql-graph-previous) :type 'user-error)
          ;; or to the first predecessor
          (codeql--graph-select 3)
          (codeql-graph-previous)
          (should (= codeql--graph-selected 1))
          ;; RET visits the node of the row at point, or the selected one
          (codeql-graph-visit-node)
          (goto-char (point-max))
          (codeql-graph-visit-node)
          (goto-char (point-min))
          (codeql-graph-visit-node)
          (should (equal visited '("/arch/src/a.js::1:1:1:3" "/arch/src/a.js::2:1:2:3"
                                   "/arch/src/a.js::2:1:2:3")))
          ;; clicks select nodes, and visit selected ones
          (with-selected-window (display-buffer (current-buffer))
            (let ((click (lambda (pos)
                           (codeql-graph-visit-node-at-mouse
                            `(mouse-1 (,(selected-window) ,pos (0 . 0) 0))))))
              (funcall click (save-excursion (goto-char (point-min))
                                             (search-forward "else") (point)))
              (should (equal (list codeql--graph-selected codeql--graph-trail) '(2 (1))))
              (should (= (length visited) 3))
              (funcall click (point))
              (should (equal (car visited) "/arch/src/a.js::3:1:3:3"))))
          ;; detail buttons select nodes
          (goto-char (point-min))
          (search-forward "Predecessors: [false] ")
          (push-button)
          (should (= codeql--graph-selected 0))
          (search-forward "[true] ")
          (push-button)
          (should (= codeql--graph-selected 1)))))))

(ert-deftest codeql-ported-test-graph-cycle-format-without-images ()
  "Image formats are skipped where they can't be shown."
  (codeql-ported-test--with-temp-dir dir
    (let ((dot (codeql-ported-test--write (concat dir "g.dot") codeql-ported-test--diamond-dot))
          (codeql-graph-format "svg"))
      (cl-letf (((symbol-function 'codeql--graph-images-p) #'ignore))
        (codeql-ported-test--with-graph-buffer dot nil
          (should (equal codeql--graph-format "text"))
          (codeql-graph-cycle-format)
          (should-not codeql--graph-format)
          (codeql-graph-cycle-format)
          (should (equal codeql--graph-format "text")))))))

(ert-deftest codeql-ported-test-find-templated-query ()
  "Templated queries of library packs take precedence over bundled ones."
  (codeql-ported-test--with-temp-dir dir
    (codeql-ported-test--with-query-buffer
      (setq codeql--search-paths-buffer-local (list (concat dir "pack")))
      (cl-letf (((symbol-function 'codeql--file-exists-p) #'file-exists-p))
        (should (equal (codeql--find-templated-query :javascript "printCfg")
                       (expand-file-name "javascript/printCfg.ql"
                                         codeql--bundled-queries-directory)))
        (should (file-exists-p (codeql--find-templated-query :javascript "printCfg")))
        (should-not (codeql--find-templated-query :javascript "noSuchQuery"))
        (should-not (codeql--find-templated-query :ruby "printCfg"))
        (let ((pack-query (codeql-ported-test--write (concat dir "pack/printCfg.ql") "")))
          (should (equal (codeql--find-templated-query :javascript "printCfg")
                         pack-query)))))))

(ert-deftest codeql-ported-test-run-bundled-templated-query ()
  "Bundled templated queries run with the library path of the query buffer."
  (codeql-ported-test--with-query-buffer
    (setq codeql--active-database "/dbs/js-db/"
          codeql--database-source-archive-root "/dbs/js-db/src"
          codeql--search-paths-buffer-local nil
          buffer-file-name "/work/pack/Query.ql")
    (let ((codeql-query-server "query-server2")
          resolved run)
      (cl-letf (((symbol-function 'codeql--await-search-paths) #'ignore)
                ((symbol-function 'message) #'ignore)
                ((symbol-function 'codeql--resolve-query-paths)
                 (lambda (path) (push path resolved) t))
                ((symbol-function 'codeql--query-server-run-query-from-path)
                 (lambda (path quick-eval values &rest _)
                   (setq run (list path quick-eval values)))))
        (codeql--run-templated-query :javascript "printCfg" "/dbs/js-db/src/app/a.js"
                                     (current-buffer) '(3 . 7))
        (should (equal resolved '("/work/pack/Query.ql")))
        (should (equal run `(,(expand-file-name "javascript/printCfg.ql"
                                                codeql--bundled-queries-directory)
                             nil
                             (:selectedSourceFile "/app/a.js"
                              :selectedSourceLine "3" :selectedSourceColumn "7"))))
        (should-error (codeql--run-templated-query :javascript "noSuchQuery"
                                                   "/dbs/js-db/src/app/a.js" (current-buffer)))))))


;;; Searching the database source archive

(defmacro codeql-ported-test--with-source-archive (root &rest body)
  "Run BODY in a query buffer whose database source archive is at ROOT."
  (declare (indent 1) (debug t))
  `(codeql-ported-test--with-temp-dir ,root
     (codeql-ported-test--write (concat ,root "src/app.js") "let a = 1;\nneedle(a);\n")
     (codeql-ported-test--write (concat ,root "src/lib.rb") "needle\n")
     (codeql-ported-test--write (concat ,root "src/other.js") "nothing\n")
     (codeql-ported-test--with-query-buffer
       (setq codeql--active-database "/dbs/js-db/"
             codeql--database-source-archive-root (directory-file-name ,root))
       (let ((codeql--database-grep-query-buffers nil)
             (xref-after-jump-hook nil))
         ,@body))))

(defun codeql-ported-test--grep (regexp &optional files)
  "Return (FILE . LINE) of the `codeql-database-grep' matches of REGEXP in FILES."
  (let (matches)
    (cl-letf (((symbol-function 'xref-show-xrefs)
               (lambda (fetcher _)
                 (setq matches
                       (mapcar (lambda (xref)
                                 (let ((location (xref-item-location xref)))
                                   (cons (file-name-nondirectory
                                          (xref-location-group location))
                                         (xref-location-line location))))
                               (funcall fetcher))))))
      (codeql-database-grep regexp files))
    (sort matches (lambda (a b) (string< (car a) (car b))))))

(ert-deftest codeql-ported-test-database-grep ()
  "Grepping finds matches in the source archive files."
  (codeql-ported-test--with-source-archive root
    (should (equal (codeql-ported-test--grep "needle") '(("app.js" . 2) ("lib.rb" . 1))))
    (should (equal (codeql-ported-test--grep "needle" "*.js") '(("app.js" . 2))))
    (should (equal codeql--database-grep-query-buffers
                   `((,(directory-file-name root) . ,query-buffer))))
    (should (memq #'codeql--database-grep-after-jump xref-after-jump-hook))
    (should-error (codeql-ported-test--grep "haystack") :type 'user-error)))

(ert-deftest codeql-ported-test-database-grep-without-archive ()
  "Grepping needs a database with an extracted source archive."
  (codeql-ported-test--with-query-buffer
    (should-error (codeql-database-grep "needle") :type 'user-error)
    (setq codeql--active-database "/dbs/js-db/"
          codeql--database-source-archive-root "/no/such/archive")
    (should-error (codeql-database-grep "needle") :type 'user-error)))

(ert-deftest codeql-ported-test-database-grep-after-jump ()
  "Files visited from matches are set up like those of result locations."
  (codeql-ported-test--with-source-archive root
    (codeql-ported-test--grep "needle")
    (let ((archive-file (find-file-noselect (concat root "src/app.js")))
          (other-file (find-file-noselect
                       (codeql-ported-test--write
                        (concat (file-name-directory (directory-file-name root))
                                (file-name-nondirectory (directory-file-name root))
                                "-sibling.js")
                        "needle\n"))))
      (unwind-protect
          (cl-letf (((symbol-function 'codeql-xref-backend) #'ignore))
            (with-current-buffer archive-file
              (run-hooks 'xref-after-jump-hook)
              (should (eq codeql--org-query-buffer query-buffer))
              (should buffer-read-only))
            (with-current-buffer other-file
              (run-hooks 'xref-after-jump-hook)
              (should-not codeql--org-query-buffer)
              (should-not buffer-read-only)))
        (delete-file (buffer-file-name other-file))
        (kill-buffer archive-file)
        (kill-buffer other-file)))))

;;; Doctor

(ert-deftest codeql-ported-test-doctor-line ()
  "Report lines align their status, which is colored by severity."
  (let ((line (codeql--doctor-line 'warn "dot" "graphviz not found")))
    (should (equal (substring-no-properties line) "  [warn]  dot: graphviz not found\n"))
    (should (eq (get-text-property 2 'face line) 'warning)))
  (should (equal (substring-no-properties (codeql--doctor-line 'ok "gh"))
                 "  [ok]    gh\n"))
  (should (eq (get-text-property 2 'face (codeql--doctor-line 'info "x")) 'shadow)))

(defmacro codeql-ported-test--with-programs (programs runs &rest body)
  "Run BODY with only the executables of the PROGRAMS alist found.

Running programs with `codeql--doctor-run' returns the value of RUNS,
an alist from argument lists to results."
  (declare (indent 2) (debug t))
  `(cl-letf (((symbol-function 'executable-find)
              (lambda (name &optional _remote) (cdr (assoc name ,programs))))
             ((symbol-function 'codeql--doctor-run)
              (lambda (_program &rest args) (cdr (assoc args ,runs)))))
     ,@body))

(ert-deftest codeql-ported-test-doctor-cli-checks ()
  "The CLI, gh, its extensions and the search paths are checked."
  (codeql-ported-test--with-temp-dir dir
    (let ((default-directory dir)
          (codeql-search-paths (list dir "/no/such/pack"))
          (codeql-use-gh-codeql-extension-when-available t))
      (codeql-ported-test--with-programs nil
          '((("version" "--format=terse") . (0 . "2.20.1")))
        (should (equal (codeql--doctor-cli-checks '("/bin/codeql"))
                       `((ok "CLI" "/bin/codeql, version 2.20.1")
                         (info "gh" "not found, it's only needed for the gh codeql extension")
                         (ok "Search path" ,dir)
                         (warn "Search path" "/no/such/pack doesn't exist"))))
        (should (equal (car (codeql--doctor-cli-checks '(nil)))
                       '(error "CLI" "not found, set `codeql-cli' or install the gh codeql extension"))))
      (codeql-ported-test--with-programs '(("gh" . "/bin/gh"))
          '((("codeql" "version" "--format=terse") . (2 . "unknown command"))
            (("mrva" "--help") . (0 . "Usage")))
        (cl-letf (((symbol-function 'codeql--gh-codeql-cli-available-p) (lambda () t)))
          (should (equal (seq-take (codeql--doctor-cli-checks '("gh" "codeql")) 4)
                         '((error "CLI" "gh codeql doesn't run: unknown command")
                           (ok "gh" "/bin/gh")
                           (ok "gh codeql" "installed and preferred")
                           (ok "gh mrva" "installed"))))))
      (codeql-ported-test--with-programs '(("gh" . "/bin/gh")) nil
        (cl-letf (((symbol-function 'codeql--gh-codeql-cli-available-p) #'ignore))
          (should (equal (seq-subseq (codeql--doctor-cli-checks '("/bin/codeql")) 2 4)
                         '((info "gh codeql" "not installed")
                           (info "gh mrva" "not installed, it's needed for `codeql-mrva'")))))))))

(ert-deftest codeql-ported-test-doctor-tool-checks ()
  "The external tools are checked, graphviz only if graphs are rendered."
  (let ((default-directory temporary-file-directory))
    (let ((codeql-graph-format "svg"))
      (codeql-ported-test--with-programs nil nil
        (should (equal (codeql--doctor-tool-checks)
                       '((error "unzip" "not found, database source archives can't be extracted")
                         (info "zipinfo" "not found, unzip is used to list source archives")
                         (warn "dot" "graphviz not found, graph results are shown as dot files")))))
      (codeql-ported-test--with-programs '(("unzip" . "/bin/unzip")
                                           ("zipinfo" . "/bin/zipinfo")
                                           ("dot" . "/bin/dot"))
          nil
        (should (equal (codeql--doctor-tool-checks)
                       '((ok "unzip" "/bin/unzip")
                         (ok "zipinfo" "/bin/zipinfo")
                         (ok "dot" "/bin/dot"))))))
    (let ((codeql-graph-format nil))
      (codeql-ported-test--with-programs nil nil
        (should (equal (car (last (codeql--doctor-tool-checks)))
                       '(info "dot" "graph results are shown as dot files, see `codeql-graph-format'")))))))

(ert-deftest codeql-ported-test-doctor-buffer-checks ()
  "QL buffers report their query server, database and search paths."
  (with-temp-buffer
    (setq codeql--active-database "/dbs/js-db/"
          codeql--search-paths-buffer-local '("/a" "/b"))
    (cl-letf (((symbol-function 'eglot-current-server) #'ignore))
      (let ((checks (codeql--doctor-buffer-checks)))
        (should (equal (nth 0 checks) '(info "Query server" "not running")))
        (should (equal (nth 1 checks) '(ok "Database" "/dbs/js-db/")))
        (should (equal (nth 3 checks) '(info "Search paths" "2 configured")))))))

(ert-deftest codeql-ported-test-doctor-report ()
  "The report counts errors and warnings, and lists every section."
  (cl-letf (((symbol-function 'codeql--doctor-checks)
             (lambda (_)
               '(("First" (ok "a" "fine") (error "b" "broken"))
                 ("Second" (warn "c") (warn "d" "meh") (info "e"))))))
    (save-window-excursion
      (codeql-doctor))
    (with-current-buffer "*codeql-doctor*"
      (unwind-protect
          (progn
            (should (derived-mode-p 'special-mode))
            (goto-char (point-min))
            (should (looking-at-p "emacs-codeql doctor, .*: 1 error, 2 warnings$"))
            (should (string-match-p
                     (concat "\nFirst\n  \\[ok]    a: fine\n  \\[error] b: broken\n"
                             "\nSecond\n  \\[warn]  c\n  \\[warn]  d: meh\n  \\[info]  e\n\\'")
                     (buffer-string))))
        (kill-buffer)))))

;;; Language server

(ert-deftest codeql-ported-test-lsp-single-server ()
  (require 'eglot)
  (let* ((project '(transient . "/tmp/"))
         (contact (list '(ql-tree-sitter-mode) project 'eglot-lsp-server
                        '("codeql") '("ql")))
         (connects 0))
    (cl-letf (((symbol-function 'eglot--guess-contact) (lambda (&rest _) contact))
              ((symbol-function 'eglot--connect) (lambda (&rest _) (cl-incf connects)))
              ((symbol-function 'eglot--maybe-activate-editing-mode) #'ignore))
      (codeql-ported-test--with-query-buffer
        (setq buffer-file-name "/tmp/codeql-ported-test.ql")
        ;; a mode hook's eglot-ensure would connect before the search paths are known
        (eglot-ensure)
        (should-not (local-variable-p 'post-command-hook))
        (codeql--lsp-connect nil)
        (should (= connects 1))
        ;; eglot only registers a server for its project once it is up
        (let ((server (make-instance
                       'eglot-lsp-server
                       :name "codeql-ported-test-server"
                       :process (make-process :name "codeql-ported-test-server"
                                              :command '("cat")
                                              :connection-type 'pipe
                                              :noquery t))))
          (unwind-protect
              (progn
                (setf (eglot--project server) project)
                (setf (eglot--languages server) '((ql-tree-sitter-mode . "ql")))
                (codeql--lsp-connect nil)
                (should (= connects 1))
                (setf (eglot--project server) '(transient . "/elsewhere/"))
                (codeql--lsp-connect nil)
                (should (= connects 2)))
            (delete-process (jsonrpc--process server))))))))

(provide 'emacs-codeql-ported-test)
;;; emacs-codeql-ported-test.el ends here
