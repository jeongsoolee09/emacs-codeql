;;; emacs-codeql.el --- codeql support for emacs -*- lexical-binding: t -*-

;; Author: Bas Alberts
;; Maintainer: Bas Alberts <bas@anti.computer>
;; Version: 0.2.1-pre
;; Package-Requires: ((emacs "27.1") (seq "2.23") (transient "0.3.7") (jsonrpc "1.0.14") (tree-sitter "0.18.0") (tree-sitter-langs "0.11.4") (tree-sitter-indent) (aggressive-indent) (eglot) (org))
;; Homepage: https://github.com/anticomputer/codeql.el
;; Keywords: dev

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

;; This package is a very early version of modern CodeQL support for emacs.
;;
;; It operates three major components:
;;
;; ql-tree-sitter.el || ql-tree-sitter-builtin.el
;;
;; A tree-sitter based QL highlighting and indentation mode. It requires
;; emacs-tree-sitter, tree-sitter-langs, tree-sitter-indent, tree-sitter-hl
;; and aggressive-indent to function for the non-native tree-sitter support.
;;
;; If you are on emacs 29 and have compiled with tree-sitter support you
;; can alternatively use ql-tree-sitter-builtin.el which provides a native
;; tree-sitter ql mode for emacs 29 and above.
;;
;; emacs-codeql.el
;;
;; A utility layer that enhances ql-tree-sitter-mode with modern codeql
;; ide extension functionality. It requires transient and json-pointer
;; to function in a basic capacity but eglot is highly recommended.
;;
;; While ql-tree-sitter.el does function without emacs-codeql.el, the two
;; are assumed to operate in tandem and considered part of the same package.

;; For `emacs-codeql' configuration examples and advice:
;;
;; https://github.com/anticomputer/emacs-codeql

;;; Disclaimers

;; This package has not been tested with lsp-mode and earlier experiments
;; with lsp-mode and QL language support suggest a less than ideal experience
;; when compared with eglot based lsp support for QL.

;;; Acknowledgements

;; This package was heavily inspired by, and in some cases directly ported
;; from, Alvaro Muñoz's codeql.nvim (https://github.com/pwntester/codeql.nvim)
;; I'd like to thank him for dragging me into a continuous, yet good natured,
;; editor arms race. He solved most of the hard problems in lua, and a lot of
;; this package stands on the shoulders of his prior art.

;; A lot of the fundamental ideas behind this package were both inspired and
;; outlined by Esben Sparre Andreasen (https://github.com/esbena). Esben is
;; a CodeQL engineer and his deep QL knowledge and early work on emacs codeql
;; support was a big inspiration to revive this effort. While this package
;; no longer contains Esben's original major mode and org rendering, the very
;; first iteration was heavily drafted on top of his work, and his early
;; design ideas are very much carried forward in this implementation.

;; While I was writing this code I found myself doing an inordinate amount
;; of destructuring binds to chew through the various json objects. In search
;; of a cleaner solution, I came across https://github.com/syohex/emacs-json-pointer
;; which I've found to be infinitely useful for clear json object access in elisp.
;; Since it is not available on MELPA, we bundle it as part of this package.
;; All original copyright and licensing as designated by Shohei YOSHIDA applies,
;; and I'd like to thank them for their continued contributions across the elisp
;; ecosystem.

;;; Support

;; There is none. This package is wholly unsupported and is focused solely on
;; my own workflows and requirements for codeql use. However, if you find it
;; useful and do run into problems, do please file an issue :)

;;; Code:

;; part of emacs
(require 'jsonrpc)
(require 'cl-lib)
(require 'url-util)
(require 'url-parse)
;; org is only needed for results, diagnostics, AST and performance buffers,
;; and loading it takes a noticeable while, see `codeql--require-org'
(eval-when-compile
  (require 'org)
  (require 'ol)
  (require 'org-table)
  (require 'org-src))
(declare-function org-at-table-p "org")
(declare-function org-link-escape "ol")
(declare-function org-link-set-parameters "ol")
(declare-function org-link-unescape "ol")
(declare-function org-reveal "org")
(declare-function org-escape-code-in-string "org-src")
(declare-function org-cycle-hide-drawers "org-cycle")
(declare-function outline-hide-subtree "outline")
(declare-function treesit-ready-p "treesit")
(declare-function treesit-parser-list "treesit.c")
(declare-function treesit-node-at "treesit")
(declare-function treesit-node-parent "treesit.c")
(declare-function treesit-node-type "treesit.c")
(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-child "treesit.c")
(declare-function treesit-node-child-by-field-name "treesit.c")
(declare-function treesit-node-children "treesit.c")
(declare-function treesit-node-text "treesit.c")
(declare-function tree-sitter-node-at-pos "tree-sitter")
(declare-function tsc-get-parent "tsc")
(declare-function tsc-node-type "tsc")
(declare-function tsc-node-start-position "tsc")
(declare-function tsc-get-child-by-field "tsc")
(declare-function tsc-get-nth-named-child "tsc")
(require 'files)
(require 'project)
(require 'flymake)
(require 'pulse)

(defun codeql--require-org ()
  "Load the parts of org that results and other org buffers rely on."
  (require 'org)
  (require 'ol)
  (require 'org-table)
  (require 'org-src))

;; bundled
(require 'json-pointer)

;; not part of emacs
(require 'transient)

;;; place our artifacts if they don't exist yet (very hacky!)
(cond
 ;; emacs 29+
 ((and (>= emacs-major-version 29)
       (require 'treesit nil t)
       (treesit-available-p))
  (message "Attempting to use builtin tree-sitter support for emacs-codeql.")
  (unless (treesit-ready-p 'ql)
    (if (yes-or-no-p "tree-sitter ql support not found, install artifacts now?")
        (let ((treesit-language-source-alist
               '((ql . ("https://github.com/tree-sitter/tree-sitter-ql"
                        nil
                        nil
                        nil)))))
          (treesit-install-language-grammar 'ql))
      (error "emacs-codeql does not work without tree-sitter-langs support."))))
 ;; emacs 28-
 ((and (<= emacs-major-version 28)
       (require 'tree-sitter-langs nil t))
  (declare-function tree-sitter-langs--bin-dir "ext:tree-sitter-langs")
  (unless
      (member t
              (cl-map 'list
                      (lambda (f)
                        (file-exists-p (concat (tree-sitter-langs--bin-dir) f)))
                      '("/ql.dylib" "/ql.so")))
    (if (yes-or-no-p "tree-sitter-langs ql support not found, install artifacts now?")
        (let* ((arch (string-trim-right (shell-command-to-string "uname -m")))
               (sys (cond ((eq system-type 'gnu/linux) "linux")
                          ((eq system-type 'darwin) "darwin")
                          (t (error "Your platform is currently not supported."))))
               (cmd (format "cp %s/bin/%s/%s/ql.* %s"
                            (file-name-directory (or load-file-name (buffer-file-name)))
                            sys arch (tree-sitter-langs--bin-dir))))
          (message "Placing tree-sitter artifacts with %s" cmd)
          (cl-assert (eql 0 (shell-command cmd))))
      (error "emacs-codeql does not work without tree-sitter-langs support."))))
 ;; bail out if we can't figure out tree-sitter support
 (t (error "emacs-codeql is unable to determine tree-sitter support strategy ... aborting!")))

;; pick a tree-sitter
(if (and (fboundp 'treesit-ready-p) (treesit-ready-p 'ql))
    ;; use the built-in tree-sitter
    (require 'ql-tree-sitter-builtin)
  ;; fall back to the external tree-sitter support
  (require 'ql-tree-sitter))

;;; codeql-mode aliases for ql-tree-sitter-mode

(defun codeql--alias-variable (alias base)
  "Make ALIAS a variable alias of BASE.
A value that ALIAS was given before this package loaded carries over to
BASE: hook functions are added to it, other values replace its value."
  (when (and (boundp base)
             (eq (indirect-variable alias) alias)
             (not (eq alias (indirect-variable base))))
    (let ((bound (boundp alias))
          (value (and (boundp alias) (symbol-value alias))))
      (when bound
        (makunbound alias))
      (defvaralias alias base)
      (when bound
        (if (string-suffix-p "-hook" (symbol-name alias))
            (dolist (fn (reverse (if (functionp value) (list value) value)))
              (unless (eq fn t)
                (add-hook base fn)))
          (set-default base value))))))

(defalias 'codeql-mode 'ql-tree-sitter-mode
  "Major mode for editing CodeQL files.
An alias for `ql-tree-sitter-mode'.")

;; make (derived-mode-p 'codeql-mode) hold in CodeQL buffers
(when (and (fboundp 'derived-mode-add-parents)
           (not (memq 'codeql-mode (get 'ql-tree-sitter-mode
                                        'derived-mode-extra-parents))))
  (derived-mode-add-parents 'ql-tree-sitter-mode
                            (cons 'codeql-mode
                                  (get 'ql-tree-sitter-mode
                                       'derived-mode-extra-parents))))

(dolist (pair '((codeql-mode-map . ql-tree-sitter-mode-map)
                (codeql-mode-hook . ql-tree-sitter-mode-hook)
                (codeql-mode-abbrev-table . ql-tree-sitter-mode-abbrev-table)
                (codeql-mode-syntax-table . ql-tree-sitter-mode-syntax-table)
                (codeql-mode-syntax-table . ql-tree-sitter-mode--syntax-table)
                (codeql-mode-indent-offset . ql-tree-sitter-mode-indent-offset)
                (codeql-mode-indent-offset . ql-tree-sitter-indent-offset)))
  (codeql--alias-variable (car pair) (cdr pair)))

;;; global user configuration options

(defgroup emacs-codeql nil
  "Emacs CodeQL support configuration."
  :prefix "emacs-codeql"
  :group 'emacs-codeql)

(defcustom codeql-ast-sync-highlighting t
  "Enable fancy AST viewer synchronized highlighting."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-query-server-timeout most-positive-fixnum
  "Query server compile/run timeout in seconds.

Normally we do not timeout, since queries can be long running.
Users may cancel queries instead through the transient UI."
  :type 'integer
  :group 'emacs-codeql)

(defcustom codeql-transient-binding "C-c C-d"
  "The keybinding to start the emacs-codeql transient UI."
  :type 'key-sequence
  :group 'emacs-codeql)

(defcustom codeql-enable-xrefs t
  "Enable CodeQL xref support for database source archives."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-highlight-visited-location 'pulse
  "How to highlight the location a result link points to when it is visited.

`pulse' briefly flashes the location, `region' leaves it marked as the
active region, with point at its start, and nil doesn't highlight it."
  :type '(choice (const :tag "Flash the location" pulse)
                 (const :tag "Mark the location as the region" region)
                 (const :tag "Don't highlight" nil))
  :group 'emacs-codeql)

(defcustom codeql-pulse-delay 0.3
  "Seconds to wait before pulsing a visited location.

The wait starts once the location's window has been displayed, and gives
you time to find that window before the pulse fades out."
  :type 'number
  :group 'emacs-codeql)

(defcustom codeql-pulse-duration 1.0
  "Seconds that the pulse on a visited location takes to fade out."
  :type 'number
  :group 'emacs-codeql)

(defcustom codeql-xref-resolve-on-visit nil
  "Whether to resolve xrefs as soon as a source archive file is visited.

When nil, the definitions and references of a database source archive file
are resolved by running a query the first time they are looked up, e.g.
with \\[xref-find-definitions], and cached from then on.  When non-nil,
both are resolved in the background whenever a file is opened from a
results buffer for the first time."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-xref-timeout 120
  "Seconds to wait for the definitions or references of a file to resolve."
  :type 'number
  :group 'emacs-codeql)

(defcustom codeql-share-query-server 'project
  "Which QL buffers share a query server and database.

When `project', the default, QL buffers of the same project, on the same
host and with the same CodeQL CLI, use one query server, active database
and query history, much like eglot manages one language server per
project.  A server started in one of them is used by all others,
including ones opened later.  A project is a version controlled
directory tree, or else a CodeQL pack.

When t, all QL buffers on the same host and with the same CodeQL CLI
share one query server, whatever their project.

When nil, every QL buffer has its own query server and database, and you
can share them on demand with `codeql-query-server-inherit'.

Use `codeql-query-servers' to list, restart and shut down the running
query servers."
  :type '(choice (const :tag "Per project" project)
                 (const :tag "Across projects" t)
                 (const :tag "Per buffer" nil))
  :group 'emacs-codeql)

(defcustom codeql-query-server-autoshutdown nil
  "Whether to shut down a query server when no QL buffer uses it anymore.

When nil, the default, a query server keeps running, with its database
and query history, after the last QL buffer that used it is killed, as
with `eglot-autoshutdown'.  QL buffers of its project that are opened
later use it again, see `codeql-share-query-server'.  Shut it down with
`codeql-query-servers' or `codeql-query-server-shutdown'.

When non-nil, the query server is shut down with the last QL buffer that
uses it."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-query-server-default-args '("--threads=0" "--quiet" "--log-to-stderr")
  "Arguments that `codeql-query-server-start' starts a query server with."
  :type '(repeat string)
  :group 'emacs-codeql)

(defcustom codeql-remote-server-ready-timeout 60
  "Seconds to wait for a remote query or CLI server process to start."
  :type 'number
  :group 'emacs-codeql)

(defcustom codeql-enable-remote-xrefs t
  "Enable CodeQL xref support for database source archives in remote sessions."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-configure-eglot-lsp t
  "Use eglot for LSP support by default.

emacs-codeql requires eglot 20220326.2143 or newer from MELPA."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-verbose-commands nil
  "Be verbose about which commands we're running at any given time."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-state-dir "~/.emacs-codeql"
  "Base directory for codeql emacs state maintenance.

It is important to keep this as a ~/relative path so that it will resolve both
in local and remote contexts to something that readily exists."
  :type 'directory
  :group 'emacs-codeql)

(defcustom codeql-database-history-file nil
  "The file that the databases registered in each project are kept in.

When nil, this is database-history.eld in `codeql-state-dir'.  The file
is always local, also for databases on remote hosts."
  :type '(choice (const :tag "In codeql-state-dir" nil) file)
  :group 'emacs-codeql)

(defcustom codeql-register-last-database t
  "Whether starting a query server registers the last database of the project.

The project is the one of the query buffer, see `codeql-database-history'."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-max-raw-results 200
  "The max amount of raw result tuples to render in an org-table.

Raw result sets that contain more tuples than this are paginated, with each
page holding at most this many tuples.  See `codeql-results-pagination-mode'."
  :type 'integer
  :group 'emacs-codeql)

(defcustom codeql-graph-format "svg"
  "The image format that graph results are rendered to with graphviz.

Results of queries with `@kind graph', e.g. those of
`codeql-view-cfg', are rendered by graphviz `dot' and shown in
`image-mode'.  When this is nil, or `dot' can't be found, the dot file
itself is opened instead."
  :type '(choice (const :tag "SVG" "svg")
                 (const :tag "PNG" "png")
                 (const :tag "Open the dot file" nil))
  :group 'emacs-codeql)

(defcustom codeql-max-sarif-results 100
  "The max amount of problem or path-problem results to render at once.

Queries that report more results than this are paginated, with each page
holding at most this many results.  See `codeql-results-pagination-mode'."
  :type 'integer
  :group 'emacs-codeql)

(defcustom codeql-raw-results-style 'table
  "How new results buffers show the rows of raw results.

`table' shows them as an org table, `outline' shows each row as an org
heading of its own, whose properties hold its row number, location and
the value of each column, see `codeql-results-org-ql'.  The rows of
problem and path-problem results are always headings.  Use
`codeql-results-toggle-raw-style' to switch a results buffer."
  :type '(choice (const :tag "Org table" table)
                 (const :tag "Org headings" outline))
  :group 'emacs-codeql)

(defcustom codeql-results-diagnostics nil
  "Whether new results buffers show their locations as Flymake diagnostics.

When non-nil, `codeql-results-diagnostics-mode' is enabled in the results
buffers of queries, so that the locations they link to are underlined in
the database source files."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-evaluator-log t
  "Whether to write a structured evaluator log for each query run.

The log is kept next to the results of the run, and is what
`codeql-query-performance' summarizes.  Only supported by query-server2."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-performance-max-predicates 300
  "The max amount of predicates to list in a query performance buffer.

The slowest predicates are listed first."
  :type 'integer
  :group 'emacs-codeql)

(defcustom codeql-results-page-cache-size 50
  "The max amount of rendered result pages to keep per results buffer.

Revisiting a cached page skips decoding and org rendering.  Each cached page
holds up to `codeql-max-raw-results' rendered rows, or
`codeql-max-sarif-results' rendered problem results.  Set to 0 to disable
caching."
  :type 'integer
  :group 'emacs-codeql)

(defcustom codeql-use-cli-server t
  "Whether to run CodeQL CLI commands through a persistent CLI server.

When non-nil, commands such as `codeql bqrs decode' are sent to a long-running
`codeql execute cli-server' process, which avoids the JVM startup cost of
spawning a new CLI process for every command.  One server is kept per CLI and
project directory, and it is started on demand."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-use-gh-codeql-extension-when-available t
  "If emacs-codeql detects the presence of a codeql enabled gh cli, use it.

Detection happens once per host, see `codeql-clear-cli-cache'.

See https://github.com/github/gh-codeql for more information."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-query-server-events-buffer-size 2000000
  "The scrollback size for query server event buffers."
  :type 'integer
  :group 'emacs-codeql)

;; globals that the user normally shouldn't have to touch, but may

(defvar codeql-cli (executable-find "codeql")
  "Path to codeql-cli")

(defvar codeql-search-paths '()
  "codeql cli library search paths that require search precedence.

This provides you with search path precedence control and should not be used for
standard search path configurations.")

(defvar-local codeql-query-server nil
  "Which query-server type to use.

This is automatically resolved for the buffer local context since we may be
operating multiple codeql environments, both local and remote, concurrently.

Don't confuse this for codeql--query-server, which represents the active
query server rpc connection.")

;; internal variables and configurations

(defvar codeql--run-query-always-save t
  "Whether you always want to save prior to query evaluation.

Evaluation requires a synced position in the query file on disk, such that the
query server can grab the right contents.

This applies to both normal evaluation and quick evaluation.")

(defvar codeql--query-server-max-ram nil
  "The max amount of RAM to use for query server evaluations.

Leave nil for default.")

;; we use buffer-local copies of these so we can play context dependent tricks
(defvar-local codeql--cli-buffer-local nil)
(defvar-local codeql--search-paths-buffer-local nil)
(defvar-local codeql--search-paths-pending nil
  "Non-nil while the library paths of the buffer are being resolved.")

(defun codeql--gh-codeql-cli-available-p ()
  (condition-case nil
      (eql 0 (with-temp-buffer
               (process-file "gh" nil `(,(current-buffer) nil) nil "codeql")))
    (error nil)))

(defvar codeql--cli-cache (make-hash-table :test #'equal)
  "The CodeQL CLI command of each host, see `codeql--cli-for-host'.")

(defun codeql-clear-cli-cache ()
  "Forget which CodeQL CLI command was picked for each host.

Use this after installing or removing the gh codeql extension, or the
CodeQL CLI of a remote host, so newly opened QL buffers pick again."
  (interactive)
  (clrhash codeql--cli-cache)
  (message "Cleared the CodeQL CLI cache."))

(defun codeql--cli-for-host ()
  "Return the CodeQL CLI command to use for `default-directory'.

Deciding involves running gh, and for remote hosts finding the CLI, so
the decision is cached per host, see `codeql-clear-cli-cache'."
  (let ((key (list (file-remote-p default-directory)
                   codeql-cli
                   codeql-use-gh-codeql-extension-when-available)))
    (or (gethash key codeql--cli-cache)
        (puthash key (codeql--cli-for-host-uncached) codeql--cli-cache))))

(defun codeql--cli-for-host-uncached ()
  "Return the CodeQL CLI command to use for `default-directory'."
  (cond
   ;; decide whether we want to use the gh cli to run our codeql commands
   ((and codeql-use-gh-codeql-extension-when-available
         (codeql--gh-codeql-cli-available-p))
    (message "Enabling gh cli codeql extension use.")
    (list (executable-find "gh" (file-remote-p default-directory)) "codeql"))
   ;; if we're in a remote context, make absolutely sure we know where the cli lives
   ((file-remote-p default-directory)
    (let ((remote-path
           (string-trim-right
            (or (executable-find "codeql" t)
                (expand-file-name
                 (read-file-name "Need remote path to codeql cli bin: "
                                 nil default-directory t))))))
      (message "Setting remote codeql cli path: %s" remote-path)
      (list (codeql--tramp-unwrap remote-path))))
   (t (list codeql-cli))))

(defun codeql--cli-buffer-local-as-string ()
  (mapconcat #'identity codeql--cli-buffer-local " "))

(defun codeql--search-paths-from-codeql-config ()
  "Grab search paths from the codeql cli configuration file."
  (let ((config-path "~/.config/codeql/config"))
    (when-let* ((config-file
                 (and (codeql--file-exists-p config-path)
                      (with-temp-buffer
                        (insert-file-contents
                         (codeql--tramp-wrap config-path))
                        (buffer-string))))
                (path-config
                 (when (string-match "^--search-path\\( +\\|=\\)\\(.*\\)" config-file)
                   (match-string 2 config-file))))
      (cl-loop with search-paths = (split-string path-config ":")
               for path in search-paths
               unless (codeql--file-exists-p path) do
               (error (format "Non-existing search path in configuration: %s" path))
               collect
               (let ((local-search-path
                      (codeql--tramp-unwrap
                       (expand-file-name (codeql--tramp-wrap path)))))
                 (message "Adding %s to search path from codeql cli config." local-search-path)
                 local-search-path)))))

(defun codeql--search-paths-from-emacs-config ()
  "Grab search paths from our emacs configuration."
  (cl-loop for path in codeql-search-paths
           unless (and path (codeql--file-exists-p path)) do
           (error (format "Non-existing search path in configuration: %s" path))
           collect (let ((local-search-path
                          (codeql--tramp-unwrap
                           (expand-file-name (codeql--tramp-wrap path)))))
                     (message "Adding %s to search path from emacs config." local-search-path)
                     local-search-path)))

(defun codeql--search-path ()
  "Return any currently configured codeql cli search paths."
  (mapconcat #'identity codeql--search-paths-buffer-local ":"))

;; project.el integration for eglot

(defun codeql--find-project-root (path)
  (or (locate-dominating-file path "qlpack.yml")
      (locate-dominating-file path "codeql-pack.yml")))

(defun project-codeql (dir)
  (let ((root (codeql--find-project-root dir)))
    (when root
      (list 'codeql root))))

(cl-defmethod project-root ((project (head codeql)))
  (nth 1 project))

(cl-defmethod project-external-roots ((project (head codeql)))
  codeql--search-paths-buffer-local)

(add-to-list 'project-find-functions #'project-codeql)

;; Eglot configuration

(when codeql-configure-eglot-lsp
  (require 'eglot)

  (defun codeql--lang-server-contact (_i)
    "Return the currently configured LSP server parameters."
    (cl-assert codeql--cli-buffer-local t)
    (let ((lsp-server-cmd
           (append codeql--cli-buffer-local
                   (list "execute" "language-server"
                         (format "--search-path=%s" (codeql--search-path))
                         "--check-errors" "ON_CHANGE"
                         "-q"))))
      (message "Using LSP server cmd: %s" lsp-server-cmd)
      lsp-server-cmd))

  ;; only configure eglot for codeql when we have the cli available in PATH
  (add-to-list 'eglot-server-programs
               `(ql-tree-sitter-mode . ,#'codeql--lang-server-contact))

  ;; hack to keep eglot project search spaces consistent on following xrefs
  (defvar codeql--eglot-override nil)

  (defun codeql-xref-location-marker (orig-fun &rest args)
    (cond ((eq major-mode 'ql-tree-sitter-mode)
           (let* ((codeql--eglot-override
                   (list default-directory
                         codeql--search-paths-buffer-local)))
             (apply orig-fun args)))
          (t (apply orig-fun args))))

  ;; this advice allows us to implement some special behavior when following
  ;; xrefs from the root of a codeql buffer
  (advice-add 'xref-location-marker :around #'codeql-xref-location-marker))

;; The language server watches **/*.{ql,qll,dbscheme}, which also matches
;; the lock file (.#Foo.ql) Emacs creates on the first change after a save.
;; Hearing about it makes the server drop the pending check of the edited
;; buffer, so the diagnostics of that edit never arrive and stale ones stay.

(declare-function eglot--major-modes "eglot")
(declare-function eglot-uri-to-path "eglot")

(defun codeql--lock-file-uri-p (uri)
  "Return non-nil if URI names an Emacs lock file.
Eglot resolves the lock file symlink, so URI can also be its dangling
target, which looks like USER@HOST.PID:BOOT-TIME."
  (let* ((path (eglot-uri-to-path uri))
         (name (file-name-nondirectory path)))
    (or (string-prefix-p ".#" name)
        (and (string-match-p "@.*\\.[0-9]+\\(?::[0-9]+\\)?\\'" name)
             (not (file-exists-p path))))))

(defun codeql--lsp-server-p (connection)
  "Return non-nil if CONNECTION is an eglot server for QL buffers."
  (and (featurep 'eglot)
       (object-of-class-p connection 'eglot-lsp-server)
       (memq 'ql-tree-sitter-mode
             (ignore-errors (eglot--major-modes connection)))))

(defun codeql--lsp-drop-lock-file-changes (orig-fun connection method
                                                    &optional params)
  "Keep lock file events out of watched file changes sent to QL servers."
  (if (and (eq method :workspace/didChangeWatchedFiles)
           (codeql--lsp-server-p connection))
      (let ((changes (seq-remove (lambda (change)
                                   (codeql--lock-file-uri-p (plist-get change :uri)))
                                 (plist-get params :changes))))
        (when changes
          (funcall orig-fun connection method
                   (plist-put (copy-sequence params) :changes (vconcat changes)))))
    (funcall orig-fun connection method params)))

(advice-add 'jsonrpc-notify :around #'codeql--lsp-drop-lock-file-changes)

(defun codeql--get-cli-version ()
  ;; used in setup for ql-tree-sitter-mode so we can not assert the mode here yet.
  (codeql--cli-command-to-string (list "version")))

(defvar codeql--inhibit-lsp nil
  "Non-nil to not start language servers for buffers set up meanwhile.")

(defvar-local codeql--lsp-inhibited nil
  "Non-nil if the buffer should not get a language server.")

(defun codeql--buffer-local-init-hook ()
  "Set up a codeql buffer context correctly."

  ;; remember this for when the search paths are resolved
  (setq codeql--lsp-inhibited codeql--inhibit-lsp)

  ;; decide between codeql-cli and the gh cli codeql extension
  (setq codeql--cli-buffer-local (copy-sequence (codeql--cli-for-host)))

  ;; ensure we have somewhere to store result data in both local and remote contexts
  (codeql--init-state-dirs)

  ;; ensure we were able to resolve _A_ path for the codeql cli local|remote execution
  (cl-assert codeql--cli-buffer-local t)

  ;; now that default-directory points where it should, resolve our search paths
  (if (and (boundp 'codeql--eglot-override) codeql--eglot-override)
      ;; this buffer is an xref follow from an already open project
      ;; so we just replicate the search path state of the existing project
      ;; which will prevent us from trying to start a bunch of different
      ;; language servers when navigating into xref'd qlpack roots
      (progn
        (message "Replicating search paths and project root from parent project.")
        (setq default-directory (car codeql--eglot-override))
        (setq codeql--search-paths-buffer-local (cadr codeql--eglot-override)))

    ;; this is the root of a new codeql project that we opened ourselves
    (setq default-directory
          (or (codeql--find-project-root (buffer-file-name))
              ;; if we can't find a project root, assume cwd is project root
              (file-name-directory (buffer-file-name))))

    (message "Resolving search paths from configuration.")
    (setq codeql--search-paths-buffer-local
          (append
           ;; emacs-codeql configs always have precedence
           (codeql--search-paths-from-emacs-config)
           ;; only add new paths that weren't already configured to prevent double-hits, this can be nil
           (cl-loop with config-paths = (codeql--search-paths-from-codeql-config)
                    for path in config-paths
                    unless (member path codeql-search-paths)
                    collect path)))

    (let ((query-path (codeql--tramp-unwrap
                       (expand-file-name
                        (codeql--tramp-wrap (buffer-file-name))))))
      (if (file-remote-p default-directory)
          (codeql--add-library-paths (codeql--resolve-library-paths query-path))
        ;; resolving takes a while, so let the buffer show up in the meantime
        (setq codeql--search-paths-pending t)
        (let ((buffer (current-buffer)))
          (codeql--cli-command-async
           (codeql--resolve-library-paths-args query-path)
           (lambda (json)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq codeql--search-paths-pending nil)
                 (codeql--add-library-paths (codeql--parse-library-paths json))
                 ;; out of the process filter, eglot may wait for the server
                 (run-at-time 0 nil #'codeql--lsp-start buffer t)))))))))

  ;; pick up a running query server of another QL buffer if we share them
  (codeql--query-server-adopt)

  (unless codeql--search-paths-pending
    (codeql--lsp-start (current-buffer))))

(defun codeql--add-library-paths (library-paths)
  "Add the vector LIBRARY-PATHS to the search paths of the buffer."
  ;; library paths should contain everything we need in terms of search paths
  (setq codeql--search-paths-buffer-local
        (append
         codeql--search-paths-buffer-local
         (cl-loop for library-path across library-paths
                  unless (member library-path codeql--search-paths-buffer-local)
                  collect library-path)))
  ;; dedupe and remove nil from search paths
  (setq codeql--search-paths-buffer-local
        (delq nil (delete-dups
                   codeql--search-paths-buffer-local))))

(defun codeql--await-search-paths ()
  "Wait until the search paths of the buffer are resolved."
  (let ((deadline (+ (float-time) 60)))
    (while (and codeql--search-paths-pending (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(declare-function eglot--guess-contact "eglot")
(declare-function eglot--connect "eglot")
(declare-function eglot--maybe-activate-editing-mode "eglot")
(declare-function eglot--project "eglot")
(declare-function eglot-lsp-server-p "eglot")
(defvar eglot--managed-mode)
(defvar eglot-sync-connect)

(defun codeql--lsp-start (buffer &optional now)
  "Start the language server of BUFFER, now that its search paths are known.

This relies on our project.el integration to determine the workspace paths.
With NOW, connect right away and without waiting for the server, instead of
after the current command."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and codeql-configure-eglot-lsp
                 (not codeql--lsp-inhibited)
                 (or (and (file-remote-p (buffer-file-name))
                          (yes-or-no-p "[WARNING] Do you want to use LSP remotely? This can be very slow!"))
                     (not (file-remote-p (buffer-file-name)))))
        ;; turn eglot on if local or we really want it remote
        (if now
            (codeql--lsp-connect nil)
          (add-hook 'post-command-hook #'codeql--lsp-connect-after-command
                    'append t))))))

(defun codeql--lsp-connect-after-command ()
  "Connect the buffer to its language server, the way `eglot-ensure' does."
  (remove-hook 'post-command-hook #'codeql--lsp-connect-after-command t)
  (codeql--lsp-connect eglot-sync-connect))

(defun codeql--lsp-server-process-p (process modes project)
  "Return non-nil if PROCESS is a live eglot server for MODES in PROJECT.
This includes servers that are still initializing, which eglot only
registers for their project once they are up."
  (let ((server (process-get process 'jsonrpc-connection)))
    (and (process-live-p process)
         (eglot-lsp-server-p server)
         (equal (eglot--project server) project)
         (cl-intersection (eglot--major-modes server) modes))))

(defun codeql--lsp-connect (sync)
  "Connect the buffer to a language server, unless one is already on its way.
SYNC is used as `eglot-sync-connect'."
  (condition-case nil
      (progn
        ;; join a running server of the project
        (eglot--maybe-activate-editing-mode)
        (unless eglot--managed-mode
          (let ((contact (eglot--guess-contact)))
            ;; a starting server picks up all of its buffers once it is up
            (unless (cl-loop for process in (process-list)
                             thereis (codeql--lsp-server-process-p
                                      process (nth 0 contact) (nth 1 contact)))
              (let ((eglot-sync-connect sync))
                (apply #'eglot--connect contact))))))
    ;; no LSP for us due to error
    (error (message "Ignoring failed LSP initialization and plowing ahead!"))))

(defun codeql--eglot-ensure-skip-p ()
  "Return non-nil if `eglot-ensure' should leave the buffer to us.
We start the language server of CodeQL buffers ourselves once their
search paths are known, so an `eglot-ensure' from the major mode hook
would start a server without them, or a second one."
  (or codeql--inhibit-lsp
      codeql--lsp-inhibited
      (and codeql-configure-eglot-lsp
           buffer-file-name
           (derived-mode-p 'ql-tree-sitter-mode))))

(advice-add 'eglot-ensure :before-until #'codeql--eglot-ensure-skip-p)

(defun codeql--lsp-inhibited-p ()
  "Return non-nil if the buffer must not be managed by a language server.
Eglot manages the buffers of a project whose server is running, as they
are set up and once a server is up, see `codeql--inhibit-lsp'."
  codeql--lsp-inhibited)

(advice-add 'eglot--maybe-activate-editing-mode :before-until #'codeql--lsp-inhibited-p)

(defun codeql--maybe-buffer-local-init ()
  "Run `codeql--buffer-local-init-hook' in buffers that visit a file.
Other buffers in CodeQL mode, such as those org uses to fontify and
edit source blocks, only get the major mode."
  (when (buffer-file-name)
    (codeql--buffer-local-init-hook)))

;; add a hook that sets up all the things we need to be available in the buffer-local context
(remove-hook 'ql-tree-sitter-mode-hook #'codeql--buffer-local-init-hook)
(add-hook 'ql-tree-sitter-mode-hook #'codeql--maybe-buffer-local-init)

;; #+begin_src codeql finds codeql-mode by name, ql needs a mapping
(with-eval-after-load 'org-src
  (add-to-list 'org-src-lang-modes '("ql" . codeql)))

;; backup formatting utilities for when ql-tree-sitter is not available
(defun codeql-format (&optional min max)
  "Format a QL region, use when ql-tree-sitter + agressive-indent is not available."
  (interactive)
  (shell-command-on-region
   (or min (point-min))
   (or max (point-max))
   (format "%s query format --no-syntax-errors -- -"
           (codeql--cli-buffer-local-as-string))
   t t))

(defun codeql-format-region (min max)
  "Format the current CodeQL region if active, or entire buffer if not."
  (interactive "r")
  (codeql-format min max))

;;; storage / persistence

(defvar codeql-results-dir (concat codeql-state-dir "/results"))
(defvar codeql-tmp-dir (concat codeql-state-dir "/tmp"))

;; Eglot lsp-to-point routines that deal with utf-16 code points
;;
;; START LICENSING: https://github.com/joaotavora/eglot/blob/master/LICENSE

;;; deal with utf-16 code points for column calculations, modified from eglot
(defun codeql--lsp-abiding-column ()
  "Calculate current COLUMN as defined by the LSP spec."
  ;; codeql query server uses 1-based column values and utf-16 code points
  (/ (length
      (encode-coding-region
       (line-beginning-position)
       (min (point) (point-max)) 'utf-16 t))
     2))

;; note: this isn't the same as codeql-lsp-abiding column which is 1-based
(defun codeql--eglot-lsp-abiding-column (&optional lbp)
  "Calculate current COLUMN as defined by the LSP spec.
LBP defaults to `line-beginning-position'."
  (/ (- (length
         (encode-coding-region
          (or lbp (line-beginning-position))
          ;; Fix github#860
          (min (point) (point-max)) 'utf-16 t))
        2)
     2))

(cl-defmacro codeql--eglot--widening (&rest body)
  "Save excursion and restriction.  Widen.  Then run BODY." (declare (debug t))
  `(save-excursion (save-restriction (widen) ,@body)))

(defun codeql--eglot-move-to-lsp-abiding-column (column)
  "Move to COLUMN abiding by the LSP spec."
  (save-restriction
    (cl-loop
     with lbp = (line-beginning-position)
     initially
     (narrow-to-region lbp (line-end-position))
     (move-to-column column)
     for diff = (- column
                   (codeql--eglot-lsp-abiding-column lbp))
     until (zerop diff)
     do (condition-case eob-err
            (forward-char (/ (if (> diff 0) (1+ diff) (1- diff)) 2))
          (end-of-buffer (cl-return eob-err))))))

(defun codeql--eglot--lsp-position-to-point (pos-plist &optional marker)
  "Convert LSP position POS-PLIST to Emacs point.
If optional MARKER, return a marker instead"
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (min most-positive-fixnum
                         (plist-get pos-plist :line)))
      (unless (eobp) ;; if line was excessive leave point at eob
        (let ((tab-width 1)
              (col (plist-get pos-plist :character)))
          (unless (wholenump col)
            (message "Caution: LSP server sent invalid character position %s. Using 0 instead."
                     col)
            (setq col 0))
          (codeql--eglot-move-to-lsp-abiding-column col)))
      (if marker (copy-marker (point-marker)) (point)))))

;; END LICENSING: https://github.com/joaotavora/eglot/blob/master/LICENSE

;; Helper functions to deal with tramp contexts

(defun codeql--tramp-wrap (file)
  "Wrap a tramp prefix onto file if in a remote context (if needed)."
  (cond ((file-remote-p file)
         file)
        ((file-remote-p default-directory)
         (let* ((v (tramp-dissect-file-name default-directory))
                (method (tramp-file-name-method v))
                (user (tramp-file-name-user v))
                (host (tramp-file-name-host v)))
           (format "/%s:%s%s:%s"
                   method
                   (if user (format "%s@" user) "")
                   host
                   file)))
        (t
         file)))

(defun codeql--tramp-unwrap (file)
  "Strip the tramp prefix from a file if it's a remote file."
  (cond
   ((file-remote-p file)
    (file-local-name file))
   (t
    file)))

(defun codeql--file-truename (file)
  (if (file-remote-p default-directory)
      (codeql--tramp-unwrap file)
    (file-truename file)))

(defun codeql--file-exists-p (file)
  (if (file-remote-p default-directory)
      (file-exists-p (codeql--tramp-wrap file))
    (file-exists-p (codeql--tramp-unwrap file))))

(defun codeql--init-state-dirs ()
  "Create our various storage directories if they do not exist yet."
  (mapcar (lambda (path)
            (unless (codeql--file-exists-p path)
              (mkdir (codeql--tramp-wrap path) t)))
          (list codeql-state-dir
                codeql-results-dir
                codeql-tmp-dir)))

(defun codeql-clear-state-dirs (clear-dirs)
  "Clear out storage directories."
  (interactive (list
                (yes-or-no-p
                 (format "Clear out %s and %s?"
                         codeql-results-dir
                         codeql-tmp-dir))))
  (when (and clear-dirs
             (codeql--file-exists-p codeql-results-dir)
             (codeql--file-exists-p codeql-tmp-dir))
    (when (not (directory-empty-p codeql-results-dir))
      (cl-assert (= 0 (shell-command (format  "rm -v %s/*" codeql-results-dir))) t))
    (when (not (directory-empty-p codeql-tmp-dir))
      (cl-assert (= 0 (shell-command (format "rm -v %s/*" codeql-tmp-dir)))))))

;;; Request and notification handling

(cl-defgeneric codeql--query-server-handle-request (_server method &rest params)
  "Handle SERVER's METHOD request with PARAMS."
  (message "handle request: %s %s" method params))

(cl-defgeneric codeql--query-server-handle-notification (_server _method &rest _params)
  "Handle SERVER's METHOD notification with PARAMS."
  (message "handle notification"))

(cl-defmethod codeql--query-server-handle-notification
  (_server (method (eql ql/progressUpdated)) &rest params)
  "Handle SERVER's ql/progressUpdated notification with PARAMS."
  ;;(message "%s %s" method params)
  (cl-destructuring-bind ((&key step maxStep message &allow-other-keys)) params
    (unless (string= message "")
      (message "[%s] step %s/%s -> %s" method step maxStep message))))

(cl-defmethod codeql--query-server-handle-request
  (_server (method (eql evaluation/queryCompleted)) &rest params)
  "Handle SERVER's evaluation/queryCompleted request with PARAMS."
  ;;(message "%s %s" method params)
  (cl-destructuring-bind ((&key
                           resultType
                           queryId
                           evaluationTime
                           message
                           &allow-other-keys))
      params
    (message "[%s] resultType %s evaluationTime %s"
             method resultType evaluationTime)
    (cond ((eql resultType 0)
           '())
          ((eql resultType 1)
           ;; oh the joys of function binding vs variable binding :P
           (if message
               (message message)
             (message "ERROR: Other")))
          ((eql resultType 2)
           (if message
               (message message)
             (message "ERROR: OOM")))
          ((eql resultType 3)
           (if message
               (message message)
             (message "ERROR: Timeout")))
          ((eql resultType 4)
           (if message
               (message message)
             (message "ERROR: Query was canceled"))))))

(defun codeql--query-server2-handle-message (&rest params)
  "Handle SERVER's message from PARAMS."
  (cl-destructuring-bind ((&key
                           resultType
                           queryId
                           evaluationTime
                           message
                           &allow-other-keys))
      params
    (cond ((eql resultType 0)
           '())
          ((eql resultType 1)
           ;; oh the joys of function binding vs variable binding :P
           (if message
               (message message)
             (message "ERROR: Other")))
          ((eql resultType 2)
           (if message
               (message message)
             (message "ERROR: Compilation")))
          ((eql resultType 3)
           (if message
               (message message)
             (message "ERROR: OOM")))
          ((eql resultType 4)
           (if message
               (message message)
             (message "ERROR: Query Canceled")))
          ((eql resultType 5)
           (if message
               (message message)
             (message "ERROR: DB Scheme mismatch")))
          ((eql resultType 6)
           (if message
               (message message)
             (message "ERROR: DB Scheme no upgrade found"))))))

;;; emacs-wide state tracking variables and functions

(defvar codeql--database-history 'unloaded
  "The databases registered in each project, see `codeql-database-history'.

A list of plists with the :path, :project and :language of a database, and
the :added and :used times of when it was first and last registered in
the project, most recently used first.  It is read from
`codeql-database-history-file' on first use.")

;; global caches for database source archive files defs/refs/ast
(defvar codeql--definitions-cache (make-hash-table :test #'equal))
(defvar codeql--references-cache (make-hash-table :test #'equal))
(defvar codeql--ast-cache (make-hash-table :test #'equal))

(defvar codeql--xref-pending (make-hash-table :test #'equal)
  "The (FILE . QUERY-NAME) keys of the xref queries that are running.")

(defvar codeql--ast-backwards-definitions (make-hash-table :test #'equal)
  "A hash table of src-filename -> ast-table.

Provides backwards references into the AST buffer from the source file.")

(defun codeql-clear-refs-defs-ast-cache ()
  "Clear global refs/defs/ast caches in case you need a clean slate."
  (interactive)
  (setq codeql--ast-backwards-definitions (make-hash-table :test #'equal))
  (setq codeql--definitions-cache (make-hash-table :test #'equal))
  (setq codeql--references-cache (make-hash-table :test #'equal))
  (setq codeql--ast-cache (make-hash-table :test #'equal))
  (setq codeql--xref-pending (make-hash-table :test #'equal))
  (message "Cleared refs/defs/ast caches."))

;; (defvar codeql--active-source-roots-with-buffers nil
;;   "A hash table of currently active archive source roots and their query buffers.")

(defvar codeql--active-datasets nil
  "A hash table of all registered databases across all sessions.")

(defun codeql--active-datasets-init ()
  (setq codeql--active-datasets (make-hash-table :test #'equal)))

(defun codeql--active-datasets-add (database-dataset buffer)
  (puthash database-dataset buffer codeql--active-datasets))

(defun codeql--active-datasets-del (database-dataset)
  (remhash database-dataset codeql--active-datasets))

(defun codeql--active-datasets-get (database-dataset)
  (gethash database-dataset codeql--active-datasets))

(codeql--active-datasets-init)

;;; buffer-local state tracking variables and functions

;; query server config state
(defvar-local codeql--path-problem-max-paths 10)

;; local connection state
(defvar-local codeql--query-server nil
  "CodeQL query server rpc connection.")

;; local database state
(defvar-local codeql--active-database nil)
(defvar-local codeql--active-database-language nil)
(defvar-local codeql--database-dataset-folder nil)
(defvar-local codeql--database-source-location-prefix nil)
(defvar-local codeql--database-source-archive-zip nil)
(defvar-local codeql--database-source-archive-root nil)
(defvar-local codeql--library-path nil)
(defvar-local codeql--dbscheme nil)

;; this expects to run inside a query buffer-local context
(defun codeql--reset-database-state ()
  "Clear out all the buffer-local database state."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode))
  (setq codeql--active-database nil)
  (setq codeql--active-database-language nil)
  (setq codeql--database-dataset-folder nil)
  (setq codeql--database-source-location-prefix nil)
  (setq codeql--database-source-archive-root nil)
  (setq codeql--database-source-archive-zip nil))

;; local query id state
(defvar-local codeql--query-server-client-id 0)
(defvar-local codeql--query-server-progress-id 0)
(defvar-local codeql--query-server-evaluate-id 0)

;; local query history
(defvar-local codeql--completed-query-history nil)

(defvar codeql--shared-state-variables
  '(codeql--query-server
    codeql-query-server
    codeql--active-database
    codeql--active-database-language
    codeql--database-dataset-folder
    codeql--database-source-location-prefix
    codeql--database-source-archive-zip
    codeql--database-source-archive-root
    codeql--completed-query-history)
  "Buffer-local state that QL buffers sharing a query server have in common.")

(defun codeql--ql-buffers ()
  "Return all live QL buffers."
  (seq-filter (lambda (buffer)
                (eq (buffer-local-value 'major-mode buffer) 'ql-tree-sitter-mode))
              (buffer-list)))

(defun codeql--query-server-buffers (server &optional except)
  "Return the QL buffers that use query SERVER connection, other than EXCEPT."
  (and server
       (seq-filter (lambda (buffer)
                     (and (not (eq buffer except))
                          (eq (buffer-local-value 'codeql--query-server buffer) server)))
                   (codeql--ql-buffers))))

(defun codeql--query-server-host-key ()
  "Return what QL buffers need in common to use the same query server at all."
  (list (file-remote-p default-directory) codeql--cli-buffer-local))

(defun codeql--query-server-project ()
  "Return the project that the query server of the current buffer belongs to."
  (codeql--database-history-project))

(defun codeql--query-server-share-key ()
  "Return what QL buffers need in common to share a query server automatically.

This depends on `codeql-share-query-server'."
  (append (codeql--query-server-host-key)
          (when (eq codeql-share-query-server 'project)
            (list (codeql--query-server-project)))))

(defvar codeql--query-servers (make-hash-table :test #'eq)
  "The running query server connections, and what they were started with.

The values are plists with :project, :remote, :args and :started.")

(defun codeql--query-server-copy-state (source)
  "Copy the shared query server state of buffer SOURCE to the current buffer."
  (dolist (variable codeql--shared-state-variables)
    (set (make-local-variable variable) (buffer-local-value variable source))))

(defun codeql--query-server-sync-state ()
  "Copy the shared state of the current buffer to the buffers sharing its server."
  (let ((source (current-buffer)))
    (dolist (buffer (codeql--query-server-buffers codeql--query-server source))
      (with-current-buffer buffer
        (codeql--query-server-copy-state source)))))

(defun codeql--query-server-share ()
  "Share the current buffer's query server with QL buffers that have none.

Only applies when `codeql-share-query-server' is non-nil."
  (when (and codeql-share-query-server codeql--query-server)
    (let ((source (current-buffer))
          (key (codeql--query-server-share-key)))
      (dolist (buffer (codeql--ql-buffers))
        (with-current-buffer buffer
          (when (and (not codeql--query-server)
                     (equal (codeql--query-server-share-key) key))
            (codeql--query-server-copy-state source)))))))

(defun codeql--query-server-adopt ()
  "Use the query server of another QL buffer, if `codeql-share-query-server'."
  (unless codeql--query-server
    (when-let ((source (codeql--query-server-shareable)))
      (codeql--query-server-copy-state source)
      (codeql--query-server-kill-holders codeql--query-server)
      (message "Using the query server of %s." (buffer-name source)))))

(defun codeql-query-server-inherit (buffer)
  "Use the query server, database and query history of QL BUFFER."
  (interactive
   (progn
     (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
     (when codeql--query-server
       (user-error "This buffer already has a query server, stop it first"))
     (let* ((key (codeql--query-server-host-key))
            (candidates
             (mapcar #'buffer-name
                     (seq-filter (lambda (buffer)
                                   (and (not (eq buffer (current-buffer)))
                                        (buffer-local-value 'codeql--query-server buffer)
                                        (equal (with-current-buffer buffer
                                                 (codeql--query-server-host-key))
                                               key)))
                                 (codeql--ql-buffers)))))
       (unless candidates
         (user-error "No other QL buffer on this host has a query server"))
       (list (get-buffer (completing-read "Inherit query server from: "
                                          (delete-dups candidates) nil t))))))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (with-current-buffer buffer
    ;; share query history from now on
    (unless codeql--completed-query-history
      (setq codeql--completed-query-history (make-hash-table :test #'equal))
      (codeql--query-server-sync-state)))
  (codeql--query-server-copy-state buffer)
  (message "Using the query server of %s." (buffer-name buffer))
  (codeql--query-server-kill-holders codeql--query-server))

(defvar codeql--query-server-restarting nil
  "Non-nil while a query server is restarted, to keep its hidden buffer.")

(defun codeql--query-server-on-shutdown (obj buffer-context)
  "Clear the server and database state of the buffers that used server OBJ."
  (remhash obj codeql--query-servers)
  (let ((buffers (codeql--query-server-buffers obj)))
    (when (and (buffer-live-p buffer-context) (not (memq buffer-context buffers)))
      (push buffer-context buffers))
    (dolist (buffer buffers)
      (with-current-buffer buffer
        ;; remove any active database from global database state
        (when codeql--database-dataset-folder
          (codeql--active-datasets-del codeql--database-dataset-folder))
        ;; clear out the buffer-local server and database state
        (setq codeql--query-server nil)
        (codeql--reset-database-state)))
    (unless codeql--query-server-restarting
      (dolist (buffer buffers)
        (when (and (buffer-live-p buffer)
                   (buffer-local-value 'codeql--query-server-holder buffer))
          (kill-buffer buffer))))
    (message "Shut down query server and cleared active database.")))

(defvar-local codeql--query-server-holder nil
  "Non-nil in the hidden buffer that keeps a query server without QL buffers.")

(defun codeql--query-server-user-buffers (server &optional except)
  "Return the QL buffers that use query SERVER, other than EXCEPT and hidden ones."
  (seq-remove (lambda (buffer) (buffer-local-value 'codeql--query-server-holder buffer))
              (codeql--query-server-buffers server except)))

(defun codeql--query-server-hand-over (buffer)
  "Make BUFFER the owner of the active database of the current buffer."
  (when (and codeql--database-dataset-folder
             (eq (codeql--active-datasets-get codeql--database-dataset-folder)
                 (current-buffer)))
    (codeql--active-datasets-add codeql--database-dataset-folder buffer)))

(defun codeql--query-server-detach ()
  "Keep the query server of the current buffer running in a hidden buffer.

The hidden buffer keeps the database and query history of the server,
so that QL buffers can use the server again later."
  (let* ((source (current-buffer))
         (server codeql--query-server)
         (holder (generate-new-buffer (format " *%s*" (jsonrpc-name server)))))
    (with-current-buffer holder
      (setq default-directory (buffer-local-value 'default-directory source))
      (setq major-mode 'ql-tree-sitter-mode)
      (setq codeql--query-server-holder t)
      (dolist (variable '(codeql--cli-buffer-local
                          codeql--search-paths-buffer-local
                          codeql--path-problem-max-paths))
        (set (make-local-variable variable) (buffer-local-value variable source)))
      (codeql--query-server-copy-state source))
    (codeql--query-server-hand-over holder)
    (setq codeql--query-server nil)
    (codeql--reset-database-state)
    (message "%s keeps running, shut it down with `codeql-query-servers'."
             (jsonrpc-name server))))

(defun codeql--query-server-kill-holders (server)
  "Kill the hidden buffers that kept query SERVER, now that a QL buffer uses it."
  (dolist (buffer (codeql--query-server-buffers server))
    (when (buffer-local-value 'codeql--query-server-holder buffer)
      (kill-buffer buffer))))

(defun codeql--query-server-release ()
  "Detach the current buffer from its query server.

When no other QL buffer uses the server, it is shut down if
`codeql-query-server-autoshutdown' is non-nil, and kept running otherwise."
  (when codeql--query-server
    (let* ((others (codeql--query-server-buffers codeql--query-server (current-buffer)))
           (users (seq-remove (lambda (buffer)
                                (buffer-local-value 'codeql--query-server-holder buffer))
                              others)))
      (cond
       ;; hand the database over to a buffer that keeps using it
       ((or users (and others (not codeql-query-server-autoshutdown)))
        (codeql--query-server-hand-over (car (or users others)))
        (setq codeql--query-server nil)
        (codeql--reset-database-state))
       ((or codeql-query-server-autoshutdown codeql--query-server-holder)
        (jsonrpc-shutdown codeql--query-server))
       (t
        (codeql--query-server-detach))))))

(defun codeql--query-server-next-client-id ()
  (setq codeql--query-server-client-id
        (1+ codeql--query-server-client-id))
  codeql--query-server-client-id)

(defun codeql--query-server-next-progress-id ()
  (setq codeql--query-server-progress-id
        (1+ codeql--query-server-progress-id))
  codeql--query-server-progress-id)

(defun codeql--query-server-next-evaluate-id ()
  (setq codeql--query-server-evaluate-id
        (1+ codeql--query-server-evaluate-id))
  codeql--query-server-evaluate-id)

(defun codeql--query-server-current-or-error ()
  "Check that we have an active CodeQL query server connection, or error."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (or codeql--query-server
      (jsonrpc-error "No active JSON-RPC connection.")))

;;; utility functions for running queries

(defun codeql--shell-command-to-string (cmd &optional verbose keep-stdout)
  "A shell command to string that gives us explicit control over stdout and stderr."
  (when (or verbose codeql-verbose-commands)
    (message "Running %s cmd: %s"
             (if (file-remote-p default-directory)
                 "remote" "local")
             cmd))
  (condition-case nil
      (with-temp-buffer
        (let* ((stdout-buffer (generate-new-buffer (format "* stdout: %s *" cmd)))
               ;; process-file will work in remote context pending default-directory
               (exit-code
                (apply 'process-file
                       ;; rely on something that's ALWAYS there (hopefully)
                       "/bin/sh"
                       nil
                       ;; redirect stderr here somewhere if we need to
                       `(,stdout-buffer nil)
                       nil
                       "-c"
                       (list cmd)))
               (stdout-data
                (when (eql exit-code 0)
                  (with-current-buffer stdout-buffer (buffer-string)))))
          (unless keep-stdout
            (kill-buffer stdout-buffer))
          ;; return stdout or signal error
          (if stdout-data stdout-data (error "failed to execute cmd"))))
    (error (progn (message "Error in codeql--shell-command-to-string: %s" cmd) nil))))

;;; persistent cli server

(defvar codeql--cli-servers (make-hash-table :test #'equal)
  "Running CLI server processes, keyed by CLI command and `default-directory'.")

(defun codeql--cli-server-key ()
  (list codeql--cli-buffer-local default-directory))

(defun codeql--cli-server-live-p (proc)
  (and proc (process-live-p proc)))

(defun codeql--cli-server-start ()
  "Start a CLI server for the current buffer context and return its process."
  (let* ((name (format "CODEQL CLI Server (%s%s)"
                       (or (file-remote-p default-directory) "")
                       (file-name-base (directory-file-name default-directory))))
         (cmd (codeql--query-server-cmd
               (append codeql--cli-buffer-local (list "execute" "cli-server"))))
         (stdout (generate-new-buffer (format " *%s*" name)))
         (stderr (generate-new-buffer (format " *%s stderr*" name))))
    (when codeql-verbose-commands
      (message "Starting CLI server with: %s" cmd))
    (let ((proc (codeql--make-server-process
                 'utf-8-unix
                 :name name
                 :buffer stdout
                 :command cmd
                 :connection-type 'pipe
                 :noquery t
                 :stderr stderr
                 :sentinel #'ignore)))
      (process-put proc 'codeql-stderr stderr)
      (when-let ((stderr-proc (get-buffer-process stderr)))
        (set-process-sentinel stderr-proc #'ignore))
      proc)))

(defun codeql--cli-server-kill (proc)
  "Shut down and clean up CLI server PROC."
  (when proc
    (when (process-live-p proc)
      (ignore-errors
        (process-send-string proc (concat (json-serialize ["shutdown"]) "\0")))
      (delete-process proc))
    (let ((stderr (process-get proc 'codeql-stderr)))
      (dolist (buffer (list (process-buffer proc) stderr))
        (when (buffer-live-p buffer)
          (let ((stderr-proc (get-buffer-process buffer)))
            (when stderr-proc (delete-process stderr-proc)))
          (kill-buffer buffer))))))

(defun codeql--cli-server ()
  "Return a live CLI server for the current buffer context, starting one if needed."
  (let* ((key (codeql--cli-server-key))
         (proc (gethash key codeql--cli-servers)))
    (unless (codeql--cli-server-live-p proc)
      (codeql--cli-server-kill proc)
      (setq proc (codeql--cli-server-start))
      (puthash key proc codeql--cli-servers))
    proc))

(defun codeql--cli-server-command-complete-p (proc)
  (with-current-buffer (process-buffer proc)
    (and (> (buffer-size) 0) (eq (char-before (point-max)) 0))))

(defun codeql--cli-server-run (args)
  "Run CLI ARGS on the CLI server and return stdout, or nil on failure.

The server exits when a command fails, in which case it is restarted on the
next command."
  (let ((proc (codeql--cli-server))
        (done nil))
    (process-put proc 'codeql-busy t)
    (unwind-protect
        (progn
          (with-current-buffer (process-buffer proc) (erase-buffer))
          (with-current-buffer (process-get proc 'codeql-stderr) (erase-buffer))
          (process-send-string
           proc (concat (encode-coding-string (json-serialize (vconcat args)) 'utf-8)
                        "\0"))
          (while (and (not (setq done (codeql--cli-server-command-complete-p proc)))
                      (process-live-p proc))
            (accept-process-output proc 0.05 nil t))
          ;; pick up any output that arrived together with the exit
          (unless done
            (setq done (codeql--cli-server-command-complete-p proc)))
          (if done
              (with-current-buffer (process-buffer proc)
                (buffer-substring-no-properties (point-min) (1- (point-max))))
            (let* ((stderr (process-get proc 'codeql-stderr))
                   (stderr-proc (get-buffer-process stderr)))
              ;; drain the error message, the server exits before it's read
              (while (and stderr-proc (process-live-p stderr-proc)
                          (accept-process-output stderr-proc 0.1 nil t)))
              (message "CLI server command failed: %s"
                       (with-current-buffer stderr (string-trim (buffer-string)))))
            nil))
      (process-put proc 'codeql-busy nil)
      ;; a command that didn't complete leaves the server in an unknown state
      (unless done
        (codeql--cli-server-kill proc)
        (remhash (codeql--cli-server-key) codeql--cli-servers)))))

(defun codeql--cli-command-to-string (args &optional verbose)
  "Run the buffer-local CodeQL CLI with ARGS and return stdout, or nil on failure.

Uses a persistent CLI server when `codeql-use-cli-server' is non-nil."
  (cl-assert codeql--cli-buffer-local t)
  (let ((proc (gethash (codeql--cli-server-key) codeql--cli-servers)))
    (if (and codeql-use-cli-server
             ;; fall back to a new process for commands issued while the server
             ;; is busy, e.g. from a process filter or timer
             (not (and (codeql--cli-server-live-p proc)
                       (process-get proc 'codeql-busy))))
        (progn
          (when (or verbose codeql-verbose-commands)
            (message "Running %s cli server cmd: %s"
                     (if (file-remote-p default-directory) "remote" "local")
                     (string-join args " ")))
          (codeql--cli-server-run args))
      (codeql--shell-command-to-string
       (mapconcat #'shell-quote-argument (append codeql--cli-buffer-local args) " ")
       verbose))))

;; Run a CLI command without blocking

(defun codeql--cli-server-run-async (args callback)
  "Run CLI ARGS on the CLI server and call CALLBACK with stdout, or nil on failure.

Like `codeql--cli-server-run', but returns right away.  The server is busy
until CALLBACK is called, so other commands meanwhile get processes of
their own."
  (let* ((key (codeql--cli-server-key))
         (proc (codeql--cli-server))
         (stdout (process-buffer proc))
         (stderr (process-get proc 'codeql-stderr))
         (finished nil)
         (finish
          (lambda (output)
            (unless finished
              (setq finished t)
              (set-process-filter proc #'internal-default-process-filter)
              (set-process-sentinel proc #'ignore)
              (process-put proc 'codeql-busy nil)
              (funcall callback output)))))
    (process-put proc 'codeql-busy t)
    (with-current-buffer stdout (erase-buffer))
    (with-current-buffer stderr (erase-buffer))
    (set-process-filter
     proc (lambda (proc string)
            (internal-default-process-filter proc string)
            (when (codeql--cli-server-command-complete-p proc)
              (funcall finish (with-current-buffer stdout
                                (buffer-substring-no-properties
                                 (point-min) (1- (point-max))))))))
    ;; the server exits when a command fails
    (set-process-sentinel
     proc (lambda (proc _event)
            (unless (or finished (process-live-p proc))
              (let ((output (and (buffer-live-p stdout)
                                 (codeql--cli-server-command-complete-p proc)
                                 (with-current-buffer stdout
                                   (buffer-substring-no-properties
                                    (point-min) (1- (point-max)))))))
                (unless output
                  (message "CLI server command failed: %s"
                           (if (buffer-live-p stderr)
                               (with-current-buffer stderr (string-trim (buffer-string)))
                             "")))
                (codeql--cli-server-kill proc)
                (when (eq (gethash key codeql--cli-servers) proc)
                  (remhash key codeql--cli-servers))
                (funcall finish output)))))
    (condition-case err
        (process-send-string
         proc (concat (encode-coding-string (json-serialize (vconcat args)) 'utf-8)
                      "\0"))
      (error
       (message "CLI server command failed: %s" (error-message-string err))
       (codeql--cli-server-kill proc)
       (remhash key codeql--cli-servers)
       (funcall finish nil)))))

(defun codeql--cli-process-run-async (args callback)
  "Run CLI ARGS in a new process and call CALLBACK with stdout, or nil on failure."
  (let* ((command (append codeql--cli-buffer-local args))
         (stdout (generate-new-buffer " *codeql cli*"))
         (stderr (generate-new-buffer " *codeql cli stderr*")))
    (when codeql-verbose-commands
      (message "Running async cli cmd: %s" (string-join command " ")))
    (condition-case err
        (make-process
         :name "codeql cli"
         :buffer stdout
         :stderr stderr
         :command command
         :connection-type 'pipe
         :noquery t
         :file-handler t
         :sentinel
         (lambda (proc _event)
           (unless (process-live-p proc)
             (let ((output (and (eq (process-status proc) 'exit)
                                (zerop (process-exit-status proc))
                                (with-current-buffer stdout
                                  (buffer-substring-no-properties
                                   (point-min) (point-max))))))
               (unless output
                 (message "CLI command failed: %s"
                          (with-current-buffer stderr (string-trim (buffer-string)))))
               (when-let ((stderr-proc (get-buffer-process stderr)))
                 (delete-process stderr-proc))
               (kill-buffer stdout)
               (kill-buffer stderr)
               (funcall callback output)))))
      (error
       (message "CLI command failed: %s" (error-message-string err))
       (kill-buffer stdout)
       (kill-buffer stderr)
       (funcall callback nil)))))

(defun codeql--cli-command-async (args callback)
  "Run the buffer-local CodeQL CLI with ARGS without blocking.

CALLBACK is called with stdout, or nil on failure, from a process filter or
sentinel, so it can't rely on the current buffer.  Uses a persistent CLI
server when `codeql-use-cli-server' is non-nil and it isn't busy."
  (cl-assert codeql--cli-buffer-local t)
  (let ((proc (gethash (codeql--cli-server-key) codeql--cli-servers)))
    (when codeql-verbose-commands
      (message "Running async cli cmd: %s" (string-join args " ")))
    (if (and codeql-use-cli-server
             (not (and (codeql--cli-server-live-p proc)
                       (process-get proc 'codeql-busy))))
        (codeql--cli-server-run-async args callback)
      (codeql--cli-process-run-async args callback))))

(defun codeql-cli-servers-shutdown ()
  "Shut down all running CodeQL CLI servers."
  (interactive)
  (maphash (lambda (_key proc) (codeql--cli-server-kill proc)) codeql--cli-servers)
  (clrhash codeql--cli-servers)
  (message "Shut down CLI servers."))

(defun codeql--resolve-query-server ()
  "Resolve which query-server to use, legacy or query-server2."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((help (codeql--cli-command-to-string (list "execute" "--help"))))
    (if (string-match-p (regexp-quote "query-server2") help)
        "query-server2"
      "query-server")))

(defun codeql--resolve-query-paths (query-path)
  "Resolve and set buffer-local library-path and dbscheme for QUERY-PATH.

This version is used as part of actual query resolution and sets buffer local
context variables."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (codeql--await-search-paths)
  ;; only resolve once for current query buffer
  (unless (and codeql--library-path codeql--dbscheme)
    (message "Resolving query paths.")
    (let ((json (codeql--cli-command-to-string
                 (list "resolve" "library-path" "-v" "--log-to-stderr" "--format=json"
                       (format "--additional-packs=%s" (codeql--search-path))
                       (format "--query=%s" (codeql--tramp-unwrap query-path))))))
      (when json
        (condition-case nil
            (cl-destructuring-bind (&key libraryPath dbscheme &allow-other-keys)
                (json-parse-string json :object-type 'plist)
              (setq codeql--library-path libraryPath)
              (setq codeql--dbscheme dbscheme))
          (error (progn (message "error parsing json: %s" json) nil))))))
  ;; nil indicates there was an error resolving these
  (and codeql--library-path codeql--dbscheme))

(defun codeql--resolve-library-paths (query-path)
  "Resolve library paths for QUERY-PATH.

This version is used in early buffer local init of search paths and has no
side effects."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (codeql--parse-library-paths
   (codeql--cli-command-to-string (codeql--resolve-library-paths-args query-path))))

(defun codeql--resolve-library-paths-args (query-path)
  "Return the CLI arguments that resolve the library paths of QUERY-PATH."
  (list "resolve" "library-path" "-v" "--log-to-stderr" "--format=json"
        (format "--query=%s" query-path)))

(defun codeql--parse-library-paths (json)
  "Return the library paths in the JSON output of `codeql resolve library-path'."
  (when json
    (condition-case nil
        (cl-destructuring-bind (&key libraryPath &allow-other-keys)
            (json-parse-string json :object-type 'plist)
          ;; this is a vector
          libraryPath)
      (error (progn (message "error parsing json: %s" json) nil)))))

(defun codeql--resolve-qlpack-paths (dir)
  "Resolve qlpack paths from DIR."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((json (codeql--cli-command-to-string
               (list "resolve" "qlpacks" "-v" "--log-to-stderr" "--format=json"
                     (format "--search-path=%s" dir)))))
    (when json
      (condition-case nil
          (let* ((qlpacks (json-parse-string json :object-type 'alist)))
            (cl-loop for qlpack in qlpacks collect
                     (mapcar #'identity (cdr qlpack))))
        (error (progn (message "error parsing json: %s" json) nil))))))

(defun codeql--database-info (database-path)
  "Resolve info for database at DATABASE-PATH."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((json (codeql--cli-command-to-string
               (list "resolve" "database" "-v" "--log-to-stderr" "--format=json"
                     "--" (codeql--tramp-unwrap database-path)))))
    (when json
      (condition-case nil
          (json-parse-string json :object-type 'alist)
        (error (progn (message "error parsing json: %s" json) nil))))))

(defun codeql--database-upgrades (database-scheme)
  "Resolve upgrades for DATABASE-SCHEME."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((json (codeql--cli-command-to-string
               (list "resolve" "upgrades" "-v" "--log-to-stderr" "--format=json"
                     "--" (codeql--tramp-unwrap database-scheme)))))
    (when json
      (condition-case nil
          (json-parse-string json :object-type 'alist)
        (error (progn (message "error parsing json: %s" json) nil))))))

(defun codeql--query-info (query-path)
  "Retrieve metadata for QUERY-PATH."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((json (codeql--cli-command-to-string
               (list "resolve" "metadata" "-v" "--log-to-stderr" "--format=json"
                     "--" (codeql--tramp-unwrap query-path)))))
    (when json
      (condition-case nil
          (json-parse-string json :object-type 'alist)
        (error (progn (message "error parsing json: %s" json) nil))))))

(defun codeql--bqrs-info (bqrs-path &optional paginate-rows paginate-result-set)
  "Retrieve info for BQRS-PATH.

When PAGINATE-ROWS is non-nil, also compute the byte offsets for pages of
PAGINATE-ROWS rows in result set PAGINATE-RESULT-SET, for use with the
`--start-at' option of `codeql bqrs decode'."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((json (codeql--cli-command-to-string
               (append (list "bqrs" "info" "-v" "--log-to-stderr" "--format=json")
                       (when paginate-rows
                         (list (format "--paginate-rows=%d" paginate-rows)))
                       (when (and paginate-rows paginate-result-set)
                         (list (format "--paginate-result-set=%s" paginate-result-set)))
                       (list "--" (codeql--tramp-unwrap bqrs-path))))))
    (when json
      (condition-case nil
          (json-parse-string json :object-type 'alist)
        (error (progn (message "error parsing json: %s" json) nil))))))

(defun codeql--bqrs-to-csv (bqrs-path entities)
  (let ((csv-file (concat bqrs-path ".csv")))
    (when (codeql--cli-command-to-string
           (list "bqrs" "decode"
                 (format "--output=%s" (codeql--tramp-unwrap csv-file))
                 "--format=csv" (format "--entities=%s" entities)
                 "--" (codeql--tramp-unwrap bqrs-path)))
      (with-temp-buffer (insert-file-contents csv-file) (buffer-string)))))

(defun codeql--bqrs-to-json (bqrs-path entities &optional result-set rows start-at)
  "Decode BQRS-PATH to json with ENTITIES.

When RESULT-SET is non-nil, only decode that result set.  When ROWS and
START-AT are non-nil, only decode ROWS rows starting at byte offset START-AT,
as obtained from `codeql--bqrs-info' pagination offsets."
  (let ((json-file (concat bqrs-path ".json")))
    (when (codeql--cli-command-to-string
           (append (list "bqrs" "decode"
                         (format "--output=%s" (codeql--tramp-unwrap json-file))
                         "--format=json" (format "--entities=%s" entities))
                   (when result-set
                     (list (format "--result-set=%s" result-set)))
                   (when (and rows start-at)
                     (list (format "--rows=%d" rows) (format "--start-at=%d" start-at)))
                   (list "--" (codeql--tramp-unwrap bqrs-path))))
      (with-temp-buffer (insert-file-contents json-file) (buffer-string)))))

(defun codeql--bqrs-to-sarif (bqrs-path id kind &optional max-paths)
  (cl-assert (and id kind) t)
  (let* ((sarif-file (concat bqrs-path ".sarif"))
         ;; XXX: TODO check out --column-kind a bit deeper as well
         ;; it's important to enable --no-group-results, otherwise we get piled
         ;; on messages for a single result which complicates SARIF parsing
         ;; also note that our --max-paths is set to 10 by default, as to 4 in
         ;; the codeql extension, which is why we show more results
         (args (list "bqrs" "interpret" "-v" "--log-to-stderr"
                     (format "-t=id=%s" id) (format "-t=kind=%s" kind)
                     (format "--output=%s" (codeql--tramp-unwrap sarif-file))
                     "--format=sarif-latest"
                     (format "--max-paths=%s" (or max-paths codeql--path-problem-max-paths))
                     "--no-group-results"
                     "--" (codeql--tramp-unwrap bqrs-path))))
    (when (codeql--cli-command-to-string args)
      (with-temp-buffer (insert-file-contents sarif-file) (buffer-string)))))

(defun codeql--bqrs-to-dot (bqrs-path id kind)
  "Interpret the graph results at BQRS-PATH of query ID and KIND as dot.

Return the path of the dot file, or nil on failure."
  (cl-assert (and id kind) t)
  (let ((output-dir (concat bqrs-path ".dot.d")))
    (when (codeql--cli-command-to-string
           (list "bqrs" "interpret" "-v" "--log-to-stderr"
                 (format "-t=id=%s" id) (format "-t=kind=%s" kind)
                 (format "--output=%s" (codeql--tramp-unwrap output-dir))
                 "--format=dot"
                 "--no-group-results"
                 "--" (codeql--tramp-unwrap bqrs-path)))
      ;; one file per query id, ids like rb/print-cfg become subdirectories
      (let ((dot-path (expand-file-name (concat id ".dot") output-dir)))
        (when (codeql--file-exists-p dot-path)
          dot-path)))))

(defun codeql--database-archive-zipinfo ()
  "Return extraction-relative file listing for source archive zip."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((zipinfo (codeql--shell-command-to-string
                  (format "%s -1 %s"
                          (executable-find "zipinfo" (file-remote-p default-directory))
                          codeql--database-source-archive-zip))))
    (when zipinfo
      (let ((zipinfo-relative-paths
             (cl-map 'list (lambda (file) file) (split-string zipinfo "\n"))))
        zipinfo-relative-paths))))

(defun codeql--source-archive-zip-browsable-p (zip)
  "Return non-nil if the files in the ZIP archive can be visited directly.

That needs `tramp-archive', which only works when Emacs has D-Bus support
and GVFS is running, otherwise the archive is extracted instead."
  (and (bound-and-true-p tramp-archive-enabled)
       (ignore-errors (file-directory-p (file-name-as-directory zip)))))

(defun codeql--database-extract-source-archive-zip (trusted-root)
  "Mount or extract a database source zip archive, ensuring TRUSTED-ROOT."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (message "archive-root: %s" (codeql--file-truename codeql--database-source-archive-root))
  (message "trusted-root: %s" (codeql--file-truename trusted-root))
  (cond
   ((and (>= emacs-major-version 27) (eq system-type 'gnu/linux)
         (codeql--source-archive-zip-browsable-p codeql--database-source-archive-zip))
    ;; >= emacs 27 we can just interact with the zip archive directly :)
    (setq codeql--database-source-archive-root codeql--database-source-archive-zip))
   ;; darwin does not support the zip archive via tramp
   ((not (codeql--file-exists-p (codeql--file-truename codeql--database-source-archive-root)))
    (when (string-match-p (format "^%s" (regexp-quote (codeql--file-truename trusted-root)))
                          (codeql--file-truename codeql--database-source-archive-root))
      (message "Source root verified to exist in trusted path ... extracting.")
      (cond
       ((executable-find "unzip" (file-remote-p default-directory))
        (message "Extracting source archive with unzip.")
        (when (codeql--shell-command-to-string
               (format "%s %s -d %s"
                       (executable-find "unzip" (file-remote-p default-directory))
                       (codeql--file-truename codeql--database-source-archive-zip)
                       (codeql--file-truename codeql--database-source-archive-root)))
          (message "Extracted source archive with unzip.")))
       (t (error "Could not process source archive.")))))
   (t (message "Source archive already processed."))))

;;; jsonrpc interactions with the buffer-local query server

(cl-defmethod jsonrpc-connection-ready-p
  (_server (_method (eql :evaluation/registerDatabases)))
  "Provide synchronization for register/unregister."
  ;; wait until any buffer local deregistration has completed
  (if codeql--active-database
      nil
    t))

(defun codeql-query-server-register-database (database-path)
  "Register a database with the query server."
  (interactive (list (read-file-name "Database or database archive: " nil default-directory t)))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)

  ;; if no server is running yet, offer to start one
  (unless codeql--query-server
    (transient-setup 'codeql-transient-query-server-init-start)
    (error "No query server running, please start one and re-select database."))

  ;; the cli doesn't expand ~ and resolves relative paths against the query
  (setq database-path (expand-file-name database-path))

  ;; database archives are unbundled into the state dir first
  (when (and (string-suffix-p ".zip" database-path t) (file-regular-p database-path))
    (setq database-path (codeql--database-unbundle database-path)))

  ;; resolve and set the dataset folder, we need this when running queries
  (let* ((database-info (codeql--database-info database-path))
         (database-language (json-pointer-get database-info "/languages/0"))
         (source-location-prefix (json-pointer-get database-info "/sourceLocationPrefix"))
         (source-archive-zip (json-pointer-get database-info "/sourceArchiveZip"))
         (source-archive-root (json-pointer-get database-info "/sourceArchiveRoot"))
         (database-dataset-folder (json-pointer-get database-info "/datasetFolder")))

    (cl-assert codeql--query-server t)
    (unless database-dataset-folder
      (user-error "Not a CodeQL database: %s" database-path))

    ;; perform any local deregistration first
    (when (and codeql--active-database codeql--database-dataset-folder)
      (codeql-query-server-deregister-database codeql--database-dataset-folder database-path))

    ;; check that target dataset is not registered in a different session
    (when-let ((buffer (codeql--active-datasets-get database-dataset-folder)))
      (message "Database is registered in other session! Deregistering there.")
      ;; check if we need to do remote deregister
      (with-current-buffer buffer
        (when (and codeql--active-database codeql--database-dataset-folder)
          (codeql-query-server-deregister-database codeql--database-dataset-folder database-path))))

    (message "Registering: %s" database-dataset-folder)

    (cond
     ;; legacy query-server
     ((string= codeql-query-server "query-server")
      (jsonrpc-async-request
       (codeql--query-server-current-or-error)
       :evaluation/registerDatabases
       `(:body
         (:databases
          [(:dbDir ,database-dataset-folder :workingSet "default")])
         :progressId ,(codeql--query-server-next-progress-id))
       :success-fn
       (let ((buffer (current-buffer))
             (database-language database-language)
             (database-path database-path)
             (database-dataset-folder database-dataset-folder)
             (source-location-prefix source-location-prefix)
             (source-archive-root source-archive-root)
             (source-archive-zip source-archive-zip))
         (jsonrpc-lambda
             (&key registeredDatabases &allow-other-keys)
           ;;(message "Success: %s" registeredDatabases)
           (with-current-buffer buffer
             ;; global addition can be asynchronous, so we do that on success only
             (codeql--active-datasets-add database-dataset-folder (current-buffer))
             ;; save in database selection history
             (codeql--database-history-add database-path database-language)
             ;; these variables are buffer-local to ql-tree-sitter-mode
             (setq codeql--active-database database-path)
             (setq codeql--active-database-language database-language)
             (setq codeql--database-dataset-folder database-dataset-folder)
             (setq codeql--database-source-location-prefix source-location-prefix)
             (setq codeql--database-source-archive-root source-archive-root)
             (setq codeql--database-source-archive-zip source-archive-zip)
             (codeql--query-server-sync-state)
             (message "Registered: %s" database-dataset-folder)
             ;; might change codeql--active-database semantics at some point
             ;; so use the database path value we _KNOW_ is legit
             (codeql--database-extract-source-archive-zip database-path))))
       :error-fn
       (jsonrpc-lambda (&key code message data &allow-other-keys)
         (message "Error %s: %s\n%s\n" code message data))
       ;; synchronize to only register when deregister has completed in global state
       :deferred :evaluation/registerDatabases))

     ;; query-server2
     ((string= codeql-query-server "query-server2")
      (jsonrpc-async-request
       (codeql--query-server-current-or-error)
       :evaluation/registerDatabases
       `(:body
         (:databases
          [,(codeql--file-truename database-path)])
         :progressId ,(codeql--query-server-next-progress-id))
       :success-fn
       (let ((buffer (current-buffer))
             (database-language database-language)
             (database-path database-path)
             (database-dataset-folder database-dataset-folder)
             (source-location-prefix source-location-prefix)
             (source-archive-root source-archive-root)
             (source-archive-zip source-archive-zip))
         (jsonrpc-lambda
             (&rest params)
           (let ((errors (codeql--query-server2-handle-message params)))
             (when errors
               (error errors)))
           (with-current-buffer buffer
             ;; global addition can be asynchronous, so we do that on success only
             (codeql--active-datasets-add database-dataset-folder (current-buffer))
             ;; save in database selection history
             (codeql--database-history-add database-path database-language)
             ;; these variables are buffer-local to ql-tree-sitter-mode
             (setq codeql--active-database database-path)
             (setq codeql--active-database-language database-language)
             (setq codeql--database-dataset-folder database-dataset-folder)
             (setq codeql--database-source-location-prefix source-location-prefix)
             (setq codeql--database-source-archive-root source-archive-root)
             (setq codeql--database-source-archive-zip source-archive-zip)
             (codeql--query-server-sync-state)
             (message "Registered: %s" database-dataset-folder)
             ;; might change codeql--active-database semantics at some point
             ;; so use the database path value we _KNOW_ is legit
             (codeql--database-extract-source-archive-zip database-path))))
       :error-fn
       (jsonrpc-lambda (&key code message data &allow-other-keys)
         (message "Error %s: %s\n%s\n" code message data))
       ;; synchronize to only register when deregister has completed in global state
       :deferred :evaluation/registerDatabases)))))

(defun codeql-query-server-deregister-database (database-dataset-folder &optional database-path)
  "Deregister database associated to DATABASE-DATASET-FOLDER."
  (message "Deregistering: %s" database-dataset-folder)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  ;; we need global removal to be synchronous, so just pull the entry here
  (codeql--active-datasets-del database-dataset-folder)

  (cond
   ;; legacy query server
   ((string= codeql-query-server "query-server")
    (jsonrpc-async-request
     (codeql--query-server-current-or-error)
     :evaluation/deregisterDatabases
     `(:body
       (:databases
        [(:dbDir ,database-dataset-folder :workingSet "default")])
       :progressId ,(codeql--query-server-next-progress-id))
     :success-fn
     (let ((buffer (current-buffer))
           (database-dataset-folder database-dataset-folder))
       (jsonrpc-lambda
        (&key registeredDatabases &allow-other-keys)
        ;;(message "Success: %s" registeredDatabases)
        (with-current-buffer buffer
          (codeql--reset-database-state)
          (codeql--query-server-sync-state)
          (message "Deregistered: %s" database-dataset-folder))))
     :error-fn
     (jsonrpc-lambda (&key code message data &allow-other-keys)
                     (message "Error %s: %s\n%s\n" code message data))
     :deferred :evaluation/deregisterDatabases))

   ;; query-server2
   ((string= codeql-query-server "query-server2")
    (jsonrpc-async-request
     (codeql--query-server-current-or-error)
     :evaluation/deregisterDatabases
     `(:body
       (:databases [,(codeql--file-truename database-path)])
       :progressId ,(codeql--query-server-next-progress-id))
     :success-fn
     (let ((buffer (current-buffer))
           (database-dataset-folder database-dataset-folder))
       (jsonrpc-lambda
        (&rest params)
        (let ((errors (codeql--query-server2-handle-message params)))
          (when errors
            (error errors)))
        (with-current-buffer buffer
          (codeql--reset-database-state)
          (codeql--query-server-sync-state)
          (message "Deregistered: %s" database-dataset-folder))))
     :error-fn
     (jsonrpc-lambda (&key code message data &allow-other-keys)
                     (message "Error %s: %s\n%s\n" code message data))
     :deferred :evaluation/deregisterDatabases))))

(defun codeql-query-server-active-database ()
  "Get a short identifier for the currently active database."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (if codeql--active-database
      (file-name-base
       (directory-file-name
        codeql--active-database))
    "select"))

;; XXX: this feels a little crummy still, revisit
(defun codeql--uri-to-filename (uri)
  "Turn URI into a file system location."
  (cl-assert (stringp uri) t)
  (let ((template "%%SRCROOT%%")
        (resolved-path uri))
    ;; do any source prefixing required based on global db info
    (when (string-match-p (regexp-quote template) uri)
      (setq resolved-path
            (replace-regexp-in-string
             (regexp-quote template)
             (or codeql--database-source-location-prefix "")
             uri)))
    (let* ((url (url-generic-parse-url (url-unhex-string resolved-path)))
           (type (url-type url)))
      (if (and type (not (string= type "file")))
          (error "Unsupported file scheme: %s" resolved-path))
      (url-filename url))))

(defun codeql--empty-location-uri-p (uri)
  "Return non-nil if URI doesn't name a file.

CodeQL gives entities without a location an empty path."
  (or (not (stringp uri))
      (member uri '("" "file:" "file:/" "file://" "file:///"))))

(defun codeql--location-url (url)
  "Return the bqrs location URL as an alist, or nil if it has no file.

URL is either an alist with a uri and its positions, or a file:// string
in the PATH:LINE:COLUMN:END-LINE:END-COLUMN form of getURL predicates.
A location with all positions 0 spans its whole file."
  (when (stringp url)
    (setq url
          (when (string-match
                 "\\`file://\\(.+\\):\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\)\\'"
                 url)
            `((uri . ,(concat "file://" (match-string 1 url)))
              ,@(cl-loop for key in '(startLine startColumn endLine endColumn)
                         for group from 2
                         collect (cons key (string-to-number
                                            (match-string group url))))))))
  (when (and (listp url)
             (not (codeql--empty-location-uri-p (alist-get 'uri url))))
    url))

(defun codeql--location-position-text (url)
  "Return the :LINE:COLUMN suffix of a location URL, or \"\" for a whole file."
  (let ((line (json-pointer-get url "/startLine")))
    (if (and (natnump line) (> line 0))
        (format ":%s:%s" line (json-pointer-get url "/startColumn"))
      "")))

(cl-defstruct (codeql--result-node
               (:constructor codeql--result-node-create) (:copier nil))
  (label             nil :read-only t)
  (mark              nil :read-only t)
  (filename          nil :read-only t)
  (line              nil :read-only t)
  (column            nil :read-only t)
  (visitable         nil :read-only t)
  (url               nil :read-only t)
  (code-flow         nil :read-only t)
  (rule-id           nil :read-only t)
  (code-flows        nil :read-only t)
  (locations         nil :read-only t)
  (related-locations nil :read-only t)
  (related-id        nil :read-only t))

;;; Org-mode based result rendering, so we can turn results into audit notes \o/

(defvar-local codeql--permalink-info nil
  "Permalink information of the results this source file was visited from.

See `codeql--results-permalink-info'.")

(defvar-local codeql--org-query-buffer nil
  "Share a buffer local copy of the query buffer in results buffers.")

(defun codeql--org-table-cell (text)
  "Return TEXT as the contents of a single org table cell.

Labels can span multiple lines (e.g. function bodies), which would otherwise
split a row.  Literal | characters would split the cell, so they are
displayed as ¦ instead."
  (string-trim
   (replace-regexp-in-string
    "|" "¦" (replace-regexp-in-string "[ \t]*\r?\n[ \t]*" " " text) t t)
   "[ \t]+" "[ \t]+"))

(defun codeql--org-table-cell-width (cell)
  "Return the display width of CELL in an org buffer.

Bracket links only show their description, as long as
`org-link-descriptive' is set."
  (codeql--require-org)
  (string-width
   (if (and (default-value 'org-link-descriptive)
            (string-match-p "\\[\\[" cell))
       (replace-regexp-in-string
        org-link-bracket-re
        (lambda (link) (or (match-string 2 link) (match-string 1 link)))
        cell t t)
     cell)))

(defun codeql--org-table-column-alignment (cells)
  "Return the alignment of a column holding CELLS, like `org-table-align'.

That is \"r\" when enough of CELLS are numbers, see
`org-table-number-fraction', \"l\" otherwise, unless a cookie such as
<r> fixes the alignment."
  (codeql--require-org)
  (let ((numbers 0) (non-empty 0) fixed)
    (cl-loop for cell in cells until fixed do
             (cond ((string-empty-p cell))
                   ((string-match "\\`<\\([lrc]\\)[0-9]*>\\'" cell)
                    (setq fixed (match-string 1 cell)))
                   (t (cl-incf non-empty)
                      (when (string-match-p org-table-number-regexp cell)
                        (cl-incf numbers)))))
    (cond (fixed)
          ((>= numbers (* org-table-number-fraction non-empty)) "r")
          (t "l"))))

(defun codeql--org-table (rows &optional header)
  "Return an aligned org table holding ROWS, with an optional HEADER row.

ROWS is a list of rows and HEADER a row, where a row is a list of cell
strings that are already valid org, see `codeql--org-table-cell'.  The
result is what `org-table-align' would produce, but building it directly
avoids the cost of parsing and measuring a table in an org buffer."
  (codeql--require-org)
  (let* ((all-rows (if header (cons header rows) rows))
         (ncols (apply #'max 1 (mapcar #'length all-rows)))
         (all-rows (mapcar (lambda (row)
                             (vconcat row (make-vector (- ncols (length row)) "")))
                           all-rows))
         (widths (make-vector ncols 1))
         (cell-widths
          (mapcar (lambda (row)
                    (let ((ws (make-vector ncols 0)))
                      (dotimes (i ncols)
                        (let ((w (codeql--org-table-cell-width (aref row i))))
                          (aset ws i w)
                          (aset widths i (max w (aref widths i)))))
                      ws))
                  all-rows))
         (alignments
          (vconcat (cl-loop for i below ncols collect
                            (codeql--org-table-column-alignment
                             (mapcar (lambda (row) (aref row i)) all-rows)))))
         (rule (concat "|" (mapconcat (lambda (w) (make-string (+ 2 w) ?-)) widths "+")
                       "|\n"))
         ;; org 9.5+ marks the padding around fields for bidi reordering
         (pre (if (boundp 'org-table--separator-space-pre)
                  org-table--separator-space-pre " "))
         (post (if (boundp 'org-table--separator-space-post)
                   org-table--separator-space-post " ")))
    (with-temp-buffer
      (insert rule)
      (cl-loop for row in all-rows
               for ws in cell-widths
               for first = t then nil do
               (dotimes (i ncols)
                 (let* ((spaces (- (aref widths i) (aref ws i)))
                        (prefix (pcase (aref alignments i)
                                  ("r" spaces)
                                  ("c" (/ spaces 2))
                                  (_ 0))))
                   (insert "|" pre
                           (make-string prefix ?\s)
                           (aref row i)
                           (make-string (- spaces prefix) ?\s)
                           post)))
               (insert "|\n")
               (when (and first header)
                 (insert rule)))
      (insert rule)
      (buffer-string))))

(defun codeql--escape-org-description (description)
  "Neutralize characters in DESCRIPTION that org would treat as markup."
  (if (string-match-p "[][=~_/+*<^\\]" description)
      (replace-regexp-in-string "[][=~_/+*<^\\]"
                                ;; this wraps with a zero width space ;)
                                (lambda (x) (format "​%s​" x)) description t t)
    description))

(defun codeql--printable-text (text)
  "Return TEXT on a single line, with control characters made visible."
  (if (string-match-p "[\0-\x1f\x7f]" text)
      (replace-regexp-in-string
       "[\0-\x1f\x7f]"
       (lambda (c) (string (if (eq (aref c 0) ?\x7f) ?␡ (+ ?␀ (aref c 0)))))
       (replace-regexp-in-string "[ \t]*\r?\n[ \t]*" " " text)
       t t)
    text))

(defun codeql--printable-label (label)
  "Return LABEL in a form that is visible and safe to render as org text.

Empty and whitespace-only labels get a placeholder, so their links remain
clickable, line breaks are collapsed and other control characters are shown
as their Unicode control pictures."
  (let ((label (format "%s" (or label ""))))
    (cond
     ((string-empty-p label) "[empty string]")
     ((string-match-p "\\`[[:space:]]+\\'" label)
      (format "[whitespace: \"%s\"]" (codeql--printable-text label)))
     (t (codeql--printable-text label)))))

(defun codeql--org-text (text)
  "Return TEXT escaped for display as literal text in org."
  (codeql--escape-org-description (codeql--printable-label text)))

(defun codeql--encode-link-path (path)
  "Percent encode the characters of PATH that org links in tables can't contain."
  (if (string-match-p "[%|]" path)
      (replace-regexp-in-string
       "[%|]" (lambda (c) (format "%%%02X" (aref c 0))) path t t)
    path))

(defun codeql--decode-link-path (path)
  "Reverse `codeql--encode-link-path' for PATH."
  (replace-regexp-in-string
   "%\\(25\\|7C\\)"
   (lambda (c) (if (string= (match-string 1 c) "25") "%" "|"))
   path t t))

(defvar codeql--source-link-prefix-box nil
  "When non-nil, a cons whose car caches `codeql--source-link-prefix'.

Bound around a rendering pass, so the source archive is located and
checked once rather than for every result node.")

(defun codeql--source-link-prefix ()
  "Return the encoded source archive root that result links point into."
  (or (car codeql--source-link-prefix-box)
      (progn
        (cl-assert codeql--database-source-archive-zip t)
        (cl-assert (codeql--file-exists-p codeql--database-source-archive-root) t)
        (let ((prefix (codeql--encode-link-path
                       ;; we've extracted to the expected location
                       (codeql--tramp-wrap codeql--database-source-archive-root))))
          (when codeql--source-link-prefix-box
            (setcar codeql--source-link-prefix-box prefix))
          prefix))))

(defun codeql--result-node-link (node)
  "Return the path of the codeql: link to the location of the visitable NODE."
  ;; since we have our own link type, also add in a column, and the end
  ;; of the location when known, see `codeql--parse-link-location'
  (let* ((url (codeql--result-node-url node))
         (end-line (and (listp url) (alist-get 'endLine url)))
         (end-column (and (listp url) (alist-get 'endColumn url))))
    (format "%s%s::%s:%s%s"
            (codeql--source-link-prefix)
            (codeql--encode-link-path (codeql--result-node-filename node))
            (codeql--result-node-line node)
            (codeql--result-node-column node)
            (if (and (natnump end-line) (natnump end-column))
                (format ":%s:%s" end-line end-column)
              ""))))

(defun codeql--result-node-to-org (node &optional custom-description)
  "Transform a result node into an org compatible link|string representation."
  (codeql--require-org)
  ;; https://orgmode.org/guide/Hyperlinks.html
  (if (codeql--result-node-visitable node)
      (let ((link (concat "codeql:" (codeql--result-node-link node)))
            (desc (codeql--printable-label (or custom-description
                                               (codeql--result-node-label node)))))
        (format "[[%s][%s]]"
                ;; escaping only affects brackets and backslashes
                (if (string-match-p "[][\\]" link) (org-link-escape link) link)
                (codeql--escape-org-description desc)))
    ;; not visitable, just return the label
    (codeql--org-text (codeql--result-node-label node))))

(defun codeql--org-list-from-nodes (parent-buffer nodes &optional header)
  "Turn a given list of PARENT-BUFFER context location NODES into an org-list.

Sets an optional HEADER."
  (with-temp-buffer
    (when header
      (insert header))
    (cl-loop for node in nodes
             for i below (length nodes) do
             ;; (codeql--print-node node)
             (let* ((prefix
                     (format
                      "%4s. %s %s" (1+ i)
                      (or (codeql--result-node-mark node) " ")
                      ;; make sure we have our buffer-local db state
                      (with-current-buffer parent-buffer
                        (codeql--result-node-to-org node))))
                    (suffix
                     (if-let ((url (and (codeql--result-node-visitable node)
                                        (codeql--result-node-url node))))
                         (format "%s%s"
                                 ;; set a custom description for this link
                                 (with-current-buffer parent-buffer
                                   (codeql--result-node-to-org node
                                                               (file-name-nondirectory
                                                                (codeql--uri-to-filename
                                                                 (json-pointer-get url "/uri")))))
                                 ;; org links don't support column offsets
                                 ;; so this is mostly just eye candy :P
                                 (codeql--location-position-text url))
                       ;; get ahead, but don't say nothing.
                       ""))
                    ;; do some basic ballpark alignment based on prefix label length
                    (align (- 50 (+ 10 (length (codeql--escape-org-description (codeql--result-node-label node)))))))
               ;; yolo alignment
               (insert (concat prefix (make-string (if (< align 0) 10 align) ?\s) suffix "\n"))))
    ;; return our nodes as org list
    (buffer-string)))

(defun codeql--raw-row-to-org-heading (row columns index result-set)
  "Return an org heading for the raw results ROW, a list of result nodes.

The heading lists the cells of ROW like a table row does, and its
properties hold the 0-based INDEX of ROW in the result set named
RESULT-SET, the location of its first cell that has one, and the value
of each cell under the name of its column in COLUMNS.  The current
buffer is the query buffer."
  (let ((seen (make-hash-table :test #'equal)))
    (concat
     (codeql--org-safe-heading
      (format "** %d. %s" (1+ index)
              (mapconcat (lambda (node)
                           (codeql--org-table-cell (codeql--result-node-to-org node)))
                         row " | ")))
     "\n"
     (codeql--org-property-drawer
      `(("CODEQL_KIND" . "result")
        ("CODEQL_QUERY_KIND" . "raw")
        ("CODEQL_RESULT_SET" . ,result-set)
        ("CODEQL_ROW" . ,(1+ index))
        ,@(codeql--result-location-properties
           (seq-find #'codeql--result-node-visitable row))
        ,@(cl-loop for node in row
                   for i from 1
                   for column = (and columns (< (1- i) (length columns)) (aref columns (1- i)))
                   for name = (codeql--org-property-name
                               (or (and column (json-pointer-get column "/name"))
                                   (format "col%d" i)))
                   for unique = (if (gethash name seen) (format "%s_%d" name i) name)
                   do (puthash unique t seen)
                   collect (cons (concat "CODEQL_COL_" unique)
                                 (codeql--printable-label
                                  (codeql--result-node-label node)))))))))

(defun codeql--query-results-to-org (query-results results-type &optional columns start result-set)
  "Turn QUERY-RESULTS of RESULTS-TYPE into an org data.

RESULTS-TYPE is `raw' for an org table of raw result rows, `raw-outline'
for raw result rows as org headings, see `codeql--raw-row-to-org-heading',
and `problem' or `path-problem' for problem results, which are org
headings.  The 0-based index of the first result is START, and the raw
results are from RESULT-SET, a result set name.  COLUMNS is the vector of
the columns of raw results, as decoded from the bqrs."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((parent-buffer (current-buffer))
        ;; reuse the cache of an enclosing rendering pass, if any
        (codeql--source-link-prefix-box (or codeql--source-link-prefix-box (list nil))))
    (with-temp-buffer
      (goto-char (point-min))
      (pcase results-type
        ;; raw result parsing of tuples
        ('raw
         ;; we go through the json rather than csv output of bqrs decode, so
         ;; that each cell's location data is handed to us and can be turned
         ;; into org links directly
         (insert
          (codeql--org-table
           ;; we pushed result tuples to head of list, so reverse for rendering
           (mapcar (lambda (row-data)
                     (mapcar (lambda (node)
                               ;; we use buffer-local variables here
                               (with-current-buffer parent-buffer
                                 (codeql--org-table-cell
                                  (codeql--result-node-to-org node))))
                             (reverse row-data)))
                   (reverse query-results))
           (when columns
             ;; columns are a vector, direct from the json
             (mapcar (lambda (col)
                       (let ((name (json-pointer-get col "/name"))
                             (kind (json-pointer-get col "/kind")))
                         (codeql--org-table-cell
                          (format "%s" (or name kind "(unknown)")))))
                     columns)))))
        ('raw-outline
         (cl-loop for row-data in (reverse query-results)
                  for index from (or start 0) do
                  (insert (with-current-buffer parent-buffer
                            (codeql--raw-row-to-org-heading
                             (reverse row-data) columns index result-set)))))
        ;; kind: problem and path-problem use the exact same SARIF renderer
        ((or 'problem 'path-problem)
         ;; generate an org tree off of a list structure
         (cl-loop for issue in query-results
                  for index from (or start 0)
                  for locations = (codeql--result-node-locations issue)
                  for related-locations = (codeql--result-node-related-locations issue)
                  for code-flows = (codeql--result-node-code-flows issue)
                  do
                  ;; add the locations for this issue, according to spec this can be up to 10
                  ;; but for code scanning etc. it can only have 1, nest flows either way.
                  (cl-loop for location in locations do
                           (insert
                            (concat
                             (if-let ((url (and (codeql--result-node-visitable location)
                                                (codeql--result-node-url location))))
                                 (format "** %s [%s] %s ... %s%s"
                                         (or (codeql--result-node-mark issue) " ")
                                         (codeql--result-node-rule-id issue)
                                         ;; swap sarif markdown links for org links if required
                                         (with-current-buffer parent-buffer
                                           (codeql--swap-sarif-links-for-org-links
                                            (codeql--result-node-label issue) related-locations))
                                         (with-current-buffer parent-buffer
                                           (codeql--result-node-to-org
                                            location
                                            (file-name-nondirectory
                                             (codeql--uri-to-filename
                                              (json-pointer-get url "/uri")))))
                                         (codeql--location-position-text url))
                               (format "** %s [%s] %s ... [location unknown]"
                                       (or (codeql--result-node-mark issue) " ")
                                       (codeql--result-node-rule-id issue)
                                       (with-current-buffer parent-buffer
                                         (codeql--swap-sarif-links-for-org-links
                                          (codeql--result-node-label issue) related-locations))))
                             "\n"
                             (codeql--org-property-drawer
                              `(("CODEQL_KIND" . "result")
                                ("CODEQL_QUERY_KIND" . ,(symbol-name results-type))
                                ("CODEQL_RESULT" . ,(1+ index))
                                ("CODEQL_RULE_ID" . ,(codeql--result-node-rule-id issue))
                                ("CODEQL_MESSAGE" . ,(codeql--sarif-message-text
                                                      (codeql--result-node-label issue)))
                                ,@(codeql--result-location-properties location)
                                ("CODEQL_PATHS" . ,(and code-flows
                                                        (apply #'+ (mapcar #'length code-flows))))))))
                           ;; add any codeflow paths and their associated nodes for this issue
                           (when code-flows
                             (cl-loop for path in code-flows
                                      for i below (length code-flows) do
                                      (cl-loop for nodes in path do
                                               ;; add the location|path nodes to the tree :)
                                               (insert (codeql--org-list-from-nodes
                                                        parent-buffer
                                                        nodes
                                                        (format "*** Path #%s\n" i))))))))))
      ;; return final org data
      (buffer-string))))

(defun codeql--hide-zero-width-spaces ()
  "Display the zero width spaces of escaped org text with no width at all.

By default graphical frames show them as thin spaces, which would offset the
columns of tables aligned by character width."
  (setq-local glyphless-char-display
              (let ((table (copy-sequence (default-value 'glyphless-char-display))))
                (aset table #x200b 'zero-width)
                table)))

;;; The org structure of results buffers
;;
;; A results buffer is an org document laid out as:
;;
;; * Query Source           CODEQL_KIND: query-source, folded initially
;; ** Originating Query     file: link to the query that ran
;; ** Evaluated Code        quick evaluations: the submitted code, verbatim
;; * Results                CODEQL_KIND: results
;; ** <result>              CODEQL_KIND: result, one per problem or raw row
;; *** Path #N              path-problem paths
;; * Results Footer         #+KEYWORD: metadata
;;
;; Raw results shown as a table have it directly under Results instead.

(defvar-local codeql--results-context nil
  "What the results of this buffer came from, a plist.

:provenance describes the CodeQL code that ran, see
`codeql--query-provenance', :database is the database it ran on and
:query-kind is either \"problem\", \"path-problem\" or \"raw\".")

(defun codeql--org-property-value (value)
  "Return VALUE as the text of an org property value, or nil if it is empty.

Line breaks are collapsed and control characters made visible, so the
value stays on one line.  Brackets that could start or end a link are
separated by a zero width space."
  (when value
    (let ((text (string-trim (codeql--printable-text (format "%s" value)))))
      (unless (string-empty-p text)
        (replace-regexp-in-string "\\[\\[\\|\\]\\]"
                                  (lambda (b) (concat (substring b 0 1) "\u200b" (substring b 1)))
                                  text t t)))))

(defun codeql--org-property-name (name)
  "Return NAME as an org property name made of A-Z, 0-9 and _."
  (let ((name (replace-regexp-in-string "[^A-Z0-9_]+" "_" (upcase (format "%s" name)) t t)))
    (if (string-match-p "\\`_*\\'" name) "UNNAMED" name)))

(defun codeql--org-property-drawer (properties)
  "Return an org property drawer holding PROPERTIES.

PROPERTIES is a list of (NAME . VALUE) pairs, see
`codeql--org-property-value'.  Properties without a value are left out."
  (concat ":PROPERTIES:\n"
          (mapconcat (lambda (property)
                       (when-let ((value (codeql--org-property-value (cdr property))))
                         (format ":%s: %s\n" (car property) value)))
                     properties "")
          ":END:\n"))

(defun codeql--org-file-link (path &optional search description)
  "Return an org file: link to PATH, with an optional SEARCH option.

DESCRIPTION defaults to the file name of PATH."
  (codeql--require-org)
  (format "[[%s][%s]]"
          (org-link-escape (concat "file:" path (if search (format "::%s" search) "")))
          (codeql--org-text (or description (file-name-nondirectory path)))))

(defun codeql--org-src-block (source &optional language)
  "Return an org src block of LANGUAGE (default: ql) that holds SOURCE.

Lines that org would read as headings or keywords are escaped with a
comma, which org removes again when the block is read or edited.  The
-i switch keeps the indentation of SOURCE."
  (codeql--require-org)
  (let ((body (org-escape-code-in-string source)))
    (concat (format "#+begin_src %s -i\n" (or language "ql"))
            body
            (unless (or (string-empty-p body) (string-suffix-p "\n" body)) "\n")
            "#+end_src\n")))

(defun codeql--session-action-description (provenance)
  "Describe what the session evaluation of PROVENANCE evaluated."
  (pcase (plist-get provenance :action)
    ('select "query")
    ('expression "expression")
    ('formula "formula")
    ('predicate (if (plist-get provenance :count)
                    "quick evaluation count of a predicate"
                  "quick evaluation of a predicate"))
    ('type (if (plist-get provenance :count) "count of a type" "values of a type"))
    (_ "input")))

(defun codeql--results-session-source-org (provenance)
  "Return the body of the Query Source section for session PROVENANCE.

See `codeql--session-run'."
  (concat
   "** Evaluated Code\n"
   (format "%s %s of session %s:\n"
           (or (plist-get provenance :frontend) "Session")
           (codeql--session-action-description provenance)
           (codeql--org-text (format "%s" (plist-get provenance :session))))
   (codeql--org-src-block (or (plist-get provenance :input) ""))
   "** Session Module\n"
   "The query module that ran, with the definitions of the session:\n"
   (codeql--org-src-block (or (plist-get provenance :module) ""))))

(defun codeql--results-query-source-org (context)
  "Return the Query Source section for the results of CONTEXT.

See `codeql--results-context'."
  (let* ((provenance (plist-get context :provenance))
         (kind (plist-get provenance :kind))
         (path (plist-get provenance :path))
         (session (eq kind 'session))
         (quick-eval (eq kind 'quick-eval))
         (sarif (memq kind '(sarif mrva)))
         (mrva (eq kind 'mrva)))
    (concat
     "* Query Source\n"
     (codeql--org-property-drawer
      `(("CODEQL_KIND" . "query-source")
        ("CODEQL_EVALUATION" . ,(cond (session "session")
                                      (mrva "variant-analysis")
                                      (sarif "sarif")
                                      ((not quick-eval) "query")
                                      ((plist-get provenance :count) "quick-eval-count")
                                      (t "quick-eval")))
        ("CODEQL_SESSION" . ,(and session (plist-get provenance :session)))
        ("CODEQL_QUERY" . ,path)
        ("CODEQL_DATABASE" . ,(plist-get context :database))
        ,@(when mrva
            `(("CODEQL_MRVA_SESSION" . ,(plist-get provenance :session))
              ("CODEQL_MRVA_RUN" . ,(plist-get provenance :run))
              ("CODEQL_MRVA_CONTROLLER" . ,(plist-get provenance :controller))
              ("CODEQL_MRVA_REPOSITORY" . ,(plist-get provenance :repository))))
        ,@(when sarif
            `(("CODEQL_SARIF" . ,(plist-get provenance :sarif))
              ("CODEQL_TOOL" . ,(string-join (plist-get provenance :tools) ", "))
              ("CODEQL_REPOSITORY_URI" . ,(plist-get provenance :repository-uri))
              ("CODEQL_REVISION_ID" . ,(plist-get provenance :revision-id))))
        ("VISIBILITY" . "folded")))
     (when session
       (codeql--results-session-source-org provenance))
     (when path
       (concat "** Originating Query\n" (codeql--org-file-link path) "\n"))
     (when quick-eval
       (let ((line (plist-get provenance :line))
             (column (plist-get provenance :column)))
         (concat
          "** Evaluated Code\n"
          (format "%s%s%s:\n"
                  (if (plist-get provenance :count) "Quick evaluation count" "Quick evaluation")
                  (cond ((plist-get provenance :predicate) " of the enclosing predicate")
                        ((plist-get provenance :at-point) " at point")
                        (t " of the region"))
                  (if (and path line)
                      (format " at %s" (codeql--org-file-link
                                        path line
                                        (format "%s:%s:%s" (file-name-nondirectory path)
                                                line (or column 1))))
                    ""))
          (codeql--org-src-block (or (plist-get provenance :source) "")))))
     (when mrva
       (concat
        "** Submitted Query\n"
        (if-let ((source (plist-get provenance :source)))
            (concat
             (if (plist-get provenance :source-submitted)
                 (format "The query of run %s, as submitted to %s:\n"
                         (plist-get provenance :run) (plist-get provenance :controller))
               (format "The query pack of run %s could not be fetched, %s:\n"
                       (plist-get provenance :run)
                       "this is the query file as it is now"))
             (codeql--org-src-block source))
          (format "The query of run %s could not be found.\n" (plist-get provenance :run)))))
     (when sarif
       (concat
        (when-let ((sarif-path (plist-get provenance :sarif)))
          (concat "** Originating SARIF\n" (codeql--org-file-link sarif-path) "\n"))
        (when-let ((rules (plist-get provenance :rules)))
          (concat "** Rules\n"
                  (mapconcat (lambda (rule)
                               (format "- %s%s\n"
                                       (codeql--org-text (plist-get rule :id))
                                       (if-let ((name (seq-find
                                                       (lambda (name)
                                                         (and name (not (equal name (plist-get rule :id)))))
                                                       (list (plist-get rule :name)
                                                             (plist-get rule :description)))))
                                           (concat ": " (codeql--org-text name))
                                         "")))
                             rules ""))))))))

(defun codeql--results-section-org (context)
  "Return the heading of the Results section for the results of CONTEXT."
  (concat "* Results\n"
          (codeql--org-property-drawer
           `(("CODEQL_KIND" . "results")
             ("CODEQL_QUERY_KIND" . ,(plist-get context :query-kind))))))

(defun codeql--result-location-properties (node)
  "Return org properties describing the location of the result NODE."
  (when (and node (codeql--result-node-visitable node))
    (let ((url (codeql--result-node-url node)))
      `(("CODEQL_FILE" . ,(codeql--result-node-filename node))
        ("CODEQL_LINE" . ,(codeql--result-node-line node))
        ("CODEQL_COLUMN" . ,(codeql--result-node-column node))
        ("CODEQL_END_LINE" . ,(and (listp url) (alist-get 'endLine url)))
        ("CODEQL_END_COLUMN" . ,(and (listp url) (alist-get 'endColumn url)))))))

(defun codeql--sarif-message-text (message)
  "Return SARIF MESSAGE as plain text, with links as their text."
  (mapconcat (lambda (component) (if (stringp component) component (car component)))
             (codeql--parse-sarif-message (or message "")) ""))

(defun codeql--org-safe-heading (heading)
  "Return HEADING so that org doesn't read the end of it as tags."
  (if (string-match-p "[ \t]:[^ \t\n]+:[ \t]*\\'" heading)
      (concat heading "\u200b")
    heading))

(defun codeql--results-initial-visibility ()
  "Fold the Query Source section and the property drawers of this buffer.

Everything else is left as it is, so the results remain visible."
  (save-excursion
    (if (fboundp 'org-fold-hide-drawer-all)
        (org-fold-hide-drawer-all)
      (org-cycle-hide-drawers 'all))
    (goto-char (point-min))
    (when (re-search-forward "^\\* Query Source[ \t]*$" nil t)
      (beginning-of-line)
      (if (fboundp 'org-fold-subtree)
          (org-fold-subtree t)
        (outline-hide-subtree)))))

(defvar codeql-results-mode-map (make-sparse-keymap)
  "Keymap for `codeql-results-mode'.")

(define-derived-mode codeql-results-mode org-mode "CodeQL-Results"
  "Major mode for CodeQL query results, derived from `org-mode'.

Query results, compared results and the saved results of query history
are shown in this mode, so they can have key bindings of their own in
`codeql-results-mode-map' that leave other org buffers alone.  Its
parent `org-mode-map' still applies, and `org-mode-hook' still runs.

\{codeql-results-mode-map}"
  (codeql--hide-zero-width-spaces)
  (setq-local next-error-function #'codeql--results-next-error)
  ;; saved results, rendered results are folded once they are filled in
  (codeql--results-initial-visibility))

;; the results of query history are saved as BQRS-PATH.org
(add-to-list 'auto-mode-alist '("\\.bqrs\\.org\\'" . codeql-results-mode))

(defun codeql--org-render-sarif-results (org-data query-buffer &optional footer marker context)
  "Render ORG-DATA including an optional FOOTER.

CONTEXT describes where the results came from, see
`codeql--results-context'."
  ;; sarif results are org trees
  (let ((buffer
         (generate-new-buffer
          (format "* codeql-org-results:%s *" (if marker marker "")))))
    (with-current-buffer buffer
      (codeql-results-mode)
      (setq codeql--results-context context)
      (codeql--raw-results-fill-buffer org-data footer)
      (setq buffer-read-only t)
      (setq codeql--org-query-buffer query-buffer)
      (when codeql-results-diagnostics
        (codeql-results-diagnostics-mode 1))
      (save-excursion
        (switch-to-buffer-other-window buffer))
      (buffer-string))))

(defvar-local codeql--raw-results-pagination nil
  "Pagination state of a results buffer.

A plist whose :kind is either `raw' for result set tables, or `sarif' for
problem and path-problem results.  Both kinds have the keys :page, the
0-based current page, :page-size, :total-rows and :footer.

Raw results also have :source-bqrs-path, the bqrs the query produced, and
:bqrs-path, the bqrs pages are decoded from, which is a sorted copy when
:sort is a (COLUMN . DIRECTION) pair.  :result-sets holds the alists of
all result sets as reported by `codeql bqrs info', :result-set the name of
the shown one, :offsets the vector of page byte offsets as computed by
`codeql bqrs info --paginate-rows', or nil for a single page, and :style,
see `codeql-raw-results-style'.

SARIF results have :results, the vector of all parsed SARIF results,
and :link-prefix, see `codeql--sarif-results-to-org'.")

(defvar-local codeql--raw-results-page-cache nil
  "Rendered org data of recently visited pages, as (PAGE . ORG-DATA) entries.

Most recently used entries come first, see `codeql-results-page-cache-size'.")

(defun codeql--raw-results-fill-buffer (org-data &optional footer)
  "Replace the current buffer contents with results ORG-DATA and FOOTER.

ORG-DATA is an aligned table of raw results, see `codeql--org-table', or
result headings.  It goes into the Results section, after the Query
Source section described by `codeql--results-context'.  Point ends up at
the Results section."
  (codeql--require-org)
  (let ((inhibit-read-only t))
    (unless (derived-mode-p 'codeql-results-mode)
      (let ((context codeql--results-context))
        (codeql-results-mode)
        (setq codeql--results-context context)))
    (erase-buffer)
    (insert (codeql--results-query-source-org codeql--results-context))
    (let ((results (point)))
      (insert (codeql--results-section-org codeql--results-context)
              org-data)
      (unless (bolp)
        (insert "\n"))
      ;; only add footer after the results
      (when footer
        (insert "\n* Results Footer\n")
        (insert footer))
      (codeql--results-initial-visibility)
      (goto-char results))
    (codeql--diagnostics-results-changed)))

(defun codeql--org-render-raw-query-results (org-data query-buffer &optional footer marker pagination context)
  "Render ORG-DATA including an optional FOOTER.

PAGINATION is an optional plist describing a paginated result set, see
`codeql--raw-results-pagination'.  CONTEXT describes where the results
came from, see `codeql--results-context'."
  ;; raw results are org tables or headings
  (let ((buffer
         (generate-new-buffer
          (format "* codeql-org-results:%s *" (if marker marker "")))))
    (with-current-buffer buffer
      (codeql-results-mode)
      (setq codeql--results-context context)
      (setq codeql--org-query-buffer query-buffer)
      (when pagination
        (setq codeql--raw-results-pagination pagination)
        (codeql--raw-results-cache-put (plist-get pagination :page) org-data)
        (codeql-results-pagination-mode 1))
      (codeql--raw-results-fill-buffer
       org-data
       (if pagination (codeql--raw-results-pagination-footer) footer))
      (setq buffer-read-only t)
      (when codeql-results-diagnostics
        (codeql-results-diagnostics-mode 1))
      (save-excursion
        (switch-to-buffer-other-window buffer))
      (buffer-string))))

;;; Pagination of raw results

(defun codeql--raw-results-select-result-set (bqrs-info)
  "Return the alist describing the result set to render from BQRS-INFO.

Prefers #select, otherwise the first result set that holds any rows."
  (let ((result-sets (append (alist-get 'result-sets bqrs-info) nil)))
    (or (cl-find "#select" result-sets
                 :key (lambda (rs) (alist-get 'name rs)) :test #'equal)
        (cl-find-if (lambda (rs) (> (or (alist-get 'rows rs) 0) 0)) result-sets)
        (car result-sets))))

(defun codeql--raw-results-pages (pagination)
  "Return the number of pages described by PAGINATION."
  (if-let ((offsets (plist-get pagination :offsets)))
      (max 1 (length offsets))
    (max 1 (ceiling (or (plist-get pagination :total-rows) 0)
                    (max 1 (or (plist-get pagination :page-size) 1))))))

(defun codeql--sarif-results-p (pagination)
  "Return non-nil if PAGINATION describes problem or path-problem results."
  (eq (plist-get pagination :kind) 'sarif))

(defun codeql--sarif-results-to-org (results start end &optional link-prefix)
  "Return org data for the SARIF RESULTS vector from index START below END.

Result links point into the source archive of the active database,
unless LINK-PREFIX is non-nil, in which case it is used instead, e.g.
the empty string for results whose locations are files on disk."
  (let ((codeql--source-link-prefix-box (list link-prefix))
        (n (length results)))
    (mapconcat
     #'identity
     (cl-loop for i from start below (min end n)
              for result = (aref results i)
              for code-flows = (json-pointer-get result "/codeFlows")
              do (when (zerop (% (- i start) 50))
                   (message "Rendering SARIF results ... %s/%s" (1+ i) n))
              collect
              (codeql--query-results-to-org
               (list (codeql--issue-with-nodes
                      code-flows
                      (json-pointer-get result "/locations")
                      (json-pointer-get result "/relatedLocations")
                      (json-pointer-get result "/message/text")
                      (json-pointer-get result "/ruleId")))
               (if code-flows 'path-problem 'problem)
               nil
               i))
     "")))

(defun codeql--raw-results-cache-get (page)
  "Return cached org data for PAGE in the current results buffer, or nil.

A hit marks PAGE as most recently used."
  (when-let ((entry (assq page codeql--raw-results-page-cache)))
    (setq codeql--raw-results-page-cache
          (cons entry (delq entry codeql--raw-results-page-cache)))
    (cdr entry)))

(defun codeql--raw-results-cache-put (page org-data)
  "Cache ORG-DATA for PAGE, evicting the least recently used pages."
  (when (> codeql-results-page-cache-size 0)
    (setq codeql--raw-results-page-cache
          (cons (cons page org-data)
                (assq-delete-all page codeql--raw-results-page-cache)))
    (when (> (length codeql--raw-results-page-cache) codeql-results-page-cache-size)
      (setcdr (nthcdr (1- codeql-results-page-cache-size) codeql--raw-results-page-cache)
              nil))))

(defun codeql--raw-results-row-range (pagination)
  "Return the 1-based (FIRST . LAST) rows of the current page in PAGINATION."
  (let ((page (plist-get pagination :page))
        (page-size (plist-get pagination :page-size)))
    (cons (1+ (* page page-size))
          (min (plist-get pagination :total-rows) (* (1+ page) page-size)))))

(defun codeql--raw-results-sort-description (state)
  "Return a description of how the results described by STATE are sorted."
  (if-let ((sort (plist-get state :sort)))
      (let ((result-set (cl-find (plist-get state :result-set) (plist-get state :result-sets)
                                 :key (lambda (rs) (alist-get 'name rs)) :test #'equal)))
        (format "%s %s"
                (or (nth (car sort) (codeql--raw-results-column-names result-set))
                    (format "column %d" (1+ (car sort))))
                (cdr sort)))
    "original order"))

(defun codeql--raw-results-pagination-footer ()
  "Return the results footer for the current paginated results buffer."
  (let* ((pagination codeql--raw-results-pagination)
         (page (plist-get pagination :page))
         (total-rows (plist-get pagination :total-rows))
         (rows (codeql--raw-results-row-range pagination))
         (first-row (car rows))
         (last-row (cdr rows)))
    (concat (or (plist-get pagination :footer) "")
            (if (codeql--sarif-results-p pagination)
                (format "#+RESULTS_PAGE: %d/%d\n#+RESULTS_ALERTS: %d-%d of %d\n"
                        (1+ page) (codeql--raw-results-pages pagination)
                        first-row last-row total-rows)
              (format
               (mapconcat
                #'identity
                '("#+RESULT_SET: %s"
                  "#+RESULTS_SORT: %s"
                  "#+RESULTS_PAGE: %d/%d"
                  "#+RESULTS_ROWS: %d-%d of %d" "") "\n")
               (plist-get pagination :result-set)
               (codeql--raw-results-sort-description pagination)
               (1+ page) (codeql--raw-results-pages pagination)
               first-row last-row total-rows)))))

(defun codeql--raw-results-header-line ()
  "Return a header line describing the current results page."
  (when codeql--raw-results-pagination
    (let* ((pagination codeql--raw-results-pagination)
           (page (plist-get pagination :page))
           (rows (codeql--raw-results-row-range pagination)))
      (let ((key (lambda (command)
                   (substitute-command-keys
                    (format "\\<codeql-results-pagination-mode-map>\\[%s]" command))))
            ;; the header line is a mode line construct, so escape any %
            (text (lambda (s) (replace-regexp-in-string "%" "%%" s t t))))
        (if (codeql--sarif-results-p pagination)
            (format " Alerts page %d/%d (results %d-%d of %d)   %s next, %s previous, %s jump"
                    (1+ page) (codeql--raw-results-pages pagination)
                    (car rows) (cdr rows)
                    (plist-get pagination :total-rows)
                    (funcall key 'codeql-results-next-page)
                    (funcall key 'codeql-results-previous-page)
                    (funcall key 'codeql-results-goto-page))
          (format " %s, %s: page %d/%d (rows %d-%d of %d)   %s next, %s previous, %s jump, %s sort, %s result set"
                  (funcall text (plist-get pagination :result-set))
                  (funcall text (codeql--raw-results-sort-description pagination))
                  (1+ page) (codeql--raw-results-pages pagination)
                  (car rows) (cdr rows)
                  (plist-get pagination :total-rows)
                  (funcall key 'codeql-results-next-page)
                  (funcall key 'codeql-results-previous-page)
                  (funcall key 'codeql-results-goto-page)
                  (funcall key 'codeql-results-sort)
                  (funcall key 'codeql-results-select-result-set)))))))

(defun codeql--raw-tuples-to-query-results (tuples)
  "Transform raw result TUPLES into a list of result node rows."
  (let ((query-results nil))
    ;; tuples are array of tuple, tuple are array of element
    (cl-loop for tuple across tuples do
             (let ((row-data nil))
               (cl-loop for element across tuple do
                        (cond
                         ;; node with location info
                         ((and (listp element)
                               (codeql--location-url (json-pointer-get element "/url")))
                          (let* ((url (codeql--location-url (json-pointer-get element "/url")))
                                 (node (codeql--result-node-create
                                        :label (json-pointer-get element "/label")
                                        :mark "→"
                                        :filename (codeql--uri-to-filename
                                                   (json-pointer-get url "/uri"))
                                        :line (json-pointer-get url "/startLine")
                                        :column (json-pointer-get url "/startColumn")
                                        :visitable t
                                        :url url)))
                            (cl-pushnew node row-data)))
                         ;; node with no location info, but with a label
                         ((and (listp element)
                               (json-pointer-get element "/label"))
                          (let ((node (codeql--result-node-create
                                       :label (json-pointer-get element "/label")
                                       :mark "≔")))
                            (cl-pushnew node row-data)))
                         ;; everything else is a literal node
                         (t
                          (let ((node (codeql--result-node-create
                                       :label element
                                       :mark "≔")))
                            (cl-pushnew node row-data)))))
               ;; represent each tuple as a row of node columns
               (cl-pushnew row-data query-results)))
    query-results))

(defun codeql--raw-results-page-to-org (bqrs-path result-set offsets page page-size &optional style)
  "Return org data for PAGE of RESULT-SET in BQRS-PATH, or nil if empty.

PAGE is 0-based and indexes into the byte OFFSETS vector of pages holding
PAGE-SIZE rows.  When OFFSETS is nil the whole result set is decoded.
STYLE is either `table' (the default) or `outline', see
`codeql-raw-results-style'."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (when-let* ((json-data (codeql--bqrs-to-json
                          bqrs-path "string,url" result-set
                          (when offsets page-size)
                          (when offsets (aref offsets page))))
              (json (json-parse-string json-data :object-type 'alist))
              (tuples (alist-get 'tuples json))
              ((> (length tuples) 0)))
    ;; size the org-table conversion limit by this buffer's page size, which
    ;; may differ from the current `codeql-max-raw-results'
    (let ((codeql-max-raw-results (or (and offsets page-size) codeql-max-raw-results)))
      (codeql--query-results-to-org
       (codeql--raw-tuples-to-query-results tuples)
       (if (eq style 'outline) 'raw-outline 'raw)
       (alist-get 'columns json)
       (if offsets (* page page-size) 0)
       result-set))))

(defun codeql--raw-results-sorted-bqrs (bqrs-path result-set sort)
  "Return a bqrs file holding RESULT-SET of BQRS-PATH sorted by SORT.

SORT is a (COLUMN . DIRECTION) pair with a 0-based COLUMN and a DIRECTION
of either \"asc\" or \"desc\".  Sorted copies are kept next to BQRS-PATH
and reused."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((sorted-path (format "%s.sorted-%s.bqrs" bqrs-path
                             (md5 (format "%s\0%d\0%s" result-set (car sort) (cdr sort))))))
    (if (codeql--file-exists-p sorted-path)
        sorted-path
      (message "Sorting results ...")
      (when (codeql--cli-command-to-string
             (list "bqrs" "decode" "--format=bqrs"
                   (format "--result-set=%s" result-set)
                   (format "--sort-key=%d" (car sort))
                   (format "--sort-direction=%s" (cdr sort))
                   (format "--output=%s" (codeql--tramp-unwrap sorted-path))
                   "--" (codeql--tramp-unwrap bqrs-path)))
        sorted-path))))

(defun codeql--raw-results-setup (bqrs-path result-sets result-set footer &optional sort style)
  "Prepare RESULT-SET of BQRS-PATH for display, optionally sorted by SORT.

RESULT-SETS holds the alists of all result sets in BQRS-PATH as reported
by `codeql bqrs info', and RESULT-SET is the alist of the one to show.
SORT is nil or a (COLUMN . DIRECTION) pair, see
`codeql--raw-results-sorted-bqrs'.  STYLE defaults to
`codeql-raw-results-style'.

Return a cons of the results state, see `codeql--raw-results-pagination',
and the org data of its first page, or nil when there is nothing to show."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let* ((name (alist-get 'name result-set))
         (total-rows (or (alist-get 'rows result-set) 0))
         (decode-path (if sort
                          (or (codeql--raw-results-sorted-bqrs bqrs-path name sort)
                              (user-error "Failed to sort result set %s" name))
                        bqrs-path))
         (offsets
          (when (> total-rows codeql-max-raw-results)
            (when-let ((info (codeql--bqrs-info decode-path codeql-max-raw-results name)))
              (alist-get 'offsets
                         (alist-get 'pagination
                                    (cl-find name (alist-get 'result-sets info)
                                             :key (lambda (rs) (alist-get 'name rs))
                                             :test #'equal))))))
         (offsets (and (> (length offsets) 1) offsets))
         (page-size (if offsets codeql-max-raw-results (max total-rows 1)))
         (style (or style codeql-raw-results-style)))
    (when (and (> total-rows codeql-max-raw-results) (not offsets))
      (message "Could not compute result pagination offsets, rendering all %d rows."
               total-rows))
    (when (> total-rows 0)
      (when-let ((org-data (codeql--raw-results-page-to-org
                            decode-path name offsets 0 page-size style)))
        (cons (list :kind 'raw
                    :source-bqrs-path bqrs-path
                    :bqrs-path decode-path
                    :result-sets result-sets
                    :result-set name
                    :sort sort
                    :offsets offsets
                    :page 0
                    :total-rows total-rows
                    :page-size page-size
                    :style style
                    :footer footer)
              org-data)))))

(defun codeql--raw-results-show-page (page)
  "Render PAGE (0-based) of the paginated results in the current buffer."
  (unless codeql--raw-results-pagination
    (user-error "Not a paginated CodeQL results buffer"))
  (let* ((pagination codeql--raw-results-pagination)
         (pages (codeql--raw-results-pages pagination))
         (query-buffer codeql--org-query-buffer))
    (unless (and (>= page 0) (< page pages))
      (user-error "No such results page: %d (valid pages: 1-%d)" (1+ page) pages))
    (let ((org-data
           (or (codeql--raw-results-cache-get page)
               (progn
                 (unless (buffer-live-p query-buffer)
                   (user-error "The query buffer for these results is no longer live"))
                 (message "Loading results page %d/%d ..." (1+ page) pages)
                 (with-current-buffer query-buffer
                   (if (codeql--sarif-results-p pagination)
                       (let ((page-size (plist-get pagination :page-size)))
                         (codeql--sarif-results-to-org
                          (plist-get pagination :results)
                          (* page page-size) (* (1+ page) page-size)
                          (plist-get pagination :link-prefix)))
                     (codeql--raw-results-page-to-org
                      (plist-get pagination :bqrs-path)
                      (plist-get pagination :result-set)
                      (plist-get pagination :offsets)
                      page
                      (plist-get pagination :page-size)
                      (plist-get pagination :style))))))))
      (unless org-data
        (user-error "Failed to load results page %d" (1+ page)))
      (codeql--raw-results-cache-put page org-data)
      (setq codeql--raw-results-pagination
            (plist-put (copy-sequence pagination) :page page))
      (codeql--raw-results-fill-buffer org-data (codeql--raw-results-pagination-footer))
      (force-mode-line-update)
      (message "Showing results page %d/%d." (1+ page) pages))))

(defun codeql-results-next-page ()
  "Show the next page of CodeQL raw results."
  (interactive)
  (codeql--raw-results-show-page
   (1+ (or (plist-get codeql--raw-results-pagination :page) 0))))

(defun codeql-results-previous-page ()
  "Show the previous page of CodeQL raw results."
  (interactive)
  (codeql--raw-results-show-page
   (1- (or (plist-get codeql--raw-results-pagination :page) 0))))

(defun codeql-results-first-page ()
  "Show the first page of CodeQL raw results."
  (interactive)
  (codeql--raw-results-show-page 0))

(defun codeql-results-last-page ()
  "Show the last page of CodeQL raw results."
  (interactive)
  (codeql--raw-results-show-page
   (1- (codeql--raw-results-pages codeql--raw-results-pagination))))

(defun codeql-results-goto-page (page)
  "Show PAGE (1-based) of CodeQL raw results."
  (interactive
   (progn
     (unless codeql--raw-results-pagination
       (user-error "Not a paginated CodeQL results buffer"))
     (list (read-number
            (format "Results page (1-%d): "
                    (codeql--raw-results-pages codeql--raw-results-pagination))
            (1+ (plist-get codeql--raw-results-pagination :page))))))
  (unless (integerp page)
    (user-error "Results page must be a whole number, not %s" page))
  (codeql--raw-results-show-page (1- page)))

(defun codeql--raw-results-state ()
  "Return the raw results state of the current buffer, or signal a user error."
  (let ((state (or codeql--raw-results-pagination
                   (user-error "Not a CodeQL raw results buffer"))))
    (when (codeql--sarif-results-p state)
      (user-error "Problem results can't be sorted or switched to another result set"))
    state))

(defun codeql--raw-results-column-names (result-set)
  "Return display names for the columns of the RESULT-SET alist."
  (cl-loop for column across (alist-get 'columns result-set)
           for i from 1
           collect (or (alist-get 'name column)
                       (format "column %d (%s)" i (alist-get 'kind column)))))

(defun codeql--raw-results-redisplay (result-set-name sort)
  "Show RESULT-SET-NAME sorted by SORT from the first page in this buffer.

SORT is nil or a (COLUMN . DIRECTION) pair, see
`codeql--raw-results-sorted-bqrs'."
  (let* ((state (codeql--raw-results-state))
         (query-buffer codeql--org-query-buffer)
         (result-set (or (cl-find result-set-name (plist-get state :result-sets)
                                  :key (lambda (rs) (alist-get 'name rs))
                                  :test #'equal)
                         (user-error "No such result set: %s" result-set-name))))
    (when (zerop (or (alist-get 'rows result-set) 0))
      (user-error "Result set %s has no rows" result-set-name))
    (unless (buffer-live-p query-buffer)
      (user-error "The query buffer for these results is no longer live"))
    (let ((setup (with-current-buffer query-buffer
                   (codeql--raw-results-setup
                    (plist-get state :source-bqrs-path)
                    (plist-get state :result-sets)
                    result-set
                    (plist-get state :footer)
                    sort
                    (plist-get state :style)))))
      (unless setup
        (user-error "Failed to load result set %s" result-set-name))
      (setq codeql--raw-results-pagination (car setup)
            codeql--raw-results-page-cache nil)
      (codeql--raw-results-cache-put 0 (cdr setup))
      (codeql--raw-results-fill-buffer (cdr setup) (codeql--raw-results-pagination-footer))
      (force-mode-line-update))))

(defun codeql-results-select-result-set (result-set-name)
  "Show the result set named RESULT-SET-NAME of the current CodeQL results."
  (interactive
   (let* ((state (codeql--raw-results-state))
          (result-sets (plist-get state :result-sets))
          (candidates
           (mapcar (lambda (rs)
                     (cons (format "%s (%d rows)" (alist-get 'name rs) (or (alist-get 'rows rs) 0))
                           (alist-get 'name rs)))
                   result-sets)))
     (when (< (length result-sets) 2)
       (user-error "These results only hold the result set %s"
                   (plist-get state :result-set)))
     (list (cdr (assoc (completing-read "Result set: " candidates nil t) candidates)))))
  (codeql--raw-results-redisplay result-set-name nil)
  (message "Showing result set %s." result-set-name))

(defun codeql-results-sort (column direction)
  "Sort the current CodeQL results by the 0-based COLUMN in DIRECTION.

DIRECTION is either \"asc\" or \"desc\".  When COLUMN is nil, restore the
original order of the results."
  (interactive
   (let* ((state (codeql--raw-results-state))
          (result-set (cl-find (plist-get state :result-set) (plist-get state :result-sets)
                               :key (lambda (rs) (alist-get 'name rs)) :test #'equal))
          (names (codeql--raw-results-column-names result-set))
          (original "(original order)")
          (choice (completing-read "Sort by column: "
                                   (append names (when (plist-get state :sort) (list original)))
                                   nil t))
          (column (unless (equal choice original) (cl-position choice names :test #'equal))))
     (list column
           (when column
             (completing-read "Direction: " '("asc" "desc") nil t nil nil "asc")))))
  (unless (or (null column) (member direction '("asc" "desc")))
    (user-error "Sort direction must be \"asc\" or \"desc\", not %s" direction))
  (codeql--raw-results-redisplay
   (plist-get (codeql--raw-results-state) :result-set)
   (when column (cons column direction)))
  (message (if column "Sorted results by column %d (%s)." "Restored the original order.")
           (and column (1+ column)) direction))

(defun codeql-results-toggle-raw-style ()
  "Show the raw results of this buffer as org headings or as an org table.

Headings can be searched with `codeql-results-org-ql', see
`codeql-raw-results-style'."
  (interactive)
  (let* ((state (or codeql--raw-results-pagination
                    (user-error "Not a CodeQL raw results buffer")))
         (style (if (eq (plist-get state :style) 'outline) 'table 'outline)))
    (when (codeql--sarif-results-p state)
      (user-error "Problem results are always shown as headings"))
    (setq codeql--raw-results-pagination (plist-put (copy-sequence state) :style style)
          codeql--raw-results-page-cache nil)
    (codeql--raw-results-show-page (plist-get state :page))
    (message "Showing raw results as %s." (if (eq style 'outline) "headings" "a table"))))

;;; Searching results with org-ql

(declare-function org-ql-sparse-tree "ext:org-ql-search")
(declare-function org-ql-search "ext:org-ql-search")
(declare-function org-ql--query-string-to-sexp "ext:org-ql")

(defvar codeql--results-org-ql-history nil
  "The history of `codeql-results-org-ql' queries.")

(defun codeql--results-org-ql-query (query)
  "Return the org-ql QUERY limited to the result headings of a results buffer.

QUERY is an org-ql query in sexp form, or a string holding either a sexp
or a query in org-ql's plain string syntax.  An empty QUERY matches all
results."
  (let ((sexp (cond ((not (stringp query)) query)
                    ((string-match-p "\\`[[:space:]]*\\'" query) nil)
                    ((string-match-p "\\`[[:space:]]*[(\"]" query) (car (read-from-string query)))
                    (t (org-ql--query-string-to-sexp query)))))
    `(and (property "CODEQL_KIND" "result") ,@(when sexp (list sexp)))))

(defun codeql-results-org-ql (query &optional view)
  "Search the results of this CodeQL results buffer with the org-ql QUERY.

QUERY is an org-ql query, as a sexp or in org-ql's plain string syntax,
and it only matches results, not the Query Source or the footer.  Each
result is a heading whose properties describe it:

  CODEQL_KIND        always \"result\"
  CODEQL_QUERY_KIND  \"problem\", \"path-problem\" or \"raw\"
  CODEQL_FILE, CODEQL_LINE, CODEQL_COLUMN, CODEQL_END_LINE, CODEQL_END_COLUMN
                     its location, when it has one
  CODEQL_RESULT, CODEQL_RULE_ID, CODEQL_MESSAGE, CODEQL_PATHS
                     of problems
  CODEQL_ROW, CODEQL_RESULT_SET, CODEQL_COL_<COLUMN>
                     of raw results

For example (property \"CODEQL_RULE_ID\" \"js/xss\"), or
\"property:CODEQL_FILE=src/app.js\" in the string syntax.

The matches are shown as a sparse tree of this buffer, so their links
work as usual.  With VIEW (interactively, a prefix argument) they are
listed in an org-ql view buffer instead.  Raw results shown as a table
are switched to headings first, see `codeql-results-toggle-raw-style'.
Only the current page of paginated results is searched.

This needs the org-ql package."
  (interactive
   (progn
     (unless (codeql--results-buffer-p (current-buffer))
       (user-error "Not a CodeQL results buffer"))
     (unless (require 'org-ql nil t)
       (user-error "Searching results needs the org-ql package"))
     (list (read-string "org-ql query on results: " nil 'codeql--results-org-ql-history)
           current-prefix-arg)))
  (unless (codeql--results-buffer-p (current-buffer))
    (user-error "Not a CodeQL results buffer"))
  (unless (and (require 'org-ql nil t) (require 'org-ql-search nil t))
    (user-error "Searching results needs the org-ql package"))
  (let ((query (codeql--results-org-ql-query query)))
    (when (and codeql--raw-results-pagination
               (not (codeql--sarif-results-p codeql--raw-results-pagination))
               (not (eq (plist-get codeql--raw-results-pagination :style) 'outline)))
      (codeql-results-toggle-raw-style))
    (if view
        (org-ql-search (current-buffer) query
                       :title (format "CodeQL results of %s" (buffer-name)))
      (org-ql-sparse-tree query))))

(defvar codeql-results-pagination-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-n") #'codeql-results-next-page)
    (define-key map (kbd "C-c C-p") #'codeql-results-previous-page)
    (define-key map (kbd "C-c C-j") #'codeql-results-goto-page)
    (define-key map (kbd "C-c <") #'codeql-results-first-page)
    (define-key map (kbd "C-c >") #'codeql-results-last-page)
    (define-key map (kbd "C-c C-r") #'codeql-results-select-result-set)
    (define-key map (kbd "C-c C-s") #'codeql-results-sort)
    map)
  "Keymap for `codeql-results-pagination-mode'.")

(define-minor-mode codeql-results-pagination-mode
  "Minor mode for paging, sorting and switching CodeQL raw result sets.

\\{codeql-results-pagination-mode-map}"
  :lighter " CodeQL-Pages"
  :keymap codeql-results-pagination-mode-map
  (if codeql-results-pagination-mode
      (setq-local header-line-format '(:eval (codeql--raw-results-header-line)))
    (kill-local-variable 'header-line-format)))

(defun codeql--print-node (node)
  ;; just for debugging
  (message "--- NODE SNIP START ---")
  (message ":label %s" (codeql--result-node-label node))
  (message ":mark %s" (codeql--result-node-mark node))
  (message ":filename %s" (codeql--result-node-filename node))
  (message ":line %s" (codeql--result-node-line node))
  (message ":visitable %s" (codeql--result-node-visitable node))
  (message ":url %s" (codeql--result-node-url node))
  (message "-- NODE SNIP STOP ---"))

(defun codeql--related-link-to-org-link (related-link related-locations)
  "Turn a SARIF markdown link into an org link."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (cl-destructuring-bind (text id) related-link
    ;; this expects POST processing related-locations, i.e. result nodes
    (cl-loop for node in related-locations
             when (= (codeql--result-node-related-id node) id)
             do (cl-return (codeql--result-node-to-org node text)))))

(defconst codeql--sarif-message-link-regex
  "\\[\\(\\(?:[^][\\]\\|\\\\[][\\]\\)*\\)\\](\\([0-9]+\\))"
  "Regular expression for a [text](id) link in a SARIF message.

Link text may contain escaped brackets and backslashes.")

(defun codeql--unescape-sarif-text (text)
  "Remove the backslash escapes of [, ] and \\ from SARIF message TEXT."
  (replace-regexp-in-string "\\\\\\([][\\]\\)" "\\1" text t))

(defun codeql--parse-sarif-message (message)
  "Split SARIF MESSAGE into its plain text and link components.

Returns a list of unescaped strings and (TEXT ID) lists for [text](id) links.
Brackets and backslashes in messages are escaped with a backslash, so only an
unescaped [ can start a link."
  (let ((components nil)
        (text-start 0)
        (i 0)
        (len (length message)))
    (while (< i len)
      (pcase (aref message i)
        (?\\ (setq i (+ i 2)))
        (?\[
         (if (eq (string-match codeql--sarif-message-link-regex message i) i)
             (progn
               (push (codeql--unescape-sarif-text (substring message text-start i))
                     components)
               (push (list (codeql--unescape-sarif-text (match-string 1 message))
                           (string-to-number (match-string 2 message)))
                     components)
               (setq i (match-end 0)
                     text-start i))
           (setq i (1+ i))))
        (_ (setq i (1+ i)))))
    (push (codeql--unescape-sarif-text (substring message text-start)) components)
    (nreverse components)))

(defun codeql--swap-sarif-links-for-org-links (message related-locations)
  "Render SARIF MESSAGE as org text, turning its [text](id) links into org links."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (mapconcat
   (lambda (component)
     (if (stringp component)
         (codeql--escape-org-description (codeql--printable-text component))
       (or (codeql--related-link-to-org-link component related-locations)
           ;; unresolvable links are shown as their plain text
           (codeql--escape-org-description
            (codeql--printable-text (car component))))))
   (codeql--parse-sarif-message message) ""))

(defun codeql--issue-with-nodes (code-flows locations related-locations message rule-id)
  "Returns an issue node with all its associated nodes out of a SARIF result."
  (codeql--result-node-create
   :label message
   :mark "≔"
   :code-flows
   ;; this returns a list of a list of code-flow paths
   (when code-flows
     (cl-loop for code-flow across code-flows
              for thread-flows = (json-pointer-get code-flow "/threadFlows")
              collect
              (codeql--paths-from-thread-flows thread-flows)))
   :rule-id rule-id
   :locations
   ;; this returns a list of location nodes, of which there should only be 1
   (codeql--nodes-from-locations locations message)
   :related-locations
   ;; this returns a list of related-location nodes, these resolve message links
   (codeql--nodes-from-locations related-locations message)))

(defun codeql--paths-from-thread-flows (thread-flows)
  "Returns all paths out of THREAD-FLOWS."
  ;; collect all paths out of thread-flows
  (cl-loop for thread-flow across thread-flows
           for locations = (json-pointer-get thread-flow "/locations")
           ;; collect a path
           collect
           (codeql--nodes-from-locations locations nil t)))

(defun codeql--nodes-from-locations (locations &optional message is-thread-flow-location)
  "Returns a list of location nodes from result LOCATIONS."
  ;; note, this operates on an array of location objects, this is not the same
  ;; as the top level locations which are passed for a result ...

  ;; collect all path nodes out of locations
  (cl-loop
   ;; if it's a threadFlowLocation, the actual location is nested one deeper
   with prefix             = (if is-thread-flow-location "/location"  "")
   with uri-index          = (format "%s%s" prefix "/physicalLocation/artifactLocation/uri")
   with uri-base-id-index  = (format "%s%s" prefix "/physicalLocation/artifactLocation/uriBaseId")
   with region-index       = (format "%s%s" prefix "/physicalLocation/region")
   with message-index      = (format "%s%s" prefix "/message/text")
   for location across locations
   for i below (length locations)
   for uri                 = (json-pointer-get location uri-index)
   for uri-base-id         = (json-pointer-get location uri-base-id-index)
   for region              = (json-pointer-get location region-index)
   ;; this only exists in relatedLocations nodes
   for related-id          = (json-pointer-get location "/id")
   ;; collect a node in a path
   collect
   (let* ((uri (if uri-base-id
                   (format "file:%s/%s" uri-base-id uri)
                 uri))
          (visitable (not (codeql--empty-location-uri-p uri)))
          ;; without a region a location spans its whole file, which CodeQL
          ;; locations express with all positions 0
          (start-line (if region (json-pointer-get region "/startLine") 0))
          (start-column (if region (or (json-pointer-get region "/startColumn") 1) 0))
          (node
           (codeql--result-node-create
            :label (or (json-pointer-get location message-index) message)
            :mark (if is-thread-flow-location
                      ;; mark as a path node
                      (cond ((eql i 0)
                             ;; source for a flow
                             "src")
                            ((eql i (1- (length locations)))
                             ;; sink for a flow
                             "snk")
                            (t
                             ;; step for a flow
                             "..."))
                    ;; mark as a result node
                    "-->")
            :filename (and visitable (or (codeql--uri-to-filename uri) uri))
            :line start-line
            :column start-column
            :visitable visitable
            :related-id related-id
            ;; build a json alist to parse out for url
            :url `(,(cons 'uri uri)
                   ,(cons 'startLine start-line)
                   ,(cons 'endLine (if region
                                       (or (json-pointer-get region "/endLine")
                                           start-line)
                                     0))
                   ,(cons 'startColumn start-column)
                   ;; SARIF end columns are exclusive, unlike those of CodeQL locations
                   ,(cons 'endColumn (if region
                                         (when-let ((end (json-pointer-get region "/endColumn")))
                                           (1- end))
                                       0))
                   ;; throw these in here just in case they exist and we need them
                   ,(cons 'charOffset (json-pointer-get region "/charOffset"))
                   ,(cons 'charLength (json-pointer-get region "/charLength"))
                   ,(cons 'snippet (json-pointer-get region "/snippet"))))))
     node)))

;; template queries for definitions, references, and AST

(defvar codeql--templated-query-formats
  (list
   ;; updated for library-path relative paths
   :c           "%s.ql"
   :cpp         "%s.ql"
   :java        "%s.ql"
   :cs          "%s.ql"
   :javascript  "%s.ql"
   :python      "%s.ql"
   :ql          "ide-contextual-queries/%s.ql"
   :ruby        "ide-contextual-queries/%s.ql"
   :go          "%s.ql")
  "A format list for finding templated queries by name")

(defun codeql--templated-query-path (language query-name)
  "Return the relative path for a QUERY-NAME of type LANGUAGE."
  (when-let (fmt(plist-get codeql--templated-query-formats language))
    (format fmt query-name)))

(defun codeql--templated-query-paths (language query-name)
  "Return the relative paths where QUERY-NAME of LANGUAGE may be found.

The path of `codeql--templated-query-formats' comes first, followed by
the locations that library packs of other languages or versions use."
  (delete-dups
   (delq nil (list (codeql--templated-query-path language query-name)
                   (format "%s.ql" query-name)
                   (format "ide-contextual-queries/%s.ql" query-name)))))

(defun codeql--archive-path-from-org-filename (filename)
  ;; do a dance to normalize back to the archive root relative path for this filename
  (format "/%s" (cadr
                 (split-string
                  filename
                  (format "%s/*" codeql--database-source-archive-root)))))

(cl-defun codeql--run-templated-query (language query-name src-filename src-buffer
                                                 &optional position)
  "Run the templated QUERY-NAME of LANGUAGE for SRC-FILENAME of SRC-BUFFER.

POSITION is nil, or a (LINE . COLUMN) cons of 1-based positions in
SRC-FILENAME for queries that work on what is found there, like the
printCfg query of `codeql-view-cfg'."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (cl-assert codeql--active-database t)

  (codeql--await-search-paths)
  (cl-loop for query-path in (codeql--templated-query-paths language query-name)
           do
           (cl-loop for search-path in codeql--search-paths-buffer-local
                    for full-path = (format "%s/%s" search-path query-path)
                    when (codeql--file-exists-p full-path) do
                    (message "Resolved templated query %s to %s" query-name full-path)
                    (let* ((archive-path (codeql--archive-path-from-org-filename
                                          (codeql--tramp-unwrap src-filename)))
                           (template-values
                            (cond ((string= codeql-query-server "query-server")
                                   `(:selectedSourceFile
                                     (:values (:tuples [(:stringValue ,archive-path)]))
                                     ,@(when position
                                         `(:selectedSourceLine
                                           (:values (:tuples [(:intValue ,(car position))]))
                                           :selectedSourceColumn
                                           (:values (:tuples [(:intValue ,(cdr position))]))))))
                                  ((string= codeql-query-server "query-server2")
                                   `(:selectedSourceFile
                                     ,archive-path
                                     ,@(when position
                                         `(:selectedSourceLine
                                           ,(number-to-string (car position))
                                           :selectedSourceColumn
                                           ,(number-to-string (cdr position)))))))))
                      (codeql--query-server-run-query-from-path
                       full-path
                       nil
                       template-values
                       src-filename
                       src-buffer))
                    ;; respect search precedence and only run the first find
                    (cl-return-from codeql--run-templated-query)))
  ;; if we did not return, that means we weren't able to find the thing.
  (error "Did not find templated query %s in search paths" query-name))

(defun codeql--database-src-path-p (path)
  (let ((prefix (format "^%s/*" (regexp-quote codeql--database-source-archive-root))))
    (when (string-match-p prefix (codeql--tramp-unwrap path))
      t)))

;; mutual highlighting at point for src/ast buffers

(defvar codeql--ast-to-src-buffer (make-hash-table :test #'equal))
(defvar codeql--src-to-ast-buffer (make-hash-table :test #'equal))

(defvar-local codeql--ast-last-point nil)
(defvar-local codeql--src-last-point nil)

(defvar-local codeql--ast-overlay nil)
(defvar-local codeql--src-overlay nil)

;; not the fastest, but makes life easier for now
(defvar-local codeql--ast-lookup-cache nil)

;; do expensive calc once, then reuse after that
(defun codeql--ast-lookup-cache-init (ast-lookup-vector)
  (message "Building AST lookup cache ... please hold.")
  ;; disable hooks while yolo-ing around with point in src buffer
  (remove-hook 'post-command-hook #'codeql--sync-src-to-ast-overlay :local)
  (setq codeql--ast-lookup-cache
        (cl-loop for ast-def-seq across ast-lookup-vector
                 for i below (length ast-lookup-vector)
                 for src-start-line = (aref ast-def-seq 0)
                 for src-end-line = (aref ast-def-seq 1)
                 for src-start-column = (aref ast-def-seq 2)
                 for src-end-column = (aref ast-def-seq 3)
                 for ast-line = (aref ast-def-seq 4)
                 for lsp-start-point =
                 (codeql--eglot--lsp-position-to-point
                  `(;; align
                    :line ,(1- src-start-line)
                    :character ,(1- src-start-column)))
                 for lsp-end-point =
                 (codeql--eglot--lsp-position-to-point
                  `(;; align
                    :line ,(1- src-end-line)
                    :character ,(1- src-end-column)))
                 collect
                 (vector ast-line lsp-start-point lsp-end-point)))
  (message "AST lookup cache complete ... navigate away.")
  (add-hook 'post-command-hook #'codeql--sync-src-to-ast-overlay 99 :local))

(defun codeql--ast-line-at-src-point (ast-lookup-vector &optional need-ast-buffer)
  (unless codeql--ast-lookup-cache
    (codeql--ast-lookup-cache-init ast-lookup-vector))
  (let ((line-candidates
         ;; we can optimize this much more if we also build a line to candidates index cache
         (cl-loop for ast-def-seq in codeql--ast-lookup-cache
                  for ast-line = (aref ast-def-seq 0)
                  for lsp-start-point = (aref ast-def-seq 1)
                  for lsp-end-point = (aref ast-def-seq 2)
                  when (and (>= (point) lsp-start-point)
                            (<= (point) lsp-end-point))
                  collect (list (- lsp-end-point lsp-start-point) ast-line))))
    ;; renable hook before we do anything else
    (when line-candidates
      (let ((nearest-match (car (sort line-candidates (lambda (a b) (< (car a) (car b)))))))
        (when nearest-match
          (list (cadr nearest-match)
                (when need-ast-buffer
                  (gethash (current-buffer) codeql--src-to-ast-buffer))))))))

(defun codeql--src-point-to-ast-region-highlight (ast-buffer)
  "Return the closest matching AST match available for the thing at src point."
  (when (and (buffer-live-p ast-buffer)
             ;; only do things if ast-buffer is visible and/or focused
             (or (eq ast-buffer (window-buffer (selected-window)))
                 (get-buffer-window ast-buffer)))
    (when-let* ((ast-lookup-vector (gethash (buffer-file-name) codeql--ast-backwards-definitions)))
      (cl-multiple-value-bind (ast-line _) (codeql--ast-line-at-src-point ast-lookup-vector)
        (when (and ast-line (buffer-live-p ast-buffer)
                   ;; only do things if ast-buffer is visible and/or focused
                   (or (eq ast-buffer (window-buffer (selected-window)))
                       (get-buffer-window ast-buffer)))
          (with-current-buffer ast-buffer
            ;; we don't want to save-excursion here
            (widen)
            (cond
             ;; IMPORTANT:
             ;; if we ever do something expensive in our ast buffer hooks
             ;; remember to disable/enable the command hooks them as needed

             ;; we're the focused window for some inexplicable reason
             ((eq ast-buffer (window-buffer (selected-window)))
              (goto-char (point-min)) (forward-line (1- ast-line)) (move-end-of-line nil)
              (recenter))
             ;; we're an unfocused window but visible as expected
             ((get-buffer-window ast-buffer)
              (with-selected-window (get-buffer-window ast-buffer)
                (goto-char (point-min)) (forward-line (1- ast-line)) (move-end-of-line nil)
                (recenter))))
            ;; XXX: I could make this overlay the entire subtree, but that's a little resource hoggy
            (if (overlayp codeql--ast-overlay)
                ;; move overlay if we already have one
                (unless (= (overlay-start codeql--ast-overlay)
                           (line-beginning-position))
                  (move-overlay
                   codeql--ast-overlay
                   (line-beginning-position)
                   (line-end-position)))
              ;; make an overlay if we don't
              (setq codeql--ast-overlay
                    (make-overlay
                     (line-beginning-position)
                     (line-end-position)))
              (overlay-put codeql--ast-overlay 'font-lock-face 'highlight))
            ;; I prefer having a visual ping for each event in the AST
            (pulse-momentary-highlight-one-line (point))))))))

;; XXX: TODO: placeholder
(defun codeql--ast-point-to-src-region-highlight (_src-buffer))

;; post-command hooks that run locally in ast/src buffers
(defun codeql--sync-src-to-ast-overlay ()
  (let ((ast-buffer (gethash (current-buffer) codeql--src-to-ast-buffer)))
    (when (buffer-live-p ast-buffer)
      (unless (= (point) codeql--src-last-point)
        (setq codeql--src-last-point (point))
        ;; do a thing
        (codeql--src-point-to-ast-region-highlight ast-buffer)))))

;; XXX: TODO: I find ast->src less useful than src->ast
;; XXX: but we depend on codeql--ast-last-point being available
;; XXX: so still keep this code around
(defun codeql--sync-ast-to-src-overlay ()
  (let ((src-buffer (gethash (current-buffer) codeql--ast-to-src-buffer)))
    (when (buffer-live-p src-buffer)
      (unless (= (point) codeql--ast-last-point)
        (setq codeql--ast-last-point (point))))))

;; xref backend for our global ref/def caches

(defvar-local codeql--xref-has-bindings nil)

(defun codeql--xref-thing-at-point ()
  "Return the thing at point."
  (let ((current-symbol (symbol-at-point)))
    (when current-symbol
      (symbol-name current-symbol))))

;; not what I meant when I said I was looking for closure :/
(defun codeql--set-local-xref-bindings ()
  (unless codeql--xref-has-bindings
    ;; not every major mode has a <mode>-map, e.g. `fundamental-mode'
    (use-local-map (make-composed-keymap nil (current-local-map)))
    (local-set-key (kbd "M->")
                   ;; hail to the guardians of the watch towers of the west.
                   (lambda (identifier)
                     (interactive (list (codeql--xref-thing-at-point)))
                     (cl-letf (((symbol-value 'xref-backend-functions) (list (lambda () 'codeql-ast))))
                       ;; for AST we generally want a side by side
                       (xref-find-definitions identifier))))
    (local-set-key (kbd "M-.")
                   (lambda (identifier)
                     ;;(interactive (list (xref--read-identifier "Find definitions of: ")))
                     ;; skip the completion crud, since lookups are point/location based
                     (interactive (list (codeql--xref-thing-at-point)))
                     (cl-letf (((symbol-value 'xref-backend-functions) '(codeql-xref-backend)))
                       ;; for actual definitions we want to follow
                       (xref-find-definitions identifier))))
    (local-set-key (kbd "M-?")
                   (lambda (identifier)
                     ;;(interactive (list (xref--read-identifier "Find references of: ")))
                     ;; skip the completion crud, since lookups are point/location based
                     (interactive (list (codeql--xref-thing-at-point)))
                     (cl-letf (((symbol-value 'xref-backend-functions) '(codeql-xref-backend)))
                       (xref-find-references identifier))))
    (local-set-key (kbd "M-,") #'xref-pop-marker-stack)
    ;; add a local post command hook so we can sync to ast region highlights
    (when codeql-ast-sync-highlighting
      (setq codeql--src-last-point (point))
      (add-hook 'post-command-hook #'codeql--sync-src-to-ast-overlay 99 :local))
    ;; source archive files are for browsing only!
    (unless buffer-read-only
      (setq buffer-read-only t))
    (message "Activated CodeQL source archive xref bindings in %s"
             (file-name-nondirectory (buffer-file-name)))
    (setq codeql--xref-has-bindings t)))

(defun codeql-xref-backend ()
  "CodeQL backend for Xref.

This function serves two purposes. You can bind it as a command so that
you have a shortcut to enabling the codeql xref backend for a file you
know is a source archive file, overriding any default major-mode bindings.

It also serves as the xref-backend-functions function. So even if you
don't call this yourself, when you invoke any of the standard xref
functions, this will run and replace any existing xref bindings in
the local buffer when appropriate, i.e. when the buffer is a file inside
a codeql database source archive."
  (interactive)
  (when codeql-enable-xrefs
    (unless (and (buffer-file-name)
                 (file-remote-p (buffer-file-name))
                 (not codeql-enable-remote-xrefs))

      (cond ((or (gethash (buffer-file-name) codeql--references-cache)
                 (gethash (buffer-file-name) codeql--definitions-cache))
             (codeql--set-local-xref-bindings)
             'codeql)
            ((buffer-live-p codeql--org-query-buffer)
             ;; otherwise xrefs are resolved when they are first looked up
             (when codeql-xref-resolve-on-visit
               (message "Cooking up CodeQL xrefs for %s, please hold."
                        (file-name-nondirectory (buffer-file-name)))
               (codeql--xref-resolve "localDefinitions")
               (codeql--xref-resolve "localReferences"))
             ;; we want our bindings available
             (codeql--set-local-xref-bindings)
             'codeql)
            (t (message "No xref cache or query buffer available, xref support deactivated.")
               nil)))))

(defun codeql--xref-cache (query-name)
  "Return the cache that holds the results of templated QUERY-NAME."
  (if (string= query-name "localDefinitions")
      codeql--definitions-cache
    codeql--references-cache))

(defun codeql--xref-resolve (query-name)
  "Run templated QUERY-NAME for the current source file, unless done already.

Returns non-nil if its results are cached or on their way."
  (let ((src-filename (buffer-file-name))
        (src-buffer (current-buffer)))
    (cond ((gethash src-filename (codeql--xref-cache query-name)) t)
          ((gethash (cons src-filename query-name) codeql--xref-pending) t)
          ((buffer-live-p codeql--org-query-buffer)
           (with-current-buffer codeql--org-query-buffer
             (codeql--run-templated-query
              (intern (format ":%s" codeql--active-database-language))
              query-name src-filename src-buffer))
           (puthash (cons src-filename query-name) t codeql--xref-pending)
           t))))

(defun codeql--xref-ensure (query-name)
  "Wait for the results of templated QUERY-NAME for the current source file.

Runs the query when needed, see `codeql-xref-resolve-on-visit', and waits
for at most `codeql-xref-timeout' seconds."
  (let* ((src-filename (buffer-file-name))
         (key (cons src-filename query-name))
         (cache (codeql--xref-cache query-name)))
    (unless (gethash src-filename cache)
      (if (not (codeql--xref-resolve query-name))
          (message "No query buffer available to resolve xrefs for %s."
                   (file-name-nondirectory src-filename))
        (let ((deadline (+ (float-time) codeql-xref-timeout))
              (done nil))
          (message "Resolving CodeQL %s for %s, please hold."
                   (if (eq cache codeql--definitions-cache) "definitions" "references")
                   (file-name-nondirectory src-filename))
          (unwind-protect
              (progn
                (while (and (not (gethash src-filename cache))
                            (< (float-time) deadline))
                  (accept-process-output nil 0.05))
                (setq done t))
            ;; let a failed, timed out or interrupted query be run again
            (unless (and done (gethash src-filename cache))
              (remhash key codeql--xref-pending)))
          (unless (gethash src-filename cache)
            (message "Timed out resolving CodeQL xrefs for %s."
                     (file-name-nondirectory src-filename))))))))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql codeql)))
  "Return the thing at point."
  ;; we get away with this because really our codeql xref lookups are based on position
  (codeql--xref-thing-at-point))

;; implement a special backend definition just for AST definitions
(cl-defmethod xref-backend-definitions ((_backend (eql codeql-ast)) _symbol)
  "Show any AST definitions available for the thing at point."
  (if-let ((ast-lookup-vector (gethash (buffer-file-name) codeql--ast-backwards-definitions)))
      (cl-multiple-value-bind (ast-line ast-buffer) (codeql--ast-line-at-src-point ast-lookup-vector t)
        ;; sort the candidates by diff and return the closest match as an xref
        (if (and ast-line ast-buffer (buffer-live-p ast-buffer))
            (list
             (xref-make "[AST] show thing-at-point in AST buffer."
                        (xref-make-buffer-location
                         ast-buffer
                         (save-excursion
                           (with-current-buffer ast-buffer
                             (goto-char (point-min)) (forward-line (1- ast-line)) (move-end-of-line nil)
                             (pulse-momentary-highlight-one-line (point))
                             (point))))))
          ;; buffer must have disappeared, yank it from the cache
          (remhash (buffer-file-name) codeql--ast-backwards-definitions) nil
          (error "No AST buffer available! Please M-x codeql-view-ast on the source buffer.")))
    (error "No AST buffer available yet! Please M-x codeql-view-ast on the source buffer.")))

(cl-defmethod xref-backend-definitions ((_backend (eql codeql)) _symbol)
  "Get known definitions for location at point."
  (codeql--xref-ensure "localDefinitions")
  (cl-multiple-value-bind (json src-root) (gethash (buffer-file-name) codeql--definitions-cache)
    ;; re-parsing the json for every definition is terribly inefficient
    ;; so once this works, move into more performant datastructures
    (when (and json src-root)
      (cl-loop with tuples = (json-pointer-get json "/#select/tuples")
               for tuple across tuples
               for src = (seq-elt tuple 0)
               for dst = (seq-elt tuple 1)
               for src-start-line = (json-pointer-get src "/url/startLine")
               for src-start-column = (or (json-pointer-get src "/url/startColumn") 1)
               for src-end-column = (json-pointer-get src "/url/endColumn")
               for filename = (format "%s%s" src-root (codeql--uri-to-filename (json-pointer-get dst "/url/uri")))
               for dst-line = (json-pointer-get dst "/url/startLine")
               for dst-column = (json-pointer-get dst "/url/startColumn")
               for dst-desc = (json-pointer-get dst "/label")
               when
               ;; columns in emacs are 0-based, columns in codeql are 1 based
               ;; columns in codeql are utf-16 code points, not visual column
               (let ((point-line (line-number-at-pos))
                     (point-column (codeql--lsp-abiding-column)))
                 (and (eql src-start-line point-line)
                      (>= point-column src-start-column)
                      (<= point-column src-end-column)))
               ;; if point is at a ref that we know about, collect the def
               collect
               (xref-make dst-desc (xref-make-file-location
                                    (codeql--tramp-wrap filename)
                                    dst-line (1- dst-column)))))))

(cl-defmethod xref-backend-references ((_backend (eql codeql)) _symbol)
  "Get known references for location at point."
  (codeql--xref-ensure "localReferences")
  (cl-multiple-value-bind (json src-root) (gethash (buffer-file-name) codeql--references-cache)
    (when (and json src-root)
      (cl-loop with tuples = (json-pointer-get json "/#select/tuples")
               for tuple across tuples
               for src = (seq-elt tuple 0)
               for dst = (seq-elt tuple 1)
               for dst-start-line = (json-pointer-get dst "/url/startLine")
               for dst-start-column = (json-pointer-get dst "/url/startColumn")
               for dst-end-column = (json-pointer-get dst "/url/endColumn")
               for filename = (format "%s%s" src-root (codeql--uri-to-filename (json-pointer-get src "/url/uri")))
               for src-line = (json-pointer-get src "/url/startLine")
               for src-column = (json-pointer-get src "/url/startColumn")
               for src-desc = (json-pointer-get src "/label")
               when
               ;; columns in emacs are 0-based, columns in codeql are 1 based
               ;; columns in codeql are utf-16 code points, not visual column
               (let ((point-line (line-number-at-pos))
                     (point-column (codeql--lsp-abiding-column)))
                 (and (eql dst-start-line point-line)
                      (>= point-column dst-start-column)
                      (<= point-column dst-end-column)))
               ;; if point is at a def that we know about, collect the ref
               collect
               (xref-make src-desc (xref-make-file-location
                                    (codeql--tramp-wrap filename)
                                    src-line (1- src-column)))))))

;; XXX: TODO
(cl-defmethod xref-backend-apropos ((_backend (eql codeql)) _symbol)
  nil)

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql codeql)))
  "Return a completion list for identifiers.

Our implementation simply returns the thing at point as a candidate."
  ;; just do a dumb thing at point for now so there's not really any completions
  ;; below is what most folks do for this kind of thing, but I don't think we need it.
  ;; (let (words)
  ;;   (save-excursion
  ;;     (save-restriction
  ;;       (widen)
  ;;       (goto-char (point-min))
  ;;       (while (re-search-forward "\\w+" nil t)
  ;;         (add-to-list 'words (match-string-no-properties 0)))
  ;;       (seq-uniq words))))
  (list (codeql--xref-thing-at-point)))

(add-to-list 'xref-backend-functions #'codeql-xref-backend)

;; custom org link so we can do voodoo when C-c C-o on a codeql: link
(defvar codeql--find-file-same-window nil
  "Non-nil to have `codeql--find-file-other-window' use the selected window.")

(defun codeql--find-file-other-window (filename &optional wildcards)
  (interactive
   (find-file-read-args "Find file in other window: "
                        (confirm-nonexistent-file-or-buffer)))
  ;; disable eglot-ensure
  (cl-letf (((symbol-function #'eglot-ensure)
             (lambda ()
               (message "Disabled eglot for codeql org link."))))
    (let ((value (let ((codeql--inhibit-lsp t))
                   (find-file-noselect filename nil nil wildcards)))
          (show (if codeql--find-file-same-window
                    #'pop-to-buffer-same-window
                  #'switch-to-buffer-other-window)))
      (if (listp value)
	  (progn
	    (setq value (nreverse value))
            ;; prevent folks from editing database source code
            (with-current-buffer (car value)
              (setq buffer-read-only t))
	    (funcall show (car value))
            (mapc (lambda (buf)
                    (with-current-buffer buf
                      (setq buffer-read-only t))
                    (switch-to-buffer buf))
                  (cdr value))
	    value)
        ;; prevent folks from editing database source code
        (with-current-buffer value
          (setq buffer-read-only t))
        (funcall show value)))))

(defun codeql--parse-link-location (link)
  "Parse the path of a codeql: LINK into a list of its location parts.

The list is (FILENAME LINE COLUMN END-LINE END-COLUMN).  Links look like
FILENAME::LINE:COLUMN, optionally followed by :END-LINE:END-COLUMN.
Positions are 1-based and inclusive like those of CodeQL locations, they
are nil when LINK doesn't have them."
  (if (string-match
       "\\`\\(.*\\)::\\([0-9]+\\):\\([0-9]+\\)\\(?::\\([0-9]+\\):\\([0-9]+\\)\\)?\\'" link)
      (cons (codeql--decode-link-path (match-string 1 link))
            (mapcar (lambda (group)
                      (when-let ((n (match-string group link)))
                        (string-to-number n)))
                    '(2 3 4 5)))
    (list (codeql--decode-link-path (car (split-string link "::"))) nil nil nil nil)))

(defun codeql--highlight-location (beg end)
  "Highlight the visited location from BEG to END in the current buffer.

See `codeql-highlight-visited-location'."
  (when (< beg end)
    (pcase codeql-highlight-visited-location
      ('pulse
       ;; a freshly visited file may not have been displayed yet, and the
       ;; pulse could fade out before its window is first drawn
       (let ((beg (copy-marker beg)) (end (copy-marker end)))
         (run-with-idle-timer
          0 nil
          (lambda ()
            (run-with-timer
             codeql-pulse-delay nil
             (lambda ()
               (when (buffer-live-p (marker-buffer beg))
                 (with-current-buffer (marker-buffer beg)
                   ;; the pulse fades out in `pulse-iterations' steps
                   (let ((pulse-delay (/ (float codeql-pulse-duration)
                                         (max 1 pulse-iterations))))
                     (pulse-momentary-highlight-region beg end))))
               (set-marker beg nil)
               (set-marker end nil)))))))
      ('region
       (push-mark end t t)
       (goto-char beg)))))

(defun codeql--org-open-file-link (link)
  (pcase-let ((`(,filename ,line ,column ,end-line ,end-column)
               (codeql--parse-link-location link)))

    ;; XXX: hrmmm ... we probably want to force unique file visits
    ;; XXX: since we don't want to use a cross-query state when there
    ;; XXX: concurrent query buffers operating on the same database
    ;; XXX: although this re-associates to the correct query buffer
    ;; XXX: pending which results are being navigated, so this is
    ;; XXX: probably ok in practice

    ;; results saved before empty locations got rendered as plain text
    (when (directory-name-p filename)
      (user-error "This location has no source file"))
    ;; rather than visiting a new empty file
    (unless (or (file-exists-p filename)
                ;; the sources of variant analysis results, see `codeql-mrva'
                (codeql--permalink-fetch-file filename (codeql--results-permalink-info)))
      (user-error "Source file not found: %s" filename))

    (codeql--alerts-note-visit link)
    (let* ((query-buffer codeql--org-query-buffer)
           (permalink-info (codeql--results-permalink-info))
           ;; results loaded from a SARIF file may point at a source
           ;; checkout instead, see `codeql-load-sarif'
           (database-file-p (or (not (buffer-live-p query-buffer))
                                (with-current-buffer query-buffer
                                  (and codeql--database-source-archive-root
                                       (codeql--database-src-path-p filename))))))
      (when-let ((src-buffer (codeql--find-file-other-window filename)))
        (with-current-buffer src-buffer
          ;; this will be nil for org history, which means we lose any
          ;; dynamic xref capabilities and things of that nature ...
          ;; we could restore the state for the org-file on find-file
          ;; but that's making the assumption that the active database
          ;; is still related to the query history I suppose?
          (unless query-buffer
            (message "No active query buffer for these results, opened from history?"))
          (when database-file-p
            (setq codeql--org-query-buffer query-buffer))
          (when permalink-info
            (setq codeql--permalink-info permalink-info))
          (widen)
          ;; codeql is 1 based, eglot calcs are 0 based, adjust accordingly,
          ;; line 0 is a location spanning the whole file
          (if (not (and line column (> line 0)))
              (goto-char (point-min))
            (goto-char (codeql--eglot--lsp-position-to-point
                        `(;; align
                          :line ,(1- line)
                          :character ,(1- column))))
            (when (and end-line end-column)
              (codeql--highlight-location
               (point)
               ;; an inclusive 1-based end column is an exclusive 0-based one
               (codeql--eglot--lsp-position-to-point
                `(:line ,(1- end-line) :character ,end-column)))))
          ;; enable our xref backend, this kicks in templated queries for refs and defs
          (when database-file-p
            (codeql-xref-backend)))))))

(with-eval-after-load 'ol
  (org-link-set-parameters "codeql" :follow #'codeql--org-open-file-link))

;;; Jumping to result locations, with optional consult and embark support

(declare-function consult--read "ext:consult")
(declare-function consult--temporary-files "ext:consult")
(declare-function consult--jump-preview "ext:consult")
(declare-function consult--lookup-member "ext:consult")
(defvar embark-target-finders)
(defvar embark-keymap-alist)

(defconst codeql--org-link-regexp
  "\\[\\[codeql:\\([^]]+\\)\\]\\(?:\\[\\([^]]*\\)\\]\\)?\\]"
  "Regexp matching a codeql: org link, with its path and description as groups.")

(defun codeql--location-line-context (line)
  "Return the text of a results buffer LINE, with links as their descriptions."
  (let ((text (replace-regexp-in-string
               codeql--org-link-regexp
               (lambda (link)
                 (or (match-string 2 link) ""))
               line t t)))
    (setq text (replace-regexp-in-string "\u200b" "" text t t))
    (setq text (replace-regexp-in-string "\\`\\*+ +\\|\\`[ \t]*\\(?:[-+]\\|[0-9]+[.)]\\) +" "" text))
    (setq text (replace-regexp-in-string "[ \t]*|[ \t|]*" "  " text))
    (string-trim (replace-regexp-in-string "[ \t]\\{3,\\}" "  " text))))

(defun codeql--results-location-candidates ()
  "Return a completion candidate for each codeql: link in the current buffer.

A candidate looks like FILE:LINE:COLUMN followed by the text of the line
the link is on, and by the description of the link when the line has more
than one.  FILE is relative to the directory that all locations share.  A
candidate has the `codeql-link' and `codeql-results-buffer' properties,
and `codeql-file' holding the length of its FILE part."
  (let ((buffer (current-buffer))
        (seen (make-hash-table :test #'equal))
        links candidates)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward codeql--org-link-regexp nil t)
          (let ((link (match-string-no-properties 1))
                (description (match-string-no-properties 2))
                (line (buffer-substring-no-properties (line-beginning-position)
                                                      (line-end-position))))
            (push (list link description line
                        (car (codeql--parse-link-location link)))
                  links)))))
    (setq links (seq-remove (lambda (link) (directory-name-p (nth 3 link)))
                            (nreverse links)))
    (let* ((files (delete-dups (mapcar (lambda (link) (nth 3 link)) links)))
           (prefix (if (cdr files)
                       (file-name-directory (try-completion "" files))
                     (and files (file-name-directory (car files))))))
      (pcase-dolist (`(,link ,description ,line ,filename) links)
        (pcase-let* ((`(,_ ,line-number ,column) (codeql--parse-link-location link))
                     (file (if (and prefix (string-prefix-p prefix filename))
                               (substring filename (length prefix))
                             filename))
                     (context (codeql--location-line-context line))
                     (several (> (length (split-string line "\\[\\[codeql:")) 2))
                     (cand (format "%s:%s:%s  %s%s"
                                   file (or line-number 0) (or column 0)
                                   (if (and several description)
                                       (concat (replace-regexp-in-string
                                                "\u200b" "" description t t)
                                               ": ")
                                     "")
                                   context)))
          (unless (gethash cand seen)
            (puthash cand t seen)
            (add-text-properties 0 (length cand)
                                 `(codeql-link ,link
                                   codeql-results-buffer ,buffer
                                   codeql-file ,(length file))
                                 cand)
            (when (facep 'consult-file)
              (add-face-text-property 0 (length file) 'consult-file nil cand))
            (push cand candidates)))))
    (nreverse candidates)))

(defvar codeql--location-candidates (make-hash-table :test #'equal)
  "The candidates of the last `codeql-results-goto-location', by their text.

Completion UIs and embark don't always keep the text properties of a
candidate, so its location is looked up here as well.")

(defun codeql--location-candidate-link (cand)
  "Return the codeql: link path and results buffer of the location CAND.

CAND is a candidate of `codeql-results-goto-location', or a codeql: org link."
  (cond ((and (stringp cand) (get-text-property 0 'codeql-link cand))
         (cons (get-text-property 0 'codeql-link cand)
               (get-text-property 0 'codeql-results-buffer cand)))
        ((and (stringp cand) (gethash (substring-no-properties cand) codeql--location-candidates)))
        ((and (stringp cand) (string-match "\\`\\(?:\\[\\[\\)?codeql:\\([^]]+\\)" cand))
         (cons (match-string 1 cand) (current-buffer)))))

(defun codeql--location-preview-position (cand open)
  "Return the consult preview position of the location CAND.

The file of CAND is opened with OPEN.  The position is a marker, along
with the span of the location on its first line."
  (when-let* ((location (car (codeql--location-candidate-link cand))))
    (pcase-let ((`(,filename ,line ,column ,end-line ,end-column)
                 (codeql--parse-link-location location)))
      (when-let* (((file-exists-p filename))
                  (buffer (funcall open filename)))
        (with-current-buffer buffer
          (save-restriction
            (widen)
            (if (not (and line column (> line 0)))
                (cons (copy-marker (point-min)) nil)
              (let* ((start (codeql--eglot--lsp-position-to-point
                             `(:line ,(1- line) :character ,(1- column))))
                     (end (if (and end-line end-column)
                              (codeql--eglot--lsp-position-to-point
                               `(:line ,(1- end-line) :character ,end-column))
                            start))
                     (end (min end (save-excursion (goto-char start) (line-end-position)))))
                (cons (copy-marker start)
                      (when (< start end)
                        (list (cons 0 (- end start)))))))))))))

(defun codeql--location-consult-state ()
  "Return a consult state function that previews the location candidates."
  (let ((open (consult--temporary-files))
        (preview (consult--jump-preview)))
    (lambda (action cand)
      (unless cand
        (funcall open))
      (funcall preview action
               (and cand (eq action 'preview)
                    (codeql--location-preview-position cand open))))))

(defun codeql--location-group (cand transform)
  "Return the file of the location CAND, or CAND without it if TRANSFORM.

This groups the candidates of `codeql-results-goto-location' by file."
  (let ((file-length (or (get-text-property 0 'codeql-file cand)
                         (string-match-p ":[0-9]+:[0-9]+  " cand)
                         0)))
    (if transform
        (substring cand (min (length cand) (1+ file-length)))
      (substring cand 0 file-length))))

(defun codeql-location-open (cand)
  "Visit the result location CAND, like following its codeql: org link."
  (interactive (list (codeql--read-results-location)))
  (pcase-let ((`(,link . ,buffer) (or (codeql--location-candidate-link cand)
                                      (user-error "Not a result location: %s" cand))))
    (with-current-buffer (if (buffer-live-p buffer) buffer (current-buffer))
      (codeql--org-open-file-link link))))

(defun codeql-location-copy (cand)
  "Copy the result location CAND as FILE:LINE:COLUMN to the kill ring."
  (interactive (list (codeql--read-results-location)))
  (pcase-let* ((`(,link . ,_) (or (codeql--location-candidate-link cand)
                                  (user-error "Not a result location: %s" cand)))
               (`(,filename ,line ,column) (codeql--parse-link-location link))
               (text (if (and line (> line 0))
                         (format "%s:%s:%s" filename line column)
                       filename)))
    (kill-new text)
    (message "Copied %s" text)))

(defun codeql--read-results-location ()
  "Read one of the result locations in the current buffer."
  (let ((candidates (or (codeql--results-location-candidates)
                        (user-error "No result locations in this buffer"))))
    (clrhash codeql--location-candidates)
    (dolist (cand candidates)
      (puthash (substring-no-properties cand)
               (cons (get-text-property 0 'codeql-link cand)
                     (get-text-property 0 'codeql-results-buffer cand))
               codeql--location-candidates))
    (if (require 'consult nil t)
        (consult--read candidates
                       :prompt "Go to result location: "
                       :category 'codeql-location
                       :require-match t
                       :sort nil
                       :group #'codeql--location-group
                       :lookup #'consult--lookup-member
                       :state (codeql--location-consult-state))
      (let ((cand (completing-read
                   "Go to result location: "
                   (lambda (string predicate action)
                     (if (eq action 'metadata)
                         '(metadata (category . codeql-location)
                                    (display-sort-function . identity))
                       (complete-with-action action candidates string predicate)))
                   nil t)))
        (or (seq-find (lambda (candidate) (string= candidate cand)) candidates)
            cand)))))

(defun codeql-results-goto-location ()
  "Go to one of the result locations in the current results buffer.

The locations are offered for completion along with the text they appear
in.  With consult installed, they are grouped by file and previewed as
you move between them.  The chosen location is visited like following
its codeql: org link."
  (interactive)
  (codeql-location-open (codeql--read-results-location)))

(defun codeql-embark-target-location ()
  "Return the codeql: org link at point as an embark target."
  (when (and (derived-mode-p 'org-mode) (not (use-region-p)))
    (let ((pos (point)))
      (save-excursion
        (beginning-of-line)
        (catch 'found
          (while (re-search-forward codeql--org-link-regexp (line-end-position) t)
            (when (and (<= (match-beginning 0) pos) (< pos (match-end 0)))
              (throw 'found
                     `(codeql-location
                       ,(concat "codeql:" (match-string-no-properties 1))
                       ,(match-beginning 0) . ,(match-end 0)))))
          nil)))))

(defvar codeql-location-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'codeql-location-open)
    (define-key map (kbd "o") #'codeql-location-open)
    (define-key map (kbd "w") #'codeql-location-copy)
    map)
  "Embark actions for CodeQL result locations.")

(with-eval-after-load 'embark
  (add-to-list 'embark-target-finders #'codeql-embark-target-location)
  (add-to-list 'embark-keymap-alist '(codeql-location . codeql-location-map)))

;;; Flymake diagnostics for the locations in a results buffer

(defvar codeql-results-diagnostics-mode)

(defvar codeql--diagnostics-results-buffers nil
  "Results buffers in which `codeql-results-diagnostics-mode' is enabled.")

(defvar-local codeql--results-diagnostics nil
  "Hash table of the locations in a results buffer, keyed by file name.

Its values are lists of (LINE COLUMN END-LINE END-COLUMN TYPE TEXT)
entries, see `codeql--parse-link-location' for the positions.")

(defvar-local codeql--diagnostics-enabled-flymake nil
  "Non-nil if `flymake-mode' was enabled to show results diagnostics.")

(defun codeql--diagnostics-file-key (file)
  "Return the key that FILE is stored under in `codeql--results-diagnostics'."
  (expand-file-name file))

(defun codeql--diagnostics-text (text)
  "Return org TEXT as plain text, with links replaced by their descriptions."
  (codeql--require-org)
  (string-trim
   (replace-regexp-in-string
    "[ \t]+" " "
    (replace-regexp-in-string
     "\u200b" ""
     (replace-regexp-in-string
      org-link-bracket-re
      (lambda (link) (or (match-string 2 link) (match-string 1 link)))
      text t t)
     t t))))

(defun codeql--diagnostics-location-text (text)
  "Return org TEXT as plain text, without a trailing FILE:LINE:COLUMN.

Whole file locations are shown as just their FILE after \"... \"."
  (replace-regexp-in-string
   " *\\(?:\\(?:\\.\\.\\. \\)?[^ ]+:[0-9]+:[0-9]+\\|\\.\\.\\. [^ ]+\\)\\'" ""
   (codeql--diagnostics-text text) t t))

(defun codeql--diagnostics-problem-text (heading)
  "Return the message of the problem described by an org HEADING line."
  (replace-regexp-in-string
   "\\`[^][:alnum:][]+ +" ""
   (codeql--diagnostics-location-text
    (replace-regexp-in-string "\\`\\*+ +" "" heading t t))
   t t))

(defun codeql--diagnostics-table-header ()
  "Return the column names of the org table at point, or nil if it has none."
  (codeql--require-org)
  (save-excursion
    (goto-char (org-table-begin))
    (when (looking-at-p "[ \t]*|-")
      (forward-line 1)
      (let ((header (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
        (forward-line 1)
        (when (looking-at-p "[ \t]*|-")
          (mapcar #'codeql--diagnostics-text
                  (split-string (string-trim header "[ \t]*|" "|[ \t]*") "|")))))))

(defun codeql--diagnostics-table-row-text (header)
  "Describe the org table row at point, using the column names in HEADER."
  (let ((cells (mapcar #'codeql--diagnostics-text
                       (split-string
                        (string-trim (buffer-substring-no-properties
                                      (line-beginning-position) (line-end-position))
                                     "[ \t]*|" "|[ \t]*")
                        "|"))))
    (mapconcat #'identity
               (cl-loop for cell in cells
                        for i from 0
                        for name = (nth i header)
                        collect (if (and name (not (string-empty-p name)))
                                    (format "%s: %s" name cell)
                                  cell))
               ", ")))

(defun codeql--diagnostics-collect ()
  "Return the locations of the codeql: links in the current results buffer.

The result is a hash table as described in `codeql--results-diagnostics'.
The locations of raw result rows and of problem results are `:warning'
diagnostics, path steps and related locations are `:note' diagnostics."
  (codeql--require-org)
  (let ((diagnostics (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        (header-cache nil))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward org-link-bracket-re nil t)
          (let ((link (org-link-unescape (match-string-no-properties 1)))
                (description (or (match-string-no-properties 2) ""))
                (link-end (match-end 0)))
            (when (string-prefix-p "codeql:" link)
              (pcase-let*
                  ((`(,file ,line ,column ,end-line ,end-column)
                    (codeql--parse-link-location (substring link (length "codeql:"))))
                   (line-text (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position)))
                   (`(,type ,text)
                    (cond
                     ;; a row of a raw results table
                     ((org-at-table-p)
                      (let ((table (org-table-begin)))
                        (unless (eq (car header-cache) table)
                          (setq header-cache
                                (cons table (codeql--diagnostics-table-header))))
                        (list :warning (codeql--diagnostics-table-row-text
                                        (cdr header-cache)))))
                     ;; a row of raw results shown as a heading
                     ((and (string-match-p "\\`\\*+ " line-text)
                           (eq (codeql--results-heading-kind) 'row))
                      (list :warning (codeql--diagnostics-text
                                      (replace-regexp-in-string
                                       "\\`\\*+ +[0-9]+\\. +" "" line-text t t))))
                     ;; a problem heading, its last link is the problem location
                     ((string-match-p "\\`\\*+ " line-text)
                      (let ((message (codeql--diagnostics-problem-text line-text)))
                        (if (save-excursion
                              (goto-char link-end)
                              (re-search-forward org-link-bracket-re
                                                 (line-end-position) t))
                            (list :note (format "Related location \"%s\" of: %s"
                                                (codeql--diagnostics-text description)
                                                message))
                          (list :warning message))))
                     ;; a step of a path, or some other location
                     (t
                      (list :note (concat "Path step "
                                          (codeql--diagnostics-location-text line-text))))))
                   (entry (list line column end-line end-column type text))
                   (key (codeql--diagnostics-file-key file)))
                (when (and line (not (gethash (cons key entry) seen)))
                  (puthash (cons key entry) t seen)
                  (push entry (gethash key diagnostics)))))
            (goto-char link-end)))))
    diagnostics))

(defun codeql--diagnostics-region (line column end-line end-column)
  "Return the (BEG . END) region of a CodeQL location in the current buffer."
  (let ((beg (and column (> line 0)
                  (codeql--eglot--lsp-position-to-point
                   `(:line ,(1- line) :character ,(max 0 (1- column))))))
        (end (and end-line end-column (> end-line 0)
                  (codeql--eglot--lsp-position-to-point
                   `(:line ,(1- end-line) :character ,end-column)))))
    (if (and beg end (< beg end))
        (cons beg end)
      ;; whole file locations have line 0, otherwise guess the extent
      (flymake-diag-region (current-buffer) (max 1 line) (and (> line 0) column)))))

(defun codeql--flymake-backend (report-fn &rest _args)
  "Flymake backend reporting the locations of results buffers to REPORT-FN.

See `codeql-results-diagnostics-mode'."
  (funcall
   report-fn
   (when buffer-file-name
     (let ((key (codeql--diagnostics-file-key buffer-file-name))
           (source (current-buffer)))
       (cl-loop
        for results in codeql--diagnostics-results-buffers
        when (buffer-live-p results)
        nconc
        (cl-loop
         with marker = (buffer-name results)
         for (line column end-line end-column type text)
         in (gethash key (buffer-local-value 'codeql--results-diagnostics results))
         for region = (codeql--diagnostics-region line column end-line end-column)
         when region
         collect (flymake-make-diagnostic
                  source (car region) (cdr region) type
                  (format "%s [%s]" text (string-trim marker "[* ]+" "[* ]+")))))))))

;; it only reports the locations of results buffers, so it's safe to run on
;; source archive files, which newer Flymake treats as untrusted content
(put 'codeql--flymake-backend 'flymake-always-safe t)

(defun codeql--diagnostics-wanted-p ()
  "Return non-nil if a results buffer has diagnostics for the current buffer."
  (when buffer-file-name
    (let ((key (codeql--diagnostics-file-key buffer-file-name)))
      (cl-some (lambda (results)
                 (and (buffer-live-p results)
                      (gethash key (buffer-local-value 'codeql--results-diagnostics
                                                       results))))
               codeql--diagnostics-results-buffers))))

(defun codeql--diagnostics-refresh-buffer ()
  "Show or clear results diagnostics in the current file buffer."
  (let ((wanted (codeql--diagnostics-wanted-p))
        (active (memq #'codeql--flymake-backend flymake-diagnostic-functions)))
    (cond
     (wanted
      (unless active
        (if flymake-mode
            (add-hook 'flymake-diagnostic-functions #'codeql--flymake-backend nil t)
          ;; the database source archive needs no other checkers
          (setq-local flymake-diagnostic-functions (list #'codeql--flymake-backend))
          (setq codeql--diagnostics-enabled-flymake t)
          (flymake-mode 1)))
      (flymake-start))
     (active
      (if codeql--diagnostics-enabled-flymake
          (progn
            (flymake-mode -1)
            (kill-local-variable 'flymake-diagnostic-functions)
            (setq codeql--diagnostics-enabled-flymake nil))
        ;; report nothing before letting go of the backend
        (when flymake-mode
          (flymake-start))
        (remove-hook 'flymake-diagnostic-functions #'codeql--flymake-backend t))))))

(defun codeql--diagnostics-refresh ()
  "Update the results diagnostics of all file buffers."
  (setq codeql--diagnostics-results-buffers
        (seq-filter #'buffer-live-p codeql--diagnostics-results-buffers))
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'buffer-file-name buffer)
      (with-current-buffer buffer
        (codeql--diagnostics-refresh-buffer)))))

(defun codeql--diagnostics-find-file ()
  "Show the diagnostics of results buffers in a newly visited file."
  (when codeql--diagnostics-results-buffers
    (codeql--diagnostics-refresh-buffer)))

(add-hook 'find-file-hook #'codeql--diagnostics-find-file)

(defun codeql--diagnostics-results-changed ()
  "Recollect the diagnostics of the current results buffer, if it shows them."
  (when codeql-results-diagnostics-mode
    (setq codeql--results-diagnostics (codeql--diagnostics-collect))
    (codeql--diagnostics-refresh)))

(defun codeql--diagnostics-results-killed ()
  "Clear the diagnostics of the current results buffer as it is killed."
  (when codeql-results-diagnostics-mode
    (setq codeql--diagnostics-results-buffers
          (delq (current-buffer) codeql--diagnostics-results-buffers))
    (setq codeql--results-diagnostics nil)
    (codeql--diagnostics-refresh)))

(define-minor-mode codeql-results-diagnostics-mode
  "Show the locations of a CodeQL results buffer as Flymake diagnostics.

The locations linked from the results buffer are underlined in the
database source files they point into, and listed by
`flymake-show-buffer-diagnostics'.  Raw result rows and problem
locations are warnings, path steps and related locations are notes.
Paginated results only show the locations of the current page.

See also `codeql-results-diagnostics'."
  :lighter " CodeQL-Diag"
  (cond
   ((not (derived-mode-p 'codeql-results-mode))
    (setq codeql-results-diagnostics-mode nil)
    (user-error "Not a CodeQL results buffer"))
   (codeql-results-diagnostics-mode
    (setq codeql--results-diagnostics (codeql--diagnostics-collect))
    (cl-pushnew (current-buffer) codeql--diagnostics-results-buffers)
    (add-hook 'kill-buffer-hook #'codeql--diagnostics-results-killed nil t)
    (codeql--diagnostics-refresh)
    (let ((count (cl-loop for entries being the hash-values of codeql--results-diagnostics
                          sum (length entries))))
      (message "Showing %d result location%s in %d file%s." count (if (= count 1) "" "s")
               (hash-table-count codeql--results-diagnostics)
               (if (= (hash-table-count codeql--results-diagnostics) 1) "" "s"))))
   (t
    (remove-hook 'kill-buffer-hook #'codeql--diagnostics-results-killed t)
    (setq codeql--diagnostics-results-buffers
          (delq (current-buffer) codeql--diagnostics-results-buffers))
    (setq codeql--results-diagnostics nil)
    (codeql--diagnostics-refresh))))

;;; Navigating between alerts and their locations

(cl-defstruct (codeql--alert (:constructor codeql--alert-create)
                             (:copier nil))
  "An alert of a results buffer: a problem, or a row of a raw results table.

START and END delimit it in the results buffer and MESSAGE describes it.
LOCATIONS is a vector of (LINK DESCRIPTION POSITION) entries, holding the
path of a codeql: link, its description, and where it is in the results
buffer.  The location of the alert comes first, followed by its related
locations and path steps in the order they are listed."
  start end message locations)

(defvar-local codeql--results-alerts-cache nil
  "The alerts of a results buffer, as (MODIFICATION-TICK . ALERTS).")

(defvar codeql--current-alert nil
  "The last visited alert location, as a plist.

Its keys are :buffer, the results buffer, :tick, the modification tick of
its contents, :alert, the index of the alert, and :location, the index of
the location within the alert.")

(defun codeql--line-links ()
  "Return the codeql: links on the current line, see `codeql--alert'."
  (codeql--require-org)
  (let (links)
    (save-excursion
      (beginning-of-line)
      (while (re-search-forward org-link-bracket-re (line-end-position) t)
        (let ((link (org-link-unescape (match-string-no-properties 1)))
              (description (or (match-string-no-properties 2) ""))
              (start (match-beginning 0)))
          (when (string-prefix-p "codeql:" link)
            (setq link (substring link (length "codeql:")))
            ;; locations with no source file
            (unless (directory-name-p (car (codeql--parse-link-location link)))
              (push (list link (codeql--diagnostics-text description) start)
                    links))))))
    (nreverse links)))

(defun codeql--alert-finish (start end message links)
  "Return an alert from START to END described by MESSAGE, or nil.

LINKS are its locations, see `codeql--alert', duplicates are dropped."
  (let ((seen (make-hash-table :test #'equal))
        locations)
    (dolist (link links)
      (unless (gethash (car link) seen)
        (puthash (car link) t seen)
        (push link locations)))
    (when locations
      (codeql--alert-create :start start :end end :message message
                            :locations (vconcat (nreverse locations))))))

(defun codeql--results-heading-kind ()
  "Return what the heading on the current line of a results buffer holds.

That is `problem' for a problem or path-problem result, `row' for a row
of raw results, `section' for the other top level headings, such as
Query Source, `other' for the headings nested in a result, such as its
paths, or nil when the line isn't a heading.  Results are told apart by
their CODEQL_KIND and CODEQL_QUERY_KIND properties, and in results saved
before results had properties, every other top level heading is a
problem."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "\\(\\*+\\) +\\(.*?\\)[ \t]*$")
      (let ((level (length (match-string 1)))
            (title (match-string 2))
            kind query-kind)
        (forward-line 1)
        (when (looking-at-p "[ \t]*:PROPERTIES:[ \t]*$")
          (forward-line 1)
          (while (and (not (eobp))
                      (looking-at "[ \t]*:\\([^: \t\n]+\\):\\(?:[ \t]+\\(.*?\\)\\)?[ \t]*$")
                      (not (equal (match-string 1) "END")))
            (pcase (match-string 1)
              ("CODEQL_KIND" (setq kind (match-string 2)))
              ("CODEQL_QUERY_KIND" (setq query-kind (match-string 2))))
            (forward-line 1)))
        (cond ((equal kind "result") (if (equal query-kind "raw") 'row 'problem))
              (kind 'section)
              ((> level 1) 'other)
              ((member title '("Query Source" "Results" "Results Footer")) 'section)
              (t 'problem))))))

(defun codeql--results-collect-alerts ()
  "Return a vector of the alerts in the current results buffer.

Each result heading is an alert, see `codeql--results-heading-kind'.  The
last link of a problem heading is the location of the problem, and the
first link of a raw results heading its location.  Each table row with
links is an alert of a raw results table, its first link is its
location."
  (let (alerts heading)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (cl-flet ((finish-heading ()
                    (when heading
                      (pcase-let ((`(,start ,message ,links) heading))
                        (when-let ((alert (codeql--alert-finish
                                           start (line-beginning-position)
                                           message (nreverse links))))
                          (push alert alerts)))
                      (setq heading nil))))
          (while (not (eobp))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (pcase-exhaustive (and (string-prefix-p "*" line)
                                     (codeql--results-heading-kind))
               ((and (or 'problem 'row) kind)
                (finish-heading)
                (let ((links (codeql--line-links)))
                  ;; the location of a problem comes after its message
                  (unless (or (eq kind 'row) (string-suffix-p "[location unknown]" line))
                    (setq links (append (last links) (butlast links))))
                  (setq heading (list (line-beginning-position)
                                      (if (eq kind 'row)
                                          (codeql--location-line-context line)
                                        (codeql--diagnostics-problem-text line))
                                      (reverse links)))))
               ('section (finish-heading))
               (_
                (cond
                 (heading
                  (setf (nth 2 heading)
                        (append (reverse (codeql--line-links)) (nth 2 heading))))
                 ((string-match-p "\\`[ \t]*|" line)
                  (when-let ((alert (codeql--alert-finish
                                     (line-beginning-position)
                                     (min (point-max) (1+ (line-end-position)))
                                     (codeql--location-line-context line)
                                     (codeql--line-links))))
                    (push alert alerts)))))))
            (forward-line 1))
          (finish-heading))))
    (vconcat (nreverse alerts))))

(defun codeql--results-alerts ()
  "Return the alerts of the current results buffer, see `codeql--alert'."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eq (car codeql--results-alerts-cache) tick)
      (setq codeql--results-alerts-cache
            (cons tick (codeql--results-collect-alerts))))
    (cdr codeql--results-alerts-cache)))

(defun codeql--results-buffer-p (buffer)
  "Return non-nil if BUFFER is a live buffer of CodeQL results.

These are the rendered results buffers, and the saved results of query
history.  Other buffers with codeql: links, like the AST viewer, are not."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (derived-mode-p 'codeql-results-mode))))

(defun codeql--alerts-results-buffer ()
  "Return the results buffer to navigate the alerts of."
  (or (cl-find-if #'codeql--results-buffer-p
                  (list (current-buffer)
                        (plist-get codeql--current-alert :buffer)
                        next-error-last-buffer))
      (cl-find-if #'codeql--results-buffer-p codeql--diagnostics-results-buffers)
      (cl-find-if #'codeql--results-buffer-p (mapcar #'window-buffer (window-list)))
      (cl-find-if (lambda (buffer)
                    (and (string-prefix-p "* codeql-org-results" (buffer-name buffer))
                         (codeql--results-buffer-p buffer)))
                  (buffer-list))
      (user-error "No CodeQL results buffer")))

(defun codeql--alert-at (alerts position)
  "Return the index of the last of ALERTS starting at or before POSITION."
  (cl-loop with found = -1
           for alert across alerts
           for i from 0
           while (<= (codeql--alert-start alert) position)
           do (setq found i)
           finally return found))

(defun codeql--alert-location-at (alert position)
  "Return the index of the location of ALERT on the line of POSITION, or nil."
  (save-excursion
    (goto-char position)
    (let ((bol (line-beginning-position))
          (eol (line-end-position)))
      (cl-position-if (lambda (location)
                        (<= bol (nth 2 location) eol))
                      (codeql--alert-locations alert)))))

(defun codeql--alert-location-at-point (alert)
  "Return the index of the location of ALERT that point is in, or nil.

The current buffer is a source file."
  (when buffer-file-name
    (let ((key (codeql--diagnostics-file-key buffer-file-name)))
      (cl-position-if
       (lambda (location)
         (pcase-let ((`(,file ,line ,column ,end-line ,end-column)
                      (codeql--parse-link-location (car location))))
           (when (and line (equal (codeql--diagnostics-file-key file) key))
             (when-let ((region (codeql--diagnostics-region
                                 line column end-line end-column)))
               (<= (car region) (point) (cdr region))))))
       (codeql--alert-locations alert)))))

(defun codeql--alerts-visited (results alerts)
  "Return the last visited (ALERT . LOCATION) indices into ALERTS of RESULTS.

Return nil when no alert of the current contents of RESULTS was visited."
  (and (eq (plist-get codeql--current-alert :buffer) results)
       (eql (plist-get codeql--current-alert :tick)
            (car (buffer-local-value 'codeql--results-alerts-cache results)))
       (< (plist-get codeql--current-alert :alert) (length alerts))
       (cons (plist-get codeql--current-alert :alert)
             (plist-get codeql--current-alert :location))))

(defun codeql--alerts-position (results alerts)
  "Return the current (ALERT . LOCATION) indices into ALERTS of RESULTS.

In the window of RESULTS this is the alert at point, in a source file it
is the last visited alert, or else an alert with a location at point.
The indices are -1 when there is no current alert."
  (let ((current (codeql--alerts-visited results alerts))
        (selected (window-buffer)))
    (cond
     ((eq selected results)
      (with-current-buffer results
        (let ((alert (codeql--alert-at alerts (window-point))))
          (cons alert
                (if (< alert 0)
                    -1
                  (or (codeql--alert-location-at (aref alerts alert) (window-point))
                      (and (eql alert (car current)) (cdr current))
                      0))))))
     ((buffer-local-value 'buffer-file-name selected)
      (with-current-buffer selected
        (or (and current
                 (when-let ((location (codeql--alert-location-at-point
                                       (aref alerts (car current)))))
                   (cons (car current) location)))
            current
            (cl-loop for alert across alerts
                     for i from 0
                     for location = (codeql--alert-location-at-point alert)
                     when location return (cons i location))
            (cons -1 -1))))
     (t (or current (cons -1 -1))))))

(defun codeql--alerts-note-visit (link)
  "Remember the alert location of LINK as the current one.

The current buffer is the results buffer LINK is followed from, and the
alert at point is preferred when it has the location of LINK."
  (codeql--require-org)
  (when (codeql--results-buffer-p (current-buffer))
    (let* ((alerts (codeql--results-alerts))
           (link (org-link-unescape link))
           (find (lambda (i)
                   (and (<= 0 i) (< i (length alerts))
                        (when-let ((location (cl-position
                                              link (codeql--alert-locations (aref alerts i))
                                              :key #'car :test #'equal)))
                          (cons i location)))))
           (found (or (funcall find (codeql--alert-at alerts (point)))
                      (cl-loop for i below (length alerts)
                               thereis (funcall find i)))))
      (when found
        (setq codeql--current-alert
              (list :buffer (current-buffer)
                    :tick (car codeql--results-alerts-cache)
                    :alert (car found)
                    :location (cdr found)))
        (setq next-error-last-buffer (current-buffer))))))

(defun codeql--alert-location-text (alert index)
  "Describe the location at INDEX of ALERT."
  (pcase-let ((`(,_ ,description ,position) (aref (codeql--alert-locations alert) index)))
    (if (zerop index)
        (codeql--alert-message alert)
      (let ((line (save-excursion
                    (goto-char position)
                    (buffer-substring-no-properties (line-beginning-position)
                                                    (line-end-position)))))
        (cond
         ((and (string-match-p "\\`\\*+ " line)
               (eq (save-excursion (goto-char position) (codeql--results-heading-kind))
                   'problem))
          (format "Related location \"%s\"" description))
         ((string-match "\\`[ \t]*\\([0-9]+\\)\\. +\\(?:src\\|snk\\|\\.\\.\\.\\|→\\)? *" line)
          (format "Path step %s: %s" (match-string 1 line)
                  (codeql--location-line-context (substring line (match-end 0)))))
         (t (codeql--location-line-context line)))))))

(defun codeql--alert-visit (results alert-index location-index)
  "Visit the location at LOCATION-INDEX of the alert at ALERT-INDEX of RESULTS."
  (codeql--require-org)
  (with-current-buffer results
    (let* ((alerts (codeql--results-alerts))
           (alert (aref alerts alert-index))
           (locations (codeql--alert-locations alert))
           (position (nth 2 (aref locations location-index)))
           (window (get-buffer-window results)))
      ;; follow along in the results buffer, like `next-error' does
      (goto-char position)
      (when (invisible-p position)
        (org-reveal))
      (when window
        (set-window-point window position))
      (let ((codeql--find-file-same-window (not (eq (window-buffer) results))))
        (codeql--org-open-file-link (car (aref locations location-index))))
      (setq codeql--current-alert (list :buffer results
                                        :tick (car codeql--results-alerts-cache)
                                        :alert alert-index
                                        :location location-index))
      (setq next-error-last-buffer results)
      (message "Alert %d/%d%s: %s"
               (1+ alert-index) (length alerts)
               (if (> (length locations) 1)
                   (format ", location %d/%d" (1+ location-index) (length locations))
                 "")
               (with-current-buffer results
                 (codeql--alert-location-text alert location-index))))))

(defun codeql--alerts-boundary-hint (results)
  "Return a hint about the other result pages of RESULTS, if any."
  (with-current-buffer results
    (if (and codeql--raw-results-pagination
             (> (codeql--raw-results-pages codeql--raw-results-pagination) 1))
        (format " on this page, see %s and %s"
                (substitute-command-keys
                 "\\<codeql-results-pagination-mode-map>\\[codeql-results-next-page]")
                (substitute-command-keys
                 "\\<codeql-results-pagination-mode-map>\\[codeql-results-previous-page]"))
      "")))

(defun codeql-next-alert (&optional n)
  "Visit the location of the Nth next alert of a CodeQL results buffer.

Alerts are the results of problem queries and the rows of raw results,
in the order the results buffer lists them.  Following a link of the
results buffer, or visiting the location of an alert with any of the
alert commands, makes its alert the current one.  Point in the results
buffer moves along.  Use `codeql-next-alert-location' to visit the
other locations of the current alert.

The results buffer is the current one, the one of the current alert,
or one that shows Flymake diagnostics.  Results buffers also work with
`next-error' and `previous-error'."
  (interactive "p")
  (let* ((n (or n 1))
         (results (codeql--alerts-results-buffer))
         (alerts (with-current-buffer results (codeql--results-alerts)))
         (current (car (codeql--alerts-position results alerts)))
         (target
          (cond
           ((eq (window-buffer) results)
            ;; like in compilation buffers, point between alerts or on an
            ;; alert that wasn't visited yet is before the next alert
            (let ((between (or (< current 0)
                               (>= (window-point)
                                   (codeql--alert-end (aref alerts current)))))
                  (visited (eql current (car (codeql--alerts-visited results alerts)))))
              (cond ((or visited (and between (> n 0))) (+ current n))
                    (between (+ current n 1))
                    ((> n 0) (+ current n -1))
                    (t (+ current n)))))
           ;; with no current alert, start from either end
           ((< current 0) (if (> n 0) (1- n) (+ (length alerts) n)))
           (t (+ current n)))))
    (cond
     ((zerop (length alerts))
      (user-error "No alerts in %s" (buffer-name results)))
     ((>= target (length alerts))
      (user-error "No more alerts%s" (codeql--alerts-boundary-hint results)))
     ((< target 0)
      (user-error "No previous alerts%s" (codeql--alerts-boundary-hint results))))
    (codeql--alert-visit results target 0)))

(defun codeql-previous-alert (&optional n)
  "Visit the location of the Nth previous alert of a CodeQL results buffer.

See `codeql-next-alert'."
  (interactive "p")
  (codeql-next-alert (- (or n 1))))

(defun codeql-next-alert-location (&optional n)
  "Visit the Nth next location of the current alert of CodeQL results.

The locations of an alert are its own location, followed by the related
locations of its message and the steps of its paths, from source to
sink.  Moving past either end wraps around.  See `codeql-next-alert'
for the current alert."
  (interactive "p")
  (let* ((n (or n 1))
         (results (codeql--alerts-results-buffer))
         (alerts (with-current-buffer results (codeql--results-alerts)))
         (position (codeql--alerts-position results alerts))
         (alert (car position)))
    (when (< alert 0)
      (user-error "No current alert, visit one with `codeql-next-alert' first"))
    (let ((count (length (codeql--alert-locations (aref alerts alert)))))
      (codeql--alert-visit results alert (mod (+ (max 0 (cdr position)) n) count)))))

(defun codeql-previous-alert-location (&optional n)
  "Visit the Nth previous location of the current alert of CodeQL results.

See `codeql-next-alert-location'."
  (interactive "p")
  (codeql-next-alert-location (- (or n 1))))

(defun codeql--results-next-error (n &optional reset)
  "Visit the Nth next alert of the current results buffer, for `next-error'.

With RESET, count from the first alert."
  (if (not reset)
      (codeql-next-alert n)
    (let ((alerts (codeql--results-alerts)))
      (unless (< 0 n (1+ (length alerts)))
        (user-error "No alert %d%s" n (codeql--alerts-boundary-hint (current-buffer))))
      (codeql--alert-visit (current-buffer) (1- n) 0))))

(defvar codeql-alert-navigation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'codeql-next-alert)
    (define-key map (kbd "p") #'codeql-previous-alert)
    (define-key map (kbd "f") #'codeql-next-alert-location)
    (define-key map (kbd "b") #'codeql-previous-alert-location)
    map)
  "Keymap of the commands navigating the alerts of CodeQL results.

Bind it to a prefix key, for example:

  (keymap-global-set \"C-c n\" codeql-alert-navigation-map)

It's also a `repeat-mode' map, so with `repeat-mode' enabled the
commands can be repeated without the prefix key.")

(dolist (command '(codeql-next-alert codeql-previous-alert
                   codeql-next-alert-location codeql-previous-alert-location))
  (put command 'repeat-map 'codeql-alert-navigation-map))

(defun codeql--process-defs (json src-filename src-root _src-buffer)
  (puthash src-filename (list json src-root) codeql--definitions-cache)
  (remhash (cons src-filename "localDefinitions") codeql--xref-pending)
  (message "Processed definitions for: %s" (file-name-nondirectory src-filename)))

(defun codeql--process-refs (json src-filename src-root _src-buffer)
  (puthash src-filename (list json src-root) codeql--references-cache)
  (remhash (cons src-filename "localReferences") codeql--xref-pending)
  (message "Processed references for: %s" (file-name-nondirectory src-filename)))

;; AST viewer

(cl-defstruct
    (codeql--ast-item (:constructor codeql--ast-item-create) (:copier nil))
  (id                nil :read-only t)
  (parent            nil :read-only nil)
  (label             nil :read-only t)
  (location          nil :read-only t)
  (children          []  :read-only nil)
  (order             nil :read-only nil)
  (result-node       nil :read-only nil))

(defun codeql--valid-graph-p (graph-props)
  (cl-loop for prop across (json-pointer-get graph-props "/tuples")
           when (and (string= (seq-elt prop 0) "semmle.graphKind")
                     (string= (seq-elt prop 1) "tree"))
           do
           (cl-return t)))

(defun codeql--render-ast (json src-root src-filename src-buffer)
  (message "Rendering AST")
  ;; oh boy.
  (let ((id-to-item (make-hash-table :test #'equal))
        (parent-to-children (make-hash-table :test #'equal))
        (child-to-parent (make-hash-table :test #'equal))
        (ast-order (make-hash-table :test #'equal))
        (roots [])
        (edge-labels (make-hash-table :test #'equal))
        (node-tuples (json-pointer-get json "/nodes"))
        (edge-tuples (json-pointer-get json "/edges"))
        (graph-props (json-pointer-get json "graphProperties")))
    (when (codeql--valid-graph-p graph-props)
      ;; round 1
      (cl-loop for tuple across (json-pointer-get edge-tuples "/tuples")
               for source = (seq-elt tuple 0)
               for target = (seq-elt tuple 1)
               for tuple-type = (seq-elt tuple 2)
               for value = (seq-elt tuple 3)
               for source-id = (json-pointer-get source "/id")
               for target-id = (json-pointer-get target "/id") do
               (cond ((string= tuple-type "semmle.order")
                      (puthash target-id (string-to-number value) ast-order))
                     ((string= tuple-type "semmle.label")
                      (puthash target-id source-id child-to-parent)
                      (let ((children (gethash source-id parent-to-children)))
                        (puthash source-id (vconcat children `[,target-id]) parent-to-children))
                      (condition-case nil
                          (cl-parse-integer value)
                        (error (puthash target-id value edge-labels))))))
      ;; round 2
      (cl-loop for tuple across (json-pointer-get node-tuples "/tuples")
               for entity = (seq-elt tuple 0)
               for tuple-type = (seq-elt tuple 1)
               for value = (seq-elt tuple 2)
               for entity-id = (json-pointer-get entity "/id")
               for entity-label = (json-pointer-get entity "/label")
               for entity-url = (json-pointer-get entity "/url")
               ;; XXX: double check value isn't "" here
               for node-label = (or value entity-label)
               for edge-label = (gethash entity-id edge-labels)
               for label = (if edge-label (format "%s: %s" edge-label node-label) node-label) do
               (cond ((string= tuple-type "semmle.order")
                      (puthash entity-id (string-to-number value) ast-order))
                     ((string= tuple-type "semmle.label")
                      ;; create an AST item node
                      (let ((item (codeql--ast-item-create
                                   :id entity-id
                                   :label label
                                   :location entity-url
                                   :children [])))
                        ;; tag on a location result node for our org renderer to use
                        (when entity-url
                          (setf (codeql--ast-item-result-node item)
                                (codeql--result-node-create
                                 :label label
                                 :mark ""
                                 :filename (codeql--uri-to-filename (json-pointer-get entity-url "/uri"))
                                 :line (json-pointer-get entity-url "/startLine")
                                 :column (json-pointer-get entity-url "/startColumn")
                                 :visitable t
                                 :url entity-url)))
                        (puthash entity-id item id-to-item)
                        ;; check if this item has a known parent
                        (when-let ((parent (gethash (gethash entity-id child-to-parent) id-to-item)))
                          (setf (codeql--ast-item-parent item) parent)
                          (setf (codeql--ast-item-children parent)
                                (vconcat (codeql--ast-item-children parent) `[,item])))
                        ;; check if this item has known children, children is a vector
                        (when-let ((children (gethash entity-id parent-to-children)))
                          (cl-loop for child-id across children
                                   for child = (gethash child-id id-to-item)
                                   when child do
                                   (setf (codeql--ast-item-parent child) item)
                                   (setf (codeql--ast-item-children item)
                                         (vconcat (codeql--ast-item-children item) `[,child]))))))))
      ;; round 3: sort the tree
      (maphash
       (lambda (_ item)
         (setf (codeql--ast-item-order item)
               (or (gethash (codeql--ast-item-id item) ast-order)
                   most-positive-fixnum))
         (unless (or (codeql--ast-item-parent item))
           (setq roots (vconcat roots `[,item]))))
       id-to-item)
      ;; round 4: ding ding ding,  order and render
      (let ((sorted-tree (codeql--sort-tree roots)))
        (message "Tree is sorted (%d roots) ... rendering." (length sorted-tree))
        ;; render with buffer context ...
        (with-current-buffer src-buffer
          (if (buffer-live-p codeql--org-query-buffer)
              (codeql--ast-to-org sorted-tree src-filename src-buffer codeql--org-query-buffer)
            (message "No active buffer context available to render AST with, going to plaintext.")
            (codeql--ast-to-org sorted-tree src-filename src-buffer)))))))

(defun codeql--ast-to-org (sorted-tree src-filename src-buffer &optional buffer-context)
  ;; src-filename is (buffer-filename) for the src buffer ... XXX: check with TRAMP
  (let ((ast-buffer (get-buffer-create (format "* AST viewer: %s *" src-filename))))
    (with-current-buffer ast-buffer
      ;; link the src buffer and the ast buffer in mutual harmony if it's still around
      (when (buffer-live-p src-buffer)
        (puthash ast-buffer src-buffer codeql--ast-to-src-buffer)
        (puthash src-buffer ast-buffer codeql--src-to-ast-buffer))
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert (format "#+AST_VIEWER: %s\n\n" (file-name-nondirectory src-filename)))
      (codeql--render-tree sorted-tree buffer-context)
      (goto-char (point-min))
      (setq buffer-read-only t)
      (save-excursion
        (org-mode)
        ;; add our highlighting sync
        (when codeql-ast-sync-highlighting
          (setq codeql--ast-last-point (point))
          (add-hook 'post-command-hook #'codeql--sync-ast-to-src-overlay 99 :local))
        (switch-to-buffer-other-window (current-buffer))))))

(defun codeql--render-node (node level &optional buffer-context)
  (insert
   (concat
    (format
     "%s %s" level
     (if-let* ((result-node
                ;; if these things hold, we want to resolve the org link
                (and buffer-context
                     (codeql--ast-item-result-node node)))
               ;; line == 0 means no location available
               (line (and (> (codeql--result-node-line result-node) 0)
                          (codeql--result-node-line result-node))))
         (progn
           ;; init ast reference cache if need be
           (let* ((src-filename (codeql--result-node-filename result-node))
                  ;; XXX: double check under TRAMP
                  (full-src-path
                   (with-current-buffer buffer-context
                     (format (codeql--tramp-wrap
                              (format "%s%s"
                                      codeql--database-source-archive-root
                                      src-filename))))))
             (unless (gethash full-src-path codeql--ast-backwards-definitions)
               (puthash full-src-path [] codeql--ast-backwards-definitions)))
           ;; there's backwards messages in this stuff
           (let* ((src-filename (codeql--result-node-filename result-node))
                  (full-src-path
                   (with-current-buffer buffer-context
                     (format (codeql--tramp-wrap
                              (format "%s%s"
                                      codeql--database-source-archive-root
                                      src-filename)))))
                  (ast-line (line-number-at-pos))
                  (ast-lookup-vector (gethash full-src-path codeql--ast-backwards-definitions))
                  (entity-url (codeql--result-node-url result-node))
                  (src-start-line (json-pointer-get entity-url "/startLine"))
                  (src-end-line (or (json-pointer-get entity-url "/endLine") src-start-line))
                  (src-start-column (or (json-pointer-get entity-url "/startColumn") 1))
                  (src-end-column (json-pointer-get entity-url "/endColumn")))
             ;; make all the info we need to build an AST definition available from our xref backend
             (puthash full-src-path
                      (vconcat `[,(vector
                                   src-start-line
                                   src-end-line
                                   src-start-column
                                   src-end-column
                                   ast-line)]
                               ast-lookup-vector)
                      codeql--ast-backwards-definitions))
           ;; go into the active query buffer context and resolve from database
           (save-excursion
             (with-current-buffer buffer-context
               (format "%s %s%s"
                       (codeql--org-text (codeql--ast-item-label node))
                       (codeql--result-node-to-org result-node "⧉")
                       ;; only add Line stamp to roots
                       (if (codeql--ast-item-parent node) "" (format " Line %s" line))))))
       ;; if not, just return a plain text heading
       (codeql--org-text (codeql--ast-item-label node)))) "\n"))
  ;; hail to the guardians of the watch towers of the south.
  (cl-loop for node across (codeql--ast-item-children node) do
           (codeql--render-node node (concat level "*") buffer-context)))

(defun codeql--render-tree (tree &optional buffer-context)
  (let ((codeql--source-link-prefix-box (list nil)))
    (cl-loop for root across tree do
             (codeql--render-node root "*" buffer-context))))

(defun codeql--sort-node (node)
  ;; sort this node's children
  (setf (codeql--ast-item-children node)
        (sort (codeql--ast-item-children node)
              (lambda (left right)
                (< (codeql--ast-item-order left)
                   (codeql--ast-item-order right)))))
  ;; sort any children of this node's children
  (when (> (length (codeql--ast-item-children node)) 0)
    (seq-map #'codeql--sort-node (codeql--ast-item-children node))))

(defun codeql--sort-tree (tree)
  ;; sort all the children of the tree
  (seq-map #'codeql--sort-node tree)
  ;; sort all the roots of the tree and return that vector
  (sort tree (lambda (left right)
               (< (codeql--ast-item-order left)
                  (codeql--ast-item-order right)))))

(defun codeql-view-ast ()
  "Display the AST for the current source archive file."
  (interactive)
  (cl-multiple-value-bind (json src-root) (gethash (buffer-file-name) codeql--ast-cache)
    (if json
        ;; render the AST from cache
        (codeql--render-ast json src-root (buffer-file-name) (current-buffer))
      ;; need to build an AST
      (if (buffer-live-p codeql--org-query-buffer)
          (let ((src-filename (buffer-file-name))
                (src-buffer (current-buffer)))
            (with-current-buffer codeql--org-query-buffer
              (message "Cooking up AST for %s, please hold." (file-name-nondirectory src-filename))
              (let ((language (intern (format ":%s" codeql--active-database-language))))
                (codeql--run-templated-query language "printAst" src-filename src-buffer))))
        (message "Did not recognize this file as being part of an active codeql database.")))))

(defun codeql-view-cfg ()
  "Display the control flow graph of the function at point.

This works in database source archive files, like `codeql-view-ast',
for languages whose library packs come with a printCfg query.  The graph
is shown as described for `codeql-graph-format'."
  (interactive)
  (if (buffer-live-p codeql--org-query-buffer)
      (let ((src-filename (buffer-file-name))
            (src-buffer (current-buffer))
            (position (cons (line-number-at-pos) (codeql--lsp-abiding-column))))
        (with-current-buffer codeql--org-query-buffer
          (message "Cooking up CFG for %s, please hold." (file-name-nondirectory src-filename))
          (let ((language (intern (format ":%s" codeql--active-database-language))))
            (codeql--run-templated-query language "printCfg" src-filename src-buffer position))))
    (message "Did not recognize this file as being part of an active codeql database.")))

(defun codeql--show-graph (dot-path)
  "Show the graph of the dot file at DOT-PATH, see `codeql-graph-format'."
  (let ((dot (and codeql-graph-format
                  (executable-find "dot" (file-remote-p dot-path))))
        (image-path (concat (file-name-sans-extension dot-path) "." codeql-graph-format)))
    (if (not dot)
        (progn
          (when codeql-graph-format
            (message "Install graphviz to render graphs, showing the dot file instead."))
          (switch-to-buffer-other-window (find-file-noselect dot-path)))
      (message "Rendering graph with %s ..." dot)
      (let ((default-directory (file-name-directory dot-path)))
        (make-process
         :name "codeql-dot"
         :buffer (generate-new-buffer " *codeql-dot*")
         :command (list dot (format "-T%s" codeql-graph-format)
                        "-o" (file-local-name image-path)
                        (file-local-name dot-path))
         :file-handler t
         :sentinel
         (lambda (process _event)
           (unless (process-live-p process)
             (let ((output (with-current-buffer (process-buffer process)
                             (buffer-string))))
               (kill-buffer (process-buffer process))
               (if (and (zerop (process-exit-status process))
                        (file-exists-p image-path))
                   (switch-to-buffer-other-window (find-file-noselect image-path))
                 (message "Failed to render graph, showing the dot file instead: %s"
                          (string-trim output))
                 (switch-to-buffer-other-window (find-file-noselect dot-path)))))))))))

(defun codeql--process-ast (json src-filename src-root src-buffer)
  ;; only allow this to be called as part of a templated flow
  (puthash src-filename (list json src-root) codeql--ast-cache)
  (codeql--render-ast json src-root src-filename src-buffer))

(defun codeql--templated-query-p (query-path)
  (or (string-match-p "/localDefinitions\\.ql$" query-path)
      (string-match-p "/localReferences\\.ql$" query-path)
      (string-match-p "/printAst\\.ql$" query-path)))

;; abandon hope, all ye who enter here ...
(defvar codeql--results-marker-suffix nil
  "When non-nil, a description added to the names of new results buffers.")

(defun codeql--results-marker (query-path)
  "Return the marker that names the results buffer of QUERY-PATH."
  (concat (file-name-nondirectory query-path)
          (when codeql--results-marker-suffix
            (format " (%s)" codeql--results-marker-suffix))))

(defun codeql--render-sarif-results (results query-buffer footer marker
                                             &optional link-prefix context)
  "Render the vector of SARIF RESULTS of QUERY-BUFFER in a results buffer.

FOOTER, MARKER and CONTEXT are as for `codeql--org-render-sarif-results',
and LINK-PREFIX is as for `codeql--sarif-results-to-org'.  Results are shown
one page of `codeql-max-sarif-results' at a time.  Return the rendered
org data when everything fits on a single page, nil otherwise."
  (let* ((total (length results))
         (page-size (max 1 codeql-max-sarif-results))
         (org-data (codeql--sarif-results-to-org results 0 page-size link-prefix)))
    (if (<= total page-size)
        (codeql--org-render-sarif-results org-data query-buffer footer marker context)
      (codeql--org-render-raw-query-results
       org-data query-buffer footer marker
       (list :kind 'sarif
             :results results
             :link-prefix link-prefix
             :page 0
             :page-size page-size
             :total-rows total
             :footer footer)
       context)
      nil)))

(defun codeql-load-bqrs (bqrs-path
                         query-path
                         db-path
                         query-name
                         query-kind
                         query-id
                         query-buffer
                         &optional
                         src-filename
                         src-root
                         src-buffer
                         provenance)
  "Parse the results at BQRS-PATH and render them accordingly to the user.

PROVENANCE describes the CodeQL code that produced the results, see
`codeql--query-provenance'.  It defaults to a run of the whole query at
QUERY-PATH, and is shown in the Query Source section of the results."
  (message "Loading bqrs from %s (name: %s kind: %s id: %s)"
           bqrs-path
           (or query-name "no-meta")
           (or query-kind "no-meta")
           (or query-id "no-meta"))
  (when-let ((bqrs-info (codeql--bqrs-info bqrs-path)))
    (let ((_result-sets (json-pointer-get bqrs-info "/result-sets"))
          (compatible-query-kinds (json-pointer-get bqrs-info "compatible-query-kinds"))
          (footer
           (concat
            ;; include query meta if we have some
            (if (and query-name query-kind query-id)
                (format
                 (mapconcat
                  #'identity
                  '("#+QUERY_NAME: %s"
                    "#+QUERY_KIND: %s"
                    "#+QUERY_ID: %s" "") "\n")
                 query-name
                 query-kind
                 query-id)
              "")
            ;; info we always want
            (format
             (mapconcat
              #'identity
              '("#+QUERY_TIME: %s"
                "#+BQRS_PATH: %s"
                "#+QUERY_PATH: %s"
                "#+DB_PATH: %s") "\n")
             (current-time-string)
             bqrs-path
             query-path
             db-path) "\n")))
      (setq provenance (or provenance (list :kind 'file :path query-path)))
      ;; parse results according to the query meta data
      (cond
       ;; AST parsing
       ;; process AST's, definitions, and references
       ((codeql--templated-query-p query-path)
        ;; don't let these be entered from query history
        (if (and src-filename src-root)
            (let* ((json (json-parse-string
                          (codeql--bqrs-to-json bqrs-path "id,url,string")
                          ;; json-pointer-get wants list based json
                          :object-type 'alist)))
              (when json
                (cond ((string-match-p "/localDefinitions\\.ql$" query-path)
                       (codeql--process-defs json src-filename src-root src-buffer))
                      ((string-match-p "/localReferences\\.ql$" query-path)
                       (codeql--process-refs json src-filename src-root src-buffer))
                      ((string-match-p "/printAst\\.ql$" query-path)
                       (codeql--process-ast json src-filename src-root src-buffer)))))
          (message "Can't process templated query without src-filename and src-root.")))
       ;; SARIF parsing
       ;;
       ;; https://codeql.github.com/docs/codeql-cli/sarif-output/
       ;; https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning
       ;;
       ;; Parse out a path-problem or problem query result set
       ;;
       ;; for a path-problem the org-tree will look like:
       ;;
       ;; * Issue: Location node
       ;; ** Path0
       ;; *** Source node
       ;; *** Path node(s)
       ;; *** Sink node
       ;; ** ..
       ;; ** Related Locations
       ;; *** Location node
       ;;
       ;; for a regular problem the org-tree will look like:
       ;;
       ;; * Issue: Location node
       ;; ** Related Locations
       ;; *** Location node
       ((or
         ;; path-problem
         (and (seq-contains-p compatible-query-kinds "PathProblem")
              (string= query-kind "path-problem")
              query-id)
         ;; problem
         (and (seq-contains-p compatible-query-kinds "Problem")
              (string= query-kind "problem")
              query-id))
        (when-let ((json (json-parse-string (codeql--bqrs-to-sarif bqrs-path query-id query-kind)
                                            :object-type 'alist)))
          ;; results of all runs are shown together, one page of
          ;; `codeql-max-sarif-results' results at a time
          (let* ((runs (json-pointer-get json "/runs"))
                 (results
                  (apply #'vconcat
                         (cl-loop for run across runs
                                  for run-id below (length runs)
                                  do (message "Rendering results for run %s" run-id)
                                  collect (or (json-pointer-get run "/results") [])))))
            (if (zerop (length results))
                (message "No results found.")
              (let ((rendered (codeql--render-sarif-results
                               results query-buffer footer
                               (codeql--results-marker query-path)
                               nil
                               (list :provenance provenance
                                     :database db-path
                                     :query-kind query-kind))))
                (if rendered
                    ;; save off the fully rendered version for speedy re-loads
                    (with-temp-file (format "%s.org" bqrs-path)
                      (insert rendered))
                  ;; paginated results are re-rendered from the bqrs on reload
                  (when (file-exists-p (format "%s.org" bqrs-path))
                    (delete-file (format "%s.org" bqrs-path)))))))))
       ;; graphs, e.g. control flow graphs of `codeql-view-cfg'
       ((and (seq-contains-p compatible-query-kinds "Graph")
             (string= query-kind "graph")
             query-id)
        (if-let ((dot-path (codeql--bqrs-to-dot bqrs-path query-id query-kind)))
            (codeql--show-graph dot-path)
          (message "Failed to interpret graph results in %s." bqrs-path)))
       ;; fall through to raw results parsing
       (t
        ;; raw results are decoded one page of `codeql-max-raw-results' rows at a
        ;; time, using byte offsets precomputed by `codeql bqrs info'
        (let* ((result-sets (append (alist-get 'result-sets bqrs-info) nil))
               (result-set-info (codeql--raw-results-select-result-set bqrs-info))
               (setup (when (> (or (alist-get 'rows result-set-info) 0) 0)
                        (codeql--raw-results-setup
                         bqrs-path result-sets result-set-info footer))))
          (if (not setup)
              (message "No results in bqrs.")
            (let* ((state (car setup))
                   (rendered
                    (codeql--org-render-raw-query-results
                     (cdr setup) query-buffer footer
                     (codeql--results-marker query-path)
                     state
                     (list :provenance provenance
                           :database db-path
                           :query-kind "raw"))))
              ;; results that can be paged, sorted or switched to other result
              ;; sets are re-rendered from the bqrs on reload so that they
              ;; remain interactive, only cache plain single page results
              (if (or (plist-get state :offsets) (> (length result-sets) 1))
                  (when (file-exists-p (format "%s.org" bqrs-path))
                    (delete-file (format "%s.org" bqrs-path)))
                (with-temp-file (format "%s.org" bqrs-path)
                  (insert rendered)))))))))))

;; loading SARIF files, e.g. the output of codeql database analyze

(defun codeql--sarif-file-uri-path (uri)
  "Return the local path of the absolute file URI, or nil if it isn't one."
  (let ((url (url-generic-parse-url (url-unhex-string uri))))
    (when (and (equal (url-type url) "file")
               (file-name-absolute-p (url-filename url)))
      (url-filename url))))

(defun codeql--sarif-artifact-location (artifact-location run)
  "Return ARTIFACT-LOCATION of RUN with any uri it inherits from its artifact.

SARIF locations may reference an entry of the run's artifacts by index
rather than spell out their uri."
  (let ((index (json-pointer-get artifact-location "/index")))
    (if (or (json-pointer-get artifact-location "/uri") (not (natnump index)))
        artifact-location
      (let ((artifact (ignore-errors (aref (json-pointer-get run "/artifacts") index))))
        (append (json-pointer-get artifact "/location") artifact-location)))))

(defun codeql--sarif-artifact-contents (artifact-location run)
  "Return the embedded text contents of the artifact at ARTIFACT-LOCATION in RUN."
  (let ((index (json-pointer-get artifact-location "/index"))
        (uri (json-pointer-get artifact-location "/uri")))
    (cl-loop for artifact across (or (json-pointer-get run "/artifacts") [])
             for i from 0
             when (or (eql i index)
                      (and uri (equal uri (json-pointer-get artifact "/location/uri"))))
             return (json-pointer-get artifact "/contents/text"))))

(defun codeql--sarif-resolve-location (artifact-location run base-dir artifacts-dir)
  "Return the absolute path that ARTIFACT-LOCATION of RUN refers to, or nil.

Relative uris are resolved against the run's `originalUriBaseIds' for
their `uriBaseId' when those name an absolute file uri, and otherwise
against the directory returned by calling BASE-DIR.  When ARTIFACTS-DIR
is non-nil and the resolved file doesn't exist, but the artifact has
embedded contents, those are written below ARTIFACTS-DIR instead."
  (let* ((location (codeql--sarif-artifact-location artifact-location run))
         (uri (json-pointer-get location "/uri"))
         (base-id (json-pointer-get location "/uriBaseId")))
    (when (and (stringp uri) (not (codeql--empty-location-uri-p uri)))
      (let* ((relative (and (not (url-type (url-generic-parse-url uri)))
                            (not (file-name-absolute-p uri))
                            (url-unhex-string uri)))
             (path
              (cond
               ((not relative)
                (or (codeql--sarif-file-uri-path uri)
                    (and (file-name-absolute-p uri) uri)))
               ((when-let* ((base-id)
                            (base-uri (json-pointer-get
                                       run (format "/originalUriBaseIds/%s/uri" base-id)))
                            (base-path (codeql--sarif-file-uri-path base-uri)))
                  (expand-file-name relative base-path)))
               (t
                (expand-file-name relative (funcall base-dir))))))
        (if-let ((artifacts-dir)
                 ((and path (not (codeql--file-exists-p path))))
                 (contents (codeql--sarif-artifact-contents location run)))
            (let ((copy (expand-file-name (or relative (file-name-nondirectory path))
                                          artifacts-dir)))
              (make-directory (file-name-directory copy) t)
              (with-temp-file copy
                (insert contents))
              copy)
          path)))))

(defun codeql--sarif-normalize-locations (node run base-dir artifacts-dir)
  "Rewrite all artifact locations below the parsed SARIF NODE of RUN in place.

Their uris become absolute file uris, or empty ones when they can't be
resolved, see `codeql--sarif-resolve-location' for BASE-DIR and
ARTIFACTS-DIR."
  (cond
   ((vectorp node)
    (cl-loop for child across node
             do (codeql--sarif-normalize-locations child run base-dir artifacts-dir)))
   ((and (consp node) (consp (car node)))
    (dolist (entry node)
      (if (eq (car-safe entry) 'artifactLocation)
          (let ((path (codeql--sarif-resolve-location (cdr entry) run base-dir artifacts-dir)))
            (setcdr entry `((uri . ,(if path (concat "file://" path) "")))))
        (codeql--sarif-normalize-locations (cdr-safe entry) run base-dir artifacts-dir))))))

(defun codeql--sarif-normalize-rule-id (result run)
  "Give RESULT of RUN a ruleId, looking it up in the run's rules if needed."
  (unless (json-pointer-get result "/ruleId")
    (let* ((index (or (json-pointer-get result "/ruleIndex")
                      (json-pointer-get result "/rule/index")))
           (rule-id (or (json-pointer-get result "/rule/id")
                        (and (natnump index)
                             (ignore-errors
                               (json-pointer-get
                                (aref (json-pointer-get run "/tool/driver/rules") index)
                                "/id")))
                        "unknown-rule")))
      (nconc result (list (cons 'ruleId rule-id))))))

(defun codeql--sarif-rule-provenance (json results)
  "Return the rules of the parsed SARIF JSON that RESULTS were reported for.

Each rule is a plist of its :id, and its :name and :description when
the SARIF has them."
  (let ((ids (delete-dups (cl-loop for result across results
                                   collect (alist-get 'ruleId result))))
        (rules (make-hash-table :test #'equal)))
    (cl-loop for run across (or (json-pointer-get json "/runs") [])
             do (cl-loop for component in (cons (json-pointer-get run "/tool/driver")
                                                (append (json-pointer-get run "/tool/extensions")
                                                        nil))
                         do (cl-loop for rule across (or (alist-get 'rules component) [])
                                     for id = (alist-get 'id rule)
                                     when (and id (not (gethash id rules)))
                                     do (puthash id rule rules))))
    (mapcar (lambda (id)
              (let ((rule (gethash id rules)))
                (list :id id
                      :name (or (alist-get 'name (alist-get 'properties rule))
                                (alist-get 'name rule))
                      :description (json-pointer-get rule "/shortDescription/text"))))
            (sort (delq nil ids) #'string<))))

(defun codeql--sarif-tools (json)
  "Return the names and versions of the tools that produced the parsed SARIF JSON."
  (delete-dups
   (cl-loop for run across (or (json-pointer-get json "/runs") [])
            for driver = (json-pointer-get run "/tool/driver")
            for name = (alist-get 'name driver)
            for version = (or (alist-get 'semanticVersion driver) (alist-get 'version driver))
            when name
            collect (if version (format "%s %s" name version) name))))

(defun codeql--sarif-provenance-plist (json sarif-path results)
  "Return the provenance of the RESULTS of the SARIF JSON at SARIF-PATH.

See `codeql--query-provenance', its :kind is `sarif'.  :sarif is
SARIF-PATH, :tools the tools that produced it, :rules the rules that
RESULTS were reported for, see `codeql--sarif-rule-provenance', and
:repository-uri and :revision-id its version control provenance."
  (let ((version-control (codeql--sarif-provenance json)))
    (list :kind 'sarif
          :sarif sarif-path
          :tools (codeql--sarif-tools json)
          :rules (codeql--sarif-rule-provenance json results)
          :repository-uri (car version-control)
          :revision-id (cdr version-control))))

(defun codeql-load-sarif (sarif-path &optional checkout-dir provenance)
  "Render the results of the SARIF file at SARIF-PATH.

This shows SARIF produced outside of this query buffer, e.g. by
`codeql database analyze' or a code scanning run, like the results of a
problem or path-problem query.

When the query buffer has an active database, result locations are
taken to be files of its source archive, so that they can be browsed
with xrefs like regular query results.  With a prefix argument, or
without an active database, they are taken to be files of the source
checkout at CHECKOUT-DIR instead, which is prompted for when the SARIF
contains relative locations its `originalUriBaseIds' don't resolve.
Locations that are missing from the checkout, but whose contents are
embedded in the SARIF, are shown from a copy of those contents.

The Query Source section of the results describes the SARIF file, see
`codeql--sarif-provenance-plist'.  PROVENANCE is a plist that takes
precedence over that description, e.g. a :kind of `mrva' for the results
of a variant analysis, see `codeql-mrva-load-results'."
  (interactive
   (list (read-file-name "SARIF file: " nil nil t nil
                         (lambda (f) (or (file-directory-p f)
                                         (string-match-p "\\.sarif\\(?:\\.json\\)?\\'" f))))
         (when current-prefix-arg
           (read-directory-name "Source checkout: " nil nil t))))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let* ((sarif-path (expand-file-name sarif-path))
         (database-p (and codeql--active-database
                          codeql--database-source-archive-zip
                          (not checkout-dir)))
         (json (with-temp-buffer
                 (insert-file-contents sarif-path)
                 (json-parse-buffer :object-type 'alist)))
         (base-dir
          (if database-p
              (lambda () (or codeql--database-source-location-prefix "/"))
            (lambda ()
              (or checkout-dir
                  (setq checkout-dir
                        (read-directory-name "Source checkout for relative locations: "
                                             nil nil t))))))
         (artifacts-dir (unless database-p
                          (expand-file-name
                           (format "codeql-sarif-artifacts/%s" (md5 sarif-path))
                           temporary-file-directory)))
         (results
          (apply #'vconcat
                 (cl-loop for run across (or (json-pointer-get json "/runs") [])
                          for results = (or (json-pointer-get run "/results") [])
                          do (cl-loop for result across results
                                      do (codeql--sarif-normalize-rule-id result run)
                                      (codeql--sarif-normalize-locations
                                       result run base-dir artifacts-dir))
                          collect results))))
    (if (zerop (length results))
        (message "No results found in %s." sarif-path)
      (codeql--render-sarif-results
       results (current-buffer)
       (concat
        (format (mapconcat #'identity
                           '("#+QUERY_TIME: %s"
                             "#+SARIF_PATH: %s"
                             "#+SOURCE_ROOT: %s" "") "\n")
                (current-time-string)
                sarif-path
                (if database-p
                    (directory-file-name codeql--active-database)
                  (or checkout-dir "-")))
        (when-let ((provenance (codeql--sarif-provenance json)))
          (mapconcat
           (lambda (line) (concat line "\n"))
           `(,(format "#+REPOSITORY_URI: %s" (car provenance))
             ,(format "#+REVISION_ID: %s" (cdr provenance))
             ,@(mapcar (lambda (root) (format "#+REPOSITORY_ROOT: %s" root))
                       (if database-p
                           (list (concat (directory-file-name
                                          (codeql--tramp-wrap
                                           codeql--database-source-archive-root))
                                         (directory-file-name
                                          (or codeql--database-source-location-prefix "/"))))
                         (delete-dups
                          (delq nil
                                `(,checkout-dir
                                  ,@(cl-loop for run across (or (json-pointer-get json "/runs") [])
                                             append (mapcar (lambda (base)
                                                              (codeql--sarif-file-uri-path
                                                               (or (json-pointer-get (cdr base) "/uri") "")))
                                                            (json-pointer-get run "/originalUriBaseIds")))
                                  ,artifacts-dir))))))
           "")))
       (file-name-nondirectory sarif-path)
       (unless database-p "")
       (list :provenance (append provenance
                                 (codeql--sarif-provenance-plist json sarif-path results))
             :database (and database-p (directory-file-name codeql--active-database))
             :query-kind (if (seq-some (lambda (result) (alist-get 'codeFlows result)) results)
                             "path-problem"
                           "problem"))))))

;; permalinks to the results of SARIF files with version control provenance

(defun codeql--sarif-provenance (json)
  "Return the (REPOSITORY-URI . REVISION-ID) of the parsed SARIF JSON, or nil.

This is the first `versionControlProvenance' of its runs that has both."
  (cl-loop for run across (or (json-pointer-get json "/runs") [])
           thereis (cl-loop for provenance across (or (json-pointer-get
                                                       run "/versionControlProvenance")
                                                      [])
                            for repository = (json-pointer-get provenance "/repositoryUri")
                            for revision = (json-pointer-get provenance "/revisionId")
                            when (and (stringp repository) (stringp revision))
                            return (cons repository revision))))

(defun codeql--results-keyword-values (keyword)
  "Return the values of the org KEYWORD lines of the current buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((re (format "^#\\+%s:[ \t]*\\(.*?\\)[ \t]*$" (regexp-quote keyword)))
            values)
        (while (re-search-forward re nil t)
          (push (match-string-no-properties 1) values))
        (nreverse values)))))

(defun codeql--results-permalink-info ()
  "Return the permalink information of the current results buffer, or nil.

This is a plist of the :repository uri and :revision that the results
were produced for, and the local :roots that their locations are
relative to, as recorded by `codeql-load-sarif'."
  (when (derived-mode-p 'codeql-results-mode)
    (let ((repository (car (codeql--results-keyword-values "REPOSITORY_URI")))
          (revision (car (codeql--results-keyword-values "REVISION_ID"))))
      (when (and repository revision)
        (list :repository repository
              :revision revision
              :roots (codeql--results-keyword-values "REPOSITORY_ROOT"))))))

(defun codeql--permalink-relative-path (file roots)
  "Return the path of FILE relative to the longest of ROOTS it is in, or nil."
  (let ((file (expand-file-name file)))
    (cl-loop for root in (sort (mapcar (lambda (root)
                                         (file-name-as-directory (expand-file-name root)))
                                       roots)
                               (lambda (a b) (> (length a) (length b))))
             when (string-prefix-p root file)
             return (substring file (length root)))))

(defun codeql--permalink (info path line &optional end-line)
  "Return the permalink to LINE through END-LINE of PATH for INFO.

INFO is as returned by `codeql--results-permalink-info' and PATH is
relative to the repository root.  This assumes a GitHub style
repository URI."
  (let ((repository (replace-regexp-in-string
                     "\\(?:\\.git\\)?/*\\'" ""
                     (replace-regexp-in-string
                      ;; scp-like git@host:owner/name
                      "\\`[^@/:]+@\\([^:/]+\\):" "https://\\1/"
                      (plist-get info :repository)))))
    (concat (format "%s/blob/%s/%s" repository (plist-get info :revision)
                    (mapconcat #'url-hexify-string (split-string path "/") "/"))
            (when line
              (if (and end-line (> end-line line))
                  (format "#L%d-L%d" line end-line)
                (format "#L%d" line))))))

(defun codeql--permalink-at-point ()
  "Return the permalink to the result location at point.

In a results buffer this is the location of the codeql: link at or
before point on the current line.  In a source file visited from those
results it is the current line, or the lines of the active region."
  (cl-destructuring-bind (info file line end-line)
      (cond
       ((derived-mode-p 'codeql-results-mode)
        (let ((links (or (codeql--line-links)
                         (user-error "No result location on this line"))))
          (pcase-let ((`(,file ,line ,_ ,end-line)
                       (codeql--parse-link-location
                        (car (or (cl-find-if (lambda (link) (<= (nth 2 link) (point)))
                                             links :from-end t)
                                 (car links))))))
            (list (or (codeql--results-permalink-info)
                      (user-error "These results have no version control provenance"))
                  file line end-line))))
       ((and buffer-file-name codeql--permalink-info)
        (if (use-region-p)
            (list codeql--permalink-info buffer-file-name
                  (line-number-at-pos (region-beginning))
                  (line-number-at-pos (if (and (> (region-end) (region-beginning))
                                               (save-excursion
                                                 (goto-char (region-end))
                                                 (bolp)))
                                          (1- (region-end))
                                        (region-end))))
          (list codeql--permalink-info buffer-file-name (line-number-at-pos) nil)))
       (t (user-error "Not a result location with version control provenance")))
    (codeql--permalink
     info
     (or (codeql--permalink-relative-path file (plist-get info :roots))
         (user-error "%s is not in the repository of these results" file))
     line end-line)))

(defun codeql-copy-permalink ()
  "Copy the permalink to the result location at point to the kill ring.

This works for the results of SARIF files that record the repository
and revision they were produced for, like those of code scanning, see
`codeql-load-sarif', and for source files visited from their links."
  (interactive)
  (let ((permalink (codeql--permalink-at-point)))
    (kill-new permalink)
    (message "Copied %s" permalink)))

(defun codeql-browse-permalink ()
  "Browse the permalink to the result location at point.

See `codeql-copy-permalink'."
  (interactive)
  (browse-url (codeql--permalink-at-point)))

;;; Multi-repository variant analysis with gh-mrva

;; see https://github.com/GitHubSecurityLab/gh-mrva, sessions are submitted
;; with `gh mrva submit' and browsed from here

(defvar-local codeql--mrva-session nil
  "The name of the gh-mrva session of a `codeql-mrva-mode' buffer.")

(defvar-local codeql--mrva-query-buffer nil
  "The query buffer that the results of a `codeql-mrva-mode' buffer render in.")

(defvar-local codeql--mrva-status nil
  "The parsed `gh mrva status' of the session of a `codeql-mrva-mode' buffer.")

(defun codeql--mrva-directory (&rest components)
  "Return the local directory of gh-mrva downloads, joined with COMPONENTS."
  (let ((directory (expand-file-name "mrva" codeql-state-dir)))
    (dolist (component components)
      (setq directory (expand-file-name component directory)))
    directory))

(defun codeql--mrva-sources-directory (nwo run-id)
  "Return the directory that the sources of NWO in RUN-ID are fetched to."
  (file-name-as-directory
   (codeql--mrva-directory "sources" (format "%s_%s" (string-replace "/" "_" nwo) run-id))))

(defun codeql--gh (&rest args)
  "Run the local gh with ARGS and return its stdout.

Signal an error with its output when it fails."
  (let ((gh (or (executable-find "gh")
                (user-error "The gh CLI was not found, see https://cli.github.com"))))
    (with-temp-buffer
      (let* ((stderr (make-temp-file "codeql-gh-stderr"))
             (code (unwind-protect
                       (let ((default-directory (expand-file-name "~/")))
                         (apply #'call-process gh nil (list t stderr) nil args))
                     (setq stderr (prog1 (with-temp-buffer
                                           (insert-file-contents stderr)
                                           (string-trim (buffer-string)))
                                    (delete-file stderr))))))
        (unless (eql code 0)
          (error "Running gh %s failed: %s" (string-join args " ")
                 (if (string-empty-p stderr) (string-trim (buffer-string)) stderr)))
        (buffer-string)))))

(defun codeql--gh-json (&rest args)
  "Run the local gh with ARGS and return its parsed JSON output, or nil."
  (let ((output (string-trim (apply #'codeql--gh args))))
    (unless (or (string-empty-p output) (equal output "null"))
      (json-parse-string output :object-type 'alist :null-object nil))))

(defun codeql--permalink-fetch-file (file info)
  "Fetch the missing FILE from the GitHub repository of permalink INFO.

This only fetches into the gh-mrva sources directory, where FILE is
relative to one of the roots of INFO, see
`codeql--results-permalink-info'.  Return non-nil if FILE was fetched."
  (when-let* ((info)
              ((not (file-remote-p file)))
              ((string-prefix-p (file-name-as-directory (codeql--mrva-directory "sources"))
                                (expand-file-name file)))
              (path (codeql--permalink-relative-path file (plist-get info :roots)))
              (url (url-generic-parse-url (plist-get info :repository)))
              ((member (url-type url) '("http" "https")))
              (nwo (replace-regexp-in-string
                    "\\`/+\\|\\(?:\\.git\\)?/*\\'" "" (url-filename url))))
    (message "Fetching %s from %s at %s" path nwo (plist-get info :revision))
    (let ((contents (condition-case err
                        (apply #'codeql--gh
                               `("api"
                                 ,@(unless (equal (url-host url) "github.com")
                                     (list "--hostname" (url-host url)))
                                 "-H" "Accept: application/vnd.github.raw"
                                 ,(format "repos/%s/contents/%s?ref=%s"
                                          nwo
                                          (mapconcat #'url-hexify-string
                                                     (split-string path "/") "/")
                                          (url-hexify-string (plist-get info :revision)))))
                      (error (message "%s" (error-message-string err)) nil))))
      (when contents
        (make-directory (file-name-directory file) t)
        (let ((coding-system-for-write 'no-conversion))
          (with-temp-file file
            (set-buffer-multibyte nil)
            (insert contents)))
        t))))

(defun codeql--mrva-sessions ()
  "Return the saved gh-mrva sessions, newest first."
  (sort (append (codeql--gh-json "mrva" "list" "--json") nil)
        (lambda (a b)
          (string> (or (alist-get 'timestamp a) "") (or (alist-get 'timestamp b) "")))))

(defun codeql-mrva (session)
  "Browse the results of the gh-mrva SESSION.

Sessions are submitted with `gh mrva submit'.  The repositories with
findings are listed in a `codeql-mrva-mode' buffer, from which their
results are downloaded and rendered for the current query buffer."
  (interactive
   (progn
     (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
     (let* ((sessions (or (codeql--mrva-sessions)
                          (user-error "No gh-mrva sessions, submit one with gh mrva submit")))
            (table (mapcar (lambda (session) (cons (alist-get 'name session) session))
                           sessions)))
       (list (completing-read
              "gh-mrva session: "
              (lambda (string pred action)
                (if (eq action 'metadata)
                    `(metadata
                      (display-sort-function . identity)
                      (annotation-function
                       . ,(lambda (name)
                            (let ((session (cdr (assoc name table))))
                              (format "  %s  %s  %s repositories"
                                      (replace-regexp-in-string
                                       "T\\([0-9:]+\\).*" " \\1"
                                       (or (alist-get 'timestamp session) ""))
                                      (or (alist-get 'language session) "")
                                      (or (alist-get 'repository_count session) "?"))))))
                  (complete-with-action action table string pred)))
              nil t)))))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((query-buffer (current-buffer)))
    (with-current-buffer (get-buffer-create (format "*codeql-mrva: %s*" session))
      (codeql-mrva-mode)
      (setq codeql--mrva-session session)
      (setq codeql--mrva-query-buffer query-buffer)
      (revert-buffer)
      (pop-to-buffer (current-buffer)))))

(defun codeql--mrva-header-line ()
  "Return the `header-line-format' summary of the session status."
  (let ((status codeql--mrva-status))
    (if (not status)
        (format "%s: fetching status..." codeql--mrva-session)
      (format "%s: %s, %d findings in %d repositories, %d scans, %d failed, %d skipped"
              codeql--mrva-session
              (alist-get 'status status)
              (or (alist-get 'total_findings_count status) 0)
              (or (alist-get 'total_repositories_with_findings status) 0)
              (or (alist-get 'total_successful_scans status) 0)
              (or (alist-get 'total_failed_scans status) 0)
              (or (alist-get 'total_skipped_repositories status) 0)))))

(defun codeql--mrva-refresh ()
  "Fetch the status of the session of the current `codeql-mrva-mode' buffer."
  (let ((status (car (append (codeql--gh-json "mrva" "status" "--json"
                                              "--session" codeql--mrva-session)
                             nil))))
    (setq codeql--mrva-status status)
    (cl-loop for run across (or (alist-get 'runs status) [])
             when (equal (alist-get 'status run) "failed")
             do (message "Run %s of %s failed: %s"
                         (alist-get 'id run) (alist-get 'query_id run)
                         (alist-get 'failure_reason run)))
    (setq tabulated-list-entries
          (cl-loop for repo across (or (alist-get 'repositories_with_findings status) [])
                   collect (list repo
                                 (vector (alist-get 'nwo repo)
                                         (number-to-string (alist-get 'count repo))
                                         (number-to-string (or (alist-get 'stars repo) 0))
                                         (or (alist-get 'query_id repo) "")
                                         (number-to-string (alist-get 'run_id repo))))))
    (setq header-line-format (codeql--mrva-header-line))))

(defun codeql--mrva-numeric-sort (column)
  "Return a `tabulated-list-format' sort predicate of the numeric COLUMN."
  (lambda (a b)
    (< (string-to-number (aref (cadr a) column))
       (string-to-number (aref (cadr b) column)))))

(defvar codeql-mrva-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'codeql-mrva-load-results)
    map)
  "Keymap for `codeql-mrva-mode'.")

(define-derived-mode codeql-mrva-mode tabulated-list-mode "CodeQL-MRVA"
  "Major mode for the repositories with findings of a gh-mrva session.

\\<codeql-mrva-mode-map>\\[codeql-mrva-load-results] shows the results of the repository at point, \\[revert-buffer]
refreshes the session status.

\\{codeql-mrva-mode-map}"
  (setq tabulated-list-format
        (vector '("Repository" 40 t)
                (list "Findings" 9 (codeql--mrva-numeric-sort 1) :right-align t)
                (list "Stars" 7 (codeql--mrva-numeric-sort 2) :right-align t)
                '("Query" 35 t)
                '("Run" 12 t)))
  (setq tabulated-list-sort-key '("Stars" . t))
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'codeql--mrva-refresh nil t)
  (tabulated-list-init-header)
  (setq header-line-format (codeql--mrva-header-line)))

(defun codeql--mrva-query-pack-query (directory query)
  "Return the file of QUERY in the query pack extracted to DIRECTORY, or nil.

The dependencies bundled with the pack are left out.  Without a file of
the same name as QUERY, a pack of a single query has that one."
  (when (file-directory-p directory)
    (let ((files (seq-remove (lambda (file) (string-match-p "/\\.codeql/" file))
                             (directory-files-recursively directory "\\.ql\\'"))))
      (or (and query
               (seq-find (lambda (file)
                           (equal (file-name-nondirectory file) (file-name-nondirectory query)))
                         files))
          (and (= (length files) 1) (car files))))))

(defun codeql--mrva-fetch-query-pack (controller run-id directory)
  "Fetch the query pack of the variant analysis RUN-ID of CONTROLLER.

The pack is extracted to DIRECTORY.  Return non-nil on success."
  (require 'url)
  (when-let* ((analysis (codeql--gh-json
                         "api" (format "repos/%s/code-scanning/codeql/variant-analyses/%s"
                                       controller run-id)))
              (url (alist-get 'query_pack_url analysis)))
    (let ((archive (make-temp-file "codeql-mrva-pack" nil ".tgz")))
      (unwind-protect
          (progn
            (url-copy-file url archive t)
            (make-directory directory t)
            (or (eql 0 (call-process "tar" nil nil nil "-xzf" archive "-C" directory))
                (progn (delete-directory directory t) nil)))
        (delete-file archive)))))

(defun codeql--mrva-submitted-query (controller run-id query)
  "Return the text of QUERY as submitted in the variant analysis RUN-ID.

The text is taken from the query pack of the run, which is fetched from
CONTROLLER once.  Return (TEXT . t) for the submitted text, (TEXT . nil)
for the text of the QUERY file as it is now when the pack can't be
fetched, or nil when neither is available."
  (let ((directory (codeql--mrva-directory "queries" (format "%s" run-id))))
    (when (and controller (not (file-directory-p directory)))
      (message "Fetching the query pack of run %s..." run-id)
      (condition-case err
          (codeql--mrva-fetch-query-pack controller run-id directory)
        (error (message "Fetching the query pack of run %s failed: %s"
                        run-id (error-message-string err)))))
    (if-let ((file (codeql--mrva-query-pack-query directory query)))
        (cons (codeql--file-text file) t)
      (when (and query (file-name-absolute-p query) (file-readable-p query))
        (cons (codeql--file-text query) nil)))))

(defun codeql--file-text (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun codeql--mrva-provenance (session repo)
  "Return the provenance of the results of REPO in the gh-mrva SESSION.

See `codeql--query-provenance', its :kind is `mrva'.  :source holds the
whole query that ran, see `codeql--mrva-submitted-query'."
  (let* ((run-id (alist-get 'run_id repo))
         (query (alist-get 'query repo))
         (controller (alist-get 'controller
                                (seq-find (lambda (info) (equal (alist-get 'name info) session))
                                          (ignore-errors (codeql--mrva-sessions)))))
         (submitted (codeql--mrva-submitted-query controller run-id query)))
    (list :kind 'mrva
          :path (and query (file-name-absolute-p query) (file-exists-p query) query)
          :session session
          :run run-id
          :controller controller
          :repository (alist-get 'nwo repo)
          :source (car submitted)
          :source-submitted (cdr submitted))))

(defun codeql--mrva-show-results (repo directory query-buffer &optional session)
  "Show the downloaded results of REPO in DIRECTORY for QUERY-BUFFER.

SESSION is the gh-mrva session of REPO, see `codeql--mrva-provenance'."
  (let* ((nwo (alist-get 'nwo repo))
         (run-id (alist-get 'run_id repo))
         (base (expand-file-name (format "%s_%s" (string-replace "/" "_" nwo) run-id)
                                 directory))
         (sarif (concat base ".sarif"))
         (bqrs (concat base ".bqrs")))
    (unless (buffer-live-p query-buffer)
      (user-error "The query buffer of this session is gone, use M-x codeql-mrva again"))
    (cond
     ((file-exists-p sarif)
      (let ((sources (codeql--mrva-sources-directory nwo run-id)))
        (make-directory sources t)
        (let ((provenance (codeql--mrva-provenance session repo)))
          (with-current-buffer query-buffer
            (codeql-load-sarif sarif sources provenance)))))
     ((file-exists-p bqrs)
      (let ((text (with-current-buffer query-buffer
                    (codeql--cli-command-to-string
                     (list "bqrs" "decode" "--format=text" "--entities=string,url" bqrs)))))
        (with-current-buffer (get-buffer-create (format "*codeql-mrva: %s %s*" nwo run-id))
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (or text (format "Could not decode %s" bqrs))))
          (goto-char (point-min))
          (special-mode)
          (pop-to-buffer (current-buffer)))))
     (t (message "No results were downloaded for %s" nwo)))))

(defun codeql-mrva-load-results (repo)
  "Download and show the results of the gh-mrva REPO at point.

Results are downloaded below `codeql-state-dir' once.  SARIF results
are rendered like `codeql-load-sarif' does for a source checkout, whose
files are fetched from GitHub as they are visited, at the revision that
was analyzed.  Raw BQRS results are shown decoded."
  (interactive (list (or (tabulated-list-get-id)
                         (user-error "No repository at point"))))
  (let* ((nwo (alist-get 'nwo repo))
         (run-id (alist-get 'run_id repo))
         (directory (codeql--mrva-directory codeql--mrva-session))
         (base (expand-file-name (format "%s_%s" (string-replace "/" "_" nwo) run-id)
                                 directory))
         (query-buffer codeql--mrva-query-buffer)
         (session codeql--mrva-session)
         (gh (or (executable-find "gh")
                 (user-error "The gh CLI was not found, see https://cli.github.com"))))
    (if (or (file-exists-p (concat base ".sarif")) (file-exists-p (concat base ".bqrs")))
        (codeql--mrva-show-results repo directory query-buffer session)
      (make-directory directory t)
      (message "Downloading the results of %s..." nwo)
      (let ((output (generate-new-buffer " *codeql-mrva-download*")))
        (make-process
         :name "codeql-mrva-download"
         :buffer output
         :command (list gh "mrva" "download"
                        "--run" (number-to-string run-id)
                        "--nwo" nwo
                        "--output-dir" directory)
         :sentinel
         (lambda (process _event)
           (unless (process-live-p process)
             (let ((text (with-current-buffer output (string-trim (buffer-string)))))
               (kill-buffer output)
               (cond
                ((string-match-p "try again later" text)
                 (message "The results of %s are not ready yet" nwo))
                ((not (eql (process-exit-status process) 0))
                 (message "Downloading the results of %s failed: %s" nwo text))
                (t (codeql--mrva-show-results repo directory query-buffer session)))))))))))

;; request cancellation control

(defvar-local codeql--query-server-jsonrpc-current-id nil)
(defvar-local codeql--query-server-jsonrpc-current-deferred nil)
(defvar-local codeql--query-server-jsonrpc-current-connection nil)

(defun codeql--query-server-jsonrpc-register-request (id connection deferred)
  (message "Registering jsonrpc request: %s" id)
  (setq codeql--query-server-jsonrpc-current-id id)
  (setq codeql--query-server-jsonrpc-current-connection connection)
  (setq codeql--query-server-jsonrpc-current-deferred deferred))

(defun codeql--query-server-jsonrpc-unregister-request ()
  (message "Unregistering jsonrpc request: %s" codeql--query-server-jsonrpc-current-id)
  (setq codeql--query-server-jsonrpc-current-id nil)
  (setq codeql--query-server-jsonrpc-current-connection nil)
  (setq codeql--query-server-jsonrpc-current-deferred nil))

(declare-function jsonrpc--remove "jsonrpc")
(declare-function jsonrpc--request-continuations "jsonrpc")
(declare-function jsonrpc--deferred-actions "jsonrpc")

(defun codeql--jsonrpc-forget-request (connection id deferred-spec)
  "Make CONNECTION forget the continuations of request ID.

DEFERRED-SPEC is the key of its deferred action."
  (if (fboundp 'jsonrpc--remove)
      (jsonrpc--remove connection id deferred-spec)
    ;; jsonrpc before 1.0.24 keeps continuations in a hash table
    (remhash id (jsonrpc--request-continuations connection))
    (remhash deferred-spec (jsonrpc--deferred-actions connection))))

(defun codeql-query-server-cancel-query ()
  "Cancel a currently active query."
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (if (and codeql--query-server-jsonrpc-current-id
           codeql--query-server-jsonrpc-current-deferred
           codeql--query-server-jsonrpc-current-connection)
      (progn
        (message "Canceling query id: %s" codeql--query-server-jsonrpc-current-id)
        (jsonrpc-notify (codeql--query-server-current-or-error) :$/cancelRequest
                        `(:id ,codeql--query-server-jsonrpc-current-id))
        (codeql--jsonrpc-forget-request codeql--query-server-jsonrpc-current-connection
                                        codeql--query-server-jsonrpc-current-id
                                        (list codeql--query-server-jsonrpc-current-deferred
                                              (current-buffer)))
        (message "Query canceled."))
    (message "No active query running.")))

(cl-defun codeql--jsonrpc-async-request (connection
                                         method
                                         params
                                         &rest
                                         args
                                         &key
                                         _success-fn
                                         _error-fn
                                         _timeout-fn
                                         _timeout
                                         _deferred)
  ;; we need to get at the request id, so we use our own wrapper
  (apply #'jsonrpc--async-request-1 connection method params args))

(defun codeql--run-kind-label (quick-eval)
  "Describe a query run with QUICK-EVAL, see `codeql--query-target'."
  (pcase quick-eval
    ('nil "full-query")
    ('count "quick-eval count")
    ('predicate "quick-eval predicate")
    (_ "quick-eval")))

;; bound by code that quick evaluates text of a buffer that isn't displayed
(defvar codeql--quick-eval-region nil
  "When non-nil, the (BEG . END) of the code to quick evaluate.

It is used instead of the active region or point, see
`codeql--quick-eval-bounds'.")

(defun codeql--quick-eval-predicate-position (quick-eval)
  "Return the position of the predicate name that QUICK-EVAL evaluates, or nil.

That is the name of the predicate enclosing point when QUICK-EVAL is
`predicate' and neither `codeql--quick-eval-region' nor the region is
active, see `codeql--enclosing-predicate-name-position'."
  (and (eq quick-eval 'predicate)
       (not codeql--quick-eval-region)
       (not (use-region-p))
       (codeql--enclosing-predicate-name-position)))

(defun codeql--quick-eval-bounds (&optional quick-eval)
  "Return the (BEG . END) of what a quick evaluation evaluates.

That is `codeql--quick-eval-region' when it is bound, else the active
region, else the name of the enclosing predicate when QUICK-EVAL is
`predicate', or point."
  (let ((pred-pos (codeql--quick-eval-predicate-position quick-eval)))
    (cond (codeql--quick-eval-region)
          ((use-region-p) (car (region-bounds)))
          (pred-pos (cons pred-pos pred-pos))
          (t (cons (point) (point))))))

(defun codeql--query-target (query-path quick-eval)
  "Return the query server target for running QUERY-PATH.

When QUICK-EVAL is nil the whole query runs.  Otherwise the active
region, or point when there is none, is quick evaluated: the query
server evaluates the predicate or expression found there.  When
QUICK-EVAL is `predicate', the predicate enclosing point is evaluated
instead, see `codeql--enclosing-predicate-name-position'.  When
QUICK-EVAL is `count', only the number of results is computed.  See
`codeql--quick-eval-bounds' for code that is not in the region."
  (if quick-eval
      (let* ((bounds (codeql--quick-eval-bounds quick-eval))
             (min (car bounds))
             (max (cdr bounds)))
        ;; positions in CodeQL are 1-based
        `(:quickEval
          (:quickEvalPos
           (;; align
            :fileName ,(codeql--tramp-unwrap query-path)
            :line ,(line-number-at-pos min)
            :column ,(save-excursion (goto-char min) (codeql--lsp-abiding-column))
            :endLine ,(line-number-at-pos max)
            :endColumn ,(save-excursion (goto-char max) (codeql--lsp-abiding-column)))
           ,@(when (eq quick-eval 'count)
               '(:countOnly t)))))
    ;; any non-null value will trigger a full query run
    `(:query (:xx ""))))

(defun codeql--query-provenance (query-path quick-eval)
  "Return the provenance of running QUERY-PATH with QUICK-EVAL.

This describes the CodeQL code a run evaluates, for the Query Source
section of its results buffer.  It is captured from the current buffer
when the run is requested, so editing the buffer while the run is in
flight doesn't change it.  It's a plist whose :kind is either:

- `file': the whole query at :path ran.
- `quick-eval': the region, or what is at point when :at-point is
  non-nil, of the query at :path was quick evaluated.  :source holds
  the evaluated text exactly as it was submitted, :line and :column
  (both 1-based) where it starts, and :count is non-nil for a quick
  evaluation count.  :predicate is non-nil when the predicate
  enclosing point was evaluated, then :source is its name, see
  `codeql-query-server-quick-eval-predicate'.

Other code that runs queries, e.g. to evaluate a snippet that has no
file of its own, can pass a `quick-eval' provenance whose :path is nil."
  (if (not quick-eval)
      (list :kind 'file :path query-path)
    (let* ((pred-pos (codeql--quick-eval-predicate-position quick-eval))
           (bounds (codeql--quick-eval-bounds quick-eval))
           (beg (car bounds))
           (region (/= beg (cdr bounds))))
      (list :kind 'quick-eval
            :path query-path
            :count (eq quick-eval 'count)
            :at-point (not region)
            :predicate (and pred-pos t)
            :line (line-number-at-pos beg)
            :column (1+ (save-excursion (goto-char beg) (current-column)))
            :source (if region
                        (buffer-substring-no-properties beg (cdr bounds))
                      (or (save-excursion (goto-char beg) (thing-at-point 'symbol t))
                          ""))))))

(defvar codeql--query-result-handler nil
  "Function that receives the outcome of the query runs requested now.

When nil, results are shown in a results buffer and failures are
reported as messages.  Otherwise it is called with a plist whose
:status is one of:

- `results': the run produced the results in :bqrs-path.  The plist
  also holds :query-path, :db-path, :name, :kind and :id (from the
  query metadata, any of which can be nil), :quick-eval, :provenance,
  :buffer (the QL buffer the run was requested in), :src-filename,
  :src-root, :src-buffer and :log-path, see `codeql-load-bqrs'.
- `empty': the run finished without results.
- `error': the run failed, or was canceled, as described by :message.

The handler is captured when a run is requested, so let-bind this
around `codeql--query-server-run-query-from-path'.")

(defun codeql--query-run-history-name (query-path quick-eval provenance)
  "Return how the run of QUERY-PATH with QUICK-EVAL and PROVENANCE is named.

This names the run in query history, after the time it completed."
  (if (eq (plist-get provenance :kind) 'session)
      (format "%s %s: %s"
              (or (plist-get provenance :frontend) "session")
              (plist-get provenance :session)
              (truncate-string-to-width
               (replace-regexp-in-string "[ \t\n]+" " "
                                         (string-trim (or (plist-get provenance :input) "")))
               60 nil nil "..."))
    (format "%s (%s)" (file-name-nondirectory query-path)
            (codeql--run-kind-label quick-eval))))

(defun codeql--query-run-show (outcome)
  "Show the OUTCOME of a query run, see `codeql--query-result-handler'."
  (pcase (plist-get outcome :status)
    ('results
     (with-current-buffer (plist-get outcome :buffer)
       (codeql-load-bqrs
        (plist-get outcome :bqrs-path)
        (plist-get outcome :query-path)
        (plist-get outcome :db-path)
        (plist-get outcome :name)
        (plist-get outcome :kind)
        (plist-get outcome :id)
        (plist-get outcome :buffer)
        (plist-get outcome :src-filename)
        (plist-get outcome :src-root)
        (plist-get outcome :src-buffer)
        (plist-get outcome :provenance))))
    ('empty
     (message "No query results in %s!" (plist-get outcome :bqrs-path)))
    ('error
     (message "%s" (plist-get outcome :message)))))

(defun codeql--query-run-report (handler outcome)
  "Hand the OUTCOME of a query run to HANDLER, or show it when that is nil."
  (funcall (or handler #'codeql--query-run-show) outcome))

(defun codeql--query-run-failed (handler buffer-context message &rest properties)
  "Report to HANDLER that the run requested in BUFFER-CONTEXT failed with MESSAGE.

PROPERTIES are added to the outcome, see `codeql--query-result-handler'."
  (codeql--query-run-report
   handler `(:status error :message ,message :buffer ,buffer-context ,@properties)))

(defun codeql--query-run-completed (handler outcome)
  "Record the query run of OUTCOME in query history and report it to HANDLER.

OUTCOME is a `results' outcome, see `codeql--query-result-handler',
which becomes an `empty' one when the run has no results."
  (message "Query run completed, checking results.")
  (let* ((bqrs-path (plist-get outcome :bqrs-path))
         (buffer-context (plist-get outcome :buffer))
         (query-path (plist-get outcome :query-path))
         (bqrs-size (file-attribute-size (file-attributes bqrs-path))))
    ;; if size is > 0 then we have results to deal with
    (if (not (and bqrs-size (> bqrs-size 0)))
        (codeql--query-run-report handler (plist-put (copy-sequence outcome) :status 'empty))
      ;; save in query history, name/kind/id can be nil!
      ;; skip templated queries and session definition checks in query history
      (when (and (buffer-live-p buffer-context)
                 (not (codeql--templated-query-p query-path))
                 (not (plist-get (plist-get outcome :provenance) :check)))
        (with-current-buffer buffer-context
          (unless codeql--completed-query-history
            (setq codeql--completed-query-history (make-hash-table :test #'equal))
            (codeql--query-server-sync-state))
          (let ((timestamp (current-time-string))
                (log-path (plist-get outcome :log-path)))
            (puthash
             (format "[%s] %s [%s]"
                     timestamp
                     (codeql--query-run-history-name
                      query-path (plist-get outcome :quick-eval) (plist-get outcome :provenance))
                     (codeql-query-server-active-database))
             `(;; align
               :quick-eval ,(plist-get outcome :quick-eval)
               :provenance ,(plist-get outcome :provenance)
               :query-path ,query-path
               :bqrs-path ,bqrs-path
               :db-path ,(plist-get outcome :db-path)
               :timestamp ,timestamp
               :name ,(plist-get outcome :name)
               :kind ,(plist-get outcome :kind)
               :id ,(plist-get outcome :id)
               ,@(when log-path
                   (list :log-path (and (file-exists-p log-path) log-path))))
             codeql--completed-query-history))))
      (codeql--query-run-report handler outcome))))

(defun codeql--query-server-request-run (buffer-context
                                         qlo-path
                                         bqrs-path
                                         query-path
                                         query-info
                                         library-path
                                         db-path
                                         quick-eval
                                         &optional
                                         template-values
                                         src-filename
                                         src-buffer
                                         provenance
                                         handler)
  "Request a query evaluation from the query server.

PROVENANCE describes the evaluated code, see `codeql--query-provenance'.
HANDLER receives the outcome, see `codeql--query-result-handler'."
  (with-current-buffer buffer-context
    (let ((outcome
           `(;; align
             :status results
             :bqrs-path ,bqrs-path
             :query-path ,query-path
             :db-path ,db-path
             :name ,(json-pointer-get query-info "/name")
             :kind ,(json-pointer-get query-info "/kind")
             :id ,(json-pointer-get query-info "/id")
             :quick-eval ,quick-eval
             :provenance ,provenance
             :buffer ,buffer-context
             :src-filename ,src-filename
             :src-root ,codeql--database-source-archive-root
             :src-buffer ,src-buffer))
          (error-fn
           (jsonrpc-lambda (&key code message data &allow-other-keys)
             (when (buffer-live-p buffer-context)
               (with-current-buffer buffer-context
                 (codeql--query-server-jsonrpc-unregister-request)))
             (codeql--query-run-failed
              handler buffer-context
              (format "Error %s: %s\n%s\n" code message data)))))
      (cond
       ;; legacy query-server
       ((string= codeql-query-server "query-server")
        (let ((run-query-params
               `(:body
                 (:db
                  (;; align
                   :dbDir ,codeql--database-dataset-folder
                   :workingSet "default")
                  :evaluateId ,(codeql--query-server-next-evaluate-id)
                  :queries
                  (;; align
                   :resultsPath ,(codeql--tramp-unwrap bqrs-path)
                   :qlo ,(format "file:%s" (codeql--tramp-unwrap qlo-path))
                   :allowUnknownTemplates t
                   :templateValues ,template-values
                   :id 0
                   :timeoutSecs 0)
                  :stopOnError :json-false
                  :useSequenceHint :json-false)
                 :progressId ,(codeql--query-server-next-progress-id))))
          (message "Running query ...")
          (cl-multiple-value-bind (id _timer)
              (codeql--jsonrpc-async-request
               (codeql--query-server-current-or-error)
               :evaluation/runQueries run-query-params
               :timeout codeql-query-server-timeout
               :success-fn
               (jsonrpc-lambda
                   (&rest _)
                 (when (buffer-live-p buffer-context)
                   (with-current-buffer buffer-context
                     (codeql--query-server-jsonrpc-unregister-request)))
                 (codeql--query-run-completed handler outcome))
               :error-fn error-fn
               :deferred :evaluation/runQueries)
            (codeql--query-server-jsonrpc-register-request
             id (codeql--query-server-current-or-error)
             :evaluation/runQueries))))

       ;; query-server2
       ((string= codeql-query-server "query-server2")
        (let* ((query-target
                (codeql--query-target query-path quick-eval))
               (log-path (when codeql-evaluator-log
                           (concat (file-name-sans-extension bqrs-path) ".evaluator-log.jsonl")))
               (run-query-params
                `(:body
                  (;; align
                   :db ,(codeql--file-truename codeql--active-database)
                   :additionalPacks ,library-path
                   :externalInputs ()
                   :singletonExternalInputs ,(or template-values '())
                   :outputPath ,(codeql--tramp-unwrap bqrs-path)
                   :queryPath ,(codeql--tramp-unwrap query-path)
                   ;; do we want Datalog Intermediary Language dumps?
                   ;; https://codeql.github.com/docs/codeql-overview/codeql-glossary/#dil
                   ;;:dilPath: string
                   ,@(when log-path
                       (list :logPath (codeql--tramp-unwrap log-path)))
                   :target ,query-target)
                  :progressId ,(codeql--query-server-next-progress-id))))
          (message "Running query ...")
          (cl-multiple-value-bind (id _timer)
              (codeql--jsonrpc-async-request
               (codeql--query-server-current-or-error)
               :evaluation/runQuery run-query-params
               :timeout codeql-query-server-timeout
               :success-fn
               (jsonrpc-lambda
                   (&rest params)
                 (when (buffer-live-p buffer-context)
                   (with-current-buffer buffer-context
                     (codeql--query-server-jsonrpc-unregister-request)))
                 (let ((errors (codeql--query-server2-handle-message params)))
                   (if errors
                       (codeql--query-run-failed
                        handler buffer-context errors
                        :result-type (plist-get params :resultType))
                     (codeql--query-run-completed
                      handler (append outcome (list :log-path log-path))))))
               :error-fn error-fn
               :deferred :evaluation/runQuery)
            (codeql--query-server-jsonrpc-register-request
             id (codeql--query-server-current-or-error)
             :evaluation/runQuery))))))))

(defun codeql--query-server-request-compile-and-run (buffer-context
                                                     library-path
                                                     qlo-path
                                                     bqrs-path
                                                     query-path
                                                     query-info
                                                     db-path
                                                     db-scheme
                                                     quick-eval
                                                     &optional
                                                     template-values
                                                     src-filename
                                                     src-buffer
                                                     provenance
                                                     handler)
  "Request query compilation from the query server.

HANDLER receives the outcome, see `codeql--query-result-handler'."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (with-current-buffer buffer-context
    (let*
        ((query-target
          (codeql--query-target query-path quick-eval))
         (compile-query-params
          `(:body
            (:compilationOptions
             (;; align
              :computeNoLocationUrls t
              :failOnWarnings :json-false
              :fastCompilation :json-false
              :includeDilInQlo t
              :localChecking :json-false
              :noComputeGetUrl :json-false
              :noComputeToString :json-false
              :computeDefaultStrings t)
             :extraOptions
             (:timeoutSecs 0)
             :queryToCheck
             (;; align
              :libraryPath ,library-path
              :dbschemePath ,db-scheme
              :queryPath ,(codeql--tramp-unwrap query-path))
             :resultPath ,(codeql--tramp-unwrap qlo-path)
             :target ,query-target)
            :progressId ,(codeql--query-server-next-progress-id))))
      (cond
       ;; legacy query-server
       ((string= codeql-query-server "query-server")
        (message "Compiling query (%s) ..." (codeql--run-kind-label quick-eval))
        (cl-multiple-value-bind (id _timer)
            (codeql--jsonrpc-async-request
             (codeql--query-server-current-or-error)
             :compilation/compileQuery compile-query-params
             :timeout codeql-query-server-timeout
             :success-fn
             (jsonrpc-lambda
                 (&key messages &allow-other-keys)
               (when (buffer-live-p buffer-context)
                 (with-current-buffer buffer-context
                   (codeql--query-server-jsonrpc-unregister-request)))
               (message "Compilation completed, checking results.")
               (let ((errors nil))
                 (seq-map
                  (lambda (m)
                    (cl-destructuring-bind
                        (&key severity message &allow-other-keys) m
                      (message "[compilation/compileQuery] severity %s: %s" severity message)
                      (when (eql severity 0)
                        (message "[compilation/compileQuery] Aborting query! severity 0: %s" message)
                        (push message errors))))
                  messages)
                 (if errors
                     (codeql--query-run-failed
                      handler buffer-context (string-join (nreverse errors) "\n"))
                   ;; note: this is a nested jsonrpc request, maintain buffer-local context
                   (codeql--query-server-request-run
                    buffer-context qlo-path
                    bqrs-path query-path
                    query-info
                    library-path
                    db-path
                    quick-eval
                    template-values
                    src-filename
                    src-buffer
                    provenance
                    handler))))
             :error-fn
             (jsonrpc-lambda
                 (&key code message data &allow-other-keys)
               (when (buffer-live-p buffer-context)
                 (with-current-buffer buffer-context
                   (codeql--query-server-jsonrpc-unregister-request)))
               (codeql--query-run-failed
                handler buffer-context
                (format "Error %s: %s\n%s\n" code message data)))
             :deferred :compilation/compileQuery)
          ;; register this request so we can cancel it if need be
          (codeql--query-server-jsonrpc-register-request
           id (codeql--query-server-current-or-error)
           :compilation/compileQuery)))

       ;; query-server2, compilation is part of the runQuery request
       ((string= codeql-query-server "query-server2")
        (codeql--query-server-request-run
         buffer-context
         qlo-path
         bqrs-path
         query-path
         query-info
         library-path
         db-path
         quick-eval
         template-values
         src-filename
         src-buffer
         provenance
         handler))))))

(defun codeql--query-server-run-query-from-path (query-path
                                                 quick-eval
                                                 &optional
                                                 template-values
                                                 src-filename
                                                 src-buffer
                                                 provenance)
  "Run the query at QUERY-PATH.

PROVENANCE describes the code that runs, and defaults to what QUICK-EVAL
selects in the current buffer, see `codeql--query-provenance'.  It is
captured now, before the run is requested, as is the handler of the
outcome, see `codeql--query-result-handler'."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (cl-assert codeql--active-database t)
  (cl-assert (codeql--resolve-query-paths query-path) t)
  (let* ((qlo-path
          (let ((temporary-file-directory (codeql--tramp-wrap codeql-tmp-dir)))
            (make-temp-file "qlo" nil ".qlo")))
         (bqrs-path
          (let ((temporary-file-directory (codeql--tramp-wrap codeql-results-dir)))
            (make-temp-file "bqrs" nil ".bqrs")))
         (library-path codeql--library-path)
         (db-scheme codeql--dbscheme)
         (db-path (directory-file-name codeql--active-database))
         (query-info (codeql--query-info query-path))
         (provenance (or provenance (codeql--query-provenance query-path quick-eval))))
    ;; request a query compilation, its success callback will then request a query run
    (codeql--query-server-request-compile-and-run
     (current-buffer)
     library-path
     qlo-path
     bqrs-path
     query-path
     query-info
     db-path
     db-scheme
     quick-eval
     template-values
     src-filename
     src-buffer
     provenance
     codeql--query-result-handler)))

(defun codeql-query-server-run-query (&optional quick-eval)
  "Run a query or quick eval a query region.

With QUICK-EVAL, quick evaluate the region or what is at point even when
no region is active, see `codeql--query-target'."
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  ;; init the query history if need be
  (unless codeql--completed-query-history
    (setq codeql--completed-query-history (make-hash-table :test #'equal)))
  (if codeql--query-server
      (let* ((query-path (buffer-file-name))
             (quick-eval (or quick-eval (if (use-region-p) t nil))))
        (when (and (eq quick-eval 'count)
                   (string= codeql-query-server "query-server"))
          (user-error "Quick evaluation counts need query-server2"))
        ;; make sure we save the query before running it
        (when (or codeql--run-query-always-save
                  (and (buffer-modified-p)
                       (y-or-n-p "Query was not saved prior to evaluation, save now?")))
          (save-buffer))
        (codeql--query-server-run-query-from-path query-path quick-eval))
    (message "No query server started.")))

(defun codeql-query-server-quick-eval ()
  "Quick evaluate the active region, or the predicate or expression at point.

To evaluate a predicate, put point on its name."
  (interactive)
  (codeql-query-server-run-query t))

(defun codeql--enclosing-predicate-name-position (&optional pos)
  "Return the position of the name of the predicate enclosing POS, or nil.

POS defaults to point.  Predicates are member predicates, classless
predicates and characteristic predicates, whose name is their class
name.  Return nil when POS is outside of any predicate, e.g. in the
select clause, or when no QL syntax tree is available."
  (let ((pos (or pos (point))))
    (cond
     ;; builtin tree-sitter, emacs 29+
     ((and (fboundp 'treesit-parser-list)
           (treesit-parser-list nil 'ql))
      (cl-loop for node = (treesit-node-at pos 'ql) then (treesit-node-parent node)
               while node
               for type = (treesit-node-type node)
               when (member type '("memberPredicate" "classlessPredicate"))
               return (treesit-node-start (treesit-node-child-by-field-name node "name"))
               when (equal type "charpred")
               return (treesit-node-start (treesit-node-child node 0 t))))
     ;; emacs-tree-sitter, emacs 28-
     ((and (bound-and-true-p tree-sitter-tree)
           (fboundp 'tree-sitter-node-at-pos))
      (cl-loop for node = (tree-sitter-node-at-pos nil pos) then (tsc-get-parent node)
               while node
               for type = (tsc-node-type node)
               when (memq type '(memberPredicate classlessPredicate))
               return (tsc-node-start-position (tsc-get-child-by-field node :name))
               when (eq type 'charpred)
               return (tsc-node-start-position (tsc-get-nth-named-child node 0)))))))

(defun codeql-query-server-quick-eval-predicate ()
  "Quick evaluate the predicate enclosing point, or the active region.

Unlike `codeql-query-server-quick-eval', point can be anywhere in the
predicate, not just on its name.  Outside of any predicate, e.g. in the
select clause, the whole query runs."
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (cond ((use-region-p)
         (codeql-query-server-run-query t))
        ((codeql--enclosing-predicate-name-position)
         (codeql-query-server-run-query 'predicate))
        (t
         (message "Not in a predicate, running the whole query.")
         (codeql-query-server-run-query))))

(defun codeql-query-server-quick-eval-count ()
  "Count the results of quick evaluating the region or what is at point.

This is faster than `codeql-query-server-quick-eval' for predicates
with many results, as their tuples aren't decoded and rendered."
  (interactive)
  (codeql-query-server-run-query 'count))

(defun codeql-query-history ()
  "Offer query history selection to the user."
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (if (and codeql--completed-query-history (not (eql 0 (hash-table-count codeql--completed-query-history))))
      (let* ((query-keys (vconcat (hash-table-keys codeql--completed-query-history)))
             (query (completing-read "Query History: " (reverse (append query-keys nil)) nil t)))
        (when query
          (let ((query-data (gethash query codeql--completed-query-history)))
            (cl-destructuring-bind
                (&key
                 query-path
                 bqrs-path
                 timestamp
                 db-path
                 name kind
                 id
                 provenance &allow-other-keys)
                query-data
              (let ((org-results (format "%s.org" bqrs-path)))
                ;; since we render results in a flat text format
                ;; we store it to disk on first render
                (if (file-exists-p org-results)
                    (find-file org-results)
                  (codeql-load-bqrs
                   bqrs-path
                   query-path
                   db-path
                   name
                   kind
                   id
                   (current-buffer)
                   nil nil nil
                   provenance)))))))
    ;; XXX: do we want to serialize query history state to disk?
    (message "No query history available yet in this session.")))

;;; Comparing the results of two query runs

(defun codeql--history-entry-label (data)
  "Return a short label for the query history entry DATA."
  (cl-destructuring-bind (&key query-path timestamp quick-eval &allow-other-keys) data
    (format "%s%s@%s"
            (file-name-nondirectory query-path)
            (if quick-eval " quick-eval" "")
            ;; the time of day of a `current-time-string' timestamp
            (if (and timestamp (>= (length timestamp) 19)) (substring timestamp 11 19) "?"))))

(defun codeql--history-entry-interpreted-p (data)
  "Return non-nil if the history entry DATA has problem or path-problem results."
  (and (member (plist-get data :kind) '("problem" "path-problem"))
       (plist-get data :id)
       t))

(defun codeql--bqrs-row-counts (bqrs-path)
  "Return an alist of the result set names and row counts of BQRS-PATH."
  (when-let ((info (codeql--bqrs-info bqrs-path)))
    (cl-loop for result-set across (alist-get 'result-sets info)
             collect (cons (alist-get 'name result-set)
                           (or (alist-get 'rows result-set) 0)))))

(defun codeql--bqrs-column-counts (bqrs-path)
  "Return an alist of the result set names and column counts of BQRS-PATH."
  (when-let ((info (codeql--bqrs-info bqrs-path)))
    (cl-loop for result-set across (alist-get 'result-sets info)
             collect (cons (alist-get 'name result-set)
                           (length (alist-get 'columns result-set))))))

(defun codeql--check-comparable-result-sets (from-bqrs to-bqrs)
  "Signal a `user-error' unless FROM-BQRS and TO-BQRS can be compared.

They must have result sets of the same names, and those must have the
same number of columns."
  (let ((from-columns (codeql--bqrs-column-counts from-bqrs))
        (to-columns (codeql--bqrs-column-counts to-bqrs)))
    (unless (and from-columns to-columns)
      (user-error "Could not read the result sets to compare"))
    (unless (equal (sort (mapcar #'car from-columns) #'string<)
                   (sort (mapcar #'car to-columns) #'string<))
      (user-error "The queries have different result sets: %s and %s"
                  (mapconcat #'car from-columns ", ")
                  (mapconcat #'car to-columns ", ")))
    (cl-loop for (name . columns) in from-columns
             for to = (cdr (assoc name to-columns))
             unless (= columns to)
             do (user-error "The columns of %s do not match: %d and %d"
                            name columns to))))

(defun codeql--compared-rows (counts)
  "Return the number of compared result rows in the alist of row COUNTS.

Path graph result sets are copied rather than compared by `codeql bqrs
diff', so this is the size of #select when there is one."
  (or (alist-get "#select" counts nil nil #'equal)
      (apply #'+ (mapcar #'cdr counts))))

(defun codeql-query-history-compare (from to)
  "Compare the results of the query history entries FROM and TO.

The rows only found in the results of FROM, and those only found in the
results of TO, are shown side by side in two results buffers that work
like any other.  Both runs must be on the active database, and must have
compatible result sets, e.g. be runs of two versions of a query.

Interactively, prompt for FROM and then for TO."
  (interactive
   (progn
     (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
     (unless (and codeql--completed-query-history
                  (> (hash-table-count codeql--completed-query-history) 1))
       (user-error "Comparing needs at least two queries in the query history"))
     (let* ((keys (reverse (hash-table-keys codeql--completed-query-history)))
            (from (completing-read "Compare query results of: " keys nil t))
            (from-db (plist-get (gethash from codeql--completed-query-history) :db-path))
            (others (seq-filter
                     (lambda (key)
                       (and (not (equal key from))
                            (equal (plist-get (gethash key codeql--completed-query-history)
                                              :db-path)
                                   from-db)))
                     keys)))
       (unless others
         (user-error "No other query in the history ran on the same database"))
       (list from (completing-read (format "Compare %s with: " from) others nil t)))))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let ((from-data (gethash from codeql--completed-query-history))
        (to-data (gethash to codeql--completed-query-history)))
    (unless (and from-data to-data)
      (user-error "Unknown query history entry"))
    (unless (equal (plist-get from-data :db-path) (plist-get to-data :db-path))
      (user-error "Only results of queries on the same database can be compared"))
    (unless (and codeql--active-database
                 (equal (directory-file-name (plist-get from-data :db-path))
                        (directory-file-name codeql--active-database)))
      (user-error "Register %s to compare the results of its queries"
                  (plist-get from-data :db-path)))
    (unless (eq (codeql--history-entry-interpreted-p from-data)
                (codeql--history-entry-interpreted-p to-data))
      (user-error "Problem results can only be compared with problem results"))
    (codeql--check-comparable-result-sets (plist-get from-data :bqrs-path)
                                          (plist-get to-data :bqrs-path))
    (let* ((left (let ((temporary-file-directory (codeql--tramp-wrap codeql-results-dir)))
                   (make-temp-file "bqrs" nil ".bqrs")))
           (right (let ((temporary-file-directory (codeql--tramp-wrap codeql-results-dir)))
                    (make-temp-file "bqrs" nil ".bqrs")))
           (from-label (codeql--history-entry-label from-data))
           (to-label (codeql--history-entry-label to-data)))
      (message "Comparing %s with %s ..." from-label to-label)
      (unless (codeql--cli-command-to-string
               (list "bqrs" "diff"
                     (format "--left=%s" (codeql--tramp-unwrap left))
                     (format "--right=%s" (codeql--tramp-unwrap right))
                     "--"
                     (codeql--tramp-unwrap (plist-get from-data :bqrs-path))
                     (codeql--tramp-unwrap (plist-get to-data :bqrs-path))))
        (user-error "Could not compare the results, are their result sets compatible?"))
      (let* ((from-rows (codeql--compared-rows
                         (codeql--bqrs-row-counts (plist-get from-data :bqrs-path))))
             (to-rows (codeql--compared-rows
                       (codeql--bqrs-row-counts (plist-get to-data :bqrs-path))))
             (left-rows (codeql--compared-rows (codeql--bqrs-row-counts left)))
             (right-rows (codeql--compared-rows (codeql--bqrs-row-counts right)))
             (buffers
              (cl-loop for (bqrs rows label data) in
                       `((,left ,left-rows ,(format "only in %s" from-label) ,from-data)
                         (,right ,right-rows ,(format "only in %s" to-label) ,to-data))
                       when (> rows 0)
                       collect
                       (let ((before (buffer-list))
                             (codeql--results-marker-suffix label))
                         (cl-destructuring-bind (&key query-path db-path name kind id
                                                      provenance &allow-other-keys)
                             data
                           (save-window-excursion
                             (codeql-load-bqrs bqrs query-path db-path name kind id
                                               (current-buffer) nil nil nil
                                               provenance)))
                         (seq-find (lambda (buffer)
                                     (and (not (memq buffer before))
                                          (string-prefix-p "* codeql-org-results:"
                                                           (buffer-name buffer))))
                                   (buffer-list))))))
        (setq buffers (delq nil buffers))
        (when buffers
          (let ((window (display-buffer (car buffers) '(nil (inhibit-same-window . t)))))
            (when (cadr buffers)
              (set-window-buffer (split-window window nil 'right) (cadr buffers)))))
        (message "%s: %d of %d rows only in %s, %d of %d rows only in %s%s"
                 (if (and (zerop left-rows) (zerop right-rows))
                     "The results are the same"
                   "Compared results")
                 left-rows from-rows from-label right-rows to-rows to-label
                 (if (and (> left-rows 0) (= left-rows from-rows) (= right-rows to-rows))
                     ", no rows in common"
                   ""))))))

;;; Query performance

(defun codeql--evaluator-log-summary (log-path)
  "Return the predicate events of the evaluator log at LOG-PATH.

The log is summarized by `codeql generate log-summary', and the summary is
kept next to the log for later use.  Each event is a plist."
  (let ((summary-path (concat (file-name-sans-extension log-path) ".summary.jsonl")))
    (unless (file-exists-p summary-path)
      (message "Summarizing the evaluator log ...")
      (unless (codeql--cli-command-to-string
               (list "generate" "log-summary" "--format=predicates" "--minify-output"
                     "--" (codeql--tramp-unwrap log-path) (codeql--tramp-unwrap summary-path)))
        (user-error "Could not summarize the evaluator log %s" log-path)))
    (with-temp-buffer
      (insert-file-contents summary-path)
      (goto-char (point-min))
      (let (events)
        (while (progn (skip-chars-forward " \t\r\n") (not (eobp)))
          (let ((event (json-parse-buffer :object-type 'plist :null-object nil)))
            (when (plist-get event :predicateName)
              (push event events))))
        (nreverse events)))))

(defun codeql--performance-history-entries ()
  "Return the query history keys of runs with an evaluator log, newest first."
  (when codeql--completed-query-history
    (let (entries)
      (maphash (lambda (key data)
                 (when (plist-get data :log-path)
                   (push (cons (date-to-time (plist-get data :timestamp)) key) entries)))
               codeql--completed-query-history)
      (mapcar #'cdr (sort entries (lambda (a b) (time-less-p (car b) (car a))))))))

(defun codeql--read-performance-history-entry (prompt &optional exclude)
  "Read a query history key with an evaluator log with PROMPT, other than EXCLUDE."
  (let ((keys (remove exclude (codeql--performance-history-entries))))
    (unless keys
      (user-error (if exclude
                      "No other query in the history has an evaluator log"
                    "No query in the history has an evaluator log, see `codeql-evaluator-log'")))
    (completing-read prompt keys nil t nil nil (car keys))))

(defun codeql--performance-computed-events (events)
  "Return the EVENTS of predicates that were computed, the slowest first."
  (seq-sort-by (lambda (event) (plist-get event :millis)) #'>
               (seq-filter (lambda (event) (plist-get event :millis)) events)))

(defun codeql--performance-predicate-cell (name)
  "Return the predicate NAME as the text of an org table cell."
  (codeql--escape-org-description (codeql--org-table-cell name)))

(defun codeql--performance-cell-predicate (cell)
  "Return the predicate name shown in the org table CELL."
  (replace-regexp-in-string "\u200b" "" cell t t))

(defun codeql--performance-predicate-link (event)
  "Return an org link to the definition of the predicate of EVENT, or its name."
  (let ((name (codeql--performance-predicate-cell (plist-get event :predicateName)))
        (position (plist-get event :position)))
    (if (and position (string-match "\\`\\(.*\\):\\([0-9]+\\),[0-9]+-[0-9]+,[0-9]+\\'" position))
        (format "[[file:%s::%s][%s]]"
                (codeql--tramp-wrap (match-string 1 position))
                (match-string 2 position)
                name)
      name)))

(defun codeql--performance-strategy (event)
  "Return a short name for the evaluation strategy of EVENT."
  (pcase (plist-get event :evaluationStrategy)
    ("COMPUTE_SIMPLE" "simple")
    ("COMPUTE_RECURSIVE" "recursive")
    ("COMPUTED_EXTENSIONAL" "extensional")
    (strategy (downcase (or strategy "?")))))

(defvar-local codeql--performance-events nil
  "The predicate events of the evaluator log shown in a query performance buffer.")

(defvar codeql-performance-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-a") #'codeql-performance-show-ra)
    map)
  "Keymap for `codeql-performance-mode'.")

(define-minor-mode codeql-performance-mode
  "Minor mode for query performance buffers.

\\{codeql-performance-mode-map}"
  :lighter " CodeQL-Perf"
  :keymap codeql-performance-mode-map)

(defun codeql--performance-buffer (name events)
  "Return a new org buffer NAME for the evaluator log EVENTS."
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (org-mode)
      (codeql-performance-mode 1)
      (setq codeql--performance-events events))
    buffer))

(defun codeql--performance-insert-table (header rows)
  "Insert an org table with HEADER and ROWS, both lists of org cell strings."
  (insert (codeql--org-table rows header)))

(defun codeql-query-performance (entry)
  "Show where the time of the query run ENTRY of the query history went.

The evaluator log of the run is summarized, and the predicates that were
computed are listed in an org table, the slowest first.  Each predicate
links to its definition, and `codeql-performance-show-ra' shows the
relational algebra it was evaluated with.  Sort the table with
`org-table-sort-lines'.

Interactively, prompt for a run, defaulting to the most recent one."
  (interactive
   (progn
     (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
     (list (codeql--read-performance-history-entry "Query performance of: "))))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let* ((data (or (gethash entry codeql--completed-query-history)
                   (user-error "Unknown query history entry")))
         (log-path (or (plist-get data :log-path)
                       (user-error "%s has no evaluator log" entry)))
         (events (codeql--evaluator-log-summary log-path))
         (computed (codeql--performance-computed-events events))
         (shown (seq-take computed codeql-performance-max-predicates))
         (buffer (codeql--performance-buffer
                  (format "* codeql-performance:%s *"
                          (file-name-nondirectory (plist-get data :query-path)))
                  events)))
    (with-current-buffer buffer
      (insert (format "#+TITLE: Query performance of %s\n\n" entry))
      (insert (format "Evaluation time: %s ms in %d computed predicates (%d cache hits, %d empty)\n"
                      (apply #'+ (mapcar (lambda (event) (plist-get event :millis)) computed))
                      (length computed)
                      (seq-count (lambda (event)
                                   (equal (plist-get event :evaluationStrategy) "CACHE_HIT"))
                                 events)
                      (seq-count (lambda (event)
                                   (equal (plist-get event :evaluationStrategy) "SENTINEL_EMPTY"))
                                 events)))
      (when (< (length shown) (length computed))
        (insert (format "Showing the %d slowest predicates.\n" (length shown))))
      (insert "\n")
      (codeql--performance-insert-table
       '("Time (ms)" "Tuples" "Iterations" "Strategy" "Predicate")
       (mapcar (lambda (event)
                 (list (number-to-string (plist-get event :millis))
                       (number-to-string (or (plist-get event :resultSize) 0))
                       (number-to-string (max 1 (length (plist-get event :deltaSizes))))
                       (codeql--performance-strategy event)
                       (codeql--performance-predicate-link event)))
               shown))
      (goto-char (point-min))
      (set-buffer-modified-p nil))
    (switch-to-buffer-other-window buffer)))

(defun codeql--performance-predicate-at-point ()
  "Return the name of the predicate in the table row at point, if any."
  (codeql--require-org)
  (when (org-at-table-p)
    (let ((cell (car (last (split-string
                            (buffer-substring-no-properties (line-beginning-position)
                                                            (line-end-position))
                            "|" t "[ \t]+")))))
      (if (and cell (string-match "\\`\\[\\[.*\\]\\[\\(.*\\)\\]\\]\\'" cell))
          (match-string 1 cell)
        cell))))

(defun codeql-performance-show-ra (name)
  "Show the relational algebra that the predicate NAME was evaluated with.

Interactively, NAME is the predicate in the table row at point."
  (interactive
   (list (let ((at-point (codeql--performance-predicate-at-point))
               (names (delete-dups
                       (mapcar (lambda (event) (plist-get event :predicateName))
                               (seq-filter (lambda (event) (plist-get event :ra))
                                           codeql--performance-events)))))
           (if (and at-point (member (codeql--performance-cell-predicate at-point) names))
               (codeql--performance-cell-predicate at-point)
             (completing-read "Show the RA of: " names nil t)))))
  (let ((events (seq-filter (lambda (event)
                              (and (equal (plist-get event :predicateName) name)
                                   (plist-get event :ra)))
                            codeql--performance-events)))
    (unless events
      (user-error "No relational algebra for %s" name))
    (with-current-buffer (get-buffer-create "*codeql-performance-ra*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (event events)
          (insert (format "%s\n  %s, %s ms, %s tuples%s\n"
                          name
                          (codeql--performance-strategy event)
                          (or (plist-get event :millis) "?")
                          (or (plist-get event :resultSize) "?")
                          (if-let ((deltas (plist-get event :deltaSizes)))
                              (format ", %d iterations with deltas %s"
                                      (length deltas)
                                      (mapconcat #'number-to-string deltas " "))
                            "")))
          (let ((ra (plist-get event :ra))
                (runs (plist-get event :pipelineRuns)))
            (while ra
              (let* ((pipeline (substring (symbol-name (car ra)) 1))
                     (counts (seq-some (lambda (run)
                                         (and (equal (plist-get run :raReference) pipeline)
                                              (plist-get run :counts)))
                                       runs)))
                (insert (format "\n  pipeline %s%s:\n" pipeline
                                (if counts
                                    (format " (tuple counts per step: %s)"
                                            (mapconcat #'number-to-string counts " "))
                                  "")))
                (seq-doseq (line (cadr ra))
                  (insert line "\n")))
              (setq ra (cddr ra))))
          (insert "\n")))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer)))))

(defun codeql--performance-millis-by-predicate (events)
  "Return a hash table of the total time and tuples of each predicate in EVENTS."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (event events)
      (when-let ((millis (plist-get event :millis)))
        (let ((entry (gethash (plist-get event :predicateName) table (cons 0 0))))
          (puthash (plist-get event :predicateName)
                   (cons (+ (car entry) millis)
                         (+ (cdr entry) (or (plist-get event :resultSize) 0)))
                   table))))
    table))

(defun codeql-query-performance-compare (from to)
  "Compare where the time of the query runs FROM and TO went.

The computed predicates of both runs are matched by name and listed in an
org table, the largest difference in time first.

Interactively, prompt for FROM and then for TO."
  (interactive
   (progn
     (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
     (let ((from (codeql--read-performance-history-entry "Compare query performance of: ")))
       (list from (codeql--read-performance-history-entry
                   (format "Compare %s with: " from) from)))))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let* ((from-data (or (gethash from codeql--completed-query-history)
                        (user-error "Unknown query history entry")))
         (to-data (or (gethash to codeql--completed-query-history)
                      (user-error "Unknown query history entry")))
         (from-events (codeql--evaluator-log-summary
                       (or (plist-get from-data :log-path)
                           (user-error "%s has no evaluator log" from))))
         (to-events (codeql--evaluator-log-summary
                     (or (plist-get to-data :log-path)
                         (user-error "%s has no evaluator log" to))))
         (from-table (codeql--performance-millis-by-predicate from-events))
         (to-table (codeql--performance-millis-by-predicate to-events))
         (names (delete-dups (append (hash-table-keys from-table) (hash-table-keys to-table))))
         (rows (mapcar (lambda (name)
                         (let ((a (gethash name from-table))
                               (b (gethash name to-table)))
                           (list name a b (- (if b (car b) 0) (if a (car a) 0)))))
                       names))
         (rows (seq-sort-by (lambda (row) (abs (nth 3 row))) #'> rows))
         (total (lambda (table)
                  (let ((sum 0))
                    (maphash (lambda (_ entry) (setq sum (+ sum (car entry)))) table)
                    sum)))
         (buffer (codeql--performance-buffer
                  (format "* codeql-performance-compare:%s *"
                          (file-name-nondirectory (plist-get to-data :query-path)))
                  (append from-events to-events))))
    (with-current-buffer buffer
      (insert (format "#+TITLE: Query performance of %s compared with %s\n\n" to from))
      (insert (format "Evaluation time: %s ms in %d computed predicates, compared with %s ms in %d\n"
                      (funcall total to-table) (hash-table-count to-table)
                      (funcall total from-table) (hash-table-count from-table)))
      (when (> (length rows) codeql-performance-max-predicates)
        (insert (format "Showing the %d largest differences.\n" codeql-performance-max-predicates)))
      (insert "\n")
      (codeql--performance-insert-table
       '("Delta (ms)" "Before (ms)" "After (ms)" "Tuples before" "Tuples after" "Predicate")
       (mapcar (lambda (row)
                 (cl-destructuring-bind (name a b delta) row
                   (list (format "%+d" delta)
                         (if a (number-to-string (car a)) "-")
                         (if b (number-to-string (car b)) "-")
                         (if a (number-to-string (cdr a)) "-")
                         (if b (number-to-string (cdr b)) "-")
                         (codeql--performance-predicate-cell name))))
               (seq-take rows codeql-performance-max-predicates)))
      (goto-char (point-min))
      (set-buffer-modified-p nil))
    (switch-to-buffer-other-window buffer)))

;;; Database history, by project

(declare-function consult--read "ext:consult")
(declare-function consult--type-group "ext:consult")
(declare-function consult--type-narrow "ext:consult")
(defvar embark-keymap-alist)

(defun codeql--database-history-file ()
  "Return the file that the database history is kept in."
  (or codeql-database-history-file
      (let ((default-directory "~/"))
        (expand-file-name "database-history.eld" (expand-file-name codeql-state-dir)))))

(defun codeql--database-history ()
  "Return the database history, reading it from its file if need be."
  (when (eq codeql--database-history 'unloaded)
    (setq codeql--database-history
          (let ((file (codeql--database-history-file)))
            (when (file-readable-p file)
              (condition-case err
                  (with-temp-buffer
                    (insert-file-contents file)
                    (seq-filter (lambda (entry) (plist-get entry :path))
                                (read (current-buffer))))
                (error
                 (message "Could not read the database history %s: %s"
                          file (error-message-string err))
                 nil))))))
  codeql--database-history)

(defun codeql--database-history-save ()
  "Write the database history to its file."
  (let ((file (codeql--database-history-file))
        (entries (codeql--database-history)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (let ((print-length nil)
            (print-level nil))
        (insert ";; -*- mode: lisp-data -*-\n"
                ";; The CodeQL databases registered in each project, by emacs-codeql.\n")
        (prin1 entries (current-buffer))
        (insert "\n")))))

(defun codeql--database-history-project ()
  "Return the project that databases registered in the current buffer belong to.

This is the root of the version controlled project of the buffer, or the
root of its CodeQL pack, or else its directory."
  (abbreviate-file-name
   (file-name-as-directory
    (expand-file-name
     (or (when-let ((project (let ((project-find-functions
                                    (remq #'project-codeql project-find-functions)))
                               (project-current nil default-directory))))
           (project-root project))
         (codeql--find-project-root default-directory)
         default-directory)))))

(defun codeql--database-history-path (database-path)
  "Return DATABASE-PATH the way it is kept in the database history."
  (directory-file-name (expand-file-name database-path)))

(defun codeql--database-history-add (database-path language)
  "Record that DATABASE-PATH, of LANGUAGE, was registered in the current project."
  ;; pick up what other Emacs sessions recorded meanwhile
  (setq codeql--database-history 'unloaded)
  (let* ((path (codeql--database-history-path database-path))
         (project (codeql--database-history-project))
         (now (float-time))
         (entries (codeql--database-history))
         (old (seq-find (lambda (entry)
                          (and (equal (plist-get entry :path) path)
                               (equal (plist-get entry :project) project)))
                        entries)))
    (setq codeql--database-history
          (cons (list :path path
                      :project project
                      :language (or language (plist-get old :language))
                      :added (or (plist-get old :added) now)
                      :used now)
                (delq old entries)))
    (condition-case err
        (codeql--database-history-save)
      (error (message "Could not save the database history: %s" (error-message-string err))))))

(defun codeql-database-history-remove (database-path)
  "Remove DATABASE-PATH from the database history of all projects.

This only forgets about the database, it stays on disk."
  (interactive (list (codeql--read-database "Remove from database history: ")))
  (setq codeql--database-history 'unloaded)
  (let ((path (codeql--database-history-path database-path)))
    (setq codeql--database-history
          (seq-remove (lambda (entry) (equal (plist-get entry :path) path))
                      (codeql--database-history)))
    (codeql--database-history-save)
    (message "Removed %s from the database history" path)))

(defun codeql--database-history-entries ()
  "Return the database history entries offered in the current buffer.

These are the databases on the host of the current buffer, those of its
project first, most recently used first, and then those only registered
in other projects.  Each database is listed once."
  (let* ((project (codeql--database-history-project))
         (remote (file-remote-p default-directory))
         (entries (seq-sort-by (lambda (entry) (or (plist-get entry :used) 0)) #'>
                               (seq-filter (lambda (entry)
                                             (equal (file-remote-p (plist-get entry :path))
                                                    remote))
                                           (codeql--database-history))))
         (ours (seq-filter (lambda (entry) (equal (plist-get entry :project) project))
                           entries))
         (seen (mapcar (lambda (entry) (plist-get entry :path)) ours))
         (others (seq-filter (lambda (entry)
                               (unless (member (plist-get entry :path) seen)
                                 (push (plist-get entry :path) seen)))
                             entries)))
    (list ours others)))

(defun codeql--database-annotation (entry other)
  "Return the completion annotation of the database history ENTRY.

OTHER is non-nil when ENTRY belongs to another project."
  (let ((path (plist-get entry :path)))
    (concat
     (propertize " " 'display '(space :align-to (max 50 (+ left 2))))
     (propertize (format "%-12s" (or (plist-get entry :language) "?"))
                 'face 'font-lock-type-face)
     (propertize (format-time-string "%Y-%m-%d %H:%M" (plist-get entry :used))
                 'face 'completions-annotations)
     (when other
       (propertize (format "  %s" (plist-get entry :project))
                   'face 'completions-annotations))
     ;; checking remote databases would be slow
     (unless (or (file-remote-p path) (file-directory-p path))
       (propertize "  missing" 'face 'error)))))

(defun codeql--read-database (prompt)
  "Read a database from the database history with PROMPT, and return its path.

With consult installed, the databases of the current project and of other
projects can be narrowed to with p and o."
  (pcase-let* ((`(,ours ,others) (codeql--database-history-entries))
               (annotations (make-hash-table :test #'equal))
               (candidates
                (append
                 (mapcar (lambda (entry)
                           (let ((cand (abbreviate-file-name (plist-get entry :path))))
                             (puthash cand (codeql--database-annotation entry nil) annotations)
                             (propertize cand 'consult--type ?p)))
                         ours)
                 (mapcar (lambda (entry)
                           (let ((cand (abbreviate-file-name (plist-get entry :path))))
                             (puthash cand (codeql--database-annotation entry t) annotations)
                             (propertize cand 'consult--type ?o)))
                         others)))
               (annotate (lambda (cand) (gethash cand annotations)))
               (types '((?p . "This project") (?o . "Other projects"))))
    (unless candidates
      (user-error "No databases in the history yet, register one with `codeql-query-server-register-database'"))
    (expand-file-name
     (if (require 'consult nil t)
        (consult--read candidates
                       :prompt prompt
                       :category 'codeql-database
                       :require-match t
                       :sort nil
                       :annotate annotate
                       :group (consult--type-group types)
                       :narrow (consult--type-narrow types))
      (completing-read
       prompt
       (lambda (string predicate action)
         (if (eq action 'metadata)
             `(metadata (category . codeql-database)
                        (display-sort-function . identity)
                        (annotation-function . ,annotate)
                        (group-function
                         . ,(lambda (cand transform)
                              (if transform
                                  cand
                                (alist-get (if (member (expand-file-name cand)
                                                       (mapcar (lambda (entry)
                                                                 (plist-get entry :path))
                                                               ours))
                                               ?p ?o)
                                           types)))))
           (complete-with-action action candidates string predicate)))
       nil t)))))

(defun codeql-database-history ()
  "Register a database from the database history.

The history is kept across sessions in `codeql-database-history-file'.
The databases registered in the project of the query buffer are offered
first, most recently used first, followed by those registered in other
projects.  Only databases on the host of the query buffer are offered.
A project is a version controlled directory tree, or else a CodeQL pack."
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (codeql-query-server-register-database (codeql--read-database "Database: ")))

(defun codeql--last-database ()
  "Return the database last registered in the project of the current buffer.

Databases that no longer exist are skipped."
  (when-let* ((entry (seq-find (lambda (entry)
                                 (let ((path (plist-get entry :path)))
                                   (or (file-remote-p path) (file-directory-p path))))
                               (car (codeql--database-history-entries)))))
    (plist-get entry :path)))

(defun codeql--register-last-database ()
  "Register the database last registered in the project of the current buffer."
  (unless codeql--active-database
    (when-let* ((path (codeql--last-database)))
      (message "Registering the last database of this project: %s" path)
      (codeql-query-server-register-database path))))

(defun codeql--database-unbundle (archive)
  "Unbundle the database ARCHIVE into `codeql-state-dir' and return its path.

An archive that was unbundled before is reused."
  (let* ((target (expand-file-name (codeql--tramp-wrap (concat codeql-state-dir "/databases"))))
         (name (file-name-base archive))
         (database (expand-file-name name target)))
    (if (file-exists-p (expand-file-name "codeql-database.yml" database))
        (message "Using %s, unbundled from %s before" database archive)
      (make-directory target t)
      (message "Unbundling %s ..." archive)
      (unless (codeql--cli-command-to-string
               (list "database" "unbundle"
                     (format "--name=%s" name)
                     (format "--target=%s" (codeql--tramp-unwrap target))
                     "--" (codeql--tramp-unwrap (expand-file-name archive))))
        (user-error "Could not unbundle %s" archive))
      (unless (file-exists-p (expand-file-name "codeql-database.yml" database))
        (user-error "%s is not a CodeQL database archive" archive))
      (message "Unbundled %s into %s" archive database))
    database))

(defun codeql-database-dired (database-path)
  "Open the directory of DATABASE-PATH."
  (interactive (list (codeql--read-database "Open database directory: ")))
  (dired (expand-file-name database-path)))

(defun codeql-database-copy-path (database-path)
  "Copy DATABASE-PATH to the kill ring."
  (interactive (list (codeql--read-database "Copy database path: ")))
  (kill-new (expand-file-name database-path))
  (message "Copied %s" (expand-file-name database-path)))

(defun codeql--database-lock-files (database-path)
  "Return the evaluation cache lock files of the database at DATABASE-PATH."
  (seq-filter #'file-exists-p
              (file-expand-wildcards
               (expand-file-name "db-*/default/cache/.lock" database-path))))

(defun codeql--database-users (database-path)
  "Return the QL buffers whose running query server uses DATABASE-PATH."
  (let ((database (file-name-as-directory (expand-file-name database-path))))
    (seq-filter
     (lambda (buffer)
       (with-current-buffer buffer
         (and (eq major-mode 'ql-tree-sitter-mode)
              codeql--active-database
              codeql--query-server
              (jsonrpc-running-p codeql--query-server)
              (equal (file-name-as-directory
                      (expand-file-name (codeql--tramp-wrap codeql--active-database)))
                     database))))
     (buffer-list))))

(defun codeql--lock-file-holders (file)
  "Return the PIDs of the processes that have FILE open, if that can be told."
  (when (and (not (file-remote-p file)) (executable-find "lsof"))
    (with-temp-buffer
      (when (eql 0 (call-process "lsof" nil t nil "-t" "--" file))
        (split-string (buffer-string) nil t)))))

(defun codeql-database-delete-lock (database-path)
  "Delete the evaluation cache lock files of the database at DATABASE-PATH.

A query server that crashed or was killed can leave its database locked,
so that other query servers fail to evaluate queries against it.  This
deletes the db-LANGUAGE/default/cache/.lock files of the database, after
confirmation.

Interactively, this is the active database of the current QL buffer.
With a prefix argument, or without an active database, the database is
read from the database history, or as a directory when it's empty."
  (interactive
   (list (if (and (not current-prefix-arg)
                  (eq major-mode 'ql-tree-sitter-mode)
                  codeql--active-database)
             (codeql--tramp-wrap codeql--active-database)
           (if (or (car (codeql--database-history-entries))
                   (cadr (codeql--database-history-entries)))
               (codeql--read-database "Delete the lock of database: ")
             (read-directory-name "Delete the lock of database: " nil nil t)))))
  (let* ((database (expand-file-name database-path))
         (locks (codeql--database-lock-files database))
         (users (codeql--database-users database))
         (holders (delete-dups (mapcan #'codeql--lock-file-holders locks))))
    (unless (file-exists-p (expand-file-name "codeql-database.yml" database))
      (user-error "Not a CodeQL database: %s" database))
    (if (not locks)
        (message "No lock files in %s" database)
      (when (yes-or-no-p
             (concat
              (format "Delete %s? "
                      (mapconcat (lambda (lock) (file-relative-name lock database))
                                 locks ", "))
              (cond
               (users
                (format "The query server of %s uses this database, deleting its lock \
can corrupt the cache.  Delete anyway? "
                        (mapconcat #'buffer-name users ", ")))
               (holders
                (format "Process%s %s still %s it open.  Delete anyway? "
                        (if (cdr holders) "es" "")
                        (string-join holders ", ")
                        (if (cdr holders) "have" "has")))
               (t ""))))
        (dolist (lock locks)
          (delete-file lock))
        (message "Deleted %d lock file%s of %s"
                 (length locks) (if (cdr locks) "s" "") database)))))

(defvar codeql-database-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'codeql-query-server-register-database)
    (define-key map (kbd "r") #'codeql-query-server-register-database)
    (define-key map (kbd "k") #'codeql-database-history-remove)
    (define-key map (kbd "d") #'codeql-database-dired)
    (define-key map (kbd "w") #'codeql-database-copy-path)
    (define-key map (kbd "u") #'codeql-database-delete-lock)
    map)
  "Embark actions for databases in the database history.")

(with-eval-after-load 'embark
  (add-to-list 'embark-keymap-alist '(codeql-database . codeql-database-map)))

;;; Checking the health of the setup

(declare-function eglot-current-server "eglot")

(defun codeql--doctor-run (program &rest args)
  "Run PROGRAM with ARGS in `default-directory'.

Return (EXIT-CODE . FIRST-LINE-OF-OUTPUT), or nil when it can't run."
  (condition-case nil
      (with-temp-buffer
        (let ((code (apply #'process-file program nil (list (current-buffer) nil) nil args)))
          (cons code (car (split-string (buffer-string) "\n" t "[ \t\r]+")))))
    (error nil)))

(defun codeql--doctor-line (status label &optional detail)
  "Return a report line of STATUS for LABEL, with optional DETAIL.

STATUS is one of the symbols ok, info, warn or error."
  (format "  %s %s%s\n"
          (propertize (format "%-7s" (format "[%s]" status))
                      'face (pcase status
                              ('ok 'success)
                              ('warn 'warning)
                              ('error 'error)
                              (_ 'shadow)))
          label
          (if detail (format ": %s" detail) "")))

(defun codeql--doctor-cli-checks (cli)
  "Return the `codeql-doctor' checks of the CodeQL CLI command CLI."
  (let ((remote (file-remote-p default-directory))
        (gh (executable-find "gh" (file-remote-p default-directory)))
        (version (and (car cli)
                      (apply #'codeql--doctor-run
                             (codeql--tramp-unwrap (car cli))
                             (append (cdr cli) '("version" "--format=terse"))))))
    (append
     (list
      (cond
       ((null (car cli))
        '(error "CLI" "not found, set `codeql-cli' or install the gh codeql extension"))
       ((eql 0 (car-safe version))
        (list 'ok "CLI" (format "%s, version %s"
                                (mapconcat #'identity cli " ") (cdr version))))
       (t (list 'error "CLI" (format "%s doesn't run: %s"
                                     (mapconcat #'identity cli " ")
                                     (or (cdr-safe version) "no output")))))
      (if gh
          (list 'ok "gh" gh)
        '(info "gh" "not found, it's only needed for the gh codeql extension")))
     (when gh
       (list
        (cond
         ((not (codeql--gh-codeql-cli-available-p))
          '(info "gh codeql" "not installed"))
         (codeql-use-gh-codeql-extension-when-available
          '(ok "gh codeql" "installed and preferred"))
         (t '(info "gh codeql" "disabled by `codeql-use-gh-codeql-extension-when-available'")))
        (if (and (not remote) (eql 0 (car-safe (codeql--doctor-run gh "mrva" "--help"))))
            '(ok "gh mrva" "installed")
          '(info "gh mrva" "not installed, it's needed for `codeql-mrva'"))))
     (mapcar (lambda (path)
               (if (codeql--file-exists-p path)
                   (list 'ok "Search path" path)
                 (list 'warn "Search path" (format "%s doesn't exist" path))))
             codeql-search-paths)
     (when remote
       (list (list 'info "Host" remote))))))

(defun codeql--doctor-tool-checks ()
  "Return the `codeql-doctor' checks of the external tools."
  (let ((remote (file-remote-p default-directory)))
    (list
     (if-let ((unzip (executable-find "unzip" remote)))
         (list 'ok "unzip" unzip)
       '(error "unzip" "not found, database source archives can't be extracted"))
     (if-let ((zipinfo (executable-find "zipinfo" remote)))
         (list 'ok "zipinfo" zipinfo)
       '(info "zipinfo" "not found, unzip is used to list source archives"))
     (cond
      ((not codeql-graph-format)
       '(info "dot" "graph results are shown as dot files, see `codeql-graph-format'"))
      ((executable-find "dot" remote)
       (list 'ok "dot" (executable-find "dot" remote)))
      (t '(warn "dot" "graphviz not found, graph results are shown as dot files"))))))

(defun codeql--doctor-buffer-checks ()
  "Return the `codeql-doctor' checks of the state of the current QL buffer."
  (list
   (if (and codeql--query-server (jsonrpc-running-p codeql--query-server))
       (list 'ok "Query server" (format "running (%s)" codeql-query-server))
     '(info "Query server" "not running"))
   (if codeql--active-database
       (list 'ok "Database" codeql--active-database)
     '(info "Database" "none registered"))
   (cond
    ((not (featurep 'eglot)) '(info "Language server" "no eglot"))
    ((eglot-current-server) '(ok "Language server" "connected"))
    (t '(info "Language server" "not connected")))
   (list 'info "Search paths" (format "%d configured"
                                      (length codeql--search-paths-buffer-local)))))

(defun codeql--doctor-checks (ql-buffer)
  "Return the sections of the `codeql-doctor' report.

Each is a (TITLE . CHECKS) cons, where CHECKS are (STATUS LABEL DETAIL)
lists.  QL-BUFFER is the QL buffer whose state is checked, or nil."
  (let ((cli (or (and ql-buffer (buffer-local-value 'codeql--cli-buffer-local ql-buffer))
                 (ignore-errors (codeql--cli-for-host))))
        (live-cli-servers (cl-loop for proc being the hash-values of codeql--cli-servers
                                   count (codeql--cli-server-live-p proc))))
    (append
     (list
      (list "Emacs"
            (list 'info "Emacs" emacs-version)
            (cond
             ((and (fboundp 'treesit-ready-p) (treesit-ready-p 'ql t))
              '(ok "Tree-sitter" "builtin treesit with the ql grammar"))
             ((featurep 'tree-sitter)
              '(ok "Tree-sitter" "elisp-tree-sitter"))
             (t '(error "Tree-sitter" "no ql grammar available")))
            (cond
             ((not codeql-configure-eglot-lsp)
              '(info "Eglot" "the language server is disabled by `codeql-configure-eglot-lsp'"))
             ((featurep 'eglot) '(ok "Eglot" "configured for the CodeQL language server"))
             (t '(warn "Eglot" "not available, there is no language server support"))))
      (cons "CodeQL CLI" (codeql--doctor-cli-checks cli))
      (cons "Tools" (codeql--doctor-tool-checks)))
     (when ql-buffer
       (list (cons (format "Buffer %s" (buffer-name ql-buffer))
                   (with-current-buffer ql-buffer
                     (codeql--doctor-buffer-checks)))))
     (list
      (list "CLI servers"
            (list 'info "Running"
                  (format "%d%s" live-cli-servers
                          (if codeql-use-cli-server
                              ""
                            ", disabled by `codeql-use-cli-server'"))))))))

(defun codeql-doctor ()
  "Report on the health of the emacs-codeql setup, like nvim's :checkhealth.

This checks the CodeQL CLI and the tools emacs-codeql depends on for the
host of the current buffer, and the query server, database and language
server state of the current QL buffer."
  (interactive)
  (let* ((ql-buffer (and (eq major-mode 'ql-tree-sitter-mode) (current-buffer)))
         (sections (codeql--doctor-checks ql-buffer))
         (checks (apply #'append (mapcar #'cdr sections)))
         (errors (cl-count 'error checks :key #'car))
         (warnings (cl-count 'warn checks :key #'car)))
    (with-current-buffer (get-buffer-create "*codeql-doctor*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "emacs-codeql doctor, %s: %d error%s, %d warning%s\n"
                        (format-time-string "%F %T")
                        errors (if (= errors 1) "" "s")
                        warnings (if (= warnings 1) "" "s")))
        (pcase-dolist (`(,title . ,section-checks) sections)
          (insert "\n" (propertize title 'face 'bold) "\n")
          (dolist (check section-checks)
            (insert (apply #'codeql--doctor-line check))))
        (goto-char (point-min)))
      (special-mode)
      (display-buffer (current-buffer)))))

;;; Query server connections

(defun codeql--query-server-live ()
  "Return the running query servers, with what they were started with."
  (let (servers)
    (maphash (lambda (server info)
               (if (jsonrpc-running-p server)
                   (push (cons server info) servers)
                 (remhash server codeql--query-servers)))
             codeql--query-servers)
    servers))

(defun codeql--query-server-annotation (server info)
  "Return the completion annotation of query SERVER, started with INFO."
  (let* ((all (codeql--query-server-buffers server))
         (buffers (codeql--query-server-user-buffers server))
         (database (and all (buffer-local-value 'codeql--active-database (car all))))
         (minutes (round (- (float-time) (plist-get info :started)) 60)))
    (concat
     (propertize " " 'display '(space :align-to (max 50 (+ left 2))))
     (propertize (format "%-24s" (if database
                                     (file-name-base (directory-file-name database))
                                   "no database"))
                 'face (if database 'font-lock-type-face 'shadow))
     (if buffers
         (propertize (format "%-11s" (format "%d buffer%s" (length buffers)
                                             (if (= (length buffers) 1) "" "s")))
                     'face 'completions-annotations)
       (propertize (format "%-11s" "detached") 'face 'warning))
     (propertize (if (< minutes 60)
                     (format "up %dm" minutes)
                   (format "up %dh%02dm" (/ minutes 60) (% minutes 60)))
                 'face 'completions-annotations)
     (when (and buffers (memq (current-buffer) buffers))
       (propertize "  this buffer" 'face 'success)))))

(defun codeql--read-query-server (prompt)
  "Read a running query server with PROMPT, and return its connection.

The servers of the current project come first, and the server of the
current buffer first of all.  With consult installed, the servers of
the current project and of other projects can be narrowed to with p
and o."
  (let* ((current (and (eq major-mode 'ql-tree-sitter-mode) codeql--query-server))
         (project (codeql--database-history-project))
         (remote (file-remote-p default-directory))
         (servers (seq-sort-by
                   (lambda (entry)
                     (list (if (eq (car entry) current) 0 1)
                           (- (plist-get (cdr entry) :started))))
                   (lambda (a b) (or (< (car a) (car b))
                                     (and (= (car a) (car b)) (< (cadr a) (cadr b)))))
                   (codeql--query-server-live)))
         (servers (append (seq-filter (lambda (entry)
                                        (or (eq (car entry) current)
                                            (and (equal (plist-get (cdr entry) :project) project)
                                                 (equal (plist-get (cdr entry) :remote) remote))))
                                      servers)
                          (seq-remove (lambda (entry)
                                        (or (eq (car entry) current)
                                            (and (equal (plist-get (cdr entry) :project) project)
                                                 (equal (plist-get (cdr entry) :remote) remote))))
                                      servers)))
         (lookup (make-hash-table :test #'equal))
         (annotations (make-hash-table :test #'equal))
         (groups (make-hash-table :test #'equal))
         (candidates
          (mapcar
           (lambda (entry)
             (pcase-let* ((`(,server . ,info) entry)
                          (ours (or (eq server current)
                                    (and (equal (plist-get info :project) project)
                                         (equal (plist-get info :remote) remote))))
                          (label (concat (or (plist-get info :remote) "")
                                         (plist-get info :project)))
                          (buffers (codeql--query-server-user-buffers server)))
               ;; per buffer servers can share a project
               (when (and (gethash label lookup) buffers)
                 (setq label (format "%s [%s]" label (buffer-name (car buffers)))))
               (let ((base label) (n 1))
                 (while (gethash label lookup)
                   (setq label (format "%s <%d>" base (cl-incf n)))))
               (puthash label server lookup)
               (puthash label (codeql--query-server-annotation server info) annotations)
               (puthash label (if ours ?p ?o) groups)
               (propertize label 'consult--type (if ours ?p ?o))))
           servers))
         (annotate (lambda (cand) (gethash cand annotations)))
         (types '((?p . "This project") (?o . "Other projects"))))
    (unless candidates
      (user-error "No query servers are running"))
    (gethash
     (if (require 'consult nil t)
         (consult--read candidates
                        :prompt prompt
                        :category 'codeql-query-server
                        :require-match t
                        :sort nil
                        :annotate annotate
                        :group (consult--type-group types)
                        :narrow (consult--type-narrow types))
       (completing-read
        prompt
        (lambda (string predicate action)
          (if (eq action 'metadata)
              `(metadata (category . codeql-query-server)
                         (display-sort-function . identity)
                         (annotation-function . ,annotate)
                         (group-function
                          . ,(lambda (cand transform)
                               (if transform
                                   cand
                                 (alist-get (gethash cand groups) types)))))
            (complete-with-action action candidates string predicate)))
        nil t))
     lookup)))

(defun codeql--query-server-buffers-or-error (server)
  "Return the QL buffers that use query SERVER, hidden ones last.
Signal an error when there are none."
  (or (append (codeql--query-server-user-buffers server)
              (seq-filter (lambda (buffer)
                            (buffer-local-value 'codeql--query-server-holder buffer))
                          (codeql--query-server-buffers server)))
      (user-error "No QL buffer uses this query server")))

(defun codeql-query-server-switch-to-buffer (server)
  "Switch to a QL buffer that uses query SERVER."
  (interactive (list (codeql--read-query-server "Switch to a buffer of query server: ")))
  (let ((buffers (or (codeql--query-server-user-buffers server)
                     (user-error "No QL buffer uses this query server, it is detached"))))
    (pop-to-buffer-same-window
     (if (cdr buffers)
         (read-buffer "Buffer: " (car buffers) t
                      (lambda (cand)
                        (memq (get-buffer (if (consp cand) (car cand) cand)) buffers)))
       (car buffers)))))

(defun codeql-query-server-shutdown (server)
  "Shut down query SERVER, for all the QL buffers that use it."
  (interactive (list (codeql--read-query-server "Shut down query server: ")))
  (jsonrpc-shutdown server))

(defun codeql-query-server-shutdown-all ()
  "Shut down all running query servers."
  (interactive)
  (let ((servers (mapcar #'car (codeql--query-server-live))))
    (if (not servers)
        (message "No query servers are running")
      (when (y-or-n-p (format "Shut down %d query server%s? "
                              (length servers) (if (cdr servers) "s" "")))
        (mapc #'jsonrpc-shutdown servers)))))

(defun codeql-query-server-restart (server)
  "Restart query SERVER with the options it was started with.

The QL buffers that used it use the new server, keep their query history
and get their active database registered again."
  (interactive (list (codeql--read-query-server "Restart query server: ")))
  (let* ((info (gethash server codeql--query-servers))
         (buffers (codeql--query-server-buffers-or-error server))
         (buffer (car buffers))
         (database (buffer-local-value 'codeql--active-database buffer)))
    (let ((codeql--query-server-restarting t))
      (jsonrpc-shutdown server))
    (with-current-buffer buffer
      (let ((codeql-register-last-database (and (not database)
                                                codeql-register-last-database)))
        (codeql--query-server-start (plist-get info :args)))
      (dolist (other (cdr buffers))
        (when (buffer-live-p other)
          (with-current-buffer other
            (unless codeql--query-server
              (codeql--query-server-copy-state buffer)))))
      (when database
        (codeql-query-server-register-database (codeql--tramp-wrap database))))))

(defun codeql-query-server-events-buffer (server)
  "Display the JSON-RPC events buffer of query SERVER."
  (interactive (list (codeql--read-query-server "Events of query server: ")))
  (display-buffer (jsonrpc-events-buffer server)))

(defun codeql-query-server-stderr-buffer (server)
  "Display the standard error buffer of query SERVER."
  (interactive (list (codeql--read-query-server "Stderr of query server: ")))
  (display-buffer
   (or (and (fboundp 'jsonrpc-stderr-buffer)
            (buffer-live-p (jsonrpc-stderr-buffer server))
            (jsonrpc-stderr-buffer server))
       ;; jsonrpc hides the stderr buffer that the server was started with
       (get-buffer (format " *%s stderr*" (jsonrpc-name server)))
       (get-buffer (format "*%s stderr*" (jsonrpc-name server)))
       (user-error "Query server %s has no stderr buffer" (jsonrpc-name server)))))

(defun codeql-query-server-use (server)
  "Use query SERVER, its database and query history in the current QL buffer."
  (interactive
   (progn
     (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
     (list (codeql--read-query-server "Use query server: "))))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (cond
   ((eq server codeql--query-server)
    (message "This buffer already uses that query server"))
   (codeql--query-server
    (user-error "This buffer already has a query server, stop it first"))
   (t
    (codeql-query-server-inherit (car (codeql--query-server-buffers-or-error server))))))

(defun codeql-query-servers ()
  "Pick a running query server and act on it.

The servers of the current project come first, annotated with their
active database, the number of QL buffers that use them, and how long
they have been running.  Then choose to switch to one of its buffers,
restart it, shut it down, show its JSON-RPC events or stderr, or use
it in the current QL buffer.  With embark, the same actions are in
`codeql-query-server-map'."
  (interactive)
  (let* ((server (codeql--read-query-server "Query server: "))
         (choices `((?b "buffer" "switch to one of its buffers")
                    (?r "restart" "restart it, keeping the database")
                    (?k "kill" "shut it down")
                    (?e "events" "show its JSON-RPC events")
                    (?l "log" "show its stderr")
                    ,@(when (and (eq major-mode 'ql-tree-sitter-mode)
                                 (not codeql--query-server))
                        '((?u "use" "use it in this buffer")))))
         (choice (car (read-multiple-choice (format "%s: " (jsonrpc-name server)) choices))))
    (pcase choice
      (?b (codeql-query-server-switch-to-buffer server))
      (?r (codeql-query-server-restart server))
      (?k (codeql-query-server-shutdown server))
      (?e (codeql-query-server-events-buffer server))
      (?l (codeql-query-server-stderr-buffer server))
      (?u (codeql-query-server-use server)))))

(defvar codeql-query-server-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'codeql-query-server-switch-to-buffer)
    (define-key map (kbd "b") #'codeql-query-server-switch-to-buffer)
    (define-key map (kbd "r") #'codeql-query-server-restart)
    (define-key map (kbd "k") #'codeql-query-server-shutdown)
    (define-key map (kbd "e") #'codeql-query-server-events-buffer)
    (define-key map (kbd "l") #'codeql-query-server-stderr-buffer)
    (define-key map (kbd "u") #'codeql-query-server-use)
    map)
  "Embark actions for running query servers.")

(with-eval-after-load 'embark
  (add-to-list 'embark-keymap-alist '(codeql-query-server . codeql-query-server-map)))

;;; transient ui for buffer-local server state management

(transient-define-argument codeql-transient-query-server:--threads ()
  "Use this many threads to evaluate queries."
  :description "threads"
  :class 'transient-option
  :shortarg "t"
  :argument "--threads=")

(transient-define-argument codeql-transient-query-server:--max-disk-cache ()
  :description "disk cache"
  :class 'transient-option
  :shortarg "c"
  :argument "--max-disk-cache=")

(transient-define-argument codeql-transient-query-server:--logdir ()
  :description "log dir"
  :class 'transient-option
  :shortarg "d"
  :argument "--logdir=")

(transient-define-argument codeql-transient-query-server:--verbose ()
  :description "verbosity"
  :class 'transient-switches
  :key "v"
  :argument-format "--%s"
  :argument-regexp "\\(--\\(quiet\\|verbose\\)\\)"
  :choices '("quiet" "verbose"))

;; helpers for the query server transient

(defun codeql--query-server-resolve-ram (&optional max-ram)
  "Resolve ram options for jvm, optionally bounding to MAX-RAM in MB."
  (let ((options (codeql--cli-command-to-string
                  (append (list "resolve" "ram")
                          (when max-ram (list (format "-M=%s" max-ram)))
                          (list "--")))))
    (when options
      ;; errr ... it's late
      (split-string (string-trim-right options) "\n"))))

(defconst codeql--remote-server-ready-marker "CODEQL-SERVER-READY"
  "Printed by a remote server command once its tty is in raw mode.")

(defvar tramp-use-connection-share)
(defvar tramp-use-ssh-controlmaster-options)

(defun codeql--make-server-process (coding &rest args)
  "Start a server process with `make-process' ARGS and CODING, and return it.

The process is started in the remote context of `default-directory'.

TRAMP ignores the :coding argument of `make-process' and uses its own
connection coding, which encodes newlines as carriage returns when the
remote host is Darwin.  Since `codeql--query-server-cmd' puts the
remote tty in raw mode, those carriage returns would reach the server
untranslated and corrupt the JSON-RPC headers, so CODING is set after
the process is started.

A remote server gets its own ssh connection.  When it shares the
connection of TRAMP, server output that is not read while TRAMP waits
for one of its own commands stalls that connection, and Emacs hangs.

TRAMP also returns a remote process before its command has started, and
input sent before the tty is in raw mode can be lost.  For remote
processes, wait until `codeql--query-server-cmd' signals readiness."
  (let* ((share (if (boundp 'tramp-use-connection-share) 'suppress nil))
         (tramp-use-connection-share share)
         (proc (with-suppressed-warnings
                   ((obsolete tramp-use-ssh-controlmaster-options))
                 ;; older TRAMP versions only know this name
                 (let ((tramp-use-ssh-controlmaster-options share))
                   (apply #'make-process :coding coding :file-handler t args)))))
    (set-process-coding-system proc coding coding)
    (when (file-remote-p default-directory)
      (let ((filter (process-filter proc))
            (output "")
            (ready nil)
            (deadline (+ (float-time) codeql-remote-server-ready-timeout)))
        (set-process-filter
         proc (lambda (_proc string) (setq output (concat output string))))
        (unwind-protect
            (while (and (not (setq ready (string-search
                                          codeql--remote-server-ready-marker output)))
                        (process-live-p proc)
                        (< (float-time) deadline))
              (accept-process-output proc 0.1 nil t))
          (set-process-filter proc filter))
        (if (not ready)
            (message "Remote server process did not become ready: %s" output)
          (let ((rest (substring output (+ ready (length codeql--remote-server-ready-marker)))))
            (unless (string-empty-p rest)
              (funcall filter proc rest))))))
    proc))

(defun codeql--jsonrpc-events-buffer-args ()
  "Initargs that bound the size of a query server's jsonrpc events buffer."
  ;; newer jsonrpc replaced :events-buffer-scrollback-size and warns about it
  (if (slot-exists-p 'jsonrpc-process-connection '-events-buffer-config)
      (list :events-buffer-config
            (list :size codeql-query-server-events-buffer-size))
    (list :events-buffer-scrollback-size codeql-query-server-events-buffer-size)))

;; workaround from eglot.el, disable line buffering if in remote context
(defun codeql--query-server-cmd (contact)
  "Helper for codeql query server connection."
  (if (file-remote-p default-directory)
      (list "sh" "-c"
            (string-join (append (list "stty raw > /dev/null;"
                                       "printf %s" codeql--remote-server-ready-marker ";")
                                 (mapcar #'shell-quote-argument contact))
                         " "))
    contact))

(defun codeql--query-server-start (args)
  "Start a query server for the current buffer with the user ARGS.

The server is shared with the buffers that `codeql-share-query-server'
says should share it."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (let* ((ram-options (codeql--query-server-resolve-ram codeql--query-server-max-ram))
         (server-args (append
                       args
                       ram-options
                       ;; non-user arguments go here
                       (cond
                        ;; old query-server options
                        ((string= codeql-query-server "query-server")
                         '("--require-db-registration"))
                        ;; new query-server options
                        ((string= codeql-query-server "query-server2")
                         nil))))
         (project (codeql--query-server-project)))
    (cl-assert ram-options t)
    ;; spawn the server process
    (let* ((name (format "CODEQL Query Server (%s%s)"
                         ;; add remote prefix if its there to dedicate event buffer
                         (or (file-remote-p default-directory) "")
                         (if codeql-share-query-server
                             ;; name shared servers after what they are shared by
                             (if (eq codeql-share-query-server 'project)
                                 (file-name-nondirectory (directory-file-name project))
                               "shared")
                           ;; show query file name for this server if available
                           (format "%s -> %s"
                                   (file-name-base (directory-file-name default-directory))
                                   (or (file-name-nondirectory (buffer-file-name))
                                       "(no file name)")))))
           (cmd (append
                 codeql--cli-buffer-local
                 (list "execute"
                       ;; determine which query server to use
                       ;; prefer query-server2 when available
                       ;; don't confuse this with codeql--query-server, which is the rpc connection
                       (or codeql-query-server
                           (setq codeql-query-server
                                 (codeql--resolve-query-server))))
                 server-args)))
      (message "Starting query server.")
      ;; manage these buffer local
      (setq codeql--query-server
            (apply
             #'make-instance
             'jsonrpc-process-connection
             :process
             ;; spawn in the remote context if need be
             (let* ((default-directory default-directory)
                    (cmd (codeql--query-server-cmd cmd)))
               (message "Starting query server with: %s" cmd)
               (codeql--make-server-process
                'utf-8-emacs-unix
                :name name
                :command cmd
                :connection-type 'pipe
                :noquery t
                :stderr (get-buffer-create (format "*%s stderr*" name))))
             :name name
             :notification-dispatcher #'codeql--query-server-handle-notification
             :request-dispatcher #'codeql--query-server-handle-request
             :on-shutdown
             (let ((buffer-context (current-buffer)))
               (lambda (obj)
                 (codeql--query-server-on-shutdown obj buffer-context)))
             (codeql--jsonrpc-events-buffer-args)))
      (puthash codeql--query-server
               (list :project project
                     :remote (file-remote-p default-directory)
                     :args args
                     :started (float-time))
               codeql--query-servers)
      ;; created up front so that buffers sharing this server share it too
      (unless codeql--completed-query-history
        (setq codeql--completed-query-history (make-hash-table :test #'equal)))
      (codeql--query-server-share)
      (message "Started query server.")
      (when codeql-register-last-database
        (codeql--register-last-database)))))

(defun codeql--query-server-shareable ()
  "Return a QL buffer whose query server the current buffer should share."
  (when codeql-share-query-server
    (let ((key (codeql--query-server-share-key)))
      (seq-find (lambda (buffer)
                  (and (not (eq buffer (current-buffer)))
                       (buffer-local-value 'codeql--query-server buffer)
                       (equal (with-current-buffer buffer
                                (codeql--query-server-share-key))
                              key)))
                (codeql--ql-buffers)))))

(defun codeql-query-server-start (&optional arg)
  "Start a query server for the current QL buffer.

The server is started with `codeql-query-server-default-args'.  With a
prefix ARG, pick the server options in a transient instead.

When another buffer of the same project already has a query server, and
`codeql-share-query-server' says to share it, that server is used."
  (interactive "P")
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (cond
   (codeql--query-server
    (message "There is already a query server running"))
   ((codeql--query-server-shareable)
    (codeql--query-server-adopt))
   (arg
    (transient-setup 'codeql-transient-query-server-init-start))
   (t
    (codeql--query-server-start codeql-query-server-default-args))))

(transient-define-suffix codeql-transient-query-server-start ()
  "Start a CodeQL query server."
  :description "start"
  :transient nil
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (if codeql--query-server
      (message "There is already a query server running")
    (codeql--query-server-start (transient-args transient-current-command))))

(transient-define-suffix codeql-transient-query-server-stop ()
  "Stop a CodeQL query server."
  :description "stop"
  :transient nil
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (if (not codeql--query-server)
      (message "No active query server found.")
    (jsonrpc-shutdown codeql--query-server)))

(transient-define-prefix codeql-transient-query-server-init-start ()
  "Start a CodeQL query server."
  :value (list "--threads=0" "--quiet" "--log-to-stderr")
  :incompatible '(("--logdir=" "--log-to-stderr"))
  [:class transient-columns
          ["Options"
           (codeql-transient-query-server:--threads)
           (codeql-transient-query-server:--verbose)
           (codeql-transient-query-server:--logdir)
           ("e" "log stderr" "--log-to-stderr")
           (codeql-transient-query-server:--max-disk-cache)]
          ["Server"
           ("s" codeql-transient-query-server-start)]]
  ;; only make this transient available inside ql mode
  (interactive)
  (when (eq major-mode 'ql-tree-sitter-mode)
    (transient-setup 'codeql-transient-query-server-init)))

(transient-define-prefix codeql-transient-query-server-init ()
  "Start|Stop a CodeQL query server, pending on buffer-local state."
  (interactive)
  (when (eq major-mode 'ql-tree-sitter-mode)
    (if codeql--query-server
        ;; just go straight to stopping the server in this case
        (call-interactively #'codeql-transient-query-server-stop)
      (transient-setup 'codeql-transient-query-server-init-start))))

(defun codeql-set-max-paths (max-paths)
  "Configure the buffer-local value for path problem max paths."
  (interactive "n--max-paths=")
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (setq codeql--path-problem-max-paths max-paths))

(defun codeql--database-open-file (filename)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (when-let ((src-buffer (find-file filename)))
    (with-current-buffer src-buffer
      ;; enable our xref backend, this kicks in templated queries for refs and defs
      (codeql-xref-backend))))

(defun codeql-database-open-source-archive-file ()
  "Open a file from the active database source archive."
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (if (and codeql--database-source-archive-root
           codeql--database-source-archive-zip)
      (let* ((relative-file-path
              (completing-read "Source archive file: "
                               (codeql--database-archive-zipinfo)))
             (full-file-path
              (codeql--tramp-wrap
               (format "%s/%s"
                       codeql--database-source-archive-root
                       relative-file-path))))
        (codeql--database-open-file full-file-path))
    (message "No active database.")))

(declare-function xref-matches-in-directory "xref")
(declare-function xref-show-xrefs "xref")
(defvar xref-after-jump-hook)

(defvar codeql--database-grep-query-buffers nil
  "Alist of (SOURCE-ARCHIVE-ROOT . QUERY-BUFFER) of `codeql-database-grep'.")

(defun codeql--database-grep-after-jump ()
  "Set up a source archive file visited from `codeql-database-grep' matches.

Like files visited from results, it is associated with the query buffer
that searched it, made read-only and gets the codeql xref backend."
  (when-let* ((file (buffer-file-name))
              ((not (buffer-live-p codeql--org-query-buffer)))
              (entry (cl-find-if (lambda (entry)
                                   (and (buffer-live-p (cdr entry))
                                        (string-prefix-p (file-name-as-directory (car entry))
                                                         file)))
                                 codeql--database-grep-query-buffers)))
    (setq codeql--org-query-buffer (cdr entry))
    (setq buffer-read-only t)
    (codeql-xref-backend)))

(defun codeql-database-grep (regexp &optional files)
  "Search the source archive of the active database for REGEXP.

Matches are shown with `xref-show-xrefs', and the files visited from
them are set up like those of result locations, see
`codeql--database-grep-after-jump'.  With a prefix argument, prompt for
the FILES wildcard to search, which defaults to all files."
  (interactive
   (progn
     (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
     (list (read-regexp "Search database source for regexp: " 'find-tag-default-as-regexp)
           (when current-prefix-arg
             (read-string "In files matching wildcard: " "*")))))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (unless (and codeql--active-database
               codeql--database-source-archive-root
               (codeql--file-exists-p codeql--database-source-archive-root))
    (user-error "No active database with an extracted source archive"))
  (require 'xref)
  (let ((root (codeql--tramp-wrap codeql--database-source-archive-root)))
    (setf (alist-get root codeql--database-grep-query-buffers nil nil #'equal)
          (current-buffer))
    (add-hook 'xref-after-jump-hook #'codeql--database-grep-after-jump)
    (xref-show-xrefs
     (lambda ()
       (or (xref-matches-in-directory regexp (or files "*") root nil)
           (user-error "No matches for %s in the database source archive" regexp)))
     nil)))

(transient-define-prefix codeql-transient-query-server-interact ()
  "Interact with a CodeQL query server via transient menu."
  [:class transient-columns
          ["Server"
           ("s" codeql-transient-query-server-init
            :description
            (lambda ()
              (cond ((not codeql--query-server) "start")
                    ((codeql--query-server-buffers codeql--query-server (current-buffer))
                     "stop (shared)")
                    (t "stop"))))
           ("i" "inherit" codeql-query-server-inherit)
           ("m" "manage" codeql-query-servers)]
          ["Database"
           ("d" codeql-query-server-register-database
            :description
            (lambda ()
              (codeql-query-server-active-database)))
           ("f" "file" codeql-database-open-source-archive-file)
           ("g" "grep" codeql-database-grep)
           ("k" "known" codeql-database-history)
           ("u" "unlock" codeql-database-delete-lock)]
          ["Query"
           ("r" "run" codeql-query-server-run-query)
           ("e" "quick eval" codeql-query-server-quick-eval)
           ("E" "quick eval predicate" codeql-query-server-quick-eval-predicate)
           ("n" "quick eval count" codeql-query-server-quick-eval-count)
           ("h" "history" codeql-query-history)
           ("C" "compare" codeql-query-history-compare)
           ("l" "load sarif" codeql-load-sarif)
           ("v" "variant analysis" codeql-mrva)
           ("t" "performance" codeql-query-performance)
           ("T" "compare performance" codeql-query-performance-compare)
           ("c" "cancel" codeql-query-server-cancel-query)
           ("R" "REPL" codeql-repl)
           ("E" "eval in REPL" codeql-repl-send-region)]
          ["Config"
           ("p" codeql-set-max-paths
            :description
            (lambda ()
              (format "--max-paths=%s"
                      codeql--path-problem-max-paths)))
           ("D" "doctor" codeql-doctor)]]
  (interactive)
  (when (eq major-mode 'ql-tree-sitter-mode)
    (with-current-buffer (current-buffer)
      (transient-setup 'codeql-transient-query-server-interact))))

;; make this prefix  available in our ql mode
(add-hook 'ql-tree-sitter-mode-hook
          (lambda ()
            (local-set-key
             (kbd codeql-transient-binding)
             #'codeql-transient-query-server-interact)))

;;; Sessions

;; A session evaluates snippets of CodeQL, entered one after another,
;; against the database of a project: definitions made in a snippet are
;; kept for the snippets that follow.  It does so by writing a query
;; module to a hidden buffer of the CodeQL pack, which runs like any
;; other query, so the REPL and org-babel share the query server and
;; results of the project.

(defcustom codeql-session-directory ".codeql-session"
  "Directory of a CodeQL pack in which sessions keep their query module.

Sessions write the snippets they evaluate, along with the definitions
made in the session so far, to a query module in this directory of the
pack they run in, so that the module can use the dependencies of the
pack.  The directory ignores itself for git."
  :type 'string
  :group 'emacs-codeql)

(defcustom codeql-session-check-definitions nil
  "Whether sessions compile new definitions right away.

When non-nil, input that only makes definitions is checked by running a
trivial query with them, so that errors in them are reported when they
are entered, and they are only kept when they have none.  This costs a
compilation of the query module, which can take seconds.

When nil, such definitions are kept right away, and compiled with the
input that follows.  When that has errors in definitions that were never
compiled successfully before, those definitions are dropped again."
  :type 'boolean
  :group 'emacs-codeql)

(defcustom codeql-session-timeout 60
  "Seconds to wait for the query server and database of a session."
  :type 'number
  :group 'emacs-codeql)

(cl-defstruct (codeql--session (:constructor codeql--session-make)
                               (:copier nil))
  "A CodeQL session, see `codeql--session-get'.

NAME and ROOT, the root of its CodeQL pack, identify it.  BUFFER visits
its query module.  DEFINITIONS are those made so far, see
`codeql--session-definition'.  EVALUATIONS counts the evaluations that
were requested, and PENDING is the handler of the outcome of the one
that runs, if any."
  name root buffer definitions (evaluations 0) pending)

(defvar codeql--sessions (make-hash-table :test #'equal)
  "The live sessions, by (ROOT . NAME).")

(defvar-local codeql--session nil
  "The session whose query module the current buffer visits.")

(declare-function ql-tree-sitter-mode "ext:ql-tree-sitter")

(defconst codeql--session-formula-types
  '("comp_term" "quantified" "negation" "conjunction" "disjunction" "implication"
    "in_expr" "instance_of" "if_term" "special_call")
  "Types of the tree-sitter ql nodes that are formulas rather than expressions.")

(defconst codeql--session-module-start-regexp
  (concat "\\`\\(?:[ \t\n]+\\|//[^\n]*\\|/\\*\\(?:[^*]\\|\\*+[^*/]\\)*\\*+/\\)*"
          (regexp-opt '("from" "select" "import" "predicate" "class" "module" "newtype"
                        "private" "deprecated" "abstract" "final" "cached" "pragma"
                        "bindingset" "language" "query" "signature" "extensible"
                        "external" "additional" "override" "library" "transient")
                      'symbols))
  "Matches CodeQL that starts like a module member rather than a term.")

(defun codeql--session-treesit-p ()
  "Return non-nil if sessions can parse CodeQL with the builtin tree-sitter."
  (and (fboundp 'treesit-ready-p) (treesit-ready-p 'ql t)))

(defun codeql--session-parse-root (text)
  "Parse TEXT as CodeQL in the current buffer and return the root node.

Return nil when TEXT doesn't parse."
  (erase-buffer)
  (insert text)
  (let ((root (treesit-parser-root-node (treesit-parser-create 'ql))))
    (unless (treesit-search-subtree
             root (lambda (node) (or (equal (treesit-node-type node) "ERROR")
                                     (treesit-node-check node 'missing))))
      root)))

(defun codeql--session-child (node type)
  "Return the first named child of NODE of TYPE."
  (seq-find (lambda (child) (equal (treesit-node-type child) type))
            (treesit-node-children node t)))

(defun codeql--session-definition (node text)
  "Return the definition that the module member NODE makes with TEXT.

This is a plist with the :text of the definition, a :key that a later
definition replacing it has too, and the :kind and :name of what is
defined.  Predicates have an :arity, and :result is non-nil for those
with a result."
  (let ((name-of (lambda (type) (when-let ((child (codeql--session-child node type)))
                                  (treesit-node-text child t)))))
    (pcase (treesit-node-type node)
      ("classlessPredicate"
       (let ((name (funcall name-of "predicateName"))
             (arity (seq-count (lambda (child) (equal (treesit-node-type child) "varDecl"))
                               (treesit-node-children node t))))
         (list :kind 'predicate :name name :arity arity
               :result (not (codeql--session-child node "predicate"))
               :key (list 'predicate name arity) :text text)))
      ((and (or "dataclass" "datatype") type)
       (let ((name (funcall name-of "className")))
         (list :kind (if (equal type "dataclass") 'class 'newtype) :name name
               :key (list 'type name) :text text)))
      ("module"
       (let ((name (funcall name-of "moduleName")))
         (list :kind 'module :name name :key (list 'module name) :text text)))
      ("importDirective"
       (let ((import (replace-regexp-in-string "[ \t\n]+" " " (treesit-node-text node t))))
         (list :kind 'import :name import :key (list 'import import) :text text)))
      (type
       (list :kind (intern type) :key (list 'other text) :text text)))))

(defun codeql--session-callee (node)
  "Return the name of the predicate that the call NODE calls."
  (when-let* ((callee (codeql--session-child node "aritylessPredicateExpr"))
              (name (codeql--session-child callee "literalId")))
    (treesit-node-text name t)))

(defun codeql--session-term-kind (node definitions)
  "Return whether NODE is a `formula' or an `expression', and if that is a guess.

The result is (KIND . GUESS).  Calls are formulas when they call
predicates without a result among DEFINITIONS, but calls of other
predicates can't be told apart."
  (let ((type (treesit-node-type node)))
    (cond
     ((member type codeql--session-formula-types) '(formula))
     ((and (equal type "par_expr") (= (treesit-node-child-count node t) 1))
      (codeql--session-term-kind (treesit-node-child node 0 t) definitions))
     ((equal type "call_or_unqual_agg_expr")
      (let* ((name (codeql--session-callee node))
             (callees (seq-filter (lambda (definition)
                                    (and (eq (plist-get definition :kind) 'predicate)
                                         (equal (plist-get definition :name) name)))
                                  definitions)))
        (cond ((null callees) '(expression . t))
              ((seq-every-p (lambda (definition) (plist-get definition :result)) callees)
               '(expression))
              ((seq-some (lambda (definition) (plist-get definition :result)) callees)
               '(expression . t))
              (t '(formula)))))
     ((equal type "qualified_expr") '(expression . t))
     (t '(expression)))))

(defun codeql--session-overloads (definitions name)
  "Return the predicates NAME among DEFINITIONS, by increasing arity."
  (sort (seq-filter (lambda (definition)
                      (and (eq (plist-get definition :kind) 'predicate)
                           (equal (plist-get definition :name) name)))
                    definitions)
        (lambda (a b) (< (plist-get a :arity) (plist-get b :arity)))))

(defun codeql--session-signature (definition)
  "Return the head of DEFINITION, such as \"predicate p(int x)\".
This leaves out its QLDoc, comments and body."
  (let ((text (plist-get definition :text)))
    (while (string-match "\\`[ \t\n]*\\(?:/\\*\\(?:.\\|\n\\)*?\\*/\\|//.*\\)" text)
      (setq text (substring text (match-end 0))))
    (string-trim (replace-regexp-in-string "[ \t\n]+" " " (car (split-string text "[{;]"))))))

(defun codeql--session-parse-predicate (input definitions)
  "Return what INPUT asks for when it names a predicate of DEFINITIONS.

INPUT names a predicate as NAME, or as NAME/ARITY to pick one of the
predicates NAME with different arities.  See `codeql--session-parse'."
  (when (string-match (concat "\\`[ \t\n]*\\([A-Za-z_][A-Za-z0-9_]*\\)"
                              "\\(?:[ \t\n]*/[ \t\n]*\\([0-9]+\\)\\)?[ \t\n]*\\'")
                      input)
    (let* ((name (match-string 1 input))
           (arity (and (match-beginning 2) (string-to-number (match-string 2 input))))
           (overloads (seq-filter (lambda (definition)
                                    (or (null arity) (eql (plist-get definition :arity) arity)))
                                  (codeql--session-overloads definitions name))))
      (cond
       ((cdr overloads)
        (user-error "Predicate %s is overloaded, enter one of %s" name
                    (mapconcat #'codeql--session-definition-name overloads ", ")))
       (overloads (list :action (cons 'predicate (cons name (plist-get (car overloads) :arity)))))
       ;; an identifier divided by a number is no expression
       (arity (user-error "Predicate %s/%d is not defined in this session" name arity))))))

(defun codeql--session-parse (input definitions)
  "Return what INPUT, entered in a session with DEFINITIONS, asks for.

This is a plist with the :definitions INPUT makes, see
`codeql--session-definition', and the :action it requests, which is
nil or a cons (TYPE . TEXT) of one of these types, but for predicates:

- `select': run the query that the select clause TEXT, along with the
  definitions of the session and of INPUT, makes.
- `expression' or `formula': show the values of the expression TEXT,
  or whether the formula TEXT holds.  :guess is non-nil when INPUT could
  be either, the action holds the more likely one.
- `predicate': (predicate NAME . ARITY) quick evaluates that predicate
  of the session, entered as NAME, or NAME/ARITY when it is overloaded.
- `type': select the values of the type named TEXT, a class of the
  session or of its imports.

Input that isn't valid CodeQL is evaluated as an expression, so that
the compiler explains what is wrong with it."
  (unless (codeql--session-treesit-p)
    (user-error "CodeQL sessions need Emacs 29 or newer with the tree-sitter ql grammar"))
  (let ((input (string-trim-right input)))
    (with-temp-buffer
      (cond
       ((string-empty-p (string-trim input)) nil)
       ((codeql--session-parse-predicate input definitions))
       ;; a type by name, which can't be an expression
       ((let ((case-fold-search nil))
          (string-match (concat "\\`[ \t\n]*\\(\\(?:[A-Za-z_][A-Za-z0-9_]*::\\)*"
                                "[A-Z][A-Za-z0-9_]*\\)[ \t\n]*\\'")
                        input))
        (list :action (cons 'type (match-string 1 input))))
       ;; definitions, and maybe a select clause
       ((when-let ((root (codeql--session-parse-root input)))
          (let ((start (point-min))
                (new nil)
                (select nil))
            (dolist (member (treesit-node-children root t))
              (when (equal (treesit-node-type member) "moduleMember")
                (let ((main (seq-find (lambda (child)
                                        (not (member (treesit-node-type child)
                                                     '("annotation" "qldoc"))))
                                      (treesit-node-children member t))))
                  ;; qldoc and comments go with the member that follows them
                  (when main
                    (let ((text (string-trim (buffer-substring-no-properties
                                              start (treesit-node-end member)))))
                      (setq start (treesit-node-end member))
                      (if (equal (treesit-node-type main) "select")
                          (if select
                              (user-error "Only one select clause can be evaluated at a time")
                            (setq select text))
                        (push (codeql--session-definition main text) new)))))))
            (when (or new select)
              (list :definitions (nreverse new)
                    :action (and select (cons 'select select)))))))
       ;; malformed definitions or queries, for the compiler to explain
       ((string-match-p codeql--session-module-start-regexp input)
        (list :action (cons 'select input)))
       ;; an expression or a formula
       (t
        (let* ((root (codeql--session-parse-root (concat "predicate p() {\n" input "\n}")))
               (body (and root (treesit-search-subtree
                                root (lambda (node) (equal (treesit-node-type node) "body")))))
               (terms (and body (seq-remove
                                 (lambda (node)
                                   (member (treesit-node-type node)
                                           '("line_comment" "block_comment" "qldoc")))
                                 (treesit-node-children body t))))
               (kind (if (= (length terms) 1)
                         (codeql--session-term-kind (car terms) definitions)
                       '(expression))))
          (list :action (cons (car kind) input) :guess (cdr kind))))))))

(defun codeql--session-merge (definitions new)
  "Return DEFINITIONS with the NEW definitions made after them.

A new definition replaces the one with the same key in place, the
others are added at the end.  A replacement remembers the last
replaced definition that compiled as its :previous."
  (let ((merged (copy-sequence definitions)))
    (dolist (definition new)
      (let ((old (seq-find (lambda (d) (equal (plist-get d :key) (plist-get definition :key)))
                           merged)))
        (if old
            (let ((replacement (plist-put (copy-sequence definition) :previous
                                          (if (plist-get old :verified)
                                              old
                                            (plist-get old :previous)))))
              (setq merged (mapcar (lambda (d) (if (eq d old) replacement d)) merged)))
          (setq merged (append merged (list definition))))))
    merged))

(defun codeql--session-changes (definitions entered)
  "Return how the ENTERED definitions change the session DEFINITIONS.

This is a plist of the :new definitions to merge, see
`codeql--session-merge', which leaves out those that are among
DEFINITIONS as they are, and of the names of the entered definitions
that are :redefined, :unchanged, or :repeated within ENTERED.
Definitions are the same when they have the same key: classes and
other types by name, and predicates by name and arity."
  (let ((normal (lambda (definition)
                  (replace-regexp-in-string "[ \t\n]+" " " (plist-get definition :text))))
        (same (lambda (key) (lambda (definition) (equal (plist-get definition :key) key))))
        (unchanged-keys nil)
        (redefined nil)
        (unchanged nil)
        (repeated nil))
    (dolist (definition entered)
      (let* ((key (plist-get definition :key))
             (name (codeql--session-definition-name definition))
             (last (car (last (seq-filter (funcall same key) entered))))
             (old (seq-find (funcall same key) definitions)))
        (cond
         ((not (eq definition last))
          (when name (cl-pushnew name repeated :test #'equal)))
         ((and old (equal (funcall normal old) (funcall normal definition)))
          (push key unchanged-keys)
          (when name (push name unchanged)))
         ((and old name)
          (push name redefined)))))
    (list :new (seq-remove (lambda (definition)
                             (member (plist-get definition :key) unchanged-keys))
                           entered)
          :redefined (nreverse redefined)
          :unchanged (nreverse unchanged)
          :repeated (nreverse repeated))))

(defun codeql--session-definition-notes (outcome)
  "Return what OUTCOME of `codeql--session-eval' says about definitions.

This is a list of (TEXT . WARNING) lines, WARNING being non-nil for
redefinitions."
  (let* ((dropped (plist-get outcome :dropped))
         (redefined (seq-difference (plist-get outcome :redefined) dropped))
         (unchanged (plist-get outcome :unchanged))
         (repeated (plist-get outcome :repeated))
         (defined (seq-difference (plist-get outcome :definitions)
                                  (append dropped redefined unchanged)))
         (names (lambda (names) (string-join names ", ")))
         (lines nil))
    (when defined
      (push (cons (format "Defined %s." (funcall names defined)) nil) lines))
    (when redefined
      (push (cons (format "Redefined %s, which replaces the previous definition%s."
                          (funcall names redefined) (if (cdr redefined) "s" ""))
                  t)
            lines))
    (when unchanged
      (push (cons (format "%s %s already defined like that." (funcall names unchanged)
                          (if (cdr unchanged) "were" "was"))
                  nil)
            lines))
    (when repeated
      (push (cons (format "%s %s defined more than once in the input, the last definition counts."
                          (funcall names repeated) (if (cdr repeated) "are" "is"))
                  t)
            lines))
    (nreverse lines)))

(defun codeql--session-verified (definition)
  "Return DEFINITION marked as compiled successfully."
  (let ((verified (copy-sequence definition)))
    (cl-remf verified :previous)
    (plist-put verified :verified t)))

(defun codeql--session-default-definitions (language)
  "Return the definitions a new session for a database of LANGUAGE starts with."
  (when language
    (let ((import (format "import %s" language)))
      (list (list :kind 'import :name import :key (list 'import import) :text import)))))

(defconst codeql--session-keywords
  '("and" "any" "as" "asc" "avg" "boolean" "by" "class" "concat" "count" "date"
    "desc" "else" "exists" "extends" "false" "float" "forall" "forex" "from" "if"
    "implies" "import" "in" "instanceof" "int" "max" "min" "module" "newtype" "none"
    "not" "or" "order" "predicate" "rank" "result" "select" "strictconcat"
    "strictcount" "strictsum" "string" "sum" "super" "then" "this" "true" "where")
  "CodeQL keywords, which the CodeQL REPL completes.")

(defun codeql--session-type-variable (type)
  "Return the name of a variable of TYPE, which names its column of results."
  (let* ((name (car (last (split-string type "::"))))
         (variable (concat (downcase (substring name 0 1)) (substring name 1))))
    (if (member variable codeql--session-keywords)
        (concat variable "_")
      variable)))

(defun codeql--session-module (name definitions action &optional count)
  "Return the query module of session NAME that evaluates ACTION with DEFINITIONS.

ACTION is that of `codeql--session-parse', or (check) for a module
that only checks the definitions.  With COUNT, the values of a type
are counted.  The module is a string, whose `codeql-session-action'
text property marks the code of ACTION."
  (let ((code (pcase action
                (`(select . ,text) text)
                (`(type . ,type)
                 (let ((variable (codeql--session-type-variable type)))
                   (if count
                       (format "select count(%s %s)" type variable)
                     (format "from %s %s\nselect %s" type variable variable))))
                (`(expression . ,text) (concat "select\n" text))
                (`(formula . ,text)
                 (concat "from boolean holds\nwhere\n  if (\n" text
                         "\n  ) then holds = true else holds = false\nselect holds"))
                ;; a query module needs a query, also to quick evaluate in it
                ((or '(check) `(predicate . ,_)) "select 1")
                (_ nil))))
    (concat (format "// The query module of CodeQL session %s, rewritten for each evaluation\n\n"
                    name)
            (mapconcat (lambda (definition)
                         (concat (propertize (plist-get definition :text)
                                             'codeql-session-definition
                                             (plist-get definition :key))
                                 "\n\n"))
                       definitions "")
            (when code
              (concat (propertize code 'codeql-session-action t) "\n")))))

(defun codeql--session-definition-lines ()
  "Return the (KEY FIRST-LINE LAST-LINE) of the session definitions in this buffer."
  (let ((pos (point-min))
        (lines nil))
    (while (< pos (point-max))
      (let ((key (get-text-property pos 'codeql-session-definition))
            (next (next-single-property-change pos 'codeql-session-definition nil (point-max))))
        (when key
          (push (list key (line-number-at-pos pos) (line-number-at-pos (1- next))) lines))
        (setq pos next)))
    (nreverse lines)))

(defconst codeql--session-location-regexp
  "(\\([^()\n]+\\):\\([0-9]+\\),[0-9]+-\\(?:[0-9]+,\\)?[0-9]+)"
  "Matches the (FILE:LINE,COLUMN-[LINE,]COLUMN) location of a compiler message.")

(defun codeql--session-error-keys (message file lines)
  "Return the keys of the definitions that the errors in MESSAGE are in.

FILE is the query module that was compiled, and LINES are where its
definitions are, see `codeql--session-definition-lines'."
  (let ((keys nil)
        (start 0)
        (suffix (concat "/" (file-name-nondirectory file))))
    (while (string-match (concat "^ERROR: .*" codeql--session-location-regexp "$")
                         (or message "") start)
      (setq start (match-end 0))
      (when (string-suffix-p suffix (match-string 1 message))
        (let ((line (string-to-number (match-string 2 message))))
          (dolist (entry lines)
            (when (<= (nth 1 entry) line (nth 2 entry))
              (cl-pushnew (car entry) keys :test #'equal))))))
    (nreverse keys)))

(defun codeql--session-describe-errors (message file definitions lines)
  "Return MESSAGE with its locations in FILE described in terms of the session.

FILE is the query module that was compiled with DEFINITIONS, which are
at LINES, see `codeql--session-definition-lines'.  Locations in a
definition name it, the others are in the evaluated input."
  (let ((suffix (concat "/" (file-name-nondirectory file))))
    (replace-regexp-in-string
     (concat codeql--session-location-regexp "$")
     (lambda (match)
       (let ((path (match-string 1 match))
             (line (string-to-number (match-string 2 match))))
         (if (not (string-suffix-p suffix path))
             match
           (if-let ((entry (seq-find (lambda (entry) (<= (nth 1 entry) line (nth 2 entry)))
                                     lines)))
               (format "(in %s%s)"
                       (or (codeql--session-definition-name
                            (seq-find (lambda (definition)
                                        (equal (plist-get definition :key) (car entry)))
                                      definitions))
                           "a definition")
                       (if (= (nth 1 entry) (nth 2 entry))
                           ""
                         (format ", line %d" (1+ (- line (nth 1 entry))))))
             "(in the input)"))))
     message t t)))

(defun codeql--session-kept-definitions (definitions error-keys)
  "Return the definitions a session keeps after an evaluation failed.

The evaluation used DEFINITIONS, and the compiler reported errors in
those with ERROR-KEYS, see `codeql--session-error-keys'.

Definitions that never compiled successfully are rolled back when they
have errors: they are dropped, or a redefinition leaves the definition
it replaced, see `codeql--session-merge'.  Errors in definitions that
did compile can only come from those that never did, so they are all
rolled back then."
  (let* ((broken (lambda (definition) (member (plist-get definition :key) error-keys)))
         (verified-broken (seq-some (lambda (definition)
                                      (and (plist-get definition :verified)
                                           (funcall broken definition)))
                                    definitions)))
    (delq nil
          (mapcar (lambda (definition)
                    (if (and (not (plist-get definition :verified))
                             (or verified-broken (funcall broken definition)))
                        (plist-get definition :previous)
                      definition))
                  definitions))))

(defun codeql--session-clean-message (message)
  "Return the compiler MESSAGE without warnings that sessions always cause."
  (and message
       (replace-regexp-in-string "^WARNING: unused \\(?:predicate\\|class\\|datatype\\) .*\n?"
                                 "" message)))

(defun codeql--session-definition-name (definition)
  "Return the name of DEFINITION to show to users."
  (when-let ((name (plist-get definition :name)))
    (if (plist-get definition :arity)
        (format "%s/%s" name (plist-get definition :arity))
      name)))

(defun codeql--session-predicate-name-bounds (name arity)
  "Return the bounds of the name of the last predicate NAME/ARITY in this buffer."
  (let ((root (treesit-parser-root-node (treesit-parser-create 'ql)))
        (found nil))
    (dolist (member (treesit-node-children root t))
      (when-let* ((predicate (codeql--session-child member "classlessPredicate"))
                  (node (codeql--session-child predicate "predicateName")))
        (when (and (equal (treesit-node-text node t) name)
                   (= (seq-count (lambda (child) (equal (treesit-node-type child) "varDecl"))
                                 (treesit-node-children predicate t))
                      arity))
          (setq found (cons (treesit-node-start node) (treesit-node-end node))))))
    found))

(defun codeql--session-file-name (name)
  "Return the file name of the query module of session NAME."
  (concat (replace-regexp-in-string "[^A-Za-z0-9_]" "_" name) ".ql"))

(defun codeql--session-on-kill ()
  "Forget the session of the current buffer, which is killed."
  (when codeql--session
    (let ((session codeql--session))
      (remhash (cons (codeql--session-root session) (codeql--session-name session))
               codeql--sessions)
      (when (and buffer-file-name (file-exists-p buffer-file-name))
        (delete-file buffer-file-name)))))

(defun codeql--session-open (root name)
  "Return a new session NAME in the CodeQL pack at ROOT."
  (unless (codeql--session-treesit-p)
    (user-error "CodeQL sessions need Emacs 29 or newer with the tree-sitter ql grammar"))
  (unless (codeql--find-project-root root)
    (user-error "%s is not in a CodeQL pack" root))
  (let* ((dir (expand-file-name codeql-session-directory root))
         (file (expand-file-name (codeql--session-file-name name) dir))
         (ignore (expand-file-name ".gitignore" dir))
         (session (codeql--session-make :name name :root root)))
    (make-directory dir t)
    (unless (file-exists-p ignore)
      (write-region "*\n" nil ignore nil 0))
    (write-region (codeql--session-module name nil nil) nil file nil 0)
    ;; the hidden buffer of a session must not join the language server
    ;; of the project, nor start one of its own
    (let ((buffer (let ((codeql--inhibit-lsp t)
                        (find-file-hook nil))
                    (find-file-noselect file t))))
      (with-current-buffer buffer
        (unless (eq major-mode 'ql-tree-sitter-mode)
          (let ((codeql--inhibit-lsp t))
            (ql-tree-sitter-mode)))
        (rename-buffer (format " *codeql-session %s: %s*" name (abbreviate-file-name root)) t)
        (buffer-disable-undo)
        (setq-local create-lockfiles nil)
        (auto-save-mode -1)
        (setq codeql--session session)
        (add-hook 'kill-buffer-hook #'codeql--session-on-kill nil t))
      (setf (codeql--session-buffer session) buffer)
      (puthash (cons root name) session codeql--sessions)
      session)))

(defun codeql--session-get (root &optional name)
  "Return the session NAME (default: \"default\") in the CodeQL pack at ROOT.

The session is created when there is none yet.  Its query module lives
in `codeql-session-directory' of the pack, and is visited by a hidden
QL buffer that uses the query server and database of the project, see
`codeql--session-ensure'."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (name (or name "default"))
         (session (gethash (cons root name) codeql--sessions)))
    (if (and session (buffer-live-p (codeql--session-buffer session)))
        session
      (codeql--session-open root name))))

(defun codeql--database-language (database)
  "Return the primary language of the CodeQL DATABASE directory, or nil."
  (let ((metadata (expand-file-name "codeql-database.yml" database)))
    (when (file-readable-p metadata)
      (with-temp-buffer
        (insert-file-contents metadata)
        (when (re-search-forward "^primaryLanguage:[ \t]*[\"']?\\([A-Za-z0-9_-]+\\)" nil t)
          (match-string 1))))))

(defun codeql--session-fallback-root (language)
  "Return the root of the CodeQL pack for sessions of LANGUAGE outside of packs.

The pack is in the sessions directory of `codeql-state-dir', and depends
on the standard CodeQL library of LANGUAGE, which `codeql pack install'
installs the first time."
  (let* ((root (file-name-as-directory
                (expand-file-name (format "sessions/%s" language) codeql-state-dir)))
         (lock (expand-file-name "codeql-pack.lock.yml" root)))
    (unless (file-exists-p lock)
      (make-directory root t)
      (write-region (format "name: emacs-codeql/%s-session\nversion: 0.0.1\ndependencies:\n  codeql/%s-all: \"*\"\n"
                            language language)
                    nil (expand-file-name "qlpack.yml" root) nil 0)
      (message "Installing the CodeQL library for %s sessions..." language)
      (let ((default-directory root)
            (cli (if (and codeql-use-gh-codeql-extension-when-available
                          (codeql--gh-codeql-cli-available-p))
                     (list (executable-find "gh") "codeql")
                   (list codeql-cli))))
        (unless (and (codeql--shell-command-to-string
                      (mapconcat #'shell-quote-argument
                                 (append cli (list "pack" "install" root))
                                 " "))
                     (file-exists-p lock))
          (user-error "Could not install the CodeQL library for %s in %s" language root))))
    root))

(defun codeql--session-wait (predicate what)
  "Wait until PREDICATE returns non-nil, for `codeql-session-timeout' seconds.

WHAT describes what is waited for."
  (with-timeout (codeql-session-timeout
                 (user-error "Timed out waiting for %s" what))
    (while (not (funcall predicate))
      (accept-process-output nil 0.05))))

(defun codeql--session-database (session)
  "Return the database of SESSION, or nil if it has none."
  (buffer-local-value 'codeql--active-database (codeql--session-buffer session)))

(defun codeql--session-database-holder (database)
  "Return a QL buffer whose query server has DATABASE registered, or nil."
  (let ((path (codeql--database-history-path database)))
    (seq-find (lambda (buffer)
                (with-current-buffer buffer
                  (and codeql--query-server
                       (jsonrpc-running-p codeql--query-server)
                       codeql--active-database
                       (equal (codeql--database-history-path codeql--active-database)
                              path))))
              (codeql--ql-buffers))))

(defun codeql--session-ensure (session &optional database)
  "Make sure that SESSION has a query server and a database, and return SESSION.

The query server of the project is used, or one is started, unless the
database is in use by another query server already.  DATABASE is
registered when it is given, else the database of the project, or the
one last registered in it.  When there is none, one is read from the
database history, or as a directory when the history is empty."
  (with-current-buffer (codeql--session-buffer session)
    (let ((started nil))
      (unless codeql--query-server
        (cond
         ;; a database can be used by one query server only
         ((when-let* ((wanted (or database
                                  (and (not (codeql--query-server-shareable))
                                       (codeql--last-database))))
                      (holder (codeql--session-database-holder wanted)))
            (codeql--query-server-copy-state holder)
            (message "Using the query server of %s, which has %s."
                     (buffer-name holder) (abbreviate-file-name wanted))
            t))
         ((codeql--query-server-shareable)
          (codeql--query-server-adopt))
         (t
          (codeql--query-server-start codeql-query-server-default-args)
          (setq started t))))
      (let* ((last (codeql--last-database))
             (target (or database
                         codeql--active-database
                         last
                         (if noninteractive
                             (user-error "No database for CodeQL session %s"
                                         (codeql--session-name session))
                           (let ((prompt (format "Database for CodeQL session %s: "
                                                 (codeql--session-name session))))
                             (if (seq-some #'identity (codeql--database-history-entries))
                                 (codeql--read-database prompt)
                               (read-directory-name prompt nil nil t))))))
             (target (codeql--database-history-path target))
             (active-p (lambda ()
                         (and codeql--active-database
                              (equal (codeql--database-history-path codeql--active-database)
                                     target)))))
        (unless (funcall active-p)
          ;; starting the server registers the last database already
          (unless (and started codeql-register-last-database (equal target last))
            (codeql-query-server-register-database target))
          (codeql--session-wait active-p (format "database %s" target))))
      (unless (codeql--session-definitions session)
        (setf (codeql--session-definitions session)
              (codeql--session-default-definitions codeql--active-database-language)))))
  session)

(defun codeql--session-write (text)
  "Make TEXT the content of the current buffer, and save it to its file."
  (set-visited-file-modtime)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert text))
  (let ((inhibit-message t)
        (coding-system-for-write 'utf-8-unix))
    (write-region nil nil buffer-file-name nil t)))

(cl-defun codeql--session-eval (session input callback &key frontend count)
  "Evaluate INPUT in SESSION and call CALLBACK with the outcome when done.

INPUT can make definitions, which the following input of the session can
use, and ask for a select clause, an expression or a formula to be
evaluated, for a predicate of the session to be quick evaluated, or
for the values of a type, see `codeql--session-parse'.  With COUNT,
a quick evaluation or the values of a type are only counted.  FRONTEND
names what INPUT was entered in, e.g. \"REPL\", for the Query Source
section of results and query history.

Definitions are kept right away, unless `codeql-session-check-definitions'
says to compile them first, and are rolled back when the compiler
reports errors before an evaluation succeeded with them, see
`codeql--session-kept-definitions'.

The outcome is that of `codeql--query-result-handler', with the
:session, the :action of INPUT, the names of the :definitions it made,
of those that were :redefined, :unchanged or :repeated, see
`codeql--session-changes', and of the definitions that were :dropped
for errors.  When INPUT only makes definitions, the outcome's :status
is `defined'.  This returns right away, while the evaluation runs."
  (when (codeql--session-pending session)
    (user-error "CodeQL session %s is busy" (codeql--session-name session)))
  (let* ((parsed (or (codeql--session-parse input (codeql--session-definitions session))
                     (user-error "Nothing to evaluate")))
         (entered (plist-get parsed :definitions))
         (changes (codeql--session-changes (codeql--session-definitions session) entered))
         (new (plist-get changes :new))
         (definitions (codeql--session-merge (codeql--session-definitions session) new))
         (action (or (plist-get parsed :action)
                     (and new codeql-session-check-definitions '(check))))
         (finish
          (lambda (outcome)
            (let* ((kept (pcase (plist-get outcome :status)
                           ((or 'results 'empty)
                            (mapcar #'codeql--session-verified definitions))
                           ('defined (if (plist-get outcome :verified)
                                         (mapcar #'codeql--session-verified definitions)
                                       definitions))
                           (_ (codeql--session-kept-definitions
                               definitions (plist-get outcome :error-keys)))))
                   (dropped (when (eq (plist-get outcome :status) 'error)
                              (seq-remove (lambda (definition) (memq definition kept))
                                          definitions))))
              (setf (codeql--session-definitions session) kept)
              (funcall callback
                       (append (list :session session
                                     ;; a retried expression runs as a formula
                                     :action (or (plist-get (plist-get outcome :provenance) :action)
                                                 (car (plist-get parsed :action)))
                                     :definitions (delete-dups
                                                   (delq nil (mapcar #'codeql--session-definition-name
                                                                     entered)))
                                     :redefined (plist-get changes :redefined)
                                     :unchanged (plist-get changes :unchanged)
                                     :repeated (plist-get changes :repeated)
                                     :dropped (delq nil (mapcar #'codeql--session-definition-name dropped)))
                               (if (plist-get outcome :message)
                                   (plist-put (copy-sequence outcome) :message
                                              (codeql--session-clean-message
                                               (plist-get outcome :message)))
                                 outcome)))))))
    (cl-incf (codeql--session-evaluations session))
    (if (not action)
        (funcall finish (list :status 'defined))
      (codeql--session-run
       session definitions action input frontend count
       (lambda (outcome)
         (cond
          ;; calls and member calls can be expressions or formulas
          ((and (eq (plist-get outcome :status) 'error)
                (not (plist-get outcome :cancelled))
                (plist-get parsed :guess)
                (eq (car action) 'expression))
           (codeql--session-run
            session definitions (cons 'formula (cdr action)) input frontend count
            (lambda (retry)
              (funcall finish (if (eq (plist-get retry :status) 'error) outcome retry)))))
          ((and (equal action '(check)) (not (eq (plist-get outcome :status) 'error)))
           (funcall finish (list :status 'defined :verified t)))
          (t (funcall finish outcome))))))))

(defun codeql--session-run (session definitions action input frontend count callback)
  "Run ACTION of INPUT with DEFINITIONS in SESSION.

CALLBACK is called with the outcome.  When it is an error, its
:error-keys are the keys of the definitions with errors, and its
:message tells where they are in terms of the session, see
`codeql--session-describe-errors', unlike its :compiler-message.  See
`codeql--session-eval' for FRONTEND and COUNT."
  (let ((buffer (codeql--session-buffer session))
        (name (codeql--session-name session)))
    (with-current-buffer buffer
      (unless (and codeql--query-server codeql--active-database)
        (codeql--session-ensure session))
      (codeql--session-write (codeql--session-module name definitions action count))
      (let* ((quick-eval (and (eq (car action) 'predicate) (if count 'count t)))
             (codeql--quick-eval-region
              (if quick-eval
                  (or (codeql--session-predicate-name-bounds (cadr action) (cddr action))
                      (error "Predicate %s/%d is not defined in session %s"
                             (cadr action) (cddr action) name))
                (when-let ((start (text-property-any (point-min) (point-max)
                                                     'codeql-session-action t)))
                  (cons start (or (next-single-property-change start 'codeql-session-action)
                                  (point-max))))))
             (lines (codeql--session-definition-lines))
             (file buffer-file-name)
             (provenance
              (list :kind 'session
                    :session name
                    :frontend frontend
                    :input input
                    :action (car action)
                    :count (or (eq quick-eval 'count) (and count (eq (car action) 'type)))
                    :module (buffer-substring-no-properties (point-min) (point-max))
                    :check (equal action '(check))))
             (handler nil))
        (setq handler
              (lambda (outcome)
                ;; a canceled run may still report its outcome
                (when (eq (codeql--session-pending session) handler)
                  (setf (codeql--session-pending session) nil)
                  (funcall callback
                           (if (eq (plist-get outcome :status) 'error)
                               (let ((message (plist-get outcome :message)))
                                 (append (list :error-keys
                                               (codeql--session-error-keys message file lines)
                                               :message
                                               (and message
                                                    (codeql--session-describe-errors
                                                     message file definitions lines))
                                               :compiler-message message)
                                         outcome))
                             outcome)))))
        (setf (codeql--session-pending session) handler)
        (condition-case err
            (let ((codeql--query-result-handler handler))
              (codeql--query-server-run-query-from-path
               file quick-eval nil nil nil provenance))
          ((error quit)
           (setf (codeql--session-pending session) nil)
           (signal (car err) (cdr err))))))))

(defun codeql--session-cancel (session)
  "Cancel the evaluation that runs in SESSION.

Its outcome is an error whose :cancelled is non-nil."
  (when-let ((handler (codeql--session-pending session)))
    (when (buffer-live-p (codeql--session-buffer session))
      (with-current-buffer (codeql--session-buffer session)
        (let ((inhibit-message t))
          (codeql-query-server-cancel-query))))
    (funcall handler (list :status 'error :message "Evaluation canceled" :cancelled t))))

(defun codeql--session-kill (session)
  "Kill SESSION, which forgets its definitions."
  (when (buffer-live-p (codeql--session-buffer session))
    (kill-buffer (codeql--session-buffer session))))

(defun codeql--session-undefine (session name)
  "Remove the definitions NAME from SESSION, and return them.

NAME is that of `codeql--session-definition-name', or the name of
predicates of any arity."
  (let ((removed (seq-filter (lambda (definition)
                               (or (equal (codeql--session-definition-name definition) name)
                                   (and (plist-get definition :arity)
                                        (equal (plist-get definition :name) name))))
                             (codeql--session-definitions session))))
    (setf (codeql--session-definitions session)
          (seq-difference (codeql--session-definitions session) removed #'eq))
    removed))

(defun codeql--session-reset (session)
  "Make SESSION forget its definitions, except the default ones."
  (setf (codeql--session-definitions session)
        (codeql--session-default-definitions
         (buffer-local-value 'codeql--active-database-language
                             (codeql--session-buffer session)))))

(defun codeql--session-decode (session bqrs-path rows)
  "Return the (COLUMNS TUPLES TOTAL) of the first ROWS results at BQRS-PATH.

The results are those of the #select result set, or of the first one,
as decoded by SESSION's CLI.  TOTAL is the number of results."
  (with-current-buffer (codeql--session-buffer session)
    (let* ((info (or (codeql--bqrs-info bqrs-path (max rows 1))
                     (error "No result sets in %s" bqrs-path)))
           (sets (append (alist-get 'result-sets info) nil))
           (set (or (seq-find (lambda (s) (equal (alist-get 'name s) "#select")) sets)
                    (car sets)))
           (offsets (alist-get 'offsets (alist-get 'pagination set)))
           (start (and (> (length offsets) 0) (aref offsets 0)))
           (json (codeql--bqrs-to-json bqrs-path "string,url" (alist-get 'name set)
                                       (and start (max rows 1)) start))
           (data (json-parse-string json :object-type 'alist))
           ;; a single result set isn't keyed by its name
           (data (if (assq 'columns data) data (cdar data))))
      (list (append (alist-get 'columns data) nil)
            (seq-take (append (alist-get 'tuples data) nil) rows)
            (or (alist-get 'rows set) 0)))))

(defun codeql--session-value-node (value)
  "Return a result node for the decoded result VALUE when it has a location.

The node is visitable, see `codeql--result-node-link'."
  (when-let* (((consp value))
              (url (codeql--location-url (alist-get 'url value))))
    (codeql--result-node-create
     :label (codeql--printable-label (alist-get 'label value))
     :filename (codeql--uri-to-filename (alist-get 'uri url))
     :line (alist-get 'startLine url)
     :column (alist-get 'startColumn url)
     :visitable t
     :url url)))

(defun codeql--session-eval-sync (session input &rest args)
  "Evaluate INPUT in SESSION like `codeql--session-eval', and return the outcome.

ARGS are passed on.  Quitting cancels the evaluation."
  (let* ((outcome nil)
         (done nil))
    (apply #'codeql--session-eval session input
           (lambda (result) (setq outcome result done t))
           args)
    (condition-case err
        (while (not done)
          (accept-process-output nil 0.05))
      (quit
       (codeql--session-cancel session)
       (signal (car err) (cdr err))))
    outcome))

;;; REPL

;; The CodeQL REPL is a comint front end to a session: each input is
;; evaluated with `codeql--session-eval', and the first rows of its
;; results are printed below it, with a button to open all of them in
;; an org results buffer.

;; comint is loaded when a REPL starts, see `codeql-repl--start'
(eval-when-compile (require 'comint))
(declare-function comint-check-proc "comint")
(declare-function comint-fontify-input-mode "comint")
(declare-function comint-mode "comint")
(declare-function comint-output-filter "comint")
(declare-function comint-read-input-ring "comint")
(declare-function comint-send-input "comint")
(declare-function ring-empty-p "ring")
(declare-function ring-length "ring")
(declare-function ring-ref "ring")

(defcustom codeql-repl-prompt "ql> "
  "The prompt of the CodeQL REPL."
  :type 'string
  :group 'emacs-codeql)

(defcustom codeql-repl-max-rows 10
  "The number of result rows that the CodeQL REPL prints.

All results can be opened in a results buffer from the REPL."
  :type 'natnum
  :group 'emacs-codeql)

(defcustom codeql-repl-max-column-width 60
  "The width that the CodeQL REPL truncates result values to."
  :type 'natnum
  :group 'emacs-codeql)

(defcustom codeql-repl-history-file (locate-user-emacs-file "codeql-repl-history")
  "The file that keeps the input history of the CodeQL REPL, or nil for none."
  :type '(choice file (const :tag "No history file" nil))
  :group 'emacs-codeql)

(defcustom codeql-repl-fontify-input t
  "Non-nil means that the CodeQL REPL highlights its input as CodeQL."
  :type 'boolean
  :group 'emacs-codeql)

(defface codeql-repl-error '((t :inherit error))
  "Face of errors in the CodeQL REPL."
  :group 'emacs-codeql)

(defface codeql-repl-note '((t :inherit shadow))
  "Face of notes, such as the number of results, in the CodeQL REPL."
  :group 'emacs-codeql)

(defface codeql-repl-column '((t :inherit bold))
  "Face of the names of result columns in the CodeQL REPL."
  :group 'emacs-codeql)

(defvar-local codeql-repl--session nil
  "The session that the CodeQL REPL buffer evaluates input in.")

(defvar-local codeql-repl--outcome nil
  "The outcome of the last evaluation with results in the CodeQL REPL buffer.")

(defvar-local codeql-repl--started nil
  "When the running evaluation of the CodeQL REPL buffer started, or nil.")

(defconst codeql-repl--commands
  '(("help" codeql-repl--command-help nil "list the REPL commands")
    ("defs" codeql-repl--command-defs "[NAME]"
     "list the definitions of the session, or show those named NAME")
    ("undef" codeql-repl--command-undef "NAME" "remove the definitions named NAME")
    ("reset" codeql-repl--command-reset nil "remove all definitions but the default import")
    ("count" codeql-repl--command-count "PREDICATE[/ARITY]|TYPE"
     "count the results of a predicate of the session, or the values of a type")
    ("results" codeql-repl--command-results nil "open the last results in a results buffer")
    ("module" codeql-repl--command-module nil "show the query module of the last evaluation")
    ("db" codeql-repl--command-db "[PATH]"
     "show the database, or register the one at PATH for the project")
    ("cancel" codeql-repl--command-cancel nil "cancel the running evaluation")
    ("clear" codeql-repl--command-clear nil "clear the REPL buffer"))
  "The commands of the CodeQL REPL: (NAME FUNCTION ARGUMENTS DESCRIPTION).

FUNCTION is called with the arguments of the command, a string, and
returns the text to print, or nil when it prints by itself.")

(defvar codeql-repl--syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?/ ". 124" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?* ". 23b" table)
    (modify-syntax-entry ?@ "_" table)
    table)
  "Syntax table of the CodeQL REPL, as for CodeQL code.")

(defvar codeql-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'codeql-repl-return)
    (define-key map (kbd "C-j") #'codeql-repl-newline)
    (define-key map (kbd "C-c C-c") #'codeql-repl-cancel)
    (define-key map (kbd "C-c C-v") #'codeql-repl-show-results)
    (define-key map (kbd "TAB") #'completion-at-point)
    map)
  "Keymap of `codeql-repl-mode'.")

(define-derived-mode codeql-repl-mode comint-mode "CodeQL-REPL"
  "Major mode of the CodeQL REPL, see `codeql-repl'.

\\{codeql-repl-mode-map}"
  :syntax-table codeql-repl--syntax-table
  (setq comint-prompt-regexp (concat "^" (regexp-quote codeql-repl-prompt)))
  (setq-local comint-prompt-read-only t)
  (setq-local comint-input-sender #'codeql-repl--send)
  (setq-local comint-process-echoes nil)
  (setq-local comint-inhibit-carriage-motion t)
  (setq-local comint-input-ignoredups t)
  ;; inputs span lines
  (setq-local comint-input-ring-separator "\n\0\n")
  (setq-local comint-input-ring-file-name codeql-repl-history-file)
  (setq-local comment-start "// ")
  (setq-local comment-start-skip "\\(?://+\\|/\\*+\\)\\s *")
  (setq-local mode-line-process '(codeql-repl--started ":running"))
  (add-hook 'completion-at-point-functions #'codeql-repl--completion-at-point nil t)
  (add-hook 'kill-buffer-hook #'codeql-repl--on-kill nil t)
  (when (and codeql-repl-fontify-input (codeql--session-treesit-p))
    (setq-local comint-indirect-setup-function #'ql-tree-sitter-mode)
    (comint-fontify-input-mode))
  (comint-read-input-ring t))

(defun codeql-repl--write-history ()
  "Save the input history of the current REPL buffer.

Unlike `comint-write-input-ring', this separates the inputs by the
`comint-input-ring-separator' of the REPL, so that multi-line inputs
are read back whole."
  (let ((file comint-input-ring-file-name)
        (ring comint-input-ring)
        (separator comint-input-ring-separator))
    (when (and file (not (string-empty-p file))
               ring (not (ring-empty-p ring))
               (file-writable-p file))
      (with-temp-buffer
        (dotimes (index (ring-length ring))
          (insert (ring-ref ring (- (ring-length ring) index 1)) separator))
        (write-region nil nil file nil 'silent)))))

(defun codeql-repl--on-kill ()
  "Save the input history of this killed REPL buffer, and end its session."
  (when codeql-repl--session
    (codeql-repl--write-history)
    (codeql--session-kill codeql-repl--session)))

(defun codeql-repl--save-histories ()
  "Save the input history of all CodeQL REPL buffers."
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'major-mode buffer) 'codeql-repl-mode)
      (with-current-buffer buffer
        (codeql-repl--write-history)))))

(add-hook 'kill-emacs-hook #'codeql-repl--save-histories)

(defun codeql-repl--root ()
  "Return the root of the CodeQL pack that the current buffer belongs to, or nil."
  (cond (codeql-repl--session (codeql--session-root codeql-repl--session))
        ((codeql--find-project-root (or buffer-file-name default-directory)))))

(defun codeql-repl--find (root name)
  "Return the live REPL buffer of session NAME in the CodeQL pack at ROOT, or nil."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (and (eq major-mode 'codeql-repl-mode)
                     codeql-repl--session
                     (equal (codeql--session-root codeql-repl--session) root)
                     (equal (codeql--session-name codeql-repl--session) name)
                     (comint-check-proc buffer))))
            (buffer-list)))

(defun codeql-repl--banner (session)
  "Return the text that a new REPL of SESSION starts with."
  (let ((buffer (codeql--session-buffer session)))
    (concat
     (format "CodeQL REPL, session %s of %s\n"
             (codeql--session-name session)
             (abbreviate-file-name (codeql--session-root session)))
     (format "Database: %s (%s)\n"
             (abbreviate-file-name (or (codeql--session-database session) "none"))
             (or (buffer-local-value 'codeql--active-database-language buffer) "?"))
     (substitute-command-keys
      (concat "Enter definitions, select queries, expressions or formulas.  "
              ":help lists the commands, \\<codeql-repl-mode-map>\\[codeql-repl-cancel] cancels.\n")))))

(defun codeql-repl--start (root name)
  "Return a new REPL buffer for session NAME in the CodeQL pack at ROOT."
  (require 'comint)
  (let* ((session (codeql--session-ensure (codeql--session-get root name)))
         (buffer (generate-new-buffer
                  (format "*codeql-repl %s%s*"
                          (file-name-nondirectory (directory-file-name root))
                          (if (equal name "default") "" (format "<%s>" name))))))
    (with-current-buffer buffer
      (codeql-repl-mode)
      (setq codeql-repl--session session)
      ;; result locations are visited like from results of the session
      (setq codeql--org-query-buffer (codeql--session-buffer session))
      (let ((process (make-pipe-process :name "codeql-repl" :buffer buffer :noquery t)))
        (set-process-filter process #'ignore)
        (set-marker (process-mark process) (point-max))
        (comint-output-filter process (concat (codeql-repl--banner session)
                                              codeql-repl-prompt))))
    buffer))

;;;###autoload
(defun codeql-repl (root &optional name)
  "Switch to the CodeQL REPL of the CodeQL pack at ROOT, starting it if needed.

The REPL evaluates CodeQL input in session NAME (default: \"default\")
of the pack, on the database of the project.  Input can make
definitions, which later input can use, and ask for a select query, an
expression, a formula, or the name of a predicate to quick evaluate,
see `codeql--session-eval'.  When predicates of that name have
different arities, which one to evaluate is asked for, or entered as
NAME/ARITY.  The first `codeql-repl-max-rows' rows of the
results are printed, and all of them can be opened in a results buffer.

Input that begins with a colon is a REPL command, :help lists them.

Interactively, ROOT is the pack of the current buffer, or read from the
minibuffer, and with a prefix argument, NAME is read as well."
  (interactive
   (list (or (codeql-repl--root)
             (read-directory-name "CodeQL pack: " nil nil t))
         (when current-prefix-arg
           (read-string "Session name (default \"default\"): " nil nil "default"))))
  (let* ((pack (or (codeql--find-project-root root)
                   (user-error "%s is not in a CodeQL pack" root)))
         (root (file-name-as-directory (expand-file-name pack)))
         (name (or name "default")))
    (pop-to-buffer (or (codeql-repl--find root name) (codeql-repl--start root name)))))

(defun codeql-repl--print (text)
  "Print TEXT as REPL output, followed by a new prompt."
  (comint-output-filter (get-buffer-process (current-buffer))
                        (concat text
                                (if (or (string-empty-p text) (string-suffix-p "\n" text))
                                    ""
                                  "\n")
                                codeql-repl-prompt)))

(defun codeql-repl--input-complete-p (input)
  "Return non-nil if INPUT is complete, rather than to be continued on a new line.

Input is incomplete while it has unclosed parentheses, brackets, braces,
strings or comments, when it ends in an operator, or when it is a from
or where clause without a select."
  (with-temp-buffer
    (set-syntax-table codeql-repl--syntax-table)
    (insert input)
    (let ((state (syntax-ppss (point-max)))
          (code (progn
                  ;; what the input ends with, but for comments
                  (insert "\n")
                  (forward-comment (- (point-max)))
                  (string-trim (buffer-substring-no-properties (point-min) (point))))))
      (and (<= (car state) 0)
           (not (nth 3 state))
           ;; a line comment ends with the input, unlike a block comment
           (not (and (nth 4 state) (nth 7 state)))
           (not (string-match-p
                 (concat "\\(?:[-+*/%=<>|,]\\|\\_<"
                         (regexp-opt '("and" "or" "implies" "not" "if" "then" "else"
                                       "from" "where" "select" "instanceof" "extends"
                                       "import" "as" "in"))
                         "\\)\\'")
                 code))
           (not (and (string-match-p "\\`\\(?:from\\|where\\)\\_>" code)
                     (not (string-match-p "\\_<select\\_>" code))))))))

(defun codeql-repl-return ()
  "Send the input to the CodeQL REPL when it is complete, else continue it.

See `codeql-repl--input-complete-p' for when input is complete."
  (interactive)
  (let ((process (get-buffer-process (current-buffer))))
    (if (and process
             (>= (point) (process-mark process))
             (not (codeql-repl--input-complete-p
                   (buffer-substring-no-properties (process-mark process) (point-max)))))
        (codeql-repl-newline)
      (comint-send-input))))

(defun codeql-repl-newline ()
  "Continue the input of the CodeQL REPL on a new line."
  (interactive)
  (let* ((process (get-buffer-process (current-buffer)))
         (start (if (and process (>= (point) (process-mark process)))
                    (process-mark process)
                  (line-beginning-position)))
         ;; earlier output may have unbalanced parentheses
         (depth (car (parse-partial-sexp start (point)))))
    (insert "\n" (make-string (* 2 (max depth 0)) ?\s))))

(defun codeql-repl--send (_process input)
  "Evaluate INPUT, which was entered in the current REPL buffer."
  (let ((input (string-trim input)))
    (cond ((string-empty-p input)
           (codeql-repl--print ""))
          ((string-prefix-p ":" input)
           (let* ((name (car (split-string (substring input 1) "[ \t\n]+")))
                  (arguments (string-trim (substring input (1+ (length name)))))
                  (commands (if-let ((exact (assoc name codeql-repl--commands)))
                                (list exact)
                              (seq-filter (lambda (c) (string-prefix-p name (car c)))
                                          codeql-repl--commands))))
             (cond
              ((null commands)
               (codeql-repl--print
                (codeql-repl--error (format "Unknown command :%s, :help lists them" name))))
              ((cdr commands)
               (codeql-repl--print
                (codeql-repl--error
                 (format "Ambiguous command :%s, it may be %s" name
                         (mapconcat (lambda (c) (concat ":" (car c))) commands " ")))))
              (t
               (condition-case err
                   (when-let ((text (funcall (nth 1 (car commands)) arguments)))
                     (codeql-repl--print text))
                 (error (codeql-repl--print (codeql-repl--error (error-message-string err)))))))))
          (t (codeql-repl--eval input)))))

(defun codeql-repl--error (message)
  "Return MESSAGE formatted as an error of the REPL."
  (propertize (string-trim-right message) 'font-lock-face 'codeql-repl-error))

(defun codeql-repl--note (message)
  "Return MESSAGE formatted as a note of the REPL."
  (propertize message 'font-lock-face 'codeql-repl-note))

(defun codeql-repl--resolve-overload (input)
  "Return INPUT, or the NAME/ARITY of the predicate that INPUT names.

When INPUT is the name of predicates of the session with different
arities, which one to evaluate is read from the minibuffer.  Quitting
that returns INPUT, whose evaluation then lists the predicates."
  (let ((overloads (and (string-match "\\`[ \t\n]*\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t\n]*\\'" input)
                        (codeql--session-overloads
                         (codeql--session-definitions codeql-repl--session)
                         (match-string 1 input)))))
    (if (not (cdr overloads))
        input
      (let* ((choices (mapcar (lambda (definition)
                                (cons (codeql--session-definition-name definition) definition))
                              overloads))
             (completion-extra-properties
              (list :annotation-function
                    (lambda (choice)
                      (when-let ((definition (cdr (assoc choice choices))))
                        (concat "  " (codeql--session-signature definition)))))))
        (condition-case nil
            (completing-read (format "Predicate %s is overloaded, evaluate: "
                                     (plist-get (car overloads) :name))
                             choices nil t nil nil (caar choices))
          (quit input))))))

(defun codeql-repl--eval (input &rest args)
  "Evaluate INPUT in the session of the current REPL buffer, and print the outcome.

ARGS are passed on to `codeql--session-eval'."
  (let ((buffer (current-buffer)))
    (unless (codeql--session-pending codeql-repl--session)
      (let ((resolved (codeql-repl--resolve-overload input)))
        (unless (equal resolved input)
          (comint-output-filter (get-buffer-process buffer)
                                (concat (codeql-repl--note
                                         (format (if (plist-get args :count)
                                                     "Counting %s."
                                                   "Evaluating %s.")
                                                 resolved))
                                        "\n"))
          (setq input resolved))))
    (condition-case err
        (progn
          (setq codeql-repl--started (float-time))
          (apply #'codeql--session-eval codeql-repl--session input
                 (lambda (outcome)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (codeql-repl--print (codeql-repl--format-outcome outcome)))))
                 :frontend "REPL" args))
      (error
       (setq codeql-repl--started nil)
       (codeql-repl--print
        (codeql-repl--error
         (if (codeql--session-pending codeql-repl--session)
             (substitute-command-keys
              "An evaluation is running, \\<codeql-repl-mode-map>\\[codeql-repl-cancel] cancels it")
           (error-message-string err))))))
    (force-mode-line-update)))

(defun codeql-repl--format-outcome (outcome)
  "Return the text that the REPL prints for the OUTCOME of an evaluation."
  (let* ((elapsed (and codeql-repl--started (- (float-time) codeql-repl--started)))
         (status (plist-get outcome :status))
         (dropped (plist-get outcome :dropped))
         (notes (codeql--session-definition-notes outcome))
         (lines nil))
    (setq codeql-repl--started nil)
    (force-mode-line-update)
    (dolist (note notes)
      (push (if (cdr note)
                (propertize (car note) 'font-lock-face 'warning)
              (codeql-repl--note (car note)))
            lines))
    (pcase status
      ('results
       (setq codeql-repl--outcome outcome)
       (push (condition-case err
                 (codeql-repl--format-results outcome elapsed)
               (error (codeql-repl--error (format "Could not read the results: %s"
                                                  (error-message-string err)))))
             lines))
      ('empty
       (push (codeql-repl--note (format "No results%s." (codeql-repl--elapsed elapsed))) lines))
      ('error
       (if (plist-get outcome :cancelled)
           (push (codeql-repl--note "Canceled.") lines)
         (push (codeql-repl--error (or (plist-get outcome :message) "Evaluation failed")) lines)
         (when dropped
           (push (propertize (format "Rolled back %s." (string-join dropped ", "))
                             'font-lock-face 'warning)
                 lines)))))
    (when (and (eq status 'defined) (not notes))
      (push (codeql-repl--note "Nothing new was defined.") lines))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun codeql-repl--elapsed (elapsed)
  "Return the text for an evaluation that took ELAPSED seconds, or nil."
  (if elapsed (format " in %.1fs" elapsed) ""))

(defun codeql-repl--cell (value)
  "Return the text that the REPL shows for the result VALUE.

Locations become buttons that visit them.  This is called in the query
buffer of the results, which locates their source archive."
  (pcase value
    ('t "true")
    (:false "false")
    (:null "")
    ((pred numberp) (number-to-string value))
    ((pred stringp)
     (propertize (codeql--printable-label value) 'font-lock-face 'font-lock-string-face))
    ((pred listp)
     (if-let ((node (codeql--session-value-node value)))
         (make-text-button (codeql--result-node-label node) nil
                           'action #'codeql-repl--visit
                           'codeql-link (codeql--result-node-link node)
                           'help-echo (format "Visit %s:%s"
                                              (file-name-nondirectory
                                               (codeql--result-node-filename node))
                                              (codeql--result-node-line node))
                           'follow-link t)
       (codeql--printable-label (alist-get 'label value))))
    (_ (format "%s" value))))

(defun codeql-repl--visit (button)
  "Visit the result location of BUTTON."
  (codeql--org-open-file-link (button-get button 'codeql-link)))

(defun codeql-repl--table (columns rows)
  "Return a text table of ROWS of cell texts, under the names of COLUMNS."
  (let* ((names (cl-loop for column in columns
                         for i from 0
                         collect (or (alist-get 'name column)
                                     (if (= (length columns) 1) "" (format "[%d]" i)))))
         (numeric (mapcar (lambda (column)
                            (member (alist-get 'kind column) '("Integer" "Float")))
                          columns))
         (rows (mapcar (lambda (row)
                         (mapcar (lambda (cell)
                                   (truncate-string-to-width
                                    cell codeql-repl-max-column-width nil nil "…"))
                                 row))
                       rows))
         (widths (cl-loop for i from 0 below (length columns)
                          collect (apply #'max (string-width (nth i names))
                                         (mapcar (lambda (row) (string-width (nth i row)))
                                                 rows))))
         (line (lambda (cells)
                 (string-trim-right
                  (mapconcat #'identity
                             (cl-loop for cell in cells
                                      for width in widths
                                      for right in numeric
                                      for pad = (make-string (- width (string-width cell)) ?\s)
                                      collect (if right (concat pad cell) (concat cell pad)))
                             (codeql-repl--note " │ "))))))
    (concat
     ;; a single value needs no header
     (unless (or (seq-every-p #'string-empty-p names)
                 (and (= (length columns) 1) (<= (length rows) 1)))
       (concat (funcall line (mapcar (lambda (name)
                                       (propertize name 'font-lock-face 'codeql-repl-column))
                                     names))
               "\n"
               (codeql-repl--note (mapconcat (lambda (width) (make-string width ?─))
                                             widths "─┼─"))
               "\n"))
     (mapconcat (lambda (row) (funcall line row)) rows "\n"))))

(defun codeql-repl--format-results (outcome elapsed)
  "Return the text that the REPL prints for the results of OUTCOME.

The evaluation took ELAPSED seconds."
  (pcase-let* ((session (plist-get outcome :session))
               (`(,columns ,tuples ,total)
                (codeql--session-decode session (plist-get outcome :bqrs-path)
                                        codeql-repl-max-rows))
               (rows (with-current-buffer (codeql--session-buffer session)
                       (let ((codeql--source-link-prefix-box (list nil)))
                         (mapcar (lambda (tuple) (mapcar #'codeql-repl--cell tuple))
                                 tuples))))
               (button (make-text-button "[results]" nil
                                         'action #'codeql-repl--show-outcome
                                         'codeql-outcome outcome
                                         'help-echo "Open all results in a results buffer"
                                         'follow-link t)))
    (concat
     (codeql-repl--table columns rows)
     "\n"
     (codeql-repl--note
      (format "%s%s%s "
              (if (= total 1) "1 result" (format "%d results" total))
              (if (> total (length rows)) (format ", %d shown" (length rows)) "")
              (codeql-repl--elapsed elapsed)))
     button)))

(defun codeql-repl--show-outcome (button)
  "Open the results of BUTTON's outcome in a results buffer."
  (codeql--query-run-show (button-get button 'codeql-outcome)))

(defun codeql-repl-show-results ()
  "Open the results of the last evaluation of the CodeQL REPL in a results buffer."
  (interactive)
  (if codeql-repl--outcome
      (codeql--query-run-show codeql-repl--outcome)
    (user-error "No results yet")))

(defun codeql-repl-cancel ()
  "Cancel the evaluation that runs in the CodeQL REPL."
  (interactive)
  (unless (and codeql-repl--session (codeql--session-pending codeql-repl--session))
    (user-error "No evaluation is running"))
  (codeql--session-cancel codeql-repl--session))

(defun codeql-repl--command-help (_arguments)
  "Return the help of the REPL commands."
  (concat
   (mapconcat (lambda (command)
                (format "  :%-28s %s"
                        (concat (car command) (if (nth 2 command) (concat " " (nth 2 command)) ""))
                        (nth 3 command)))
              codeql-repl--commands "\n")
   "\n"
   (codeql-repl--note
    (concat "Commands can be abbreviated.  Other input is CodeQL: definitions, a select query,\n"
            "an expression, a formula, or the name of a predicate to quick evaluate."))))

(defun codeql-repl--definition-label (definition)
  "Return how the REPL lists DEFINITION."
  (concat (pcase (plist-get definition :kind)
            ('import (plist-get definition :name))
            ('newtype (format "newtype %s" (plist-get definition :name)))
            (kind (format "%s %s" kind (codeql--session-definition-name definition))))
          (unless (or (eq (plist-get definition :kind) 'import)
                      (plist-get definition :verified))
            (codeql-repl--note " (not compiled yet)"))))

(defun codeql-repl--command-defs (arguments)
  "Return the definitions of the session, or the code of those named ARGUMENTS."
  (let ((definitions (codeql--session-definitions codeql-repl--session)))
    (if (string-empty-p arguments)
        (if definitions
            (mapconcat #'codeql-repl--definition-label definitions "\n")
          (codeql-repl--note "No definitions."))
      (let ((matching (seq-filter (lambda (definition)
                                    (or (equal (codeql--session-definition-name definition)
                                               arguments)
                                        (equal (plist-get definition :name) arguments)))
                                  definitions)))
        (if matching
            (mapconcat (lambda (definition) (plist-get definition :text)) matching "\n\n")
          (codeql-repl--error (format "No definition named %s" arguments)))))))

(defun codeql-repl--command-undef (arguments)
  "Remove the definitions named ARGUMENTS from the session."
  (when (string-empty-p arguments)
    (user-error "Usage: :undef NAME"))
  (if-let ((removed (codeql--session-undefine codeql-repl--session arguments)))
      (codeql-repl--note (format "Removed %s."
                                 (mapconcat #'codeql--session-definition-name removed ", ")))
    (codeql-repl--error (format "No definition named %s" arguments))))

(defun codeql-repl--command-reset (_arguments)
  "Remove the definitions of the session, except the default ones."
  (codeql--session-reset codeql-repl--session)
  (codeql-repl--note "Removed all definitions."))

(defun codeql-repl--command-count (arguments)
  "Count the results of the predicate, or the values of the type, ARGUMENTS."
  (when (string-empty-p arguments)
    (user-error "Usage: :count PREDICATE[/ARITY]|TYPE"))
  (codeql-repl--eval arguments :count t)
  nil)

(defun codeql-repl--command-results (_arguments)
  "Open the last results in a results buffer."
  (codeql-repl-show-results)
  "")

(defun codeql-repl--command-module (_arguments)
  "Return the query module of the last evaluation."
  (with-current-buffer (codeql--session-buffer codeql-repl--session)
    (string-trim-right (buffer-substring-no-properties (point-min) (point-max)))))

(defun codeql-repl--command-db (arguments)
  "Return the database of the session, after registering the one at ARGUMENTS."
  (unless (string-empty-p arguments)
    (when (codeql--session-pending codeql-repl--session)
      (user-error "An evaluation is running"))
    (codeql--session-ensure codeql-repl--session (expand-file-name arguments)))
  (format "%s (%s)"
          (abbreviate-file-name (or (codeql--session-database codeql-repl--session) "none"))
          (or (buffer-local-value 'codeql--active-database-language
                                  (codeql--session-buffer codeql-repl--session))
              "?")))

(defun codeql-repl--command-cancel (_arguments)
  "Cancel the running evaluation."
  (if (codeql--session-pending codeql-repl--session)
      (progn (codeql--session-cancel codeql-repl--session) nil)
    (codeql-repl--note "No evaluation is running.")))

(defun codeql-repl--command-clear (_arguments)
  "Clear the REPL buffer."
  (let ((inhibit-read-only t))
    (delete-region (point-min) (process-mark (get-buffer-process (current-buffer)))))
  "")

(defun codeql-repl--completions (session)
  "Return the names of the definitions of SESSION, to complete.
Predicates with several arities are also there as NAME/ARITY."
  (let ((definitions (seq-remove (lambda (definition) (eq (plist-get definition :kind) 'import))
                                 (codeql--session-definitions session))))
    (delete-dups
     (append (mapcar (lambda (definition) (plist-get definition :name)) definitions)
             (delq nil (mapcar (lambda (definition)
                                 (when (cdr (codeql--session-overloads
                                             definitions (plist-get definition :name)))
                                   (codeql--session-definition-name definition)))
                               definitions))))))

(defun codeql-repl--annotation (session candidate)
  "Return the annotation of the completion CANDIDATE in SESSION.
That is the signature of the definition it names, the names of the
predicates it names, or that it is a keyword."
  (let ((matching (seq-filter (lambda (definition)
                                (and (not (eq (plist-get definition :kind) 'import))
                                     (or (equal (plist-get definition :name) candidate)
                                         (equal (codeql--session-definition-name definition)
                                                candidate))))
                              (codeql--session-definitions session))))
    (cond ((cdr matching)
           (concat "  " (mapconcat #'codeql--session-definition-name matching ", ")))
          (matching (concat "  " (codeql--session-signature (car matching))))
          ((member candidate codeql--session-keywords) "  keyword"))))

(defun codeql-repl--completion-at-point ()
  "Complete CodeQL keywords, names of session definitions and REPL commands."
  (let ((process (get-buffer-process (current-buffer)))
        (session codeql-repl--session))
    (when (and process session (>= (point) (process-mark process)))
      (let* ((bounds (or (bounds-of-thing-at-point 'symbol) (cons (point) (point))))
             (start (car bounds))
             (command (and (eq (char-before start) ?:)
                           (= (1- start) (process-mark process)))))
        ;; NAME/ARITY of an overloaded predicate
        (when (and (looking-back "\\_<\\([A-Za-z_][A-Za-z0-9_]*\\)/[0-9]*"
                                 (process-mark process))
                   (cdr (codeql--session-overloads (codeql--session-definitions session)
                                                   (match-string 1))))
          (setq bounds (cons (match-beginning 0) (point))
                start (car bounds)))
        (list start (cdr bounds)
              (if command
                  (mapcar #'car codeql-repl--commands)
                (completion-table-dynamic
                 (lambda (_)
                   (append (codeql-repl--completions session) codeql--session-keywords))))
              :annotation-function (unless command
                                     (lambda (candidate)
                                       (codeql-repl--annotation session candidate)))
              :exclusive 'no)))))

(defun codeql-repl--member-bounds ()
  "Return the bounds of the top-level definition or query at point."
  (let ((node (treesit-node-at (point) 'ql))
        (member nil))
    (while node
      (when (equal (treesit-node-type node) "moduleMember")
        (setq member node))
      (setq node (treesit-node-parent node)))
    (unless member
      (user-error "No definition or query at point"))
    (list (treesit-node-start member) (treesit-node-end member))))

(defun codeql-repl-send-region (start end)
  "Evaluate the code from START to END in the CodeQL REPL of its pack.

Interactively, that is the active region, or the top-level definition
or query at point.  The code is entered in the REPL, which is displayed,
and started when there is none yet."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (codeql-repl--member-bounds)))
  (let ((code (string-trim (buffer-substring-no-properties start end)))
        (root (or (codeql-repl--root) (user-error "Not in a CodeQL pack"))))
    (save-selected-window
      (codeql-repl root)
      (codeql-repl--enter code))))

(defun codeql-repl--enter (code)
  "Enter CODE in the current REPL buffer, as if it was typed and sent."
  (let* ((process (get-buffer-process (current-buffer)))
         (pending (buffer-substring (process-mark process) (point-max))))
    (goto-char (point-max))
    (delete-region (process-mark process) (point-max))
    (insert code)
    (comint-send-input)
    (insert pending)))

;; cleanup on kill
(defun codeql--cli-server-release ()
  "Shut down the current buffer's CLI server unless another QL buffer uses it."
  (let* ((key (codeql--cli-server-key))
         (proc (gethash key codeql--cli-servers)))
    (when (and proc
               (not (cl-some (lambda (buffer)
                               (and (not (eq buffer (current-buffer)))
                                    (eq (buffer-local-value 'major-mode buffer)
                                        'ql-tree-sitter-mode)
                                    (equal (with-current-buffer buffer
                                             (codeql--cli-server-key))
                                           key)))
                             (buffer-list))))
      (codeql--cli-server-kill proc)
      (remhash key codeql--cli-servers))))

(add-hook 'kill-buffer-hook
          (lambda ()
            (when (eq major-mode 'ql-tree-sitter-mode)
              (codeql--cli-server-release)
              (codeql--query-server-release))))

(provide 'emacs-codeql)

;;; emacs-codeql.el ends here
