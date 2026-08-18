// cindex-uefilter is a drop-in replacement for cindex that adds
// -files-from <file> mode: read absolute paths one per line from <file>
// (or stdin if <file> is "-") and index exactly those files.
//
// All other cindex flags work identically. The original walk behavior
// is preserved when -files-from is not given.
//
// Built locally; lives next to cindex in $GOBIN.

package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime/pprof"
	"sort"
	"strings"

	"github.com/google/codesearch/index"
)

var usageMessage = `usage: cindex-uefilter [-list] [-reset] [-files-from FILE] [path...]

Like cindex, but with -files-from FILE: read absolute file paths
(one per line) from FILE — or from stdin if FILE is "-" — and index
exactly those files. Skips the walk entirely. Other cindex flags work
identically.
`

func usage() {
	fmt.Fprint(os.Stderr, usageMessage)
	os.Exit(2)
}

var (
	listFlag      = flag.Bool("list", false, "list indexed paths and exit")
	resetFlag     = flag.Bool("reset", false, "discard existing index")
	verboseFlag   = flag.Bool("verbose", false, "print extra information")
	cpuProfile    = flag.String("cpuprofile", "", "write cpu profile to this file")
	filesFromFlag = flag.String("files-from", "", "read paths from FILE (or stdin if -)")
)

func uniqueSortedStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	sort.Strings(values)
	out := values[:0]
	for _, value := range values {
		if value == "" {
			continue
		}
		if len(out) > 0 && out[len(out)-1] == value {
			continue
		}
		out = append(out, value)
	}
	return out
}

func readFilesFromList(name string) ([]string, int, error) {
	var (
		scanner *bufio.Scanner
		file    *os.File
		err     error
	)
	if name == "-" {
		scanner = bufio.NewScanner(os.Stdin)
	} else {
		file, err = os.Open(name)
		if err != nil {
			return nil, 0, fmt.Errorf("open %s: %w", name, err)
		}
		defer file.Close()
		scanner = bufio.NewScanner(file)
	}

	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	seen := make(map[string]struct{})
	files := make([]string, 0)
	skipped := 0
	for scanner.Scan() {
		path := strings.TrimSpace(scanner.Text())
		if path == "" {
			continue
		}
		info, statErr := os.Stat(path)
		if statErr != nil || info.IsDir() {
			skipped++
			continue
		}
		if _, ok := seen[path]; ok {
			continue
		}
		seen[path] = struct{}{}
		files = append(files, path)
	}
	if err := scanner.Err(); err != nil {
		return nil, skipped, fmt.Errorf("read %s: %w", name, err)
	}
	return uniqueSortedStrings(files), skipped, nil
}

func filesFromIndexPaths(args, files []string, reset bool) []string {
	if !reset {
		// Merge treats every staged Path as a replacement prefix. Broad CLI
		// roots would therefore delete untouched names from the old index when
		// the files-from list contains only a delta. Exact files are the only
		// safe shadow keys for add mode.
		return uniqueSortedStrings(append([]string{}, files...))
	}
	paths := append([]string{}, args...)
	for i, arg := range paths {
		abs, err := filepath.Abs(arg)
		if err == nil {
			paths[i] = abs
		}
	}
	return uniqueSortedStrings(paths)
}

func main() {
	flag.Usage = usage
	flag.Parse()
	args := flag.Args()

	if *listFlag {
		ix := index.Open(index.File())
		for _, arg := range ix.Paths() {
			fmt.Printf("%s\n", arg)
		}
		return
	}

	if *cpuProfile != "" {
		f, err := os.Create(*cpuProfile)
		if err != nil {
			log.Fatal(err)
		}
		defer f.Close()
		pprof.StartCPUProfile(f)
		defer pprof.StopCPUProfile()
	}

	if *resetFlag && len(args) == 0 && *filesFromFlag == "" {
		os.Remove(index.File())
		return
	}

	master := index.File()
	if _, err := os.Stat(master); err != nil {
		*resetFlag = true
	}
	file := master
	if !*resetFlag {
		file += "~"
	}

	ix := index.Create(file)
	ix.Verbose = *verboseFlag

	// ─── -files-from mode ────────────────────────────────────────────
	if *filesFromFlag != "" {
		files, skipped, err := readFilesFromList(*filesFromFlag)
		if err != nil {
			log.Fatal(err)
		}

		ix.AddPaths(filesFromIndexPaths(args, files, *resetFlag))

		log.Printf("indexing from %s", *filesFromFlag)
		count := 0
		for _, path := range files {
			ix.AddFile(path)
			count++
			if count%5000 == 0 {
				log.Printf("indexed %d files...", count)
			}
		}
		log.Printf("indexed %d files (%d skipped)", count, skipped)
	} else {
		// ─── Original walk mode (unchanged from cindex) ──────────────
		if len(args) == 0 {
			ix2 := index.Open(index.File())
			for _, arg := range ix2.Paths() {
				args = append(args, arg)
			}
		}
		for i, arg := range args {
			a, err := filepath.Abs(arg)
			if err != nil {
				log.Printf("%s: %s", arg, err)
				args[i] = ""
				continue
			}
			args[i] = a
		}
		sort.Strings(args)
		for len(args) > 0 && args[0] == "" {
			args = args[1:]
		}
		ix.AddPaths(args)
		for _, arg := range args {
			log.Printf("index %s", arg)
			filepath.Walk(arg, func(path string, info os.FileInfo, err error) error {
				if _, elem := filepath.Split(path); elem != "" {
					if elem[0] == '.' || elem[0] == '#' || elem[0] == '~' || elem[len(elem)-1] == '~' {
						if info != nil && info.IsDir() {
							return filepath.SkipDir
						}
						return nil
					}
				}
				if err != nil {
					log.Printf("%s: %s", path, err)
					return nil
				}
				if info != nil && info.Mode()&os.ModeType == 0 {
					ix.AddFile(path)
				}
				return nil
			})
		}
	}

	log.Printf("flush index")
	ix.Flush()

	if !*resetFlag {
		log.Printf("merge %s %s", master, file)
		index.Merge(file+"~", master, file)
		os.Remove(file)
		os.Rename(file+"~", master)
	}
	log.Printf("done")
}
