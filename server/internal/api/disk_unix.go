//go:build unix

package api

import "syscall"

// diskSpace returns free and total bytes of the filesystem holding dir.
func diskSpace(dir string) (free, total uint64) {
	var st syscall.Statfs_t
	if syscall.Statfs(dir, &st) != nil {
		return 0, 0
	}
	return uint64(st.Bavail) * uint64(st.Bsize), uint64(st.Blocks) * uint64(st.Bsize)
}
