# cindex-uefilter

Drop-in fork of [google/codesearch](https://github.com/google/codesearch)'s
`cindex` that adds one feature: `-files-from FILE`. Reads absolute paths
(one per line) from `FILE` — or stdin if `FILE` is `-` — and indexes
exactly those files. Skips the directory walk.

Why we need it: Unreal Engine source trees mix code with multi-GB
generated junk (graphify-out caches, Intermediate, DerivedDataCache,
etc.). cindex's directory walker doesn't support exclude patterns, so
indexing a UE workspace would include 80k+ junk JSON files. We already
maintain a clean file list as part of `:UEPrepare` (used by GTAGS); this
fork lets us feed that same list directly into the trigram index.

## Build

macOS/Linux installs both this fork and the pinned query binary:

```sh
sh scripts/install_csearch.sh
```

Run that command from the Neovim configuration root. Windows setup installs
the same pair from `scripts/install_windows.ps1`.

To build only this fork manually:

```pwsh
$env:GOPROXY = 'https://goproxy.cn,direct'
$env:GOSUMDB = 'off'
go install ./...
# binary lands in $GOBIN (default %USERPROFILE%\go\bin)
```

## Incremental merge semantics

Without `-reset` the tool merges into the existing index. codesearch's `Merge`
gives every staged root `P` ownership of all old names in
`[P, P-with-last-byte-incremented)`, which has two consequences the tool handles:

- `-delete-from FILE` lists files that are gone; staging them with no content
  removes them from the merged index, so deletions need no full rebuild.
- A root such as `Foo.h` also shadows an untouched `Foo.hpp`. Those siblings are
  detected from the master index and re-indexed from disk, instead of being
  silently dropped by the merge.

Verified on a real 182k-file Unreal Engine list: 300 deletions plus 237 touched
files merged in ~2.4s, byte-equivalent (names and every trigram posting list) to
a full reset of the remaining set, which took ~87s.

## Use

```pwsh
$env:CSEARCHINDEX = '<PROJ_DRIVE>\UEProj\.cache\nvim-ue\csearch.idx'
cindex-uefilter -reset -files-from <PROJ_DRIVE>\UEProj\.cache\nvim-ue\workspace_all.txt
csearch -n FRDGBuilder
```

Without `-reset`, each listed file is also recorded as an exact merge path.
That lets codesearch atomically add new files and replace the old trigrams for
modified files. Deletions are not representable by upstream `index.Merge` and
must trigger a reset build.

When `-files-from` is omitted, behaves identically to upstream `cindex`.
