#!/bin/sh
# A CI recipe for a Varis project (AUTHORING_TOOLS_PLAN stage A6): run it from the project root,
# with the `varis` executable on PATH or named by $VARIS. It fails (non-zero status) when
#
#   * a file does not compile, or the checks find an error, or the engine rejects the content
#     (`varis check`, which also loads the project's entry module),
#   * an author test fails (`varis test`), or
#   * the message catalog is out of date (`varis l10n extract --check`), when the project keeps one.
#
# Diagnostics are `file:line:column: severity: message [code]` and name the storylet or choice.
VARIS=${VARIS:-varis}
status=0
"$VARIS" check || status=1
if { [ -f project.varis ] && grep -q 'tests' project.varis; } || { [ -f project.lua ] && grep -q 'tests' project.lua; }; then
    "$VARIS" test || status=1
fi
if [ -f l10n/source.json ]; then
    "$VARIS" l10n extract --check || status=1
fi
exit $status
