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
		var rd *bufio.Scanner
		if *filesFromFlag == "-" {
			rd = bufio.NewScanner(os.Stdin)
		} else {
			f, err := os.Open(*filesFromFlag)
			if err != nil {
				log.Fatalf("open %s: %v", *filesFromFlag, err)
			}
			defer f.Close()
			rd = bufio.NewScanner(f)
		}
		// Allow long lines (UE paths can be deep).
		rd.Buffer(make([]byte, 1024*1024), 1024*1024)

		// Treat any path roots from CLI as auxiliary "indexed paths"
		// that show up in cindex -list (so users know what's covered).
		paths := args
		for i, arg := range paths {
			abs, err := filepath.Abs(arg)
			if err == nil {
				paths[i] = abs
			}
		}
		sort.Strings(paths)
		ix.AddPaths(paths)

		log.Printf("indexing from %s", *filesFromFlag)
		count := 0
		skipped := 0
		for rd.Scan() {
			path := strings.TrimSpace(rd.Text())
			if path == "" {
				continue
			}
			info, err := os.Stat(path)
			if err != nil || info.IsDir() {
				skipped++
				continue
			}
			ix.AddFile(path)
			count++
			if count%5000 == 0 {
				log.Printf("indexed %d files...", count)
			}
		}
		if err := rd.Err(); err != nil {
			log.Fatalf("read %s: %v", *filesFromFlag, err)
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
