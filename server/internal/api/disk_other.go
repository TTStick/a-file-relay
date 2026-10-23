//go:build !unix

package api

func diskSpace(dir string) (free, total uint64) { return 0, 0 }
