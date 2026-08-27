package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

const rawIndexTrailerMagic = "\ncsearch trailr\n"
const rawPostEntrySize = 3 + 4 + 4

type rawIndex struct {
	data      []byte
	pathData  uint32
	nameData  uint32
	postData  uint32
	nameIndex uint32
	postIndex uint32
	numName   int
	numPost   int
}

func openRawIndex(file string) (*rawIndex, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	if len(data) < 4*4+len(rawIndexTrailerMagic) || string(data[len(data)-len(rawIndexTrailerMagic):]) != rawIndexTrailerMagic {
		return nil, os.ErrInvalid
	}
	n := uint32(len(data) - len(rawIndexTrailerMagic) - 5*4)
	ix := &rawIndex{data: data}
	ix.pathData = ix.uint32(n)
	ix.nameData = ix.uint32(n + 4)
	ix.postData = ix.uint32(n + 8)
	ix.nameIndex = ix.uint32(n + 12)
	ix.postIndex = ix.uint32(n + 16)
	ix.numName = int((ix.postIndex-ix.nameIndex)/4) - 1
	ix.numPost = int((n - ix.postIndex) / rawPostEntrySize)
	return ix, nil
}

func (ix *rawIndex) slice(off uint32, n int) []byte {
	o := int(off)
	if n < 0 {
		return ix.data[o:]
	}
	return ix.data[o : o+n]
}

func (ix *rawIndex) uint32(off uint32) uint32 {
	return binary.BigEndian.Uint32(ix.slice(off, 4))
}

func (ix *rawIndex) str(off uint32) []byte {
	data := ix.slice(off, -1)
	end := bytes.IndexByte(data, 0)
	if end < 0 {
		return nil
	}
	return data[:end]
}

func (ix *rawIndex) Paths() []string {
	off := ix.pathData
	var out []string
	for {
		s := ix.str(off)
		if len(s) == 0 {
			return out
		}
		out = append(out, string(s))
		off += uint32(len(s) + 1)
	}
}

func (ix *rawIndex) Name(fileid uint32) string {
	off := ix.uint32(ix.nameIndex + 4*fileid)
	return string(ix.str(ix.nameData + off))
}

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
