package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

func (ix *rawIndex) PostingList(trigram uint32) []uint32 {
	data := ix.slice(ix.postIndex, rawPostEntrySize*ix.numPost)
	i := sort.Search(ix.numPost, func(i int) bool {
		i *= rawPostEntrySize
		t := uint32(data[i])<<16 | uint32(data[i+1])<<8 | uint32(data[i+2])
		return t >= trigram
	})
	if i >= ix.numPost {
		return nil
	}
	i *= rawPostEntrySize
	t := uint32(data[i])<<16 | uint32(data[i+1])<<8 | uint32(data[i+2])
	if t != trigram {
		return nil
	}
	count := int(binary.BigEndian.Uint32(data[i+3:]))
	offset := binary.BigEndian.Uint32(data[i+7:])
	post := ix.slice(ix.postData+offset+3, -1)
	fileid := ^uint32(0)
	out := make([]uint32, 0, count)
	for count > 0 {
		count--
		delta64, n := binary.Uvarint(post)
		delta := uint32(delta64)
		post = post[n:]
		fileid += delta
		out = append(out, fileid)
	}
	return out
}

func resetFlagsForTest() {
	flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ExitOnError)
	listFlag = flag.CommandLine.Bool("list", false, "list indexed paths and exit")
	resetFlag = flag.CommandLine.Bool("reset", false, "discard existing index")
	verboseFlag = flag.CommandLine.Bool("verbose", false, "print extra information")
	cpuProfile = flag.CommandLine.String("cpuprofile", "", "write cpu profile to this file")
	filesFromFlag = flag.CommandLine.String("files-from", "", "read paths from FILE (or stdin if -)")
	deleteFromFlag = flag.CommandLine.String("delete-from", "", "incremental only: remove the paths listed in FILE from the index")
}

func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_CINDEX_UEFILTER_HELPER") != "1" {
		return
	}

	sep := -1
	for i, arg := range os.Args {
		if arg == "--" {
			sep = i
			break
		}
	}
	if sep < 0 {
		os.Exit(2)
	}

	os.Args = append([]string{os.Args[0]}, os.Args[sep+1:]...)
	resetFlagsForTest()
	main()
	os.Exit(0)
}

func runTool(t *testing.T, indexPath string, args ...string) (string, string) {
	t.Helper()

	cmdArgs := append([]string{"-test.run=TestHelperProcess", "--"}, args...)
	cmd := exec.Command(os.Args[0], cmdArgs...)
	cmd.Env = append(os.Environ(),
		"GO_WANT_CINDEX_UEFILTER_HELPER=1",
		"CSEARCHINDEX="+indexPath,
	)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("runTool(%v) failed: %v\nstdout:\n%s\nstderr:\n%s", args, err, stdout.String(), stderr.String())
	}
	if strings.Contains(stderr.String(), "panic:") {
		t.Fatalf("runTool(%v) panicked:\n%s", args, stderr.String())
	}
	return stdout.String(), stderr.String()
}

func writeFile(t *testing.T, name, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		t.Fatalf("MkdirAll(%s): %v", name, err)
	}
	if err := os.WriteFile(name, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile(%s): %v", name, err)
	}
}

func writeListFile(t *testing.T, name string, paths ...string) {
	t.Helper()
	content := strings.Join(paths, "\n")
	if content != "" {
		content += "\n"
	}
	writeFile(t, name, content)
}

func trigramNames(ix *rawIndex, trigram string) []string {
	ids := ix.PostingList(uint32(trigram[0])<<16 | uint32(trigram[1])<<8 | uint32(trigram[2]))
	names := make([]string, 0, len(ids))
	for _, id := range ids {
		names = append(names, ix.Name(id))
	}
	sort.Strings(names)
	return names
}

func sortedStrings(values []string) []string {
	out := append([]string(nil), values...)
	sort.Strings(out)
	return out
}

func TestFilesFromResetBuildsExactIndex(t *testing.T) {
	tempDir := t.TempDir()
	indexPath := filepath.Join(tempDir, "reset.idx")
	staleFile := filepath.Join(tempDir, "stale.txt")
	freshFile := filepath.Join(tempDir, "fresh file.txt")
	staleList := filepath.Join(tempDir, "stale.list")
	freshList := filepath.Join(tempDir, "fresh.list")

	writeFile(t, staleFile, "stale-marker-aaa\n")
	writeFile(t, freshFile, "fresh-marker-bbb\n")
	writeListFile(t, staleList, staleFile)
	writeListFile(t, freshList, freshFile)

	runTool(t, indexPath, "-reset", "-files-from", staleList)
	runTool(t, indexPath, "-reset", "-files-from", freshList)

	ix, err := openRawIndex(indexPath)
	if err != nil {
		t.Fatalf("openRawIndex(%s): %v", indexPath, err)
	}
	if got, want := ix.Paths(), []string(nil); !reflect.DeepEqual(got, want) {
		t.Fatalf("Paths() = %v, want %v", got, want)
	}
	if got := trigramNames(ix, "sta"); len(got) != 0 {
		t.Fatalf("stale trigram still indexed: %v", got)
	}
	if got, want := trigramNames(ix, "fre"), []string{freshFile}; !reflect.DeepEqual(got, want) {
		t.Fatalf("fresh trigram names = %v, want %v", got, want)
	}
}

func TestFailedResetPreservesPublishedIndex(t *testing.T) {
	tempDir := t.TempDir()
	indexPath := filepath.Join(tempDir, "published.idx")
	source := filepath.Join(tempDir, "keep.cpp")
	list := filepath.Join(tempDir, "files.list")
	writeFile(t, source, "keep-marker\n")
	writeListFile(t, list, source)
	runTool(t, indexPath, "-reset", "-files-from", list)
	before, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=TestHelperProcess", "--", "-reset", "-files-from", filepath.Join(tempDir, "missing.list"))
	cmd.Env = append(os.Environ(), "GO_WANT_CINDEX_UEFILTER_HELPER=1", "CSEARCHINDEX="+indexPath)
	if err := cmd.Run(); err == nil {
		t.Fatal("missing list must fail")
	}
	after, err := os.ReadFile(indexPath)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("failed reset changed published index: %v", err)
	}
}

func TestResetKeepsPublishedIndexWhileReadingInput(t *testing.T) {
	tempDir := t.TempDir()
	indexPath := filepath.Join(tempDir, "published.idx")
	source := filepath.Join(tempDir, "keep.cpp")
	list := filepath.Join(tempDir, "files.list")
	writeFile(t, source, "keep-marker\n")
	writeListFile(t, list, source)
	runTool(t, indexPath, "-reset", "-files-from", list)
	before, _ := os.ReadFile(indexPath)
	cmd := exec.Command(os.Args[0], "-test.run=TestHelperProcess", "--", "-reset", "-files-from", "-")
	cmd.Env = append(os.Environ(), "GO_WANT_CINDEX_UEFILTER_HELPER=1", "CSEARCHINDEX="+indexPath)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer stdin.Close()
	var output bytes.Buffer
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	deadline := time.Now().Add(10 * time.Second)
	for {
		current, err := os.ReadFile(indexPath)
		if err != nil || !bytes.Equal(before, current) {
			t.Fatalf("reader observed unpublished reset bytes: %v", err)
		}
		if _, err := os.Stat(indexPath + "~"); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("writer did not create staging file")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, err := fmt.Fprintln(stdin, source); err != nil {
		t.Fatal(err)
	}
	_ = stdin.Close()
	if err := cmd.Wait(); err != nil {
		t.Fatalf("reset failed: %v: %s", err, output.String())
	}
	if _, err := openRawIndex(indexPath); err != nil {
		t.Fatal(err)
	}
}

func TestFilesFromIncrementalAddReplacesAndAddsWithoutPanic(t *testing.T) {
	tempDir := t.TempDir()
	indexPath := filepath.Join(tempDir, "incremental.idx")
	keepFile := filepath.Join(tempDir, "keep.txt")
	replaceFile := filepath.Join(tempDir, "dir with spaces", "replace file.txt")
	newFile := filepath.Join(tempDir, "new file.txt")
	initialList := filepath.Join(tempDir, "initial.list")
	updateList := filepath.Join(tempDir, "update.list")

	writeFile(t, keepFile, "keep-token-kkk\n")
	writeFile(t, replaceFile, "old-token-ooo\n")
	writeListFile(t, initialList, keepFile, replaceFile)
	runTool(t, indexPath, "-reset", "-files-from", initialList, tempDir)

	writeFile(t, replaceFile, "fresh-token-fff\n")
	writeFile(t, newFile, "new-token-nnn\n")
	writeListFile(t, updateList, newFile, replaceFile, newFile)
	runTool(t, indexPath, "-files-from", updateList, tempDir)

	ix, err := openRawIndex(indexPath)
	if err != nil {
		t.Fatalf("openRawIndex(%s): %v", indexPath, err)
	}
	if got, want := sortedStrings(ix.Paths()), []string{tempDir}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Paths() = %v, want %v", got, want)
	}
	if got, want := trigramNames(ix, "kee"), []string{keepFile}; !reflect.DeepEqual(got, want) {
		t.Fatalf("keep trigram names = %v, want %v", got, want)
	}
	if got := trigramNames(ix, "old"); len(got) != 0 {
		t.Fatalf("old trigram still indexed after replacement: %v", got)
	}
	if got, want := trigramNames(ix, "fre"), []string{replaceFile}; !reflect.DeepEqual(got, want) {
		t.Fatalf("replacement trigram names = %v, want %v", got, want)
	}
	if got, want := trigramNames(ix, "new"), []string{newFile}; !reflect.DeepEqual(got, want) {
		t.Fatalf("new trigram names = %v, want %v", got, want)
	}
	for _, leftover := range []string{indexPath + "~", indexPath + "~~", indexPath + ".bak"} {
		if _, err := os.Stat(leftover); !os.IsNotExist(err) {
			t.Fatalf("unexpected publish leftover %s", leftover)
		}
	}
}

// Merge treats each staged path P as owning every old name in [P, P+1): a
// delta that re-adds "Foo.h" therefore also shadows "Foo.hpp". The tool must
// re-stage such untouched siblings or an incremental add silently drops them.
func TestIncrementalAddKeepsSiblingsSharingAPathPrefix(t *testing.T) {
	tempDir := t.TempDir()
	indexPath := filepath.Join(tempDir, "prefix.idx")
	header := filepath.Join(tempDir, "Foo.h")
	sibling := filepath.Join(tempDir, "Foo.hpp")
	initialList := filepath.Join(tempDir, "initial.list")
	updateList := filepath.Join(tempDir, "update.list")

	writeFile(t, header, "header-token-hhh\n")
	writeFile(t, sibling, "sibling-token-sss\n")
	writeListFile(t, initialList, header, sibling)
	runTool(t, indexPath, "-reset", "-files-from", initialList, tempDir)

	writeFile(t, header, "edited-token-eee\n")
	writeListFile(t, updateList, header)
	runTool(t, indexPath, "-files-from", updateList)

	ix, err := openRawIndex(indexPath)
	if err != nil {
		t.Fatalf("openRawIndex(%s): %v", indexPath, err)
	}
	if got, want := trigramNames(ix, "sib"), []string{sibling}; !reflect.DeepEqual(got, want) {
		t.Fatalf("sibling dropped by prefix shadow: names = %v, want %v", got, want)
	}
	if got, want := trigramNames(ix, "edi"), []string{header}; !reflect.DeepEqual(got, want) {
		t.Fatalf("edited header names = %v, want %v", got, want)
	}
}

// -delete-from removes vanished files from the index without a full reset.
func TestDeleteFromRemovesOnlyListedFiles(t *testing.T) {
	tempDir := t.TempDir()
	indexPath := filepath.Join(tempDir, "delete.idx")
	keep := filepath.Join(tempDir, "keep.cpp")
	gone := filepath.Join(tempDir, "gone.cpp")
	goneSibling := filepath.Join(tempDir, "gone.cpp.inl")
	initialList := filepath.Join(tempDir, "initial.list")
	emptyList := filepath.Join(tempDir, "empty.list")
	deleteList := filepath.Join(tempDir, "delete.list")

	writeFile(t, keep, "keep-token-kkk\n")
	writeFile(t, gone, "gone-token-ggg\n")
	writeFile(t, goneSibling, "inline-token-iii\n")
	writeListFile(t, initialList, keep, gone, goneSibling)
	runTool(t, indexPath, "-reset", "-files-from", initialList, tempDir)

	if err := os.Remove(gone); err != nil {
		t.Fatal(err)
	}
	writeListFile(t, emptyList)
	writeListFile(t, deleteList, gone)
	runTool(t, indexPath, "-files-from", emptyList, "-delete-from", deleteList)

	ix, err := openRawIndex(indexPath)
	if err != nil {
		t.Fatalf("openRawIndex(%s): %v", indexPath, err)
	}
	if got := trigramNames(ix, "gon"); len(got) != 0 {
		t.Fatalf("deleted file still indexed: %v", got)
	}
	if got, want := trigramNames(ix, "kee"), []string{keep}; !reflect.DeepEqual(got, want) {
		t.Fatalf("untouched file names = %v, want %v", got, want)
	}
	if got, want := trigramNames(ix, "inl"), []string{goneSibling}; !reflect.DeepEqual(got, want) {
		t.Fatalf("prefix sibling of deleted file = %v, want %v", got, want)
	}
}
