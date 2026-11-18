;;; ob-codeql.el --- Org Babel support for CodeQL -*- lexical-binding: t -*-

;; This file is not part of GNU Emacs

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Evaluates `codeql' (or `ql') source blocks in CodeQL sessions, like
;; the CodeQL REPL does, see `codeql--session-eval'.  A block can hold
;; a query, definitions, an expression, a formula, the name of a
;; predicate of its session to quick evaluate, or the name of a type:
;;
;;   #+begin_src codeql :database ~/dbs/js-db
;;   from CallExpr c
;;   where c.getNumArgument() > 2
;;   select c, c.getNumArgument()
;;   #+end_src
;;
;; Results become org tables, whose locations are codeql: links.
;;
;; Header arguments:
;;
;;   :database  the database to evaluate on, else that of the project
;;   :pack      a directory of the CodeQL pack to evaluate in, else the
;;              pack of the org file, or a pack that ob-codeql makes for
;;              the language of the database
;;   :session   a session whose definitions later blocks can use, which
;;              the CodeQL REPL of the pack can share; with none (the
;;              default), each block is evaluated on its own
;;   :limit     the number of result rows, `ob-codeql-default-limit'
;;   :count     with yes, a quick evaluation or the values of a type are
;;              counted
;;   :open      with yes, the results also open in a results buffer
;;
;; Enable it with
;;
;;   (org-babel-do-load-languages 'org-babel-load-languages '((codeql . t)))

;;; Code:

(require 'ob)
(require 'emacs-codeql)

(defcustom ob-codeql-default-limit 100
  "The number of result rows that a CodeQL source block returns by default.

The :limit header argument overrides this."
  :type 'natnum
  :group 'emacs-codeql)

(defvaralias 'org-babel-default-header-args:ql 'org-babel-default-header-args:codeql)

(defvar org-babel-default-header-args:codeql '((:session . "none"))
  "Default header arguments of CodeQL source blocks.")

(defconst org-babel-header-args:codeql
  '((database . :any)
    (pack . :any)
    (limit . :any)
    (count . ((yes no)))
    (open . ((yes no))))
  "CodeQL specific header arguments.")

(defconst ob-codeql--anonymous-session "org-babel"
  "The name of the session that blocks without a :session are evaluated in.")

(defun ob-codeql--yes-p (params key)
  "Return non-nil if the header argument KEY of PARAMS is yes."
  (member (format "%s" (cdr (assq key params))) '("yes" "t")))

(defun ob-codeql--session-name (params)
  "Return the name of the session to evaluate in according to PARAMS, or nil."
  (let ((session (cdr (assq :session params))))
    (cond ((or (not (assq :session params)) (equal session "none")) nil)
          ;; a :session without a name
          ((member session '(nil "" "yes")) "default")
          (t (format "%s" session)))))

(defun ob-codeql--root (params database)
  "Return (ROOT . DATABASE) of the CodeQL pack to evaluate in according to PARAMS.

DATABASE is that of the :database header argument, or nil.  Outside of
CodeQL packs, it is read when it is nil, to find the pack of its
language, see `codeql--session-fallback-root'."
  (let ((pack (cdr (assq :pack params))))
    (cond
     (pack
      (cons (or (codeql--find-project-root (expand-file-name (format "%s" pack)))
                (user-error "%s is not in a CodeQL pack" pack))
            database))
     ((codeql--find-project-root default-directory)
      (cons (codeql--find-project-root default-directory) database))
     (t
      (let* ((database (or database
                           (if noninteractive
                               (user-error "CodeQL blocks outside of packs need a :database")
                             (codeql--read-database "Database for CodeQL blocks: "))))
             (language (or (codeql--database-language database)
                           (user-error "No CodeQL database at %s" database))))
        (cons (codeql--session-fallback-root language) database))))))

(defun ob-codeql--session (params)
  "Return the CodeQL session to evaluate a block with PARAMS in.

Without a :session, that is a session whose definitions are reset."
  (when (assq :var params)
    (user-error "CodeQL blocks don't support :var"))
  (pcase-let* ((database (when-let ((database (cdr (assq :database params))))
                           (expand-file-name (format "%s" database))))
               (`(,root . ,database) (ob-codeql--root params database))
               (name (ob-codeql--session-name params))
               (session (codeql--session-ensure
                         (codeql--session-get root (or name ob-codeql--anonymous-session))
                         database)))
    (unless name
      (codeql--session-reset session))
    session))

(defun ob-codeql--cell (value)
  "Return the org table cell for the decoded result VALUE.

This is called in the query buffer of the results, which locates their
source archive."
  (pcase value
    ('t "true")
    (:false "false")
    (:null "")
    ((pred numberp) value)
    ((pred stringp) (codeql--org-table-cell (codeql--printable-text value)))
    (_ (codeql--org-table-cell
        (if-let ((node (codeql--session-value-node value)))
            (codeql--result-node-to-org node)
          (codeql--org-text (alist-get 'label value)))))))

(defun ob-codeql--results (outcome limit)
  "Return the babel result for the first LIMIT results of OUTCOME.

A single value is returned as is, other results as a table under the
names, or kinds, of their columns."
  (pcase-let* ((session (plist-get outcome :session))
               (`(,columns ,tuples ,total)
                (codeql--session-decode session (plist-get outcome :bqrs-path) limit))
               (rows (with-current-buffer (codeql--session-buffer session)
                       (let ((codeql--source-link-prefix-box (list nil)))
                         (mapcar (lambda (tuple) (mapcar #'ob-codeql--cell tuple))
                                 tuples)))))
    (when (> total (length rows))
      (message "Showing %d of %d CodeQL results, :limit shows more" (length rows) total))
    (if (and (= (length columns) 1) (= total 1))
        (let ((value (elt (car tuples) 0)))
          (if (stringp value) value (caar rows)))
      (cons (mapcar (lambda (column)
                      (codeql--org-table-cell
                       (format "%s" (or (alist-get 'name column)
                                        (alist-get 'kind column)
                                        ""))))
                    columns)
            (cons 'hline rows)))))

(defun ob-codeql--error (outcome)
  "Report the failed evaluation of OUTCOME, and return nil."
  (if (plist-get outcome :cancelled)
      (message "CodeQL evaluation canceled")
    (org-babel-eval-error-notify
     1 (concat (string-trim-right (or (plist-get outcome :message) "Evaluation failed"))
               (when-let ((dropped (plist-get outcome :dropped)))
                 (format "\nRolled back %s." (string-join dropped ", ")))
               "\n")))
  nil)

;;;###autoload
(defun org-babel-execute:codeql (body params)
  "Evaluate the CodeQL BODY of a source block with header arguments PARAMS.

See the commentary of ob-codeql.el for the header arguments."
  (let* ((session (ob-codeql--session params))
         (limit (let ((limit (cdr (assq :limit params))))
                  (if limit
                      (if (stringp limit) (string-to-number limit) limit)
                    ob-codeql-default-limit)))
         (outcome (codeql--session-eval-sync session body
                                             :frontend "Org Babel"
                                             :count (ob-codeql--yes-p params :count))))
    (pcase (plist-get outcome :status)
      ('results
       (prog1 (ob-codeql--results outcome limit)
         (when (ob-codeql--yes-p params :open)
           (codeql--query-run-show outcome))))
      ('empty nil)
      ('error (ob-codeql--error outcome))
      (_ (let ((defined (seq-difference (plist-get outcome :definitions)
                                        (plist-get outcome :dropped))))
           (if defined
               (format "Defined %s." (string-join defined ", "))
             "Nothing new was defined."))))))

;;;###autoload
(defalias 'org-babel-execute:ql #'org-babel-execute:codeql)

(provide 'ob-codeql)
;;; ob-codeql.el ends here
