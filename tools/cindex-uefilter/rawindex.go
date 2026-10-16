package main

// Minimal read-only view of the codesearch v1 index format, used to find the
// names an incremental merge would shadow. index.Index does not export its
// name count, and reading past it is undefined.

import (
	"bytes"
	"encoding/binary"
	"os"
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
