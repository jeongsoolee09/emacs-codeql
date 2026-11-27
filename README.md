# emacs-codeql

An emacs package for writing and testing [CodeQL](https://codeql.github.com/) queries.

![screenshot](img/codeql-dot-el.png?raw=true "emacs-codeql")

## Features

- [Tree-sitter](https://tree-sitter.github.io/tree-sitter/) based syntax highlighting and indentation for the CodeQL query language
- Query execution
- Quick query evaluation of regions or of the predicate at point, and quick evaluation counts
- Query history for the local session
- A CodeQL REPL and Org Babel source blocks, on sessions that remember definitions
- Comparing the results of two query runs
- Loading SARIF files, e.g. from `codeql database analyze` or code scanning, as browsable results
- Query performance summaries from evaluator logs
- Persistent per-project database history, with optional consult narrowing and embark actions
- Registration of zipped database archives
- Result browsing
- Jumping to result locations with completion, with optional [consult](https://github.com/minad/consult) preview and [embark](https://github.com/oantolin/embark) actions
- Stepping through alerts and through the related locations and path steps of an alert, from results or source buffers
- Source archive location opening
- Buffer local query server state with concurrent remote|local project, database and query support
- Automatic database selection deconfliction
- Org based rendering of path-problem, problem, and raw results
- Pagination of large raw result sets
- Result locations shown as Flymake diagnostics in database source files
- Remote query development + evaluation via TRAMP
- Compatible with [github/gh-codeql](https://github.com/github/gh-codeql) for cli version management
- Database source archive xref backend support
- Searching the database source archive with `codeql-database-grep`
- GitHub permalinks to the results of SARIF files with version control provenance
- Browsing multi-repository variant analysis results of gh-mrva sessions
- A `codeql-doctor` health report of the setup
- AST Viewer with xref backend support
- Rendering of graph results with graphviz, and a CFG viewer

## Requirements

- Emacs 29.1+ (built-in tree-sitter)
  - transient

- Emacs 27.1+ (external tree-sitter)
  - transient
  - tree-sitter
  - tree-sitter-langs
  - tree-sitter-indent
  - aggressive-indent
  - eglot

- CodeQL CLI 2.12.0+

## Installation

### Recommended install method (Emacs 29 and above)

Emacs 29.1+ comes with `use-package`, `tree-sitter` and `eglot` built-in, which simplifies `emacs-codeql` setup considerably. A [quelpa](https://github.com/quelpa/quelpa) for non-MELPA package installs configuration may look like:

```elisp
(use-package emacs-codeql
  :quelpa
  (emacs-codeql :repo "anticomputer/emacs-codeql"
		:fetcher github-ssh
		:branch "main"
		:files (:defaults "bin" "queries"))
  :demand t
  :init
  (setq codeql-transient-binding "C-c q")
  (setq codeql-configure-eglot-lsp t))
```

### Recommended install method (Emacs 28 and below)

`use-package` + [quelpa](https://github.com/quelpa/quelpa) for non-MELPA package installs:

```elisp
(use-package emacs-codeql
  :quelpa
  (emacs-codeql :repo "anticomputer/emacs-codeql"
		:fetcher github-ssh
		:branch "main"
		:files (:defaults "bin" "queries"))
  :after tree-sitter-langs
  :demand t
  :init
  (setq codeql-transient-binding "C-c q")
  (setq codeql-configure-eglot-lsp t))
```

### Alternative install methods

#### Local

You can clone this repository and place it into your emacs `load-path`, you'll want to ensure that you have all required dependencies available, including the most recent MELPA versions of any required packages.

```elisp
;; initialization options
(setq codeql-transient-binding "C-c q")
(setq codeql-configure-eglot-lsp t)
(require 'emacs-codeql)
```

#### Straight.el

Users of `straight.el` can use the below `use-package` declaration:

```elisp
(use-package emacs-codeql
  :straight
  (emacs-codeql :type git
		:host github
		:repo "anticomputer/emacs-codeql"
		:branch "main"
        :files (:defaults "bin" "queries"))
  :after tree-sitter-langs
  :demand t
  :init
  (setq codeql-transient-binding "C-c q")
  (setq codeql-configure-eglot-lsp t))
```

### Getting Started with CodeQL

#### Production CodeQL Development

The quickest way into painfree production-ready CodeQL development is to use the [GitHub CLI CodeQL extension](https://github.com/github/gh-codeql) to manage your CodeQL toolchain dependencies and then use [CodeQL Packs](https://codeql.github.com/docs/codeql-cli/about-codeql-packs/) and (optionally) [CodeQL Workspaces](https://codeql.github.com/docs/codeql-cli/about-codeql-workspaces/) for your query development. CodeQL packs are the canonical way to share your CodeQL queries with the CodeQL community.

To get started:

1. Install the [GitHub CLI](https://cli.github.com/) via your package manager of choice.

2. Install the [GitHub CLI CodeQL extension](https://github.com/github/gh-codeql) via `gh extensions install github/gh-codeql`.

3. Confirm you can resolve qlpacks using `gh codeql resolve qlpacks`, on first run this will also download the CodeQL CLI on your behalf.

4. [Download or create a database](https://codeql.github.com/docs/codeql-cli/creating-codeql-databases/#obtaining-databases-from-lgtm-com) to query.

5. Create a new CodeQL pack using `gh codeql pack init yourname/my-queries`. This will create a directory named `my-queries`. If you intend to eventually publish your queries, then `yourname` should map to a GitHub organization or user account (e.g. `anticomputer/my-queries`).

6. From inside your newly created pack directory, add any CodeQL dependencies that your query pack needs using `gh codeql pack add`. For example, if we're writing a Ruby query pack and want to add the latest Ruby support, we would run `gh codeql pack add codeql/ruby-all` inside our newly created `my-queries` pack. This operation will (re)install any declared dependencies. If we want to specify a specific version of the `codeql/ruby-all` dependency, say `0.4.2`, we can further qualify the dependency with `gh codeql pack add codeql/ruby-all@0.4.2`. Note that if you are working with a pre-existing `qlpack.yml` that has existing dependencies you can install those dependencies with `gh codeql pack install`.

7. Open `my-queries/my-first-query.ql` from your `emacs-codeql` enabled Emacs, and off you go!

Note: If you prefer not to use the gh cli, you can also [install the CodeQL CLI yourself](https://codeql.github.com/docs/codeql-cli/getting-started-with-the-codeql-cli/#getting-started-with-the-codeql-cli). The pack commands would have the `gh` prefix removed in this case, but otherwise remain the same.

##### More about CodeQL packs and workspaces

You can find the latest versions of the standard CodeQL packs at https://github.com/orgs/codeql/packages

For more details about how to properly create and work with CodeQL packs please see https://codeql.github.com/docs/codeql-cli/creating-and-working-with-codeql-packs/ and the [CodeQL packs documentation](https://codeql.github.com/docs/codeql-cli/about-ql-packs/).

For writing queries that only depend on standard CodeQL libraries, you do not have to create a workspace. However, for more advanced CodeQL library and query development, we recommend you use [CodeQL workspaces](https://codeql.github.com/docs/codeql-cli/about-codeql-workspaces/) to define and manage your CodeQL project dependencies.

#### Personal CodeQL Development

If you don't intend to publish or otherwise distribute your CodeQL queries, a quicker way to bootstrap a working CodeQL query template environment is via the [VSCode CodeQL Starter Workspace](https://github.com/github/vscode-codeql-starter).

You can again either bootstrap a CodeQL CLI via the [GitHub CLI CodeQL extension](https://github.com/github/gh-codeql) or by [installing it yourself](https://codeql.github.com/docs/codeql-cli/getting-started-with-the-codeql-cli/#getting-started-with-the-codeql-cli).

To use the VSCode CodeQL Starter workspace with `emacs-codeql`, just `git clone --recursive https://github.com/github/vscode-codeql-starter.git` and you'll be able to open any of the example queries contained within this workspace to start iterating on a query.

For example, you can open `vscode-codeql-starter/codeql-custom-queries-ruby/example.ql` with your `emacs-codeql` enabled Emacs, and you're ready to run and iterate on `example.ql` against a Ruby CodeQL database.

## Using `emacs-codeql`

### Writing and Running Queries

Edit a `.ql` or `.qll` file inside a `qlpack.yml` project root, start a query server with `M-x codeql-query-server-start`, register a database with `M-x codeql-query-server-register-database`, and run the query with `M-x codeql-query-server-run-query`. Both setup steps are also on the control panel (`codeql-transient-binding`, `C-c C-d` by default), and the query commands are in `codeql-command-map` (`codeql-command-binding`, `C-c C-q` by default), see [Commands](#commands). Running a query before a server is started or a database registered fails with a message saying which one is missing.

#### Syntax highlighting and indentation

`emacs-codeql` includes a `tree-sitter` based major-mode that provides indentation and syntax highlighting for `.ql` and `.qll` files. On Emacs 28 and below, it relies on `aggressive-indent` for continuous indentation, as is common practice in structural editing modes. On Emacs 29 and above, it employs a more conservative electric indent based indentation approach.

On Emacs 28 and below, `emacs-codeql` relies on a custom version of `tree-sitter-langs` that includes `tree-sitter` support for QL. This support has not been upstreamed as of 03-27-2022, but package recipes for custom forks are provided above.

On Emacs 28 and below, `emacs-codeql` also packages QL `tree-sitter` artifacts for Linux x64 and MacOS x64 systems, which may preclude the need to build your own artifacts. If your system is compatible with the existing artifacts, you are not required to install the custom forks of `tree-sitter`, `tree-sitter-langs` and `tree-sitter-indent` and can just use the existing MELPA versions.

On Emacs 29 and above you do not have to worry about any of this, as all the required `tree-sitter` support is included in the default build of Emacs and building the required artifacts is handled by standard Emacs 29+ functionalities.

On Emacs 29 and above `emacs-codeql` also comes with an Emacs 29+ specific version of its CodeQL major mode `ql-tree-sitter-builtin.el` that relies only on the included tree-sitter libraries and API.

The major mode is called `ql-tree-sitter-mode`, and `emacs-codeql` makes it available as `codeql-mode` too. `codeql-mode-map`, `codeql-mode-hook`, `codeql-mode-syntax-table`, `codeql-mode-abbrev-table` and `codeql-mode-indent-offset` are aliases of the corresponding `ql-tree-sitter-mode` variables, so either name can be used in your configuration, and on Emacs 30 and above `(derived-mode-p 'codeql-mode)` holds in CodeQL buffers. The value of `major-mode` stays `ql-tree-sitter-mode`.

In org documents, `#+begin_src codeql` and `#+begin_src ql` blocks use this mode for highlighting and for editing with `C-c '`. Source block buffers don't visit a file, so they don't get a query server, language server or search paths.

#### Database selection

You can register a database for your current project with `M-x codeql-query-server-register-database`, or `d` on the control panel. Start a query server first, with `M-x codeql-query-server-start` or `s` on the control panel. If a database is active in another query buffer, it will automatically be deregistered there and registered for your current buffer.

Database selection is per project by default (see [Sharing a query server](#sharing-a-query-server-across-query-and-library-files)), and you can run as many concurrent query projects as you have resources available.

#### Database history

Every database you register is remembered per project, across Emacs sessions. The project is the version-controlled project that contains the query file, or the CodeQL pack root when the query is not under version control. Select `k` (known databases) to pick one from the history. Databases of the current project come first, most recently used on top, followed by databases used in other projects. Each candidate is annotated with its language, when it was last used, its project, and whether it no longer exists on disk.

When [consult](https://github.com/minad/consult) is installed the picker uses it, and you can narrow to the current project with `p` or to other projects with `o`. With [embark](https://github.com/oantolin/embark), the candidates offer the actions in `codeql-database-map`: `r` to register, `k` to forget the database (`codeql-database-history-remove`), `d` to open it in dired, `w` to copy its path, and `u` to delete its lock.

After a query server starts, the most recently used database of the project is registered automatically. Set `codeql-register-last-database` to `nil` to disable this.

The history is stored in `database-history.eld` inside `codeql-state-dir`; customize `codeql-database-history-file` to put it elsewhere. It always lives on the local machine; entries for TRAMP databases keep their remote paths and are offered only to query buffers on the same host.

You can also register a zipped database archive (`.zip`) with `d`. It is unpacked with `codeql database unbundle` into the `databases` directory of `codeql-state-dir`, and an already unpacked copy is reused.

#### Deleting a stale database lock

A query server that crashed or was killed can leave its database locked, so that other query servers fail to evaluate queries against it. Select `u` (unlock), or `M-x codeql-database-delete-lock`, to delete the evaluation cache lock (`db-<language>/default/cache/.lock`) of the active database. With a prefix argument, or without an active database, you pick the database from the history instead. You are asked to confirm first, and warned when a query server in this Emacs still uses the database, or when another process (as reported by `lsof`) still has the lock open.

`emacs-codeql`'s per-project approach means you can work on e.g. a `cpp` and `javascript` project concurrently, and you can an arbitrary amount of concurrent results buffers as you toggle between your query buffers.

#### Sharing a query server across query and library files

When a query grows into helper `.qll` files, you'll want those buffers to use the same query server and database, e.g. to quick-eval a library predicate. By default, query servers are per project, much like eglot manages one language server per project: all query buffers of the same project, on the same host and with the same CodeQL CLI, share a single query server, database and query history. A project is a version-controlled directory tree, or else a CodeQL pack. A server started in one of them is picked up by the others, including buffers you open later, and registering a database in any of them makes it active in all of them. Stopping the server stops it for all of them.

Query servers are disposed of manually: killing the last buffer that uses a server keeps it running in the background, detached, with its database and query history, much like eglot keeps its language servers. A buffer of its project that you open later uses it again (or pick it with `u` in `codeql-query-servers` when sharing is off), and registering its database from another server takes the database over. Shut it down with `codeql-query-servers` or `codeql-query-server-shutdown`. To shut a server down with the last buffer that uses it instead, set `codeql-query-server-autoshutdown`:

```elisp
(setq codeql-query-server-autoshutdown t)
```

`codeql-share-query-server` controls this:

```elisp
(setq codeql-share-query-server 'project) ; the default: one server per project
(setq codeql-share-query-server t)        ; one server across projects, as in the VS Code extension
(setq codeql-share-query-server nil)      ; one server per buffer
```

Select `i` (inherit) on the control panel of a buffer without a query server to share the server, active database and query history of any other query buffer on the same host, whatever its project.

`M-x codeql-query-server-start` starts a query server with the options in `codeql-query-server-default-args`; with a prefix argument it opens a transient to pick the options.

#### Managing query servers

`M-x codeql-query-servers` (`m` on the control panel) lists the running query servers, those of the current project first and the one of the current buffer first of all. Each is annotated with its active database, the number of query buffers that use it (or `detached` when none does) and how long it has been running. After picking one, choose an action: `b` to switch to one of its buffers, `r` to restart it, `k` to shut it down, `e` for its JSON-RPC events, `l` for its stderr, or `u` to use it in the current buffer. The actions are also commands of their own: `codeql-query-server-switch-to-buffer`, `codeql-query-server-restart`, `codeql-query-server-shutdown`, `codeql-query-server-events-buffer`, `codeql-query-server-stderr-buffer` and `codeql-query-server-use`. `codeql-query-server-shutdown-all` shuts down all of them.

Restarting a server starts a new one with the same options, used by the same buffers, which keep their query history, and registers their database again.

When [consult](https://github.com/minad/consult) is installed the picker uses it, and you can narrow to the current project with `p` or to other projects with `o`. With [embark](https://github.com/oantolin/embark), the candidates offer the actions in `codeql-query-server-map`, with the same keys.

You can find existing databases for a ton of open source projects on [LGTM.com](https://codeql.github.com/docs/codeql-cli/creating-codeql-databases/#obtaining-databases-from-lgtm-com), or you can [create your own](https://codeql.github.com/docs/codeql-cli/creating-codeql-databases/#creating-codeql-databases) using the codeql cli.

#### Run a query or quick evaluate query regions

If there is an active region, `emacs-codeql` will attempt to quick-eval that region. Note that to quick-eval an entire predicate, you should mark the predicate name itself as opposed to the entire predicate definition. This follows the same semantics as quick-evaluation in the vscode extension.

If there is no active region, `emacs-codeql` will attempt to run the full query by default.

The `e` (quick eval) command of `codeql-command-map`, `codeql-query-server-quick-eval`, always quick evaluates: the active region if there is one, and otherwise the predicate or expression at point, e.g. with point on the name of a predicate. The `n` (quick eval count) command, `codeql-query-server-quick-eval-count`, does the same but only counts the results, which is much faster for predicates with many tuples. The counts are shown as a table of the total number of tuples and the distinct values of each column. Quick evaluation counts need the `query-server2` query server.

The `p` (quick eval predicate) command, `codeql-query-server-quick-eval-predicate`, quick evaluates the predicate enclosing point, so point can be anywhere in its parameters or body rather than on its name. In a class, the characteristic predicate and member predicates are evaluated the same way. Outside of any predicate, e.g. in the select clause, it runs the whole query instead. With an active region it behaves like `e`.

#### Result rendering

Results are rendered through `org-mode` buffers, which allows you to save results as normal text files and even read them in other editors. This approach also allows you to turn a result buffer into a living audit document, take notes, and do all the things that `org-mode` allows you to do.

Results buffers use `codeql-results-mode`, a major mode derived from `org-mode`. Everything from `org-mode` keeps working, including `org-mode-hook` and the bindings in `org-mode-map`, while `codeql-results-mode-hook` and `codeql-results-mode-map` let you customize results buffers without touching other org files. Results saved by the query history (`*.bqrs.org` files) open in `codeql-results-mode` as well. For example:

```elisp
(with-eval-after-load 'emacs-codeql
  (define-key codeql-results-mode-map (kbd "C-c C-g") #'codeql-results-goto-location)
  (define-key codeql-results-mode-map (kbd "C-c C-d") #'codeql-results-diagnostics-mode))
```

The following query "kinds" are supported: `path-problem`, `problem`, and raw tuple results.

kind: `problem` and `path-problem` are rendered as org trees, raw tuple results are rendered as org tables. Set `codeql-raw-results-style` to `outline` to render raw tuples as one org heading per row instead, or toggle the style of a results buffer with `codeql-results-toggle-raw-style`. Tables are easier to scan and sort, headings carry properties that can be searched (see below).

Every results buffer is a regular org document with the same layout:

```org
* Query Source                 ← folded when the buffer is opened
:PROPERTIES:
:CODEQL_KIND: query-source
:CODEQL_EVALUATION: query      ← or quick-eval, quick-eval-count, sarif, variant-analysis
:CODEQL_QUERY: /path/to/query.ql
:CODEQL_DATABASE: /path/to/db
:END:
** Originating Query
[[file:/path/to/query.ql][query.ql]]
** Evaluated Code              ← quick evaluations only
Quick evaluation of the region at [[file:/path/to/query.ql::12][query.ql:12:5]]:
#+begin_src ql -i
from int x where x in [1 .. 5] select x
#+end_src
* Results
:PROPERTIES:
:CODEQL_KIND: results
:CODEQL_QUERY_KIND: problem    ← or path-problem, raw
:END:
** ≔ [js/xss] Cross-site scripting ... [[codeql:...][app.js]]:3:5
:PROPERTIES:
:CODEQL_KIND: result
:CODEQL_QUERY_KIND: problem
:CODEQL_RESULT: 1
:CODEQL_RULE_ID: js/xss
:CODEQL_MESSAGE: Cross-site scripting vulnerability due to user-provided value.
:CODEQL_FILE: /src/app.js
:CODEQL_LINE: 3
:CODEQL_COLUMN: 5
:CODEQL_END_LINE: 3
:CODEQL_END_COLUMN: 10
:END:
*** Path #0
...
* Results Footer
```

`Query Source` records what produced the results: a link to the query file that was run, and for quick evaluations the exact code that was submitted, captured when you ran it, so later edits to the query buffer don't change it. Results of `codeql-load-sarif` and `codeql-mrva` record their origin there too, see below. Expand it with `TAB` as usual. Rows of raw results rendered as headings (`outline` style) carry `CODEQL_RESULT_SET`, `CODEQL_ROW`, the location properties of their first location, and one `CODEQL_COL_<NAME>` property per column. `CODEQL_FILE` is the path of the file in the analyzed project, the links point into the source archive of the database.

##### Searching results with org-ql

When [org-ql](https://github.com/alphapapa/org-ql) is installed, `codeql-results-org-ql` searches the results of the current results buffer and shows the matches as a sparse tree; with a prefix argument the matches are shown in an `org-ql-search` view instead. Queries are restricted to result headings (`CODEQL_KIND` = `result`), and can be written in the org-ql string syntax or as a sexp, e.g.:

```
xss                                         ; plain text search
(property "CODEQL_FILE" "/src/app.js")      ; exact property values
(property "CODEQL_RULE_ID" "js/xss")
(regexp "user-provided")
(and (property "CODEQL_QUERY_KIND" "raw") (regexp "eval"))
```

Raw results rendered as a table are switched to the `outline` style first, since org-ql only sees headings. Results buffers are org buffers, so `org-ql-select`, `org-ql-search` and friends work on them directly, too. org-ql is an optional dependency.

Only the current page of paginated results is part of the buffer, and therefore searchable.

Results contain source code locations in the form of org links, which can be visited with the normal org mode operations for link handling (e.g. `org-open-at-point`)

Visiting a location briefly flashes the code it spans. Set `codeql-highlight-visited-location` to `region` to leave the location marked as the active region instead, or to `nil` to only move point to its start. The flash starts `codeql-pulse-delay` seconds after the location is displayed, so that you have time to find its window, and fades out over `codeql-pulse-duration` seconds.

Locations that span a whole file open that file at the top, and locations without a source file are shown as plain text.

`emacs-codeql` will resolve file paths into the project snapshot source code archive included with the database archive.

#### Comparing query results

`codeql-query-history-compare` (`C` in `codeql-command-map`) compares the results of two runs from the query history, e.g. of two versions of the same query. It prompts for the two runs, which must be on the active database and have result sets with the same names and number of columns. Problem and path-problem results can only be compared with each other.

The rows only found in the first run and those only found in the second run are computed by `codeql bqrs diff` and shown side by side in two results buffers, named after the runs they came from. These work like any other results buffer, so problem results are rendered as org trees and raw results as tables that can be sorted and paged. The echo area summarizes how many rows each side has to itself.

#### Loading SARIF files

`codeql-load-sarif` (`l` in `codeql-command-map`) renders an existing SARIF file, e.g. the output of `codeql database analyze` or a code scanning run, like the results of a problem or path-problem query, with pagination, alert navigation and diagnostics.

When the query buffer has an active database, result locations are taken to be files of its source archive, so that they work with the database source archive xref backend like regular results. With a prefix argument, or without an active database, they are taken to be files of a source checkout instead, which is prompted for when the SARIF has relative locations that its `originalUriBaseIds` don't resolve. Locations missing from the checkout whose contents are embedded in the SARIF (`codeql database analyze --sarif-add-file-contents`) are shown from a read-only copy of those contents.

The `Query Source` section of the results describes the SARIF file: `CODEQL_EVALUATION` is `sarif`, `CODEQL_SARIF` its path, `CODEQL_TOOL` the tools that produced it, `CODEQL_REPOSITORY_URI` and `CODEQL_REVISION_ID` its version control provenance, if any. An `Originating SARIF` heading links to the file, and a `Rules` heading lists the rules that results were reported for, with their names.

When the SARIF records the repository and revision it was produced for in its `versionControlProvenance`, as code scanning and variant analysis results do, `codeql-copy-permalink` copies a GitHub permalink to the result location at point, and `codeql-browse-permalink` opens it in a browser. They work on the links of the results buffer and in source files visited from them, where an active region links to its range of lines. For example:

```elisp
(with-eval-after-load 'emacs-codeql
  (define-key codeql-results-mode-map (kbd "C-c C-l") #'codeql-copy-permalink))
```

#### Multi-repository variant analysis

`codeql-mrva` (`v` in `codeql-command-map`) browses the results of [gh-mrva](https://github.com/GitHubSecurityLab/gh-mrva) sessions, which you submit with `gh mrva submit`. Install the extension with `gh extension install GitHubSecurityLab/gh-mrva`.

After picking a session, its repositories with findings are listed in a `codeql-mrva-mode` buffer, along with their finding and star counts. `RET` downloads the results of the repository at point below `codeql-state-dir` and renders them for the query buffer `codeql-mrva` was called from, like `codeql-load-sarif` does. `g` refreshes the status of the session. The source files of result locations are fetched from GitHub with `gh api` as you visit them, at the revision that was analyzed, and `codeql-copy-permalink` works on them too. Results of queries that aren't problem or path-problem queries are shown decoded.

The `Query Source` section of variant analysis results holds the whole query as it was submitted, in a `Submitted Query` src block. It is taken from the query pack of the run, which is fetched from the controller repository with `gh api` once per run, so later edits to the query file don't change it. When the pack can't be fetched, the query file as it is now is shown instead, and said so. `CODEQL_EVALUATION` is `variant-analysis`, and `CODEQL_MRVA_SESSION`, `CODEQL_MRVA_RUN`, `CODEQL_MRVA_CONTROLLER` and `CODEQL_MRVA_REPOSITORY` record where the results came from, along with the properties of the downloaded SARIF file.

#### Query performance

Each query run writes a structured evaluator log next to its results (set `codeql-evaluator-log` to `nil` to turn this off; it needs query-server2). `codeql-query-performance` (`t` in `codeql-command-map`) summarizes the log of a run from the query history with `codeql generate log-summary` and lists the predicates that were computed, the slowest first, in an org table with their time, tuple count, number of iterations and evaluation strategy. The header shows the total evaluation time and how many predicates came from the cache. Predicate names link to their definitions, `C-c C-a` shows the relational algebra of the predicate at point together with its iteration deltas, and the table can be sorted by any column with `org-table-sort-lines` (`C-c ^`). Only the `codeql-performance-max-predicates` (default: 300) slowest predicates are listed.

`codeql-query-performance-compare` (`T`) matches the computed predicates of two runs by name and lists the time and tuples of each run, the largest difference in time first. Predicates that were taken from the cache in one of the runs show `-` for that run.

#### Jumping to result locations

`codeql-results-goto-location` offers every source location in the current results buffer (or page of results) for completion, each with the text of the result it belongs to, and visits the chosen one like following its link. Bind it in `codeql-results-mode-map`, or call it with `M-x`.

There are no extra dependencies, but when [consult](https://github.com/minad/consult) is installed the locations are grouped by file and previewed as you move between them. When [embark](https://github.com/oantolin/embark) is loaded, `codeql:` links at point and the completion candidates are `codeql-location` targets, with the actions in `codeql-location-map`: `o` (or `RET`) visits the location, and `w` copies it as `FILE:LINE:COLUMN`.

#### Navigating between alerts

These commands step through the results from wherever you are, including the source files the results point into:

- `codeql-next-alert` and `codeql-previous-alert` visit the location of the next or previous alert, in the order the results buffer lists them. An alert is a `problem` or `path-problem` result, or a row of a raw results table.
- `codeql-next-alert-location` and `codeql-previous-alert-location` cycle through the locations of the current alert: its own location, then the related locations its message links to, then the steps of its paths from source to sink.

Following a link in a results buffer, or visiting a location with these commands, makes its alert the current one. In a source file, point on one of the current alert's locations counts as that location, so the commands continue from where you are. Point in the results buffer moves along, and inside the results buffer the commands start from the alert at point, like `next-error` in compilation buffers. Paginated results are navigated one page at a time.

The commands use the current results buffer, or else the one you last navigated, or one that shows its results as diagnostics. Results buffers also work with `next-error` and `previous-error` (`M-g n` and `M-g p`), which move between alerts.

The commands aren't bound by default. `codeql-alert-navigation-map` has them on `n`, `p`, `f` and `b`. Bind it to a prefix key, and with `repeat-mode` on you can keep pressing `n`, `p`, `f` and `b` without the prefix:

```elisp
(keymap-global-set "C-c n" codeql-alert-navigation-map)
(repeat-mode 1)
```

### CodeQL sessions

A session evaluates snippets of CodeQL one after another, like a REPL, against the database of a project, and remembers the definitions it was given. Interactive front ends, such as a REPL, build on sessions. A session needs Emacs 29 or newer with the tree-sitter `ql` grammar.

Each input can define predicates, classes, modules, newtypes and imports, and ask for one of the following:

- a `select` query (`from int x where x in [1 .. 3] select x`);
- an expression (`count(CallExpr c | manyArgs(c, _))`), which is selected;
- a formula (`exists(CallExpr c | manyArgs(c, 4))`), whose truth is selected as `holds`;
- the name of a predicate of the session (`manyArgs`), which is quick evaluated, or its name and arity (`manyArgs/2`) to pick one of several predicates of that name;
- the name of a type (`Integers`, `DataFlow::Node`), whose values are selected.

A call of a predicate that the session doesn't define could be an expression or a formula. It is tried as an expression first, and then as a formula.

Each evaluation rewrites a query module that holds the session's definitions, followed by the code to evaluate. The module lives in the hidden `.codeql-session/` directory of the CodeQL pack, so it resolves the same libraries as the pack's queries. The directory has a `.gitignore` that ignores everything in it. A session runs on the project's query server and database. Without a database it uses the one last registered in the project, or asks for one.

Definitions are kept as soon as they are entered, without compiling them. When an evaluation fails with compiler errors in definitions that have never compiled successfully, they are rolled back: a new definition is dropped, and a redefinition is replaced by the last version that compiled. With `codeql-session-check-definitions`, definitions are compiled before they are kept. This catches mistakes early, but compiling a new query module can take several seconds.

A definition with the same name as one the session already has replaces it: classes, newtypes and modules by name, predicates by name and arity, so `p/1` and `p/2` are distinct. Front ends warn about such a redefinition, and about definitions given more than once in the same input, where the last one counts. Entering a definition again unchanged, up to whitespace, keeps it as it is.

Session results use the same org results buffers and query history as other runs. Their `Query Source` shows the evaluated input and the query module that ran.

Compiler errors are reported in terms of the session: a location in a definition names it, such as `(in manyArgs/2, line 3)`, and other locations are `(in the input)`.

### CodeQL REPL

`M-x codeql-repl` opens a REPL for the CodeQL pack of the current buffer, which evaluates its input in a session of the pack (with a prefix argument, it asks for the name of the session). Several REPLs, each with its own session, can run in a pack.

```
ql> predicate manyArgs(CallExpr c, int n) { n = c.getNumArgument() and n > 2 }
Defined manyArgs/2.
ql> count(CallExpr c | manyArgs(c, _))
37
1 result in 9.8s [results]
ql> manyArgs
c                    │ n
─────────────────────┼──
assert. ... empty")  │ 3
...
37 results, 10 shown in 1.1s [results]
```

`RET` sends the input when it is complete, and otherwise continues it on a new, indented line: while parentheses, brackets, braces, strings or block comments are open, after an operator or a keyword like `and`, and in a `from` or `where` clause without a `select`. `C-j` always continues the input. `TAB` completes the names of the session's definitions, annotated with their signatures, CodeQL keywords, and commands after a `:`. Predicates with several arities are also completed as `NAME/ARITY`. Entering just the name of such predicates, also with `:count`, asks which of them to evaluate.

The first `codeql-repl-max-rows` results are printed as a table, with cells cut at `codeql-repl-max-column-width`. Result locations are buttons that visit the source archive. `RET` or a click pushes a button, also in Evil's normal state, where evil-collection binds `RET` to send input. `[results]`, `C-c C-v` or `:results` opens all results in an org results buffer. `C-c C-c` cancels the running evaluation. Input is fontified as CodeQL when `codeql-repl-fontify-input` is non-nil.

Input that begins with a colon is a command. Commands can be abbreviated, such as `:d` for `:defs`.

| Command | Description |
| --- | --- |
| `:help` | List the commands |
| `:defs [NAME]` | List the definitions of the session, or show the code of those named NAME |
| `:undef NAME` | Remove the definitions named NAME |
| `:reset` | Remove all definitions but the default import |
| `:count PREDICATE[/ARITY]\|TYPE` | Count the results of a predicate of the session, or the values of a type |
| `:results` | Open the last results in a results buffer |
| `:module` | Show the query module of the last evaluation |
| `:db [PATH]` | Show the database, or register the one at PATH for the project |
| `:cancel` | Cancel the running evaluation |
| `:clear` | Clear the REPL buffer |

`M-x codeql-repl-send-region` evaluates the region of a query buffer in the REPL of its pack, or the top-level definition or query at point when the region isn't active. The query server menu has these as `R` and `E`.

The input history, which keeps multi-line inputs whole, is saved in `codeql-repl-history-file`. The prompt is `codeql-repl-prompt`. Killing a REPL ends its session.

### Org Babel

`ob-codeql.el` evaluates `codeql` (or `ql`) source blocks in sessions, so a block can hold anything that a REPL input can. Enable it with:

```elisp
(org-babel-do-load-languages 'org-babel-load-languages '((codeql . t)))
```

```org
#+begin_src codeql :session
predicate manyArgs(CallExpr c, int n) { n = c.getNumArgument() and n > 2 }
#+end_src

#+RESULTS:
: Defined manyArgs/2.

#+begin_src codeql :session :limit 2
manyArgs
#+end_src

#+RESULTS:
| c                   | n |
|---------------------+---|
| [[codeql:...][assert. ... empty")]] | 3 |
| [[codeql:...][assert. ... empty")]] | 3 |
```

A single result is returned as a value, other results as a table whose header holds the names of the columns, or their types. Result locations are `codeql:` links into the source archive, and numbers stay numbers, so the tables can be used by other blocks. Definitions return what was defined, and what was redefined. Redefinitions are also reported in the echo area when the block evaluates something as well. Errors are shown in the `*Org-Babel Error Output*` buffer, with what was rolled back, and return no result.

| Header argument | Description |
| --- | --- |
| `:session [NAME]` | Evaluate in the session NAME (`default` without a name), which keeps definitions for later blocks and is shared with the REPL of that name. Without a session, each block is evaluated on its own. |
| `:database PATH` | The database to evaluate on, else that of the project |
| `:pack DIR` | The CodeQL pack to evaluate in, else that of the org file |
| `:limit N` | The number of result rows, `ob-codeql-default-limit` by default |
| `:count yes` | Count the results of a quick evaluated predicate, or the values of a type |
| `:open yes` | Also open all results in an org results buffer |

Outside of CodeQL packs, blocks need a `:database` (or ask for one), and are evaluated in a pack that `ob-codeql` makes in `codeql-state-dir` for the language of the database. The pack depends on the latest standard library of the language, which `codeql pack install` installs the first time. When a query server already has the database, blocks use that query server.

Evaluation is synchronous: `C-g` cancels it. `:var` is not supported.

### Database source archive Xref support

`emacs-codeql` automatically retrieves references and definitions for database source archive files that are opened from a result buffer org link. It achieves this by registering a custom org-link handler for a `codeql:` link type which then performs a ridiculous elisp ritual to trick emacs into thinking it actually has xref support for these files specifically.

`emacs-codeql` rudely overrides the default xref bindings for any existing major-mode that might normally take precedence for the type of source file that is opened, but only for files opened from a result buffer. But not to worry, these overrides are buffer-local only, and won't tamper with any other source files sharing the same major-mode that are NOT inside a codeql database source archive.

The `codeql:` link handler sets up a buffer-local context for the opened source file that initializes a custom xref backend, such that the normal emacs `xref-find-definitions` and `xref-find-references` functions (commonly bound to `M-.` and `M-,`) operate as you would expect them to.

Note: definitions and references are resolved by running templated queries the first time they are looked up in a given archive file during the current session, so the first `M-.` or `M-?` in a file may take a few seconds (at most `codeql-xref-timeout` seconds, default: 120). After that, they are pulled from cache and are available instantly. Set `codeql-xref-resolve-on-visit` to `t` to instead resolve both in the background as soon as an archive file is opened from a result buffer.

There occurs a somewhat awkward situation when you follow a transitive xref, i.e. one that is not directly in a child buffer of a org link follow. At that point `emacs-codeql` doesn't know yet that this file was opened in a codeql source browsing context and that it still needs its references and definitions resolved. To deal with this, you can can `M-x RET codeql-xref-backend RET` as this will initialize the buffer with the required xref bindings.

Alternatively, any invocation of the default `xref-find-references` or `xref-find-definitions` functions will trigger a call to the `codeql-xref-backend` function as well, since it serves as the `xref-backend-functions` entry for the codeql xref backend. After this initial invocation to the standard bindings, the codeql xref bindings will then take over if `codeql-xref-backend` determined that the file its operating on is inside a codeql database source archive.

It is left as a matter of user preference whether to invoke `codeql-xref-backend` themselves, or to deal with a single layer of indirection and wait for one of the xref API to invoke it for them.

`codeql-database-grep` (`g` in `codeql-command-map`) searches the source archive of the active database for a regexp and lists the matches in an xref buffer. With a prefix argument it prompts for a wildcard to restrict the searched files, e.g. `*.java`. Archive files visited from those matches are set up like ones opened from a result buffer, so the codeql xref backend is available in them right away.

### AST Viewer

Just like the vscode extension, `emacs-codeql` lets you browse the AST of a database source archive file. Similar to the other results buffers, the AST is rendered as an org-mode tree. You can invoke the AST viewer with `M-x RET codeql-view-ast RET` for a database source archive file.

Moving point in the source file highlights its node in the AST viewer, and moving point in the AST viewer shows the source of the node at point in another window, highlighted with `codeql-follow-source-face`, like the CFG viewer below. `codeql-ast-sync-highlighting` turns both off.

`M-x RET codeql-view-ast-graph RET` shows the AST as a graph instead, in the formats of the CFG viewer below. As a text diagram, each top-level node is a part of its own, its children run side by side, and the innermost node at point is selected. Since ASTs are dense, the rows only list node types like `[IfStmt]`, and the header line and the description below the diagram show the full label and location of the selected node. While the diagram is visible, moving point in the source file selects the innermost node at point, as long as `codeql-ast-sync-highlighting` is on.

### Graph results and the CFG Viewer

Results of `@kind graph` queries are interpreted as graphviz dot files with `codeql bqrs interpret --format=dot` and shown in a `codeql-graph-mode` buffer. The viewing format is set by `codeql-graph-format`: an `svg` (the default) or `png` image rendered by graphviz's `dot`, a `text` diagram, or `nil` for the dot source. When `dot` is not installed or the frame can't show images, e.g. in a terminal, the graph is drawn as text.

Much like [org-graph-view](https://github.com/alphapapa/org-graph-view), the rendered nodes are clickable: `mouse-1` on a node jumps to its location in the database source archive, and `RET` lets you pick a node by its label with `completing-read`. `f` cycles the viewing format between svg, png, text and the dot source, and `g` re-renders the graph.

The text diagram is drawn like `undo-tree-visualize`, with the edges running down the diagram and edges pointing back up (e.g. of loops) noted as `^ label`. Branches run side by side, so the nodes at the same depth of each branch share a row, with their labels listed from left to right. Separate parts of a graph, like the nodes of a function and its body in a CFG, are drawn one below the other:

```
  x-.  if (x)  a.js:1
  | |
  o o  then  a.js:2 │ else  a.js:3
  | |
  o-'  end  a.js:4
```

`n`/`p` (or `C-n`/`C-p`) move the selection `x` to the next node and back the way you came, `C-f`/`C-b` move to the node beside it on the same row, `N`/`P` (or `M-n`/`M-p`) jump between the roots of the graph, the nodes no edge leads down to, and `RET` or clicking the selected node jumps to its location; `C-u RET` picks a node by label. `s` or `/` searches the node labels incrementally: as you type, the first node down the diagram whose label contains the input is selected, `C-s`/`C-r` select the next/previous match, `RET` ends the search and `C-g` goes back to where it started. An empty search repeats the last one. Like isearch, it ignores case unless the input has upper case letters. The predecessors and successors of the selected node are listed below the diagram as buttons. With evil, `j`/`k`/`l`/`h` move like `n`/`p`/`C-f`/`C-b`, `J`/`K` like `N`/`P`, and `s` and `/` search.

`TAB` collapses the nodes below the selected node, like a subtree of an AST, into it, or expands them again; `S-TAB` expands all of them. A collapsed node is drawn as `+` and its label is followed by the number of nodes it hides, like `[FunctionDeclStmt] [+19]`. Only nodes that can't be reached any other way are hidden, so collapsing one branch of a CFG keeps the nodes after the branches join. Searches skip hidden nodes, and selecting one, e.g. when the AST graph follows point in the source, selects the collapsed node it's in. With evil, `za` and `zR` work too.

The nodes are drawn with `codeql-graph-node-face` (bold) and the selected one, as `x`, with `codeql-graph-selected-face` (bold red), as is its label. As the selection moves, the source location of the selected node is shown in another window, without leaving the diagram, and highlighted with `codeql-follow-source-face`. Set `codeql-graph-follow-source` to nil to turn this off.

`M-x RET codeql-view-cfg RET` shows the control flow graph of the function at point in a database source archive file, like the vscode extension's CFG viewer. It runs the printCfg query of the database language's library pack, which is available for e.g. C/C++, C#, Java, Python, Ruby and Swift. For JavaScript, which ships no printCfg query, `emacs-codeql` uses its own bundled query from the `queries` directory, so make sure your package recipe includes it (e.g. `:files (:defaults "bin" "queries")`). In text diagrams, the innermost node at point is selected when the graph is shown; graphs that don't know a position open on their first node with edges.

`M-x codeql-results-path-graph` in a results buffer shows the paths of the path-problem result at point as a graph, with its sources at the top and its sink at the bottom. Steps at the same location are a single node, so you can see where the paths of a result part ways and join again. With point on a step of a path, its node is selected.

![screenshot](img/codeql-ast-viewer.png?raw=true "emacs-codeql")

There is AST xref support bound to `M->` in any database source file that also has an active AST viewer buffer open.

### Query X-Ray

`codeql-xray` (`x` in `codeql-command-map`) compiles the query with `codeql query compile --dump-dil --dump-ra` and shows beside it, like [Compiler Explorer](https://godbolt.org), the optimized DIL and RA of the predicates, classes and select clause of the query, without the ones of the libraries, in three columns: the query, its DIL and its RA. With `codeql-xray-layout` set to `single`, one column shows either dump, starting with `codeql-xray-kind`. Running `codeql-xray` again in the query buffer closes the x-ray.

Each definition and its code have the same background color, `codeql-xray-1` to `codeql-xray-6`. Moving point over any of them highlights the definition and its code in all columns with `codeql-xray-active`, scrolling the others into view. A definition the compiler inlined, or dropped for being unused, is marked at the end of its line with the dumps it has no code in, like `no DIL or RA: unused`, and the definitions of the query that it went into, like `no DIL or RA: inlined into select`. Point on an inlined class also highlights the types of the variables the DIL still names it in, like `/* Query::Class */`.

The many relations of a module the query instantiates, like `module Flow = TaintTracking::Global<Config>;`, belong to its alias and fold into one line per alias, like `▸ Flow  ·  1114 blocks  ·  TaintTracking::Global<Config>  ·  o opens`. Point on such an alias also highlights the DIL types naming the module it instantiates in the other code, like the variables of the select clause. Saving the query compiles it again; the header line shows how many blocks of the dump are the query's and how long compiling took. When the query doesn't compile, the columns list the compiler's messages.

In the x-ray columns:

| Key | Evil | Action |
|-----|------|--------|
| `TAB` | `TAB` | go to the other column at the code of the same relation, or else of the same definition; toggle DIL and RA in the single layout |
| `RET` | `RET` | go to the definition of the block at point in the query |
| `M-.`, `.` | `gd` | go to the block of the relation at point, showing a relation of the libraries below the others, which `TAB` then shows in the other column too |
| `n`, `p` | `]]`, `[[` | go to the next or previous block, a closed fold counting as one |
| `o` | `o`, `za`, `zo`, `zc` | open or close the fold of an instantiated module |
| `g` | `gr`, `r` | compile the query again |
| `q` | `q` | close the x-ray |

### Commands

The control panel, a `transient` bound to `codeql-transient-binding` (default `C-c C-d`) in query buffers, shows the query server and active database of the buffer and manages them and other settings:

| Key | Command |
|-----|---------|
| `s` | start (with server options) or stop the query server |
| `i` | inherit the query server of another query buffer |
| `m` | manage the running query servers |
| `d` | register a database |
| `k` | pick a known database from the history |
| `u` | remove a stale database lock |
| `P` | max paths of path problem results |
| `D` | `codeql-doctor` |

It doesn't run anything. Queries are run with the commands of `codeql-command-map`, bound to `codeql-command-binding` (default `C-c C-q`, set it to `nil` to bind the commands yourself):

| Key | Command |
|-----|---------|
| `r` | `codeql-query-server-run-query` |
| `e` | `codeql-query-server-quick-eval` |
| `p` | `codeql-query-server-quick-eval-predicate` |
| `n` | `codeql-query-server-quick-eval-count` |
| `c` | `codeql-query-server-cancel-query` |
| `h` | `codeql-query-history` |
| `C` | `codeql-query-history-compare` |
| `t` | `codeql-query-performance` |
| `T` | `codeql-query-performance-compare` |
| `l` | `codeql-load-sarif` |
| `v` | `codeql-mrva` |
| `f` | `codeql-database-open-source-archive-file` |
| `g` | `codeql-database-grep` |
| `R` | `codeql-repl` |
| `E` | `codeql-repl-send-region` |
| `x` | `codeql-xray` |

Commands that need a query server or a database fail with a message naming the command that sets it up.

`codeql-doctor` (`D` on the control panel, or `M-x codeql-doctor` from any buffer) reports on the health of your setup, much like Neovim's `:checkhealth`: the tree-sitter and eglot support, the CodeQL CLI and its version, the gh codeql extension, configured search paths, the external tools (`unzip`, `zipinfo`, graphviz `dot`) on the host of the current buffer, and the query server, database and language server state of the current query buffer.

### Paginated results

Raw (table) result sets with more tuples than `codeql-max-raw-results` (default: 200) are rendered one page at a time, using the pagination support of `codeql bqrs info --paginate-rows` and `codeql bqrs decode --rows --start-at`. Raw results buffers enable `codeql-results-pagination-mode`, which shows the current result set, sort order and page in the header line and provides the following bindings:

| Binding   | Command                            |
|-----------|------------------------------------|
| `C-c C-n` | `codeql-results-next-page`          |
| `C-c C-p` | `codeql-results-previous-page`      |
| `C-c C-j` | `codeql-results-goto-page`          |
| `C-c <`   | `codeql-results-first-page`         |
| `C-c >`   | `codeql-results-last-page`          |
| `C-c C-s` | `codeql-results-sort`               |
| `C-c C-w` | `codeql-results-filter`             |
| `C-c C-v` | `codeql-results-project`            |
| `C-c C-k` | `codeql-results-reset`              |
| `C-c C-r` | `codeql-results-select-result-set`  |

These commands work like `ORDER BY`, `WHERE` and `SELECT` on the whole result set, not just the current page, and they combine: rows are sorted, then filtered, then only the chosen columns are shown. The header line and the results footer show the current sort, filter and columns.

- `codeql-results-sort` sorts by one or more columns, in the order you give them: rows are ordered by the first column, rows that are equal in it by the second, and so on. Columns sort in ascending order; with a prefix argument (`C-u C-c C-s`) you choose the direction of each. Empty input restores the original order. Sorting is done by `codeql bqrs decode --sort-key --sort-direction`, which writes a sorted copy of the result set next to the BQRS file that is reused when sorting the same way again.
- `codeql-results-filter` adds a condition on a column: a row is shown when it meets all conditions. The operators `=`, `!=`, `<`, `<=`, `>` and `>=` compare numerically when both the cell and the value are numbers and as strings otherwise, and `~` and `!~` match a regexp. Entities are compared by their label. With a prefix argument (`C-u C-c C-w`) it removes conditions instead. Filtering decodes all rows of the result set into memory, which are then reused for other filters of the same order.
- `codeql-results-project` shows only the columns you choose, in that order. Filters may still use the hidden columns. Empty input shows all columns.
- `codeql-results-reset` goes back to all rows and columns in the original order.

Sorting and filtering result sets of more than `codeql-results-large-threshold` rows (default: 50000) asks for confirmation first, as they may take a while and a lot of memory. Set it to `nil` to never ask.

Queries can produce more than one result set, e.g. through `query predicate` declarations. The `#select` result set is shown by default, and `codeql-results-select-result-set` switches to another one.

Problem and path-problem queries are paginated as well: when they produce more alerts than `codeql-max-sarif-results` (default: 100), the interpreted SARIF results of all runs are kept in the results buffer and rendered `codeql-max-sarif-results` alerts at a time. The page commands above work the same way; sorting, filtering, choosing columns and result set selection are only available for raw results.

Loading a page that isn't cached requires the query buffer that produced the results to still be live. Raw results, and paginated problem results, are re-rendered from the BQRS file when loaded from query history, so that they can be paged, sorted and filtered again.

Recently visited pages are cached per results buffer, so going back to them is near instant. The number of cached pages is controlled by `codeql-results-page-cache-size` (default: 50, set to 0 to disable).

### Result locations as diagnostics

`M-x codeql-results-diagnostics-mode` in a results buffer underlines the source locations it links to, using Flymake, in the database source archive files they point into. This works for raw, `problem` and `path-problem` results, and for results reopened from query history.

- Raw result rows and the locations of problems are warnings. Their messages are the row, with column names, or the problem message.
- Path steps and the related locations of problem messages are notes.

The diagnostics follow the results buffer: they are updated when you change pages, and removed when you disable the mode or kill the buffer. Paginated results only show the locations of the current page. Files that are opened later, for example by following a result link, get their diagnostics right away, and the usual Flymake commands such as `flymake-goto-next-error` and `flymake-show-buffer-diagnostics` work as normal. To step through alerts and their related locations across files, see [Navigating between alerts](#navigating-between-alerts).

Flymake is turned on in the source files that need it, and turned off again when no diagnostics remain, unless it was already on. Set `codeql-results-diagnostics` to `t` to enable `codeql-results-diagnostics-mode` in every new results buffer.

### TRAMP support

`emacs-codeql` is fully TRAMP compatible, which means you can edit a query file over TRAMP and as long as `emacs-codeql` can find, or is told where to find, the codeql cli installation on the remote end, everything will work just as if you were working locally. Yes, this means you can develop codeql queries without any locally installed dependencies from your emacs. Science.

![screenshot](img/codeql-over-tramp.png?raw=true "emacs-codeql")

On emacs 28.1+, TRAMP version (2.5.2+) provides a fairly trouble free experience on Linux even with the LSP enabled, at least in my experience. On emacs 27.2, with the older version of TRAMP, I've had less luck with the LSP experience, but the query server performs fine over TRAMP. `emacs-codeql` will ask for confirmation to enable the LSP when it detects it is running in a remote context. When in doubt, keep it disabled.

The remote query server and CLI server each get their own ssh connection, separate from the one TRAMP uses for file access, so expect an extra login (or password prompt, if you don't use ssh keys) when they start. Sharing TRAMP's connection lets unread server output stall TRAMP and freeze emacs. Startup waits up to `codeql-remote-server-ready-timeout` seconds for a remote server to come up.

For optimal performance over TRAMP, especially if you're expecting very large (multiple thousands) of result sets, I recommend the following settings:

```elisp
;; be ok with large process outputs
(setq read-process-output-max (* 1024 1024))

;; disable file cache, vc registration in tramp
(setq remote-file-name-inhibit-cache nil)
(setq vc-ignore-dir-regexp
      (format "%s\\|%s"
              vc-ignore-dir-regexp
              tramp-file-name-regexp))

;; shush tramp, shush
(setq tramp-verbose 1)

;; ensure projectile doesn't trigger tramp ops
(setq projectile-mode-line-function (lambda () "Projectile"))
```

### GitHub Codespaces access over TRAMP

I recommend using the `codespaces.el` [package](https://github.com/patrickt/codespaces.el), which provides convenient TRAMP support for GitHub codespaces.

With this package in place, you can just TAB to get a list of your available Codespaces when opening a `/ghcs:` prefixed file.

### Language Server Protocol

`emacs-codeql` performs very well with `eglot`. Due to the codeql language server relying on `workspaceFolders` support, `eglot 20220326.2143` or newer is required from MELPA, which includes the basic project-root based `workspaceFolders` introduced in: https://github.com/joaotavora/eglot/commit/9eb9353fdc15c91a66ef8f4e53e18b22aa0870cd and a compatible version of `eglot` ships with Emacs 29+ by default. An eglot configuration for the CodeQL LSP is included in `emacs-codeql` and controlled by the `codeql-configure-eglot-lsp` variable.

`emacs-codeql` has not been tested in conjunction with `lsp-mode`.

#### LSP over TRAMP

While the recommended LSP client, `eglot`, does function over TRAMP, running LSP over TRAMP can be very quirky and laggy unless you're on the latest emacs and TRAMP versions. Slow server initialization can be blocking to the point of full freezes. When operating in a TRAMP context, `emacs-codeql` will ask you if you want to enable the LSP client, unless you reaaaally want it, I recommend disabling it for remote editing and query debugging.

The codeql query server, while also running jsonrpc over stdio, is not tied to a direct editor feedback loop, so it is a much more pleasant experience over TRAMP, so all local functionality is enabled and available.

Having said that, on emacs 28.1+, TRAMP version (2.5.2+) provides a fairly trouble free experience on Linux at least even with LSP enabled remotely.

## Advanced Configuration

### Custom search paths

You can use [`.config/codeql/config`](https://codeql.github.com/docs/codeql-cli/specifying-command-options-in-a-codeql-configuration-file/) for your custom codeql cli search path configurations. This allows for more straightforward standard search path deconfliction between local and remote query contexts. Under normal circumstances, i.e. when developing using the recommended CodeQL pack and/or workspace methodology, you should not have to configure any custom search paths and `emacs-codeql` will automatically resolve any required paths.

The `codeql-search-paths` variable in `emacs-codeql` exists purely to provide you with search path precedence control. Unless you're wanting to override any of the default qlpacks from locations outside of the current project root, the existing and default value of '("./") suffices.

`codeql-search-paths` entries are expanded in the context of their location, so if you do want to configure search paths that work across both local and remote systems, you're able to e.g. use a standard "~/path" notation, which will expand to the correct absolute path in the context of the remote or local system via TRAMP.

### Persistent CLI server

CodeQL CLI commands that `emacs-codeql` runs on your behalf, such as `codeql bqrs decode` for rendering results and `codeql resolve` for query and database metadata, are sent to a long-running `codeql execute cli-server` process. This avoids paying the JVM startup cost on every command, which e.g. makes loading a new page of paginated results noticeably faster.

A CLI server is started on demand for each CLI and project root, both locally and over TRAMP, and is shut down when the last query buffer that uses it is killed. You can shut down all CLI servers with `M-x codeql-cli-servers-shutdown`, or disable the CLI server altogether, falling back to running a new CLI process for every command:

```elisp
(setq codeql-use-cli-server nil)
```


### Custom tree-sitter artifacts

#### Emacs 29 and newer

On Emacs 29 and newer, with `tree-sitter` support enabled, you can use the `treesit-install-language-grammar` function to install the required ql artifact. You can either invoke `M-x treesit-install-language-grammar RET` and provide https://github.com/tree-sitter/tree-sitter-ql interactively, or programmatically you can run:

```elisp
(let ((treesit-language-source-alist
             '((ql . ("https://github.com/tree-sitter/tree-sitter-ql"
                      nil
                      nil
                      nil)))))
        (treesit-install-language-grammar 'ql))
```

On first use `emacs-codeql` will offer to run the above snippet if the ql tree-sitter grammar artifact is not yet installed on your system. Note that this requires a working C compiler (e.g. gcc) is present in your `PATH`.

#### Emacs 28 and older

If this package does not contain the required `tree-sitter-langs` artifacts for your system, or you simply do not trust the binary artifacts I provided, you will have to build your own.

Follow the [tree-sitter-langs documentation](https://github.com/anticomputer/tree-sitter-langs-1) for detailed instructions on how to build such an artifact.

In a nutshell:

1. Install cask.
2. run `cask install` for my fork (`git clone --branch anticomputer-ql git@github.com:/anticomputer/tree-sitter-langs-1`) of `tree-sitter-langs` from its project root.
3. Download a copy of the [binary release](https://github.com/tree-sitter/tree-sitter/releases/tag/v0.19.5) of `tree-sitter` and put it in your `PATH` somewhere. `tree-sitter` version <0.20 is required due to a breaking change in >= 0.20, I use 0.19.5.
4. Compile the QL support using `script/compile ql` from `tree-sitter-langs` project root, note that this also has `nodejs` as a dependency.

If you're on a Mac, you'll also need to set `EMACSDATA` and `EMACSLOADPATH` correctly and symlink `emacs` into your `PATH` somewhere, e.g when using MacPorts Emacs.app:

```
ln -s /Applications/MacPorts/EmacsMac.app/Contents/MacOS/Emacs ~/bin/emacs
EMACSDATA=/Applications/MacPorts/EmacsMac.app/Contents/Resources/etc EMACSLOADPATH=/Applications/MacPorts/EmacsMac.app/Contents/Resources/lisp cask install
EMACSDATA=/Applications/MacPorts/EmacsMac.app/Contents/Resources/etc EMACSLOADPATH=/Applications/MacPorts/EmacsMac.app/Contents/Resources/lisp script/compile ql
```

On M1 Macs, if you don't want to use the pre-packaged artifact, you're able to use the x86_64 `tree-sitter` 0.19.5 binary thanks to Rosetta, but you'll have to compile the `ql.dylib` yourself out of the `tree-sitter-langs` fork with an arch-appropriate compiler.

To prepare the pre-packaged artifact on an M1 Mac I use the following:

```
$ cd ~/tree-sitter-langs-fork/repos/ql
$ tree-sitter generate
$ gcc -o ql.dylib --shared src/parser.c -I./src
$ cp ql.dylib ~/.emacs.d/elpa/tree-sitter-langs*/bin/
```

Alternatively you can compile `tree-sitter` 0.19.5 from scratch on an M1 mac by checking out the v0.19.5 tag of https://github.com/tree-sitter/tree-sitter and using `cargo` to build the `tree-sitter` cli, e.g. `cd cli && cargo install --path .`, which will get you an M1 build of `tree-sitter` for the proper architecture, but personally I just compile `ql.dylib` myself after using the x86_64 `tree-sitter` binary for `tree-sitter generate`. You can find more suggestions and alternatives for dealing with M1 Macs in https://github.com/emacs-tree-sitter/elisp-tree-sitter/issues/88

After building the QL artifact(s) for the architectures and platforms you need to support, you'll want to grab `bin/ql.*` and move those into `~/.emacs.d/elpa/tree-sitter-langs*/bin/` and restart emacs.

QL syntax highlighting and indentation should now work fine.

## Running the tests

The regression tests in `test/` don't need the CodeQL CLI:

```
emacs -Q --batch -L . -l test/emacs-codeql-test.el -f ert-run-tests-batch-and-exit
```

The org-ql tests are skipped unless org-ql and its dependencies are on the `load-path` (add them with `-L`). The session, REPL and Org Babel tests are skipped unless the tree-sitter `ql` grammar is installed.

## Known Quirks

### The very first run of a newly created query file compiles but does not actually run

You can re-run the query and it will execute fine on the second run and any subsequent runs against any other database. Seemingly on the very first run of a new query file the query server may not report success on compilation completion. This happens only for the first run of a newly created query file. I'm debugging this still, but it's a rare enough event to not cause too much friction. It also works fine across restarts of emacs and for any iterations on the actual contents of the query after the very first compilation.

The symptom of this is the last message displayed remaining on `[ql/progressUpdated] step 1000 -> Compiling` and things seem to not progress further. Re-running the query at this point should then complete it fine.

### Sometimes running a remote query over TRAMP gets "stuck"

Currently `emacs-codeql` uses synchronous shell commands to invoke the codeql cli with various tasks, ranging from meta data gathering to result parsing. While these commands are generally short lived, and longer tasks such as query compilation and evaluation are handled by the query server asynchronously, on rare occasion one of the synchronous commands may block emacs, due to TRAMP quirks. This is known behavior, and I'm thinking about a more asynchronous design for the shell command handling. In practice this does not happen so frequently that it causes too much friction, but buyer beware when venturing into remote contexts.

When in doubt `C-g` is your friend. If you'd like to see what's happening under the covers `(setq tramp-verbose 6)` and watch the TRAMP debug buffer with some popcorn at hand.

### TRAMP sometimes returns unexpected data in buffers or complains about reentrancy

The code has some reentrancy issues currently which makes the TRAMP support a little flaky if you're spamming a ton of operations rapidly. I'm working on resolving these for a more stable experience, as well as looking into how to improve the LSP experience over TRAMP as well on older versions of emacs and TRAMP.

If you see `error in process filter: peculiar error: "Forbidden reentrant call of Tramp"` on TRAMP 2.5.2, I'm aware, and looking into resolving the reentrancy where possible. TRAMP is very chatty, so we need some better synchronization primitives to prevent launching into TRAMP operations while it's already in the middle of e.g. performing a file stat.

In the meantime, you should be able to just repeat whatever action was interrupted by the error without causing any issues.

## TODO

- `emacs-codeql` does NOT yet provide compressed database support, however this is underway and should be part of the first version, for now you should manually `unzip` a CodeQL database to enable it for use with `emacs-codeql`.

## Acknowledgements

This package was heavily inspired by, and in some cases directly ported from, [Alvaro Muñoz](https://github.com/pwntester)'s [codeql.nvim](https://github.com/pwntester/codeql.nvim) I'd like to thank him for dragging me into a continuously good natured editor arms race. He solved most of the hard problems in lua, and a lot of this package stands on the shoulders of his prior art. I also stole his `README.md` in an attempt at tongue in cheek comedy. I know it took me two years to actually start this project, but here we are sir :P

A lot of the fundamental ideas behind this package were first implemented by [Esben Sparre Andreasen](https://github.com/esbena). Esben is a seasoned CodeQL engineer and his deep QL knowledge and early work on emacs codeql support were a big inspiration to finally revive this effort. While this package no longer resembles Esben's original (private) major mode, the very first iteration of `emacs-codeql` was heavily drafted on top of his work, and his original design ideas such as the org-mode based result rendering are very much carried forward in this implementation.

I'd also like to acknowledge the [eglot](https://github.com/joaotavora/eglot) project and its maintainers. The eglot project has solved many of the problems that pop up when dealing with asynchronous jsonrpc over stdio in a synchronous emacs world. Their various tips and tricks, sprinkled throughout the `eglot` codebase as well as the `jsonrpc` library itself, were consistently the answers to most of the blocking issues that popped up while writing `emacs-codeql`, especially when dealing with TRAMP quirks. They were also very responsive in getting the `workspaceFolders` support required by the codeql langserver in place.

Last, but not least, I want to acknowledge the omnipresent [Shohei YOSHIDA](https://github.com/syohex). While I was writing this code I found myself doing an inordinate amount of destructuring binds to chew through the various json objects involved in juggling the query server protocol as well as the local result parsing. In a pursuit of legibility, I came across https://github.com/syohex/emacs-json-pointer which is a small but fantastically useful piece of code for clear json object access in elisp. Since it is not available on MELPA, it is bundled as part of this package. All original copyright and licensing as designated by Shohei YOSHIDA applies, and I'd like to thank them for their continued contributions across the elisp ecosystem.

## Demo

You can find an early feature demo below, note that it is probably out of sync with the current state of the project.

[![emacs-codeql demo](https://img.youtube.com/vi/wP9fU9gVGS4/0.jpg)](https://www.youtube.com/watch?v=wP9fU9gVGS4)
