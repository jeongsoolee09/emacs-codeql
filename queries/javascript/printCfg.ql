/**
 * @name Print CFG
 * @description Produces a representation of the control flow graph of the
 *              function or toplevel at the selected position of a file.
 * @id js/print-cfg
 * @kind graph
 * @tags ide-contextual-queries/print-cfg
 */

import javascript
import IDEContextual

external string selectedSourceFile();

external int selectedSourceLine();

external int selectedSourceColumn();

/** Holds if `container` spans the selected position of the selected file. */
private predicate spansSelectedPosition(StmtContainer container) {
  exists(int startLine, int startColumn, int endLine, int endColumn, int line, int column |
    container.getFile() = getFileBySourceArchiveName(selectedSourceFile()) and
    container.getLocation().hasLocationInfo(_, startLine, startColumn, endLine, endColumn) and
    line = selectedSourceLine() and
    column = selectedSourceColumn()
  |
    (startLine < line or startLine = line and startColumn <= column) and
    (line < endLine or line = endLine and column <= endColumn)
  )
}

/** Gets the innermost function or toplevel at the selected position. */
private StmtContainer selectedContainer() {
  spansSelectedPosition(result) and
  not exists(StmtContainer inner |
    spansSelectedPosition(inner) and inner.getEnclosingContainer+() = result
  )
}

query predicate nodes(ControlFlowNode node, string key, string value) {
  node.getContainer() = selectedContainer() and
  // A declaration's name is bound by hoisting and never evaluated, so it has no edges.
  not node = any(Function f).getIdentifier() and
  key = "semmle.label" and
  value = node.toString()
}

query predicate edges(ControlFlowNode pred, ControlFlowNode succ) {
  nodes(pred, _, _) and
  succ = pred.getASuccessor()
}
