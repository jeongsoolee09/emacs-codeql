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
(require 'org)
(require 'ol)
(require 'files)
(require 'project)

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

(defcustom codeql-share-query-server nil
  "Share one query server and database across all QL buffers.

When nil, every QL buffer has its own query server and database, and you can
share them on demand with `codeql-query-server-inherit'.

When non-nil, QL buffers on the same host and with the same CodeQL CLI use one
query server, active database and query history: a server started in one of
them is used by all others, including ones opened later.  This is convenient
when developing a query together with its library files."
  :type 'boolean
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

(defcustom codeql-max-raw-results 200
  "The max amount of raw result tuples to render in an org-table.

Raw result sets that contain more tuples than this are paginated, with each
page holding at most this many tuples.  See `codeql-results-pagination-mode'."
  :type 'integer
  :group 'emacs-codeql)

(defcustom codeql-max-sarif-results 100
  "The max amount of problem or path-problem results to render at once.

Queries that report more results than this are paginated, with each page
holding at most this many results.  See `codeql-results-pagination-mode'."
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

(defun codeql--gh-codeql-cli-available-p ()
  (condition-case nil
      (eql 0 (with-temp-buffer
               (process-file "gh" nil `(,(current-buffer) nil) nil "codeql")))
    (error nil)))

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

(defun codeql--get-cli-version ()
  ;; used in setup for ql-tree-sitter-mode so we can not assert the mode here yet.
  (codeql--cli-command-to-string (list "version")))

(defun codeql--buffer-local-init-hook ()
  "Set up a codeql buffer context correctly."

  ;; use whatever the current config for codeql-cli and codeql-search-paths is
  (setq codeql--cli-buffer-local (list codeql-cli))

  ;; decide whether we want to use the gh cli to run our codeql commands
  (if (and codeql-use-gh-codeql-extension-when-available
           (codeql--gh-codeql-cli-available-p))
      (progn
        (message "Enabling gh cli codeql extension use.")
        (setq codeql--cli-buffer-local
              (list (executable-find "gh" (file-remote-p default-directory)) "codeql")))
    ;; if we're in a remote context, make absolutely sure we know where the cli lives
    (when (and (file-remote-p default-directory))
      (let ((remote-path
             (string-trim-right
              (or (executable-find "codeql" t)
                  (read-file-name "Need remote path to codeql cli bin: "
                                  nil default-directory t)))))
        (message "Setting remote codeql cli path: %s" remote-path)
        (setq codeql--cli-buffer-local (list (codeql--tramp-unwrap remote-path))))))

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

    ;; library paths should contain everything we need in terms of search paths
    (let ((library-paths
           (codeql--resolve-library-paths
            (codeql--tramp-unwrap
             (expand-file-name
              (codeql--tramp-wrap (buffer-file-name)))))))
      (setq codeql--search-paths-buffer-local
            (append
             codeql--search-paths-buffer-local
             (cl-loop for library-path across library-paths
                      unless (member library-path codeql--search-paths-buffer-local)
                      collect library-path))))

    ;; dedupe and remove nil from search paths
    (setq codeql--search-paths-buffer-local
          (delq nil (delete-dups
                     codeql--search-paths-buffer-local))))

  ;; pick up a running query server of another QL buffer if we share them
  (codeql--query-server-adopt)

  ;; now that we have all our search paths, let's try and start up our LSP server
  ;; this will rely on our project.el integration to determine the workspace paths
  (condition-case nil
      (when (and codeql-configure-eglot-lsp
                 (or (and (file-remote-p (buffer-file-name))
                          (yes-or-no-p "[WARNING] Do you want to use LSP remotely? This can be very slow!"))
                     (not (file-remote-p (buffer-file-name)))))
        ;; turn eglot on if local or we really want it remote
        (eglot-ensure))
    ;; no LSP for us due to error
    (error (message "Ignoring failed LSP initialization and plowing ahead!"))))

;; add a hook that sets up all the things we need to be available in the buffer-local context
(add-hook 'ql-tree-sitter-mode-hook #'codeql--buffer-local-init-hook)

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

(defvar codeql--registered-database-history nil)

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

(defun codeql--query-server-share-key ()
  "Return what QL buffers need in common to share a query server."
  (list (file-remote-p default-directory) codeql--cli-buffer-local))

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
  (when (and codeql-share-query-server (not codeql--query-server))
    (let ((key (codeql--query-server-share-key)))
      (when-let ((source (seq-find (lambda (buffer)
                                     (and (not (eq buffer (current-buffer)))
                                          (buffer-local-value 'codeql--query-server buffer)
                                          (equal (with-current-buffer buffer
                                                   (codeql--query-server-share-key))
                                                 key)))
                                   (codeql--ql-buffers))))
        (codeql--query-server-copy-state source)
        (message "Using the query server of %s." (buffer-name source))))))

(defun codeql-query-server-inherit (buffer)
  "Use the query server, database and query history of QL BUFFER."
  (interactive
   (progn
     (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
     (when codeql--query-server
       (user-error "This buffer already has a query server, stop it first"))
     (let* ((key (codeql--query-server-share-key))
            (candidates
             (mapcar #'buffer-name
                     (seq-filter (lambda (buffer)
                                   (and (not (eq buffer (current-buffer)))
                                        (buffer-local-value 'codeql--query-server buffer)
                                        (equal (with-current-buffer buffer
                                                 (codeql--query-server-share-key))
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
  (message "Using the query server of %s." (buffer-name buffer)))

(defun codeql--query-server-on-shutdown (obj buffer-context)
  "Clear the server and database state of the buffers that used server OBJ."
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
    (message "Shut down query server and cleared active database.")))

(defun codeql--query-server-release ()
  "Detach the current buffer from its query server, shutting it down if unused."
  (when codeql--query-server
    (if-let ((others (codeql--query-server-buffers codeql--query-server (current-buffer))))
        (progn
          ;; hand the database over to a buffer that keeps using it
          (when (and codeql--database-dataset-folder
                     (eq (codeql--active-datasets-get codeql--database-dataset-folder)
                         (current-buffer)))
            (codeql--active-datasets-add codeql--database-dataset-folder (car others)))
          (setq codeql--query-server nil)
          (codeql--reset-database-state))
      (jsonrpc-shutdown codeql--query-server))))

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
  (let ((json (codeql--cli-command-to-string
               (list "resolve" "library-path" "-v" "--log-to-stderr" "--format=json"
                     (format "--query=%s" query-path)))))
    (when json
      (condition-case nil
          (cl-destructuring-bind (&key libraryPath &allow-other-keys)
              (json-parse-string json :object-type 'plist)
            ;; this is a vector
            libraryPath)
        (error (progn (message "error parsing json: %s" json) nil))))))

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

(defun codeql--database-extract-source-archive-zip (trusted-root)
  "Mount or extract a database source zip archive, ensuring TRUSTED-ROOT."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (message "archive-root: %s" (codeql--file-truename codeql--database-source-archive-root))
  (message "trusted-root: %s" (codeql--file-truename trusted-root))
  (cond
   ((and (>= emacs-major-version 27) (eq system-type 'gnu/linux))
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
  (interactive (list (read-file-name "Database: " nil default-directory t)))
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)

  ;; if no server is running yet, offer to start one
  (unless codeql--query-server
    (transient-setup 'codeql-transient-query-server-init-start)
    (error "No query server running, please start one and re-select database."))

  ;; init the database history if need be
  (unless codeql--registered-database-history
    (setq codeql--registered-database-history (make-hash-table :test #'equal)))

  ;; resolve and set the dataset folder, we need this when running queries
  (let* ((database-info (codeql--database-info database-path))
         (database-language (json-pointer-get database-info "/languages/0"))
         (source-location-prefix (json-pointer-get database-info "/sourceLocationPrefix"))
         (source-archive-zip (json-pointer-get database-info "/sourceArchiveZip"))
         (source-archive-root (json-pointer-get database-info "/sourceArchiveRoot"))
         (database-dataset-folder (json-pointer-get database-info "/datasetFolder")))

    (cl-assert codeql--query-server t)
    (cl-assert database-dataset-folder t)

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
             (puthash database-path database-path codeql--registered-database-history)
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
             (puthash database-path database-path codeql--registered-database-history)
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
  (require 'org-table)
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

(defun codeql--result-node-to-org (node &optional custom-description)
  "Transform a result node into an org compatible link|string representation."
  ;; https://orgmode.org/guide/Hyperlinks.html
  (if (codeql--result-node-visitable node)
      ;; since we have our own link type, also add in a column
      (let ((link (format "codeql:%s%s::%s:%s"
                          (codeql--source-link-prefix)
                          (codeql--encode-link-path (codeql--result-node-filename node))
                          (codeql--result-node-line node)
                          (codeql--result-node-column node)))
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
                     (if-let ((url (codeql--result-node-url node)))
                         (format "%s:%s:%s"
                                 ;; set a custom description for this link
                                 (with-current-buffer parent-buffer
                                   (codeql--result-node-to-org node
                                                               (file-name-nondirectory
                                                                (codeql--uri-to-filename
                                                                 (json-pointer-get url "/uri")))))
                                 ;; org links don't support column offsets
                                 ;; so this is mostly just eye candy :P
                                 (json-pointer-get url "/startLine")
                                 (json-pointer-get url "/startColumn"))
                       ;; get ahead, but don't say nothing.
                       ""))
                    ;; do some basic ballpark alignment based on prefix label length
                    (align (- 50 (+ 10 (length (codeql--escape-org-description (codeql--result-node-label node)))))))
               ;; yolo alignment
               (insert (concat prefix (make-string (if (< align 0) 10 align) ?\s) suffix "\n"))))
    ;; return our nodes as org list
    (buffer-string)))

(defun codeql--query-results-to-org (query-results results-type &optional columns)
  "Turn QUERY-RESULTS of RESULTS-TYPE into an org data."
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
        ;; kind: problem and path-problem use the exact same SARIF renderer
        ((or 'problem 'path-problem)
         ;; generate an org tree off of a list structure
         (cl-loop for issue in query-results
                  for locations = (codeql--result-node-locations issue)
                  for related-locations = (codeql--result-node-related-locations issue)
                  for code-flows = (codeql--result-node-code-flows issue)
                  do
                  ;; add the locations for this issue, according to spec this can be up to 10
                  ;; but for code scanning etc. it can only have 1, nest flows either way.
                  (cl-loop for location in locations do
                           (insert
                            (concat
                             (if-let ((url (codeql--result-node-url location)))
                                 (format "* %s [%s] %s ... %s:%s:%s"
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
                                         (json-pointer-get url "/startLine")
                                         (json-pointer-get url "/startColumn"))
                               (format "* %s ... [location unknown]"
                                       (with-current-buffer parent-buffer
                                         (codeql--swap-sarif-links-for-org-links
                                          (codeql--result-node-label issue) related-locations))))
                             "\n"))
                           ;; add any codeflow paths and their associated nodes for this issue
                           (when code-flows
                             (cl-loop for path in code-flows
                                      for i below (length code-flows) do
                                      (cl-loop for nodes in path do
                                               ;; add the location|path nodes to the tree :)
                                               (insert (codeql--org-list-from-nodes
                                                        parent-buffer
                                                        nodes
                                                        (format "** Path #%s\n" i))))))))))
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

(defun codeql--org-render-sarif-results (org-data query-buffer &optional footer marker)
  "Render ORG-DATA including an optional FOOTER."
  ;; sarif results are org trees
  (let ((buffer
         (generate-new-buffer
          (format "* codeql-org-results:%s *" (if marker marker "")))))
    (with-current-buffer buffer
      (insert org-data)
      (org-mode)
      (codeql--hide-zero-width-spaces)
      (when footer
        (goto-char (point-max))
        (insert "\n* Results Footer\n")
        (insert footer))
      (goto-char (point-min))
      (setq buffer-read-only t)
      (setq codeql--org-query-buffer query-buffer)
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
the shown one, and :offsets the vector of page byte offsets as computed by
`codeql bqrs info --paginate-rows', or nil for a single page.

SARIF results have :results, the vector of all parsed SARIF results.")

(defvar-local codeql--raw-results-page-cache nil
  "Rendered org data of recently visited pages, as (PAGE . ORG-DATA) entries.

Most recently used entries come first, see `codeql-results-page-cache-size'.")

(defun codeql--raw-results-fill-buffer (org-data &optional footer)
  "Replace the current buffer contents with raw results ORG-DATA and FOOTER.

ORG-DATA is expected to be aligned already, see `codeql--org-table'."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert org-data)
    (unless (derived-mode-p 'org-mode)
      (org-mode))
    ;; only add footer after the table
    (when footer
      (goto-char (point-max))
      (insert "\n* Results Footer\n")
      (insert footer))
    (goto-char (point-min))))

(defun codeql--org-render-raw-query-results (org-data query-buffer &optional footer marker pagination)
  "Render ORG-DATA including an optional FOOTER.

PAGINATION is an optional plist describing a paginated result set, see
`codeql--raw-results-pagination'."
  ;; raw results are org tables
  (let ((buffer
         (generate-new-buffer
          (format "* codeql-org-results:%s *" (if marker marker "")))))
    (with-current-buffer buffer
      (org-mode)
      (codeql--hide-zero-width-spaces)
      (setq codeql--org-query-buffer query-buffer)
      (when pagination
        (setq codeql--raw-results-pagination pagination)
        (codeql--raw-results-cache-put (plist-get pagination :page) org-data)
        (codeql-results-pagination-mode 1))
      (codeql--raw-results-fill-buffer
       org-data
       (if pagination (codeql--raw-results-pagination-footer) footer))
      (setq buffer-read-only t)
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

(defun codeql--sarif-results-to-org (results start end)
  "Return org data for the SARIF RESULTS vector from index START below END."
  (let ((codeql--source-link-prefix-box (list nil))
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
               nil))
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
                               (json-pointer-get element "/url"))
                          (let ((node (codeql--result-node-create
                                       :label (json-pointer-get element "/label")
                                       :mark "→"
                                       :filename (codeql--uri-to-filename
                                                  (json-pointer-get element "/url/uri"))
                                       :line (json-pointer-get element "/url/startLine")
                                       :column (json-pointer-get element "/url/startColumn")
                                       :visitable t
                                       :url (json-pointer-get element "/url"))))
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

(defun codeql--raw-results-page-to-org (bqrs-path result-set offsets page page-size)
  "Return org data for PAGE of RESULT-SET in BQRS-PATH, or nil if empty.

PAGE is 0-based and indexes into the byte OFFSETS vector of pages holding
PAGE-SIZE rows.  When OFFSETS is nil the whole result set is decoded."
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
       'raw
       (alist-get 'columns json)))))

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

(defun codeql--raw-results-setup (bqrs-path result-sets result-set footer &optional sort)
  "Prepare RESULT-SET of BQRS-PATH for display, optionally sorted by SORT.

RESULT-SETS holds the alists of all result sets in BQRS-PATH as reported
by `codeql bqrs info', and RESULT-SET is the alist of the one to show.
SORT is nil or a (COLUMN . DIRECTION) pair, see
`codeql--raw-results-sorted-bqrs'.

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
         (page-size (if offsets codeql-max-raw-results (max total-rows 1))))
    (when (and (> total-rows codeql-max-raw-results) (not offsets))
      (message "Could not compute result pagination offsets, rendering all %d rows."
               total-rows))
    (when (> total-rows 0)
      (when-let ((org-data (codeql--raw-results-page-to-org
                            decode-path name offsets 0 page-size)))
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
                          (* page page-size) (* (1+ page) page-size)))
                     (codeql--raw-results-page-to-org
                      (plist-get pagination :bqrs-path)
                      (plist-get pagination :result-set)
                      (plist-get pagination :offsets)
                      page
                      (plist-get pagination :page-size))))))))
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
                    sort))))
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
            :filename (or (codeql--uri-to-filename uri) uri)
            :line  (json-pointer-get region "/startLine")
            :column (or (json-pointer-get region "/startColumn") 1)
            :visitable region
            :related-id related-id
            ;; build a json alist to parse out for url
            :url `(,(cons 'uri uri)
                   ,(cons 'startLine (json-pointer-get region "/startLine"))
                   ,(cons 'endLine (or (json-pointer-get region "/endLine")
                                       (json-pointer-get region "/startLine")))
                   ,(cons 'startColumn (or (json-pointer-get region "/startColumn") 1))
                   ,(cons 'endColumn (json-pointer-get region "/endColumn"))
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

(defun codeql--archive-path-from-org-filename (filename)
  ;; do a dance to normalize back to the archive root relative path for this filename
  (format "/%s" (cadr
                 (split-string
                  filename
                  (format "%s/*" codeql--database-source-archive-root)))))

(defun codeql--run-templated-query (language query-name src-filename src-buffer)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (cl-assert codeql--active-database t)

  (when-let ((query-path (codeql--templated-query-path language query-name)))
    (cl-loop for search-path in codeql--search-paths-buffer-local
             for full-path = (format "%s/%s" search-path query-path)
             when (codeql--file-exists-p full-path) do
             (message "Resolved templated query %s to %s" query-name full-path)
             (let ((template-values
                    (cond ((string= codeql-query-server "query-server")
                           `(:selectedSourceFile
                             (:values
                              (:tuples
                               [(:stringValue
                                 ,(codeql--archive-path-from-org-filename
                                   (codeql--tramp-unwrap src-filename)))]))))
                          ((string= codeql-query-server "query-server2")
                           `(:selectedSourceFile
                             ,(codeql--archive-path-from-org-filename
                               (codeql--tramp-unwrap src-filename)))))))
               (codeql--query-server-run-query-from-path
                full-path
                nil
                template-values
                src-filename
                src-buffer))
             ;; respect search precedence and only return from first find
             (cl-return)
             ;; if we did not return, that means we weren't able to find the thing.
             finally
             (error "Did not find templated queries in search paths."))))

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
    (use-local-map (copy-keymap (symbol-value (intern (format "%s-map" major-mode)))))
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
(defun codeql--find-file-other-window (filename &optional wildcards)
  (interactive
   (find-file-read-args "Find file in other window: "
                        (confirm-nonexistent-file-or-buffer)))
  ;; disable eglot-ensure
  (cl-letf (((symbol-function #'eglot-ensure)
             (lambda ()
               (message "Disabled eglot for codeql org link."))))
    (let ((value (find-file-noselect filename nil nil wildcards)))
      (if (listp value)
	  (progn
	    (setq value (nreverse value))
            ;; prevent folks from editing database source code
            (with-current-buffer (car value)
              (setq buffer-read-only t))
	    (switch-to-buffer-other-window (car value))
            (mapc (lambda (buf)
                    (with-current-buffer buf
                      (setq buffer-read-only t))
                    (switch-to-buffer buf))
                  (cdr value))
	    value)
        ;; prevent folks from editing database source code
        (with-current-buffer value
          (setq buffer-read-only t))
        (switch-to-buffer-other-window value)))))

(defun codeql--org-open-file-link (link)
  (let* ((parsed (string-match "\\`\\(.*\\)::\\([0-9]+\\):\\([0-9]+\\)\\'" link))
         (filename (codeql--decode-link-path
                    (if parsed (match-string 1 link) (car (split-string link "::")))))
         (line (when parsed (match-string 2 link)))
         (column (when parsed (match-string 3 link))))

    ;; XXX: hrmmm ... we probably want to force unique file visits
    ;; XXX: since we don't want to use a cross-query state when there
    ;; XXX: concurrent query buffers operating on the same database
    ;; XXX: although this re-associates to the correct query buffer
    ;; XXX: pending which results are being navigated, so this is
    ;; XXX: probably ok in practice

    (let ((query-buffer codeql--org-query-buffer))
      (when-let ((src-buffer (codeql--find-file-other-window filename)))
        (with-current-buffer src-buffer
          ;; this will be nil for org history, which means we lose any
          ;; dynamic xref capabilities and things of that nature ...
          ;; we could restore the state for the org-file on find-file
          ;; but that's making the assumption that the active database
          ;; is still related to the query history I suppose?
          (unless query-buffer
            (message "No active query buffer for these results, opened from history?"))
          (setq codeql--org-query-buffer query-buffer)
          (widen)
          ;; codeql is 1 based, eglot calcs are 0 based, adjust accordingly
          (when (and column line)
            (goto-char (codeql--eglot--lsp-position-to-point
                        `(;; align
                          :line ,(1- (string-to-number line))
                          :character ,(1- (string-to-number column))))))
          ;; enable our xref backend, this kicks in templated queries for refs and defs
          (codeql-xref-backend))))))

(org-link-set-parameters "codeql" :follow #'codeql--org-open-file-link)

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

(defun codeql--process-ast (json src-filename src-root src-buffer)
  ;; only allow this to be called as part of a templated flow
  (puthash src-filename (list json src-root) codeql--ast-cache)
  (codeql--render-ast json src-root src-filename src-buffer))

(defun codeql--templated-query-p (query-path)
  (or (string-match-p "/localDefinitions\\.ql$" query-path)
      (string-match-p "/localReferences\\.ql$" query-path)
      (string-match-p "/printAst\\.ql$" query-path)))

;; abandon hope, all ye who enter here ...
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
                         src-buffer)
  "Parse the results at BQRS-PATH and render them accordingly to the user."
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
                                  ;; check if we have any artifact contents, TODO: do something with 'm?
                                  (cl-loop for artifact across (json-pointer-get run "/artifacts")
                                           when (json-pointer-get artifact "/contents")
                                           do (message "Found artifact contents.")
                                           (cl-return t))
                                  collect (or (json-pointer-get run "/results") []))))
                 (total (length results))
                 (page-size (max 1 codeql-max-sarif-results)))
            (if (zerop total)
                (message "No results found.")
              (let* ((org-data (codeql--sarif-results-to-org results 0 page-size))
                     (marker (file-name-nondirectory query-path)))
                (if (<= total page-size)
                    (let ((rendered (codeql--org-render-sarif-results
                                     org-data query-buffer footer marker)))
                      ;; save off the fully rendered version for speedy re-loads
                      (with-temp-file (format "%s.org" bqrs-path)
                        (insert rendered)))
                  (codeql--org-render-raw-query-results
                   org-data query-buffer footer marker
                   (list :kind 'sarif
                         :results results
                         :page 0
                         :page-size page-size
                         :total-rows total
                         :footer footer))
                  ;; paginated results are re-rendered from the bqrs on reload
                  (when (file-exists-p (format "%s.org" bqrs-path))
                    (delete-file (format "%s.org" bqrs-path)))))))))
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
                     (file-name-nondirectory query-path)
                     state)))
              ;; results that can be paged, sorted or switched to other result
              ;; sets are re-rendered from the bqrs on reload so that they
              ;; remain interactive, only cache plain single page results
              (if (or (plist-get state :offsets) (> (length result-sets) 1))
                  (when (file-exists-p (format "%s.org" bqrs-path))
                    (delete-file (format "%s.org" bqrs-path)))
                (with-temp-file (format "%s.org" bqrs-path)
                  (insert rendered)))))))))))

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
        (remhash codeql--query-server-jsonrpc-current-id
                 (jsonrpc--request-continuations codeql--query-server-jsonrpc-current-connection))
        (remhash (list codeql--query-server-jsonrpc-current-deferred (current-buffer))
                 (jsonrpc--deferred-actions codeql--query-server-jsonrpc-current-connection))
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
                                         src-buffer)
  "Request a query evaluation from the query server."
  (with-current-buffer buffer-context
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
        (cl-multiple-value-bind (id timer)
            (codeql--jsonrpc-async-request
             (codeql--query-server-current-or-error)
             :evaluation/runQueries run-query-params
             :timeout codeql-query-server-timeout
             :success-fn
             (let ((buffer-context buffer-context)
                   (query-info query-info)
                   (bqrs-path bqrs-path)
                   (query-path query-path)
                   (db-path db-path)
                   (quick-eval quick-eval)
                   (src-filename src-filename)
                   (src-root codeql--database-source-archive-root))
               (jsonrpc-lambda
                   (&rest _)
                 (with-current-buffer buffer-context
                   (codeql--query-server-jsonrpc-unregister-request))
                 (message "Query run completed, checking results.")
                 ;; if size is > 0 then we have results to deal with
                 (let ((bqrs-size (file-attribute-size (file-attributes bqrs-path))))
                   (if (> bqrs-size 0)
                       (progn
                         (with-current-buffer buffer-context
                           ;; save in query history,  name/kind/id can be nil!
                           (let ((name (json-pointer-get query-info "/name"))
                                 (kind (json-pointer-get query-info "/kind"))
                                 (id (json-pointer-get query-info "/id")))
                             (let ((timestamp (current-time-string)))
                               ;; skip templated queries in query history
                               (unless (codeql--templated-query-p query-path)
                                 (puthash
                                  (format "[%s] %s (%s) [%s]"
                                          timestamp
                                          (file-name-nondirectory query-path)
                                          (if quick-eval "quick-eval" "full-query")
                                          (codeql-query-server-active-database))
                                  `(;; align
                                    :quick-eval ,quick-eval
                                    :query-path ,query-path
                                    :bqrs-path ,bqrs-path
                                    :db-path ,db-path
                                    :timestamp ,timestamp
                                    :name ,name
                                    :kind ,kind
                                    :id ,id)
                                  codeql--completed-query-history)))
                             ;; display results
                             (codeql-load-bqrs
                              bqrs-path
                              query-path
                              db-path
                              name
                              kind
                              id
                              buffer-context
                              src-filename
                              codeql--database-source-archive-root
                              src-buffer))))
                     (message "No query results in %s!" bqrs-path)))))
             :error-fn
             (let ((buffer-context buffer-context))
               (jsonrpc-lambda (&key code message data &allow-other-keys)
                 (with-current-buffer buffer-context
                   (codeql--query-server-jsonrpc-unregister-request))
                 (message "Error %s: %s\n%s\n" code message data)))
             :deferred :evaluation/runQueries)
          (codeql--query-server-jsonrpc-register-request
           id (codeql--query-server-current-or-error)
           :evaluation/runQueries))))

     ;; query-server2
     ((string= codeql-query-server "query-server2")
      (let* ((query-target
              (if quick-eval
                  ;; set a quick eval position if need be, otherwise run the entire query
                  (cl-destructuring-bind (min . max) (car (region-bounds))
                    ;; positions in CodeQL are 1-based
                    (let ((start-line (line-number-at-pos min))
                          (end-line (line-number-at-pos max))
                          (start-col (save-excursion (goto-char min) (codeql--lsp-abiding-column)))
                          (end-col (save-excursion (goto-char max) (codeql--lsp-abiding-column))))
                      `(:quickEval
                        (:quickEvalPos
                         (;; align
                          :fileName ,(codeql--tramp-unwrap query-path)
                          :line ,start-line
                          :column ,start-col
                          :endLine ,end-line
                          :endColumn ,end-col)))))
                ;; any non-null value will trigger a full query run
                `(:query (:xx ""))))
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
                 ;;:logPath: string
                 :target ,query-target)
                :progressId ,(codeql--query-server-next-progress-id))))
        (message "Running query ...")
        (cl-multiple-value-bind (id timer)
            (codeql--jsonrpc-async-request
             (codeql--query-server-current-or-error)
             :evaluation/runQuery run-query-params
             :timeout codeql-query-server-timeout
             :success-fn
             (let ((buffer-context buffer-context)
                   (query-info query-info)
                   (bqrs-path bqrs-path)
                   (query-path query-path)
                   (db-path db-path)
                   (quick-eval quick-eval)
                   (src-filename src-filename)
                   (src-root codeql--database-source-archive-root))
               (jsonrpc-lambda
                   (&rest params)
                 (with-current-buffer buffer-context
                   (codeql--query-server-jsonrpc-unregister-request))
                 (let ((errors (codeql--query-server2-handle-message params)))
                   (when errors
                     (error errors)))
                 (message "Query run completed, checking results.")
                 ;; if size is > 0 then we have results to deal with
                 (let ((bqrs-size (file-attribute-size (file-attributes bqrs-path))))
                   (if (> bqrs-size 0)
                       (progn
                         (with-current-buffer buffer-context
                           ;; save in query history,  name/kind/id can be nil!
                           (let ((name (json-pointer-get query-info "/name"))
                                 (kind (json-pointer-get query-info "/kind"))
                                 (id (json-pointer-get query-info "/id")))
                             (let ((timestamp (current-time-string)))
                               ;; skip templated queries in query history
                               (unless (codeql--templated-query-p query-path)
                                 (puthash
                                  (format "[%s] %s (%s) [%s]"
                                          timestamp
                                          (file-name-nondirectory query-path)
                                          (if quick-eval "quick-eval" "full-query")
                                          (codeql-query-server-active-database))
                                  `(;; align
                                    :quick-eval ,quick-eval
                                    :query-path ,query-path
                                    :bqrs-path ,bqrs-path
                                    :db-path ,db-path
                                    :timestamp ,timestamp
                                    :name ,name
                                    :kind ,kind
                                    :id ,id)
                                  codeql--completed-query-history)))
                             ;; display results
                             (codeql-load-bqrs
                              bqrs-path
                              query-path
                              db-path
                              name
                              kind
                              id
                              buffer-context
                              src-filename
                              codeql--database-source-archive-root
                              src-buffer))))
                     (message "No query results in %s!" bqrs-path)))))
             :error-fn
             (let ((buffer-context buffer-context))
               (jsonrpc-lambda (&key code message data &allow-other-keys)
                 (with-current-buffer buffer-context
                   (codeql--query-server-jsonrpc-unregister-request))
                 (message "Error %s: %s\n%s\n" code message data)))
             :deferred :evaluation/runQuery)
          (codeql--query-server-jsonrpc-register-request
           id (codeql--query-server-current-or-error)
           :evaluation/runQuery)))))))

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
                                                     src-buffer)
  "Request query compilation from the query server."
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (with-current-buffer buffer-context
    (let*
        ((query-target
          (if quick-eval
              ;; set a quick eval position if need be, otherwise run the entire query
              (cl-destructuring-bind (min . max) (car (region-bounds))
                ;; positions in CodeQL are 1-based
                (let ((start-line (line-number-at-pos min))
                      (end-line (line-number-at-pos max))
                      (start-col (save-excursion (goto-char min) (codeql--lsp-abiding-column)))
                      (end-col (save-excursion (goto-char max) (codeql--lsp-abiding-column))))
                  `(:quickEval
                    (:quickEvalPos
                     (;; align
                      :fileName ,(codeql--tramp-unwrap query-path)
                      :line ,start-line
                      :column ,start-col
                      :endLine ,end-line
                      :endColumn ,end-col)))))
            ;; any non-null value will trigger a full query run
            `(:query (:xx ""))))
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
        (message "Compiling query (%s) ..." (if quick-eval "quick-eval" "full-query"))
        (cl-multiple-value-bind (id timer)
            (codeql--jsonrpc-async-request
             (codeql--query-server-current-or-error)
             :compilation/compileQuery compile-query-params
             :timeout codeql-query-server-timeout
             :success-fn
             (let ((buffer-context buffer-context)
                   (bqrs-path bqrs-path)
                   (qlo-path qlo-path)
                   (query-path query-path)
                   (query-info query-info)
                   (library-path library-path)
                   (db-path db-path)
                   (quick-eval quick-eval)
                   (template-values template-values)
                   (src-filename src-filename))
               (jsonrpc-lambda
                (&key messages &allow-other-keys)
                (with-current-buffer buffer-context
                  (codeql--query-server-jsonrpc-unregister-request))
                (message "Compilation completed, checking results.")
                (let ((abort-run-query nil))
                  (seq-map
                   (lambda (m)
                     (cl-destructuring-bind
                         (&key severity message &allow-other-keys) m
                       (message "[compilation/compileQuery] severity %s: %s" severity message)
                       (when (eql severity 0)
                         (message "[compilation/compileQuery] Aborting query! severity 0: %s" message)
                         (setq abort-run-query t))))
                   messages)
                  (unless abort-run-query
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
                     src-buffer)))))
             :error-fn
             (let ((buffer-context buffer-context))
               (jsonrpc-lambda
                (&key code message data &allow-other-keys)
                (with-current-buffer buffer-context
                  (codeql--query-server-jsonrpc-unregister-request))
                (message "Error %s: %s\n%s\n" code message data)))
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
         src-buffer))))))

(defun codeql--query-server-run-query-from-path (query-path
                                                 quick-eval
                                                 &optional
                                                 template-values
                                                 src-filename
                                                 src-buffer)
  "Run the query at QUERY-PATH."
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
         (query-info (codeql--query-info query-path)))
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
     src-buffer)))

(defun codeql-query-server-run-query ()
  "Run a query or quick eval a query region."
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  ;; init the query history if need be
  (unless codeql--completed-query-history
    (setq codeql--completed-query-history (make-hash-table :test #'equal)))
  (if codeql--query-server
      (let* ((query-path (buffer-file-name))
             (quick-eval (if (use-region-p) t nil)))
        ;; make sure we save the query before running it
        (when (or codeql--run-query-always-save
                  (and (buffer-modified-p)
                       (y-or-n-p "Query was not saved prior to evaluation, save now?")))
          (save-buffer))
        (codeql--query-server-run-query-from-path query-path quick-eval))
    (message "No query server started.")))

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
                 id &allow-other-keys)
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
                   (current-buffer))))))))
    ;; XXX: do we want to serialize query history state to disk?
    (message "No query history available yet in this session.")))

(defun codeql-database-history ()
  "Offer global database history selection to the user."
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (if (and codeql--registered-database-history
           (not (eql 0 (hash-table-count codeql--registered-database-history))))
      (let* ((db-keys (vconcat (hash-table-keys codeql--registered-database-history)))
             (db (completing-read
                  "Recent Databases: "
                  ;; show remote files only for active remote context
                  ;; show local files in global local context
                  (reverse
                   (append
                    (cl-loop
                     ;; file-remote-p returns the tramp prefix of a remote file or nil
                     with remote-prefix = (file-remote-p default-directory)
                     for k across db-keys
                     ;; deal with both strings and symbols
                     when (equal (file-remote-p k) remote-prefix)
                     collect k)
                    nil))
                  nil t)))
        (when db
          (let ((database-path (gethash db codeql--registered-database-history)))
            (codeql-query-server-register-database database-path))))
    (message "No database history available across any sessions.")))

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

(transient-define-suffix codeql-transient-query-server-start ()
  "Start a CodeQL query server."
  :description "start"
  :transient nil
  (interactive)
  (cl-assert (eq major-mode 'ql-tree-sitter-mode) t)
  (if codeql--query-server
      (message "There is already a query server running")
    (let* ((ram-options (codeql--query-server-resolve-ram codeql--query-server-max-ram))
           (args (append
                  (transient-args transient-current-command)
                  ram-options
                  ;; non-user arguments go here
                  (cond
                   ;; old query-server options
                   ((string= codeql-query-server "query-server")
                    '("--require-db-registration"))
                   ;; new query-server options
                   ((string= codeql-query-server "query-server2")
                    nil)))))
      (cl-assert ram-options t)
      ;; spawn the server process
      (let* ((name (format "CODEQL Query Server (%s%s -> %s)"
                           ;; add remote prefix if its there to dedicate event buffer
                           (or (file-remote-p default-directory) "")
                           ;; show query file name for this server if available
                           (file-name-base (directory-file-name default-directory))
                           (or (file-name-nondirectory (buffer-file-name)) "(no file name)")))
             (cmd (append
                   codeql--cli-buffer-local
                   (list "execute"
                         ;; determine which query server to use
                         ;; prefer query-server2 when available
                         ;; don't confuse this with codeql--query-server, which is the rpc connection
                         (or codeql-query-server
                             (setq codeql-query-server
                                   (codeql--resolve-query-server))))
                   args)))
        (message "Starting query server.")
        ;; manage these buffer local
        (setq codeql--query-server
              (make-instance
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
               :events-buffer-scrollback-size codeql-query-server-events-buffer-size
               :notification-dispatcher #'codeql--query-server-handle-notification
               :request-dispatcher #'codeql--query-server-handle-request
               :on-shutdown
               (let ((buffer-context (current-buffer)))
                 (lambda (obj)
                   (codeql--query-server-on-shutdown obj buffer-context)))))
        ;; created up front so that buffers sharing this server share it too
        (unless codeql--completed-query-history
          (setq codeql--completed-query-history (make-hash-table :test #'equal)))
        (codeql--query-server-share)
        (message "Started query server.")))))

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
           ("i" "inherit" codeql-query-server-inherit)]
          ["Database"
           ("d" codeql-query-server-register-database
            :description
            (lambda ()
              (codeql-query-server-active-database)))
           ("f" "file" codeql-database-open-source-archive-file)
           ("k" "known" codeql-database-history)]
          ["Query"
           ("r" "run" codeql-query-server-run-query)
           ("h" "history" codeql-query-history)
           ("c" "cancel" codeql-query-server-cancel-query)]
          ["Config"
           ("p" codeql-set-max-paths
            :description
            (lambda ()
              (format "--max-paths=%s"
                      codeql--path-problem-max-paths)))]]
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
