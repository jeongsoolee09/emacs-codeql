;;; emacs-codeql-xray-test.el --- Tests of the x-ray of a query -*- lexical-binding: t; -*-

;;; Commentary:

;; The x-ray of a query, its DIL and RA beside it, ported from the one of
;; codeql.nvim with the same fixtures.  Run with
;;
;;   emacs -Q --batch -L . -l test/emacs-codeql-xray-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'emacs-codeql)

(defconst codeql-xray-test--source
  '("/** A query. */"                                                                     ; 0
    "import javascript"                                                                   ; 1
    ""                                                                                    ; 2
    "module Inner {"                                                                      ; 3
    "  pragma[noinline]"                                                                  ; 4
    "  predicate big(File f, int n) { n = f.getNumberOfLines() and f.getBaseName() = \"{\" }" ; 5
    ""                                                                                    ; 6
    "  class Big extends File {"                                                          ; 7
    "    int n;"                                                                          ; 8
    "    Big() { big(this, n) }"                                                          ; 9
    "    // a member { with a brace"                                                      ; 10
    "    int lines() {"                                                                   ; 11
    "      result = n"                                                                    ; 12
    "    }"                                                                               ; 13
    "  }"                                                                                 ; 14
    "}"                                                                                   ; 15
    ""                                                                                    ; 16
    "newtype TKind = TA() or TB(int i) { i = [1 .. 2] }"                                  ; 17
    ""                                                                                    ; 18
    "query predicate files(Inner::Big b, int n) { n = b.lines() }"                        ; 19
    ""                                                                                    ; 20
    "int unused(int x, Map<int, int>::T y) { x = 1 and result = 2 }"                      ; 21
    ""                                                                                    ; 22
    "from Inner::Big b"                                                                   ; 23
    "where b.lines() > 100"                                                               ; 24
    "select b, b.lines()"                                                                 ; 25
    ""                                                                                    ; 26
    "predicate after() { any() }")                                                        ; 27
  "Deep.ql.")

(defconst codeql-xray-test--dil
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
    "}"))

(defconst codeql-xray-test--ra
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
    "    return r1"))

(defconst codeql-xray-test--inst
  '("import javascript"
    "module Flow = TaintTracking::Global<Config>;"
    "module Graph = PathGraph<Flow::PathNode,"
    "  Flow::PathGraph>;"
    "from Flow::PathNode n"
    "select n")
  "Inst.ql, instantiating parameterized modules.")

(defconst codeql-xray-test--inst-dil
  (let ((g "TaintTracking::Global<Lib::Config>::Flow"))
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
          "{ `TaintTracking::Global<Lib::Other>::Flow::p/0#4`() }")))

(defconst codeql-xray-test--route
  '("import javascript"                                                     ; 0
    "predicate isRoute(File f) { f.getBaseName() = \"r.js\" }"              ; 1
    "class Input extends DataFlow::Node {"                                  ; 2
    "  Input() { isRoute(this.getFile()) }"                                 ; 3
    "  string kind() { result = super.getSourceType() }"                    ; 4
    "}"                                                                     ; 5
    "from Input i"                                                          ; 6
    "select i, i.kind()")                                                   ; 7
  "Route.ql, a class inlined into the select.")

(defconst codeql-xray-test--route-dil
  '("`Route::isRoute/1#aa`(/* Files::File */ interned unique entity f)"
    "{ `Files::File.getBaseName/0#dispred#bb`(f, \"r.js\") }"
    ""
    "#select(/* Route::Input */ DataFlowNode#4b input, string kind)"
    "{"
    "  `Route::isRoute/1#aa`(`AST::AstNode.getFile/0#dispred#cc`(input)) and"
    "  `DataFlow::Node.getSourceType/0#dd`(input, kind) and"
    "  `Lib::Input.kind/0#ee`(input, _)"
    "}"))

(defconst codeql-xray-test--route-ra
  '("EVALUATE NONRECURSIVE RELATION:"
    "  `Route::isRoute/1#aa`(int f) :- "
    "    {1} r1 = SCAN `Files::File.getBaseName/0#dispred#bb` OUTPUT In.0"
    "    return r1"
    ""
    "EVALUATE NONRECURSIVE RELATION:"
    "  #select(numbered_tuple input, string kind) :- "
    "    {1} r1 = JOIN `Route::isRoute/1#aa` WITH `AST::AstNode.getFile/0#dispred#cc` ON In.0 OUTPUT Rhs.0 'input'"
    "    {2} r2 = JOIN r1 WITH `DataFlow::Node.getSourceType/0#dd` ON In.0 OUTPUT In.0 'input', Rhs.1 'kind'"
    "    return r2"))

;;; Helpers

(defun codeql-xray-test--summary (defs)
  "Return DEFS as strings of their kind, keys and rows."
  (mapcar (lambda (def)
            (format "%s %s %d-%d" (codeql--xray-def-kind def)
                    (string-join (codeql--xray-def-keys def) ",")
                    (codeql--xray-def-srow def) (codeql--xray-def-erow def)))
          defs))

(defun codeql-xray-test--def (defs name)
  "Return the definition of DEFS named NAME."
  (seq-find (lambda (def) (equal (codeql--xray-def-name def) name)) defs))

(defun codeql-xray-test--overlays (buffer category)
  "Return the overlays of CATEGORY of BUFFER, in order."
  (with-current-buffer buffer
    (sort (seq-filter (lambda (o) (eq (overlay-get o 'codeql-xray) category))
                      (overlays-in (point-min) (point-max)))
          (lambda (a b) (or (< (overlay-start a) (overlay-start b))
                            (and (= (overlay-start a) (overlay-start b))
                                 (< (overlay-end a) (overlay-end b))))))))

(defun codeql-xray-test--line-mark-p (o)
  "Return non-nil if the overlay O covers whole lines."
  (with-current-buffer (overlay-buffer o)
    (save-excursion
      (and (overlay-get o 'face)
           (progn (goto-char (overlay-start o)) (bolp))
           (progn (goto-char (overlay-end o)) (or (bolp) (eobp)))
           (or (> (count-lines (overlay-start o) (overlay-end o)) 1)
               (= (- (overlay-end o) (overlay-start o))
                  (save-excursion (goto-char (overlay-start o))
                                  (- (line-beginning-position 2) (point))))
               (eobp))))))

(defun codeql-xray-test--marks (buffer category)
  "Return the line marks of CATEGORY of BUFFER as \"FIRST-LAST FACE\", and its notes."
  (with-current-buffer buffer
    (delq nil
          (mapcar (lambda (o)
                    (cond
                     ((overlay-get o 'codeql-xray-text)
                      (format "%d %s" (codeql--xray-row-at (overlay-start o))
                              (overlay-get o 'codeql-xray-text)))
                     ((codeql-xray-test--line-mark-p o)
                      (let ((end (overlay-end o)))
                        (format "%d-%d %s" (codeql--xray-row-at (overlay-start o))
                                (- (codeql--xray-row-at end)
                                   (if (save-excursion (goto-char end) (and (bolp) (> end (overlay-start o))))
                                       1 0))
                                (overlay-get o 'face))))))
                  (codeql-xray-test--overlays buffer category)))))

(defun codeql-xray-test--spans (buffer category)
  "Return the marks of CATEGORY of BUFFER within a line, as \"ROW TEXT FACE\"."
  (with-current-buffer buffer
    (delq nil
          (mapcar (lambda (o)
                    (when (and (overlay-get o 'face)
                               (not (codeql-xray-test--line-mark-p o)))
                      (format "%d %s %s" (codeql--xray-row-at (overlay-start o))
                              (buffer-substring-no-properties (overlay-start o) (overlay-end o))
                              (overlay-get o 'face))))
                  (codeql-xray-test--overlays buffer category)))))

(defun codeql-xray-test--lines (buffer)
  "Return the lines of BUFFER."
  (with-current-buffer buffer
    (split-string (buffer-string) "\n")))

(defun codeql-xray-test--goto (window row &optional col)
  "Select WINDOW and go to the 0-based ROW and COL of its buffer, as if moved there."
  (select-window window)
  (goto-char (codeql--xray-pos row))
  (forward-char (or col 0))
  (if codeql--xray-this-view (codeql--xray-view-moved) (codeql--xray-source-moved)))

(defun codeql-xray-test--window (view)
  "Return the window of VIEW."
  (get-buffer-window (codeql--xray-view-buffer view)))

(defmacro codeql-xray-test--with (spec &rest body)
  "Run BODY with an x-ray of a query, its views in windows left to right.

SPEC is (STATE SRC KINDS &optional NAME LINES DUMPS): bind STATE and SRC
to the x-ray and the buffer of the query NAME, Deep by default, with the
LINES and the plist DUMPS of :DIL and :RA, and a view of each of KINDS."
  (declare (indent 1))
  (let ((dir (make-symbol "dir")))
    (pcase-let ((`(,state ,src ,kinds ,name ,lines ,dumps) spec))
      `(let* ((,dir (make-temp-file "codeql-xray" t))
              (file (expand-file-name (concat (or ,name "Deep") ".ql") ,dir))
              ,src ,state)
         (with-temp-file file
           (insert (string-join (or ,lines codeql-xray-test--source) "\n")))
         (setq ,src (find-file-noselect file))
         (unwind-protect
             (save-window-excursion
               (delete-other-windows)
               (switch-to-buffer ,src)
               (setq ,state (codeql--xray-attach ,src ,kinds))
               (let ((window (selected-window)))
                 (dolist (view (codeql--xr-views ,state))
                   (setq window (split-window window nil 'right))
                   (set-window-buffer window (codeql--xray-view-buffer view))))
               (codeql--xray-show
                ,state
                (list :success t
                      :DIL (or (plist-get ,dumps :DIL) codeql-xray-test--dil)
                      :RA (or (plist-get ,dumps :RA) codeql-xray-test--ra)
                      :messages '((:severity "WARNING" :message "unused predicate 'unused'"))))
               ,@body)
           (when (buffer-live-p ,src)
             (with-current-buffer ,src (set-buffer-modified-p nil))
             (kill-buffer ,src))
           (delete-directory ,dir t))))))

;;; The pure core

(ert-deftest codeql-xray-test-outline ()
  "Find the definitions of a query and the keys of their relations."
  (should (equal (codeql-xray-test--summary (codeql--xray-outline codeql-xray-test--source))
                 '("predicate Inner::big/2 4-5"
                   "class Inner::Big 7-14"
                   "predicate Inner::Big.lines/0 11-13"
                   "newtype TKind,TA,TB 17-17"
                   "predicate files/2,query:files 19-19"
                   "predicate unused/2 21-21"
                   "select #select 23-25"
                   "predicate after/0 27-27"))))

(ert-deftest codeql-xray-test-def-at ()
  "Pick the innermost definition at a row."
  (let ((defs (codeql--xray-outline codeql-xray-test--source)))
    ;; the characteristic predicate is part of its class
    (should (equal "class" (codeql--xray-def-kind (codeql--xray-def-at defs 9))))
    (should (equal "class" (codeql--xray-def-kind (codeql--xray-def-at defs 8))))
    (should (equal "Inner::Big.lines/0" (car (codeql--xray-def-keys (codeql--xray-def-at defs 12)))))
    (should-not (codeql--xray-def-at defs 16))))

(ert-deftest codeql-xray-test-keys ()
  "Name the definitions of the query module, and leave the library alone."
  (should (equal "Inner::big/2" (codeql--xray-key "`Deep::Inner::big/2#0154355b`" "Deep")))
  (should (equal "C.p/1" (codeql--xray-key "`#Deep::C.p/1#dispred#1234Merge`" "Deep")))
  (should (equal "p/0" (codeql--xray-key "project#Deep#ab12cd::p/0#ff" "Deep")))
  (should (equal "M::C" (codeql--xray-key "Deep::M<int, Other::X<Y>>::C#99" "Deep")))
  (should (equal "#select" (codeql--xray-key "#select#query" "Deep")))
  (should (equal "query:edges" (codeql--xray-key "edges#query" "Deep")))
  (should-not (codeql--xray-key "`Files::Container.getRelativePath/0#dispred#6933ed0f`" "Deep"))
  (should-not (codeql--xray-key "`DeepLib::p/0#12`" "Deep"))
  (should-not (codeql--xray-key "`NotDeep::p/0#12`" "Deep"))
  ;; a library module named like the query
  (should-not (codeql--xray-key "`DeepQuery::Deep::isSink/1#55`" "Deep")))

(ert-deftest codeql-xray-test-blocks ()
  "Split DIL into its definitions, and RA into the steps of the plan."
  (let ((blocks (codeql--xray-blocks codeql-xray-test--dil "DIL")))
    (should (equal '(1 7 15) (mapcar #'codeql--xray-block-first blocks)))
    (should (equal '(("Lib::helper/1#11") ("Deep::Inner::big/2#0154355b") ("#select"))
                   (mapcar #'codeql--xray-block-names blocks))))
  (let ((blocks (codeql--xray-blocks codeql-xray-test--ra "RA")))
    (should (equal '((1 1) (2 5) (7 15) (17 20))
                   (mapcar (lambda (b) (list (codeql--xray-block-first b) (codeql--xray-block-last b)))
                           blocks)))
    ;; all relations of a layer
    (should (equal '("Deep::Inner::Big.lines/0#dispred#77" "Other::q/1#22")
                   (codeql--xray-block-names (nth 2 blocks))))
    (should-not (codeql--xray-block-names (nth 0 blocks)))))

(ert-deftest codeql-xray-test-users ()
  "Find the definitions using each definition by name."
  (let* ((defs (codeql--xray-outline codeql-xray-test--source))
         (users (codeql--xray-users codeql-xray-test--source defs)))
    (cl-flet ((names (name)
                (mapcar #'codeql--xray-def-name
                        (gethash (codeql-xray-test--def defs name) users))))
      ;; the class itself, with its characteristic predicate, doesn't count
      (should (equal '("Big") (names "big")))
      (should (equal '("files" "select") (names "Big")))
      (should (equal '("files" "select") (names "lines")))
      (should-not (names "unused")))))

(ert-deftest codeql-xray-test-diff ()
  "Tell the blocks new or changed since the last compile, and how many are gone."
  (let* ((old '("`M::p/0#aa11`()" "{ x = 1 }" "" "`M::q/0#bb22`()" "{ `M::p/0#aa11`() }" ""
                "`M::r/0#cc`()" "{ }"))
         (new '("`M::p/0#dd33`()" "{ x = 2 }" "" "`M::q/0#ee44`()" "{ `M::p/0#dd33`() }" ""
                "`M::s/0#ff`()" "{ }"))
         (old-blocks (codeql--xray-blocks old "DIL"))
         (blocks (codeql--xray-blocks new "DIL")))
    (should (= 1 (codeql--xray-diff old old-blocks new blocks)))
    (should (equal '("changed" "new")
                   (list (codeql--xray-block-diff (nth 0 blocks)) (codeql--xray-block-diff (nth 2 blocks)))))
    ;; only the hashes differ
    (should-not (codeql--xray-block-diff (nth 1 blocks)))))

(ert-deftest codeql-xray-test-map ()
  "Map the blocks of the query module to its definitions."
  (let* ((defs (codeql--xray-outline codeql-xray-test--source))
         (mapped (codeql--xray-map (codeql--xray-blocks codeql-xray-test--ra "RA") "Deep" defs)))
    (should (equal '("Inner::Big.lines/0" "#select")
                   (mapcar (lambda (m) (car (codeql--xray-def-keys (cdr m)))) mapped)))
    ;; a class compiles to one relation with its characteristic predicate
    (let ((class (codeql--xray-map
                  (list (codeql--xray-block-make :first 1 :last 1 :names '("Deep::Inner::Big#33")))
                  "Deep" defs)))
      (should (equal "class" (codeql--xray-def-kind (cdar class)))))))

(ert-deftest codeql-xray-test-instances ()
  "Map the relations of the modules a query instantiates to their aliases."
  (let ((defs (codeql--xray-outline codeql-xray-test--inst)))
    (should (equal '("instance Flow 1-1" "instance Graph 2-3" "select select 4-5")
                   (mapcar (lambda (d) (format "%s %s %d-%d" (codeql--xray-def-kind d) (codeql--xray-def-name d)
                                               (codeql--xray-def-srow d) (codeql--xray-def-erow d)))
                           defs)))
    (should (equal '("Global<Config>" "PathGraph<PathNode,PathGraph>")
                   (mapcar #'codeql--xray-def-shape (seq-take defs 2))))
    (should (equal "Global<Opt<int>>" (codeql--xray-shape "M::Global<Lib::Opt<int>>")))
    ;; named after the instantiated module, through the ones it
    ;; instantiates, but for those of other arguments
    (should (equal '("Flow" "Graph" "Flow" "select")
                   (mapcar (lambda (m) (codeql--xray-def-name (cdr m)))
                           (codeql--xray-map (codeql--xray-blocks codeql-xray-test--inst-dil "DIL")
                                             "Inst" defs))))))

;;; A single view

(ert-deftest codeql-xray-test-shows-the-query-code ()
  "Show only the code of the query, colored like its definitions."
  (codeql-xray-test--with (state src '("DIL"))
    (let ((buffer (codeql--xray-view-buffer (car (codeql--xr-views state)))))
      (should (equal (codeql-xray-test--lines buffer)
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
      (should (equal '("0-6 codeql-xray-1" "8-11 codeql-xray-4")
                     (codeql-xray-test--marks buffer 'paint)))
      ;; Big has no DIL of its own, but its characteristic predicate went
      ;; into the select, calling big
      (should (equal '("10 `Deep::Inner::big/2#0154355b` codeql-xray-2")
                     (codeql-xray-test--spans buffer 'paint)))
      (let ((marks (append (codeql-xray-test--marks src 'paint) (codeql-xray-test--marks src 'note))))
        ;; big has DIL, lines has only RA, and all keep their colors in either
        (dolist (mark '("4-5 codeql-xray-1" "7-14 codeql-xray-2" "11-13 codeql-xray-3" "23-25 codeql-xray-4"
                        ;; lines is used by files, without DIL, and the select clause
                        "11 no DIL: inlined into select"
                        "21 no DIL: unused"
                        "27 no DIL: inlined"
                        ;; a class has code when an inner definition has
                        "7 no DIL: inlined into select"))
          (should (member mark marks))))
      ;; with a single view, TAB shows the other dump in it
      (codeql-xray-test--goto (codeql-xray-test--window (car (codeql--xr-views state))) 0)
      (call-interactively #'codeql-xray-other)
      (should (equal "RA" (codeql--xray-view-kind (car (codeql--xr-views state)))))
      (should (equal "EVALUATE RECURSIVE LAYER:" (car (codeql-xray-test--lines buffer))))
      (should-not (member "7 no RA: inlined into select" (codeql-xray-test--marks src 'note))))))

(ert-deftest codeql-xray-test-activates-both-ways ()
  "Highlight the code of the definition at point, and the other way around."
  (codeql-xray-test--with (state src '("DIL"))
    (let* ((view (car (codeql--xr-views state)))
           (buffer (codeql--xray-view-buffer view)))
      (codeql-xray-test--goto (get-buffer-window src) 24)
      (should (equal '("8-11 codeql-xray-active-face") (codeql-xray-test--marks buffer 'active)))
      (should (equal '("23-25 codeql-xray-active-face") (codeql-xray-test--marks src 'active)))
      (codeql-xray-test--goto (codeql-xray-test--window view) 1)
      (should (equal '("4-5 codeql-xray-active-face") (codeql-xray-test--marks src 'active)))
      (call-interactively #'codeql-xray-goto-source)
      (should (eq src (current-buffer)))
      (should (= 4 (codeql--xray-row))))))

(ert-deftest codeql-xray-test-follows-edits ()
  "Follow the definitions as the query is edited, dropping renamed ones."
  (codeql-xray-test--with (state src '("DIL"))
    (let ((buffer (codeql--xray-view-buffer (car (codeql--xr-views state)))))
      (with-current-buffer src
        (goto-char (point-min))
        (insert "\n\n"))
      (codeql--xray-refresh state)
      (should (member "6-7 codeql-xray-1" (codeql-xray-test--marks src 'paint)))
      (should (member "`Deep::Inner::big/2#0154355b`(" (codeql-xray-test--lines buffer)))
      (with-current-buffer src
        (goto-char (point-min))
        (search-forward "big(File")
        (replace-match "bigger(File"))
      (codeql--xray-refresh state)
      (should-not (member "`Deep::Inner::big/2#0154355b`(" (codeql-xray-test--lines buffer))))))

(ert-deftest codeql-xray-test-error ()
  "Show why the query doesn't compile."
  (codeql-xray-test--with (state _src '("DIL"))
    (codeql--xray-show state '(:success nil
                               :messages ((:severity "ERROR" :message "could not resolve type Bigg"
                                           :position (:line 24 :column 6)))))
    (should (equal '("-- Deep.ql doesn't compile" "error:24:6: could not resolve type Bigg")
                   (codeql-xray-test--lines (codeql--xray-view-buffer (car (codeql--xr-views state))))))))

(ert-deftest codeql-xray-test-colors ()
  "Color each definition differently, and its code in the dumps the same."
  (let (lines dil)
    (dotimes (i 8)
      (push (format "predicate p%d() { any() }" (1+ i)) lines)
      (setq dil (append dil (list (format "`Many::p%d/0#%d`()" (1+ i) (1+ i)) "{ }" ""))))
    (codeql-xray-test--with (state src '("DIL") "Many" (nreverse lines) (list :DIL dil :RA '("")))
      (let ((ql (mapcar (lambda (o) (overlay-get o 'face)) (codeql-xray-test--overlays src 'paint)))
            (code (mapcar (lambda (o) (overlay-get o 'face))
                          (codeql-xray-test--overlays (codeql--xray-view-buffer (car (codeql--xr-views state)))
                                                      'paint))))
        (should (= 8 (length ql)))
        (should (equal ql code))
        (let ((backgrounds (mapcar (lambda (face) (face-attribute face :background nil t)) ql)))
          (should-not (memq 'unspecified backgrounds))
          (should (= 8 (length (delete-dups (copy-sequence backgrounds))))))))))

;;; Columns

(ert-deftest codeql-xray-test-columns-notes ()
  "Tell which dumps a definition has no code in."
  (codeql-xray-test--with (_state src '("DIL" "RA"))
    (let ((notes (codeql-xray-test--marks src 'note)))
      (should (member "11 no DIL: inlined into select" notes))
      (should (member "21 no DIL or RA: unused" notes))
      ;; the class has RA through lines, but no DIL
      (should (member "7 no DIL: inlined into select" notes))
      ;; big is inlined into the characteristic predicate of Big
      (should (member "4 no RA: inlined into Big" notes)))))

(ert-deftest codeql-xray-test-columns-activate ()
  "Highlight the definition at point in the query and both dumps."
  (codeql-xray-test--with (state src '("DIL" "RA"))
    (pcase-let ((`(,dil ,ra) (mapcar #'codeql--xray-view-buffer (codeql--xr-views state))))
      (codeql-xray-test--goto (get-buffer-window src) 24)
      (should (equal '("8-11 codeql-xray-active-face") (codeql-xray-test--marks dil 'active)))
      (should (equal '("10-13 codeql-xray-active-face") (codeql-xray-test--marks ra 'active)))
      (codeql-xray-test--goto (get-buffer-window dil) 1)
      (should (equal '("4-5 codeql-xray-active-face") (codeql-xray-test--marks src 'active)))
      ;; big is inlined into the RA of lines, which scans it
      (should (equal '("3 `Deep::Inner::big/2#0154355b` codeql-xray-active-face")
                     (codeql-xray-test--spans ra 'active)))
      (should (equal '("3 `Deep::Inner::big/2#0154355b` codeql-xray-1")
                     (codeql-xray-test--spans ra 'paint))))))

(ert-deftest codeql-xray-test-columns-scroll ()
  "Scroll the other dumps to the definition at point."
  (codeql-xray-test--with (state src '("DIL" "RA"))
    (let ((window (codeql-xray-test--window (cadr (codeql--xr-views state)))))
      ;; a short RA window, showing its first lines
      (split-window window 5 'below)
      (set-window-start window 1)
      (codeql-xray-test--goto (get-buffer-window src) 24)
      (should (= 10 (with-current-buffer (window-buffer window)
                      (codeql--xray-row-at (window-start window))))))))

(ert-deftest codeql-xray-test-columns-other ()
  "Go to the code of the same definition, and relation, in the other dump."
  (codeql-xray-test--with (state _src '("DIL" "RA"))
    (pcase-let ((`(,dil ,ra) (codeql--xr-views state)))
      (codeql-xray-test--goto (codeql-xray-test--window dil) 9)
      (call-interactively #'codeql-xray-other)
      (should (eq (codeql--xray-view-buffer ra) (current-buffer)))
      (should (= 10 (codeql--xray-row)))
      (should (equal "DIL" (codeql--xray-view-kind dil)))
      (call-interactively #'codeql-xray-other)
      (should (eq (codeql--xray-view-buffer dil) (current-buffer)))
      (should (= 8 (codeql--xray-row)))
      ;; a definition with several relations
      (codeql--xray-show state
                         (list :success t
                               :DIL (append codeql-xray-test--dil
                                            '("" "#select#query(int b)" "{" "  #select(b, _)" "}"))
                               :RA (append codeql-xray-test--ra
                                           '("" "EVALUATE NONRECURSIVE RELATION:" "  #select#query(int b) :- "
                                             "    return r1"))))
      (codeql-xray-test--goto (codeql-xray-test--window dil) 14)
      (call-interactively #'codeql-xray-other)
      (should (equal "  #select#query(int b) :- "
                     (buffer-substring-no-properties (line-beginning-position 2) (line-end-position 2))))
      (call-interactively #'codeql-xray-other)
      (should (equal "#select#query(int b)" (buffer-substring-no-properties (pos-bol) (pos-eol)))))))

(ert-deftest codeql-xray-test-columns-peer ()
  "Mark the block of the relation at point in both dumps, as it moves."
  (codeql-xray-test--with (state _src '("DIL" "RA"))
    (codeql--xray-show state
                       (list :success t
                             :DIL (append codeql-xray-test--dil
                                          '("" "#select#query(int b)" "{" "  #select(b, _)" "}"))
                             :RA (append codeql-xray-test--ra
                                         '("" "EVALUATE NONRECURSIVE RELATION:" "  #select#query(int b) :- "
                                           "    return r1"))))
    (pcase-let ((`(,dil ,ra) (codeql--xr-views state)))
      (cl-flet ((rows (view)
                  (with-current-buffer (codeql--xray-view-buffer view)
                    (mapcar (lambda (o) (codeql--xray-row-at (overlay-start o)))
                            (codeql-xray-test--overlays (current-buffer) 'peer))))
                (block-of (view)
                  (with-current-buffer (codeql--xray-view-buffer view)
                    (let ((o (car (codeql-xray-test--overlays (current-buffer) 'peer))))
                      (save-excursion
                        (goto-char (overlay-start o))
                        (buffer-substring-no-properties (line-beginning-position 2) (line-end-position 2)))))))
        (let ((select (with-current-buffer (codeql--xray-view-buffer dil)
                        (goto-char (point-min))
                        (re-search-forward "^#select(")
                        (codeql--xray-row))))
          (codeql-xray-test--goto (codeql-xray-test--window dil) select)
          (should (= select (car (rows dil))))
          (let ((first (block-of ra)))
            (codeql-xray-test--goto (codeql-xray-test--window dil)
                                    (progn (goto-char (point-min))
                                           (re-search-forward "^#select#query")
                                           (codeql--xray-row)))
            (should (= (codeql--xray-span-first (car (last (codeql--xray-view-spans dil))))
                       (car (rows dil))))
            (should (equal "  #select#query(int b) :- " (block-of ra)))
            (should-not (equal first (block-of ra)))))))))

(ert-deftest codeql-xray-test-columns-diff ()
  "Mark the blocks changed since the last compile."
  (codeql-xray-test--with (state _src '("DIL" "RA"))
    (pcase-let ((`(,dil ,ra) (codeql--xr-views state))
                (changed (copy-sequence codeql-xray-test--ra)))
      (setf (nth 18 changed)
            "    {2} r1 = SCAN `Deep::Inner::Big.lines/0#dispred#78` OUTPUT In.1 'b', In.0 'n'")
      (codeql--xray-show state (list :success t :DIL codeql-xray-test--dil :RA changed))
      (should-not (codeql-xray-test--overlays (codeql--xray-view-buffer dil) 'diff))
      (let ((found (codeql-xray-test--overlays (codeql--xray-view-buffer ra) 'diff)))
        (should (= 1 (length found)))
        (with-current-buffer (codeql--xray-view-buffer ra)
          (goto-char (overlay-start (car found)))
          (should (equal "  #select(int b, int n) :- "
                         (buffer-substring-no-properties (line-beginning-position 2) (line-end-position 2))))
          (should (string-search "1 changed" (codeql--xray-header-line)))))
      ;; compiling the same again changes nothing
      (codeql--xray-show state (list :success t :DIL codeql-xray-test--dil :RA changed))
      (should-not (codeql-xray-test--overlays (codeql--xray-view-buffer ra) 'diff))
      (with-current-buffer (codeql--xray-view-buffer ra)
        (should-not (string-search "changed" (codeql--xray-header-line)))
        (should (string-prefix-p " RA" (codeql--xray-header-line)))))))

(ert-deftest codeql-xray-test-columns-mentions ()
  "Highlight the types naming a class inlined into its users, and scroll to them."
  (codeql-xray-test--with (state src '("DIL" "RA"))
    (let ((with-types (copy-sequence codeql-xray-test--dil))
          (dil (car (codeql--xr-views state))))
      (setf (nth 14 with-types) "#select(/* Deep::Inner::Big */ interned unique entity b, int n)")
      (codeql--xray-show state (list :success t :DIL with-types :RA codeql-xray-test--ra))
      (let ((window (codeql-xray-test--window dil)))
        (split-window window 5 'below)
        (set-window-start window 1)
        (codeql-xray-test--goto (get-buffer-window src) 7)
        ;; and the call of its characteristic predicate, once each
        (should (equal '("8 /* Deep::Inner::Big */ codeql-xray-active-face"
                         "10 `Deep::Inner::big/2#0154355b` codeql-xray-active-face")
                       (codeql-xray-test--spans (codeql--xray-view-buffer dil) 'active)))
        (should (= 8 (with-current-buffer (window-buffer window)
                       (codeql--xray-row-at (window-start window)))))))))

(ert-deftest codeql-xray-test-columns-close-one ()
  "Keep the other view when one is closed."
  (codeql-xray-test--with (state src '("DIL" "RA"))
    (let ((dil (car (codeql--xr-views state))))
      (kill-buffer (codeql--xray-view-buffer (cadr (codeql--xr-views state))))
      (should (equal (list dil) (codeql--xr-views state)))
      (should (eq state (buffer-local-value 'codeql--xray-state src))))))

;;; Inlined definitions

(defmacro codeql-xray-test--with-route (spec &rest body)
  "Run BODY with the x-ray of Route.ql, binding SPEC (STATE SRC DIL RA)."
  (declare (indent 1))
  (pcase-let ((`(,state ,src ,dil ,ra) spec))
    `(codeql-xray-test--with (,state ,src '("DIL" "RA") "Route" codeql-xray-test--route
                                     (list :DIL codeql-xray-test--route-dil :RA codeql-xray-test--route-ra))
       (pcase-let ((`(,,dil ,,ra) (mapcar #'codeql--xray-view-buffer (codeql--xr-views ,state))))
         ,@body))))

(ert-deftest codeql-xray-test-inlined-regions ()
  "Color the code of their users the inlined definitions went into."
  (codeql-xray-test--with-route (_state src dil ra)
    ;; each definition in its own color, even with no code of its own
    (let ((marks (append (codeql-xray-test--marks src 'paint) (codeql-xray-test--marks src 'note))))
      (dolist (mark '("1-1 codeql-xray-1" "2-5 codeql-xray-2" "4-4 codeql-xray-3" "6-7 codeql-xray-4"
                      "2 no DIL or RA: inlined into select"))
        (should (member mark marks))))
    ;; the class: the type naming it and the predicates its characteristic
    ;; predicate calls; its member: the predicate it calls
    (should (equal '("3 /* Route::Input */ codeql-xray-2"
                     "5 `Route::isRoute/1#aa` codeql-xray-2"
                     "5 `AST::AstNode.getFile/0#dispred#cc` codeql-xray-2"
                     "6 `DataFlow::Node.getSourceType/0#dd` codeql-xray-3")
                   (codeql-xray-test--spans dil 'paint)))
    ;; and in the RA the columns of the variables of the class
    (should (equal '("6 input codeql-xray-2"
                     "7 `Route::isRoute/1#aa` codeql-xray-2"
                     "7 `AST::AstNode.getFile/0#dispred#cc` codeql-xray-2"
                     "7 'input' codeql-xray-2"
                     "8 `DataFlow::Node.getSourceType/0#dd` codeql-xray-3"
                     "8 'input' codeql-xray-2")
                   (codeql-xray-test--spans ra 'paint)))))

(ert-deftest codeql-xray-test-inlined-follow ()
  "Follow point from the query to the code of the inlined definitions, and back."
  (codeql-xray-test--with-route (_state src dil ra)
    (codeql-xray-test--goto (get-buffer-window src) 4)
    (should (equal '("6 `DataFlow::Node.getSourceType/0#dd` codeql-xray-active-face")
                   (codeql-xray-test--spans dil 'active)))
    (should (equal '("8 `DataFlow::Node.getSourceType/0#dd` codeql-xray-active-face")
                   (codeql-xray-test--spans ra 'active)))
    ;; on the columns of the class in the select
    (codeql-xray-test--goto (get-buffer-window ra) 8 83)
    (should (equal '("2-5 codeql-xray-active-face") (codeql-xray-test--marks src 'active)))
    (should (equal '("3 /* Route::Input */ codeql-xray-active-face"
                     "5 `Route::isRoute/1#aa` codeql-xray-active-face"
                     "5 `AST::AstNode.getFile/0#dispred#cc` codeql-xray-active-face")
                   (codeql-xray-test--spans dil 'active)))
    ;; elsewhere in the select, even past them
    (codeql-xray-test--goto (get-buffer-window ra) 8 95)
    (should (equal '("6-7 codeql-xray-active-face") (codeql-xray-test--marks src 'active)))))

;;; emacs-codeql-xray-test.el ends here
