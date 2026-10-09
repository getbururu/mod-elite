// Command pack writes a mod folder as <id>-<version>.brr the way
// `bururu mod pack` writes it: the allowed files only, sorted, each one
// deflated and dated 2026-01-01 00:00 UTC, so the same files always give
// the same bytes. The release workflow runs it, since it has no Bururu to
// call. It prints name=, version=, files= and sha256= lines.
//
//	go run .github/pack/main.go -out <folder> <mod folder>
package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

// The rules below are Bururu's (internal/mods/pkgfs.go, cmd/bururu/mod_pack.go).

// packTime is every entry's time in a pack.
var packTime = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

const (
	maxZipBytes  = 64 << 20 // a zip
	maxFileBytes = 16 << 20 // one file
	maxJSONBytes = 4 << 20  // one .json file
	maxFiles     = 4000     // files in one package
)

var (
	allowedExt   = []string{".json", ".jsonl", ".lua", ".md", ".txt", ".png", ".wav", ".glyphs"}
	licenceNames = []string{"LICENSE", "LICENCE", "COPYING", "NOTICE"}
	// .github holds this repo's workflows: never part of the mod
	skippedDirs  = []string{".git", ".hg", ".svn", "__MACOSX", ".github"}
	skippedFiles = []string{".DS_Store", "Thumbs.db", "desktop.ini", ".gitignore", ".gitattributes"}
	// REAPER projects are the feels' source, never part of the pack
	skippedExt  = []string{".rpp", ".rpp-bak"}
	editorFiles = []string{"types/", ".luarc.json", ".bururu/", ".vscode/"}
)

var (
	idRE      = regexp.MustCompile(`^[a-z][a-z0-9-]{1,39}$`)
	versionRE = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$`)
)

func main() {
	out := flag.String("out", ".", "the folder to write the pack into")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: pack -out <folder> <mod folder>")
		os.Exit(2)
	}
	if err := run(flag.Arg(0), *out); err != nil {
		fmt.Fprintln(os.Stderr, "pack:", err)
		os.Exit(1)
	}
}

func run(dir, out string) error {
	id, version, err := readManifest(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return err
	}
	files, err := packFiles(dir)
	if err != nil {
		return err
	}
	b, err := zipFiles(dir, files)
	if err != nil {
		return err
	}
	if len(b) > maxZipBytes {
		return fmt.Errorf("the pack would be %d bytes; a mod pack has at most %d", len(b), maxZipBytes)
	}
	name := id + "-" + version + ".brr"
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(out, name), b, 0o644); err != nil {
		return err
	}
	sum := sha256.Sum256(b)
	fmt.Printf("name=%s\nversion=%s\nfiles=%d\nsha256=%s\n", name, version, len(files), hex.EncodeToString(sum[:]))
	return nil
}

// readManifest reads the id and the version from a manifest, which may
// hold comments and trailing commas.
func readManifest(file string) (id, version string, err error) {
	b, err := os.ReadFile(file)
	if err != nil {
		return "", "", err
	}
	var m struct {
		ID      string `json:"id"`
		Version string `json:"version"`
	}
	if err := json.Unmarshal(plainJSON(b), &m); err != nil {
		return "", "", fmt.Errorf("%s: %v", file, err)
	}
	if !idRE.MatchString(m.ID) {
		return "", "", fmt.Errorf("%s: %q is no mod id", file, m.ID)
	}
	if !versionRE.MatchString(m.Version) {
		return "", "", fmt.Errorf("%s: %q is not a version like 1.0.0", file, m.Version)
	}
	return m.ID, m.Version, nil
}

// plainJSON drops comments and trailing commas outside strings.
func plainJSON(b []byte) []byte {
	var o bytes.Buffer
	in := false
	for i := 0; i < len(b); i++ {
		c := b[i]
		switch {
		case in:
			o.WriteByte(c)
			if c == '\\' && i+1 < len(b) {
				i++
				o.WriteByte(b[i])
			} else if c == '"' {
				in = false
			}
		case c == '"':
			in = true
			o.WriteByte(c)
		case c == '/' && i+1 < len(b) && b[i+1] == '/':
			for i < len(b) && b[i] != '\n' {
				i++
			}
			o.WriteByte('\n')
		case c == '/' && i+1 < len(b) && b[i+1] == '*':
			end := bytes.Index(b[i+2:], []byte("*/"))
			if end < 0 {
				i = len(b)
			} else {
				i += end + 3
			}
		case c == '}' || c == ']':
			// a comma before the closing bracket goes
			t := bytes.TrimRight(o.Bytes(), " \t\r\n")
			if len(t) > 0 && t[len(t)-1] == ',' {
				o.Truncate(len(t) - 1)
			}
			o.WriteByte(c)
		default:
			o.WriteByte(c)
		}
	}
	return o.Bytes()
}

// packFiles are the files of a mod folder that go into its pack, slash
// separated and sorted.
func packFiles(dir string) ([]string, error) {
	var files, bad []string
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil || rel == "." {
			return err
		}
		rel = filepath.ToSlash(rel)
		if skipped(rel) || isEditorFile(rel) || (d.IsDir() && isEditorFile(rel+"/")) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 || (!d.IsDir() && !d.Type().IsRegular()) {
			bad = append(bad, rel+": a link or a special file")
			return nil
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		limit := int64(maxFileBytes)
		if strings.EqualFold(path.Ext(rel), ".json") {
			limit = maxJSONBytes
		}
		switch {
		case !allowed(rel):
			bad = append(bad, rel+": this file type is not allowed in a mod")
		case info.Size() > limit:
			bad = append(bad, fmt.Sprintf("%s: larger than %d bytes", rel, limit))
		default:
			files = append(files, rel)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(files) > maxFiles {
		bad = append(bad, fmt.Sprintf("%d files; a mod has at most %d", len(files), maxFiles))
	}
	if len(bad) > 0 {
		return nil, errors.New("not packed:\n  " + strings.Join(bad, "\n  "))
	}
	slices.Sort(files)
	return files, nil
}

// zipFiles writes the files into a zip, in order.
func zipFiles(dir string, files []string) ([]byte, error) {
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, rel := range files {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: rel, Method: zip.Deflate, Modified: packTime})
		if err != nil {
			return nil, err
		}
		f, err := os.Open(filepath.Join(dir, filepath.FromSlash(rel)))
		if err != nil {
			return nil, err
		}
		_, err = io.Copy(w, f)
		f.Close()
		if err != nil {
			return nil, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func skipped(rel string) bool {
	parts := strings.Split(rel, "/")
	for _, p := range parts[:len(parts)-1] {
		if slices.Contains(skippedDirs, p) {
			return true
		}
	}
	last := parts[len(parts)-1]
	return slices.Contains(skippedFiles, last) || slices.Contains(skippedDirs, last) ||
		slices.Contains(skippedExt, strings.ToLower(path.Ext(last)))
}

func isEditorFile(rel string) bool {
	for _, e := range editorFiles {
		if strings.HasSuffix(e, "/") && strings.HasPrefix(rel, e) || rel == e {
			return true
		}
	}
	return false
}

func allowed(name string) bool {
	base := path.Base(name)
	ext := strings.ToLower(path.Ext(base))
	if slices.Contains(allowedExt, ext) {
		return true
	}
	return ext == "" && slices.Contains(licenceNames, strings.ToUpper(base))
}
