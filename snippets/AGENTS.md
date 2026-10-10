# snippets/ — audited editor templates

Inherits ../AGENTS.md. These are Blink's existing native snippet source assets.
Keep JSON valid and placeholders editable. UE templates must be checked against
the selected engine's headers/UHT; do not silently import version-specific RPC
or obsolete generated macros. Preserve ordinary C++ snippets and test expansion,
field navigation and undo via the ide_editing filter. No new snippet dependency.
