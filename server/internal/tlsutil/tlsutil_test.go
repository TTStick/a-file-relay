package tlsutil

import (
	"crypto/x509"
	"os"
	"slices"
	"testing"
)

// The self-signed certificate must not carry the machine's hostname.
func TestCertificateNames(t *testing.T) {
	c, err := Load(t.TempDir(), "", "", []string{"154.9.253.14", "nas.example"})
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(c.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if h, _ := os.Hostname(); h != "" && slices.Contains(leaf.DNSNames, h) {
		t.Fatalf("hostname %q in the certificate: %v", h, leaf.DNSNames)
	}
	if !slices.Equal(leaf.DNSNames, []string{"localhost", "nas.example"}) || leaf.Subject.CommonName != "FileSwitch" {
		t.Fatalf("names: CN=%s SAN=%v", leaf.Subject.CommonName, leaf.DNSNames)
	}
}
