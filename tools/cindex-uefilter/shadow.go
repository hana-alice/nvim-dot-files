package main

// Incremental merge support.
//
// index.Merge(dst, master, delta) treats every root path P staged in the delta
// as owning ALL master names in [P, P with its last byte incremented): those
// master entries are dropped and replaced by whatever the delta indexed under
// P. Two consequences, both verified against codesearch v1.2.0:
//
//   - A root that names a deleted file and indexes nothing removes that file
//     from the merged index. This is how -delete-from works without a reset.
//   - A root "Foo.h" also shadows an untouched "Foo.hpp". Such siblings must be
//     re-staged from disk, or an incremental add silently drops them.

import (
	"encoding/binary"
	"fmt"
	"os"
	"sort"

	"github.com/google/codesearch/index"
)

// indexNameCount reads only the trailer: index.Index keeps its name count
// private, and Name(i) past the end is undefined.
func indexNameCount(file string) (int, error) {
	f, err := os.Open(file)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return 0, err
	}
	trailer := int64(5*4 + len(rawIndexTrailerMagic))
	if info.Size() < trailer {
		return 0, fmt.Errorf("%s: index too small", file)
	}
	buf := make([]byte, trailer)
	if _, err := f.ReadAt(buf, info.Size()-trailer); err != nil {
		return 0, err
	}
	if string(buf[20:]) != rawIndexTrailerMagic {
		return 0, fmt.Errorf("%s: bad index trailer", file)
	}
	nameIndex := binary.BigEndian.Uint32(buf[12:16])
	postIndex := binary.BigEndian.Uint32(buf[16:20])
	return int((postIndex-nameIndex)/4) - 1, nil
}

// shadowLimit mirrors index.Merge: the exclusive end of the range a root owns.
func shadowLimit(root string) string {
	return root[:len(root)-1] + string(root[len(root)-1]+1)
}

// shadowedNames returns the master names inside [root, shadowLimit(root)).
func shadowedNames(name func(int) string, count int, root string) []string {
	limit := shadowLimit(root)
	lo := sort.Search(count, func(i int) bool { return name(i) >= root })
	var out []string
	for i := lo; i < count; i++ {
		n := name(i)
		if n >= limit {
			break
		}
		out = append(out, n)
	}
	return out
}

// closeOverShadows grows the staged root set until every master name it
// shadows is itself staged. Callers re-index the returned extras from disk;
// an extra that no longer exists is dropped, which matches reality.
func closeOverShadows(name func(int) string, count int, roots []string) (all []string, extras []string) {
	staged := make(map[string]struct{}, len(roots))
	for _, r := range roots {
		staged[r] = struct{}{}
	}
	pending := append([]string{}, roots...)
	for len(pending) > 0 {
		root := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if root == "" {
			continue
		}
		for _, n := range shadowedNames(name, count, root) {
			if _, ok := staged[n]; ok {
				continue
			}
			staged[n] = struct{}{}
			extras = append(extras, n)
			pending = append(pending, n)
		}
	}
	for r := range staged {
		all = append(all, r)
	}
	sort.Strings(all)
	sort.Strings(extras)
	return all, extras
}

// incrementalRoots computes the delta's roots and the full set of files to
// index for a safe merge into master.
func incrementalRoots(master string, files, deletes []string) (roots, toIndex []string, err error) {
	count, err := indexNameCount(master)
	if err != nil {
		return nil, nil, err
	}
	ix := index.Open(master)
	name := func(i int) string { return ix.Name(uint32(i)) }
	seed := uniqueSortedStrings(append(append([]string{}, files...), deletes...))
	roots, extras := closeOverShadows(name, count, seed)
	toIndex = append([]string{}, files...)
	for _, extra := range extras {
		if info, statErr := os.Stat(extra); statErr == nil && !info.IsDir() {
			toIndex = append(toIndex, extra)
		}
	}
	return roots, uniqueSortedStrings(toIndex), nil
}
