// Прозрачный MITM-прокси только для twinby.ru: на путях /sync-ad/* отдаёт
// «пустую» рекламу, весь остальной трафик (включая другие хосты Twinby —
// фото анкет и т.п.) пропускает без расшифровки.
//
// Запускается внутри Magisk-модуля. iptables заворачивает на него ТОЛЬКО
// исходящий 443 процесса Twinby (по UID). Для соединений, чьё SNI не twinby.ru,
// прокси просто туннелирует байты в исходный адрес, ничего не расшифровывая.
package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	soOriginalDst = 80 // SO_ORIGINAL_DST
	listenAddr    = "127.0.0.1:8443"
	targetHost    = "twinby.ru"
	adPathPrefix  = "/sync-ad"
)

var (
	caCert   *x509.Certificate
	caKey    any
	caTLS    tls.Certificate
	leafMu   sync.Mutex
	leafs    = map[string]*tls.Certificate{}
	emptyAd  []byte
	blockAds bool
)

func main() {
	caPath := envOr("TB_CA_CERT", "/data/adb/twinby_adblock/ca.pem")
	keyPath := envOr("TB_CA_KEY", "/data/adb/twinby_adblock/ca.key")
	respPath := envOr("TB_AD_RESPONSE", "/data/adb/twinby_adblock/sync_ad_response.json")
	blockAds = envOr("TB_MODE", "block") == "block"

	cert, err := tls.LoadX509KeyPair(caPath, keyPath)
	if err != nil {
		fatal("не загрузить CA: %v", err)
	}
	caTLS = cert
	caCert, err = x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		fatal("разбор CA: %v", err)
	}
	caKey = cert.PrivateKey

	emptyAd, err = os.ReadFile(respPath)
	if err != nil || len(bytes.TrimSpace(emptyAd)) == 0 {
		emptyAd = []byte(`{"ads":[]}`) // дефолт; можно поменять в sync_ad_response.json
	}

	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		fatal("listen: %v", err)
	}
	mode := "block"
	if !blockAds {
		mode = "passthrough"
	}
	fmt.Printf("twinby-adproxy слушает %s, хост %s, путь %s, режим %s\n", listenAddr, targetHost, adPathPrefix, mode)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go handle(c.(*net.TCPConn))
	}
}

func handle(c *net.TCPConn) {
	defer c.Close()
	origDst, err := originalDst(c)
	if err != nil {
		return
	}

	// Подглядываем ClientHello, чтобы узнать SNI, не теряя байты.
	peek := &peekConn{Conn: c}
	sni := peekSNI(peek)

	// Расшифровываем только twinby.ru. Остальное — прозрачный туннель.
	if !hostMatch(sni, targetHost) {
		tunnel(peek, origDst)
		return
	}
	mitmTwinby(peek, origDst, sni)
}

func hostMatch(sni, base string) bool {
	sni = strings.ToLower(strings.TrimSuffix(sni, "."))
	return sni == base || strings.HasSuffix(sni, "."+base)
}

// Прозрачный туннель исходному адресу без расшифровки.
func tunnel(c net.Conn, dst string) {
	up, err := net.DialTimeout("tcp", dst, 10*time.Second)
	if err != nil {
		return
	}
	defer up.Close()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(up, c); half(up) }()
	go func() { defer wg.Done(); io.Copy(c, up); half(c) }()
	wg.Wait()
}

func half(c net.Conn) {
	if t, ok := c.(*net.TCPConn); ok {
		t.CloseWrite()
	}
}

// MITM для twinby.ru: терминируем TLS своим листовым сертификатом,
// читаем HTTP/1.1, на /sync-ad отдаём пустую рекламу, прочее — проксируем.
func mitmTwinby(c net.Conn, dst, sni string) {
	srvCfg := &tls.Config{
		NextProtos: []string{"http/1.1"},
		GetCertificate: func(hi *tls.ClientHelloInfo) (*tls.Certificate, error) {
			return leafFor(sni), nil
		},
	}
	tlsClient := tls.Server(c, srvCfg)
	if err := tlsClient.Handshake(); err != nil {
		return
	}
	defer tlsClient.Close()

	var up *tls.Conn
	var upRW *bufio.ReadWriter
	br := bufio.NewReader(tlsClient)

	for {
		req, err := http.ReadRequest(br)
		if err != nil {
			return
		}

		if blockAds && strings.HasPrefix(req.URL.Path, adPathPrefix) {
			io.Copy(io.Discard, req.Body)
			req.Body.Close()
			writeEmptyAd(tlsClient)
			if strings.EqualFold(req.Header.Get("Connection"), "close") {
				return
			}
			continue
		}

		// Ленивое открытие апстрима к настоящему серверу.
		if up == nil {
			conn, err := tls.Dial("tcp", dst, &tls.Config{ServerName: sni, NextProtos: []string{"http/1.1"}})
			if err != nil {
				return
			}
			up = conn
			defer up.Close()
			upRW = bufio.NewReadWriter(bufio.NewReader(up), bufio.NewWriter(up))
		}

		if err := req.Write(upRW); err != nil {
			return
		}
		upRW.Flush()
		resp, err := http.ReadResponse(upRW.Reader, req)
		if err != nil {
			return
		}
		if err := resp.Write(tlsClient); err != nil {
			resp.Body.Close()
			return
		}
		resp.Body.Close()
		if req.Close || resp.Close {
			return
		}
	}
}

func writeEmptyAd(w io.Writer) {
	fmt.Fprintf(w, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: keep-alive\r\n\r\n", len(emptyAd))
	w.Write(emptyAd)
}

func leafFor(host string) *tls.Certificate {
	leafMu.Lock()
	defer leafMu.Unlock()
	if c, ok := leafs[host]; ok {
		return c
	}
	c := makeLeaf(host)
	leafs[host] = c
	return c
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func fatal(f string, a ...any) {
	fmt.Fprintf(os.Stderr, f+"\n", a...)
	os.Exit(1)
}

// SO_ORIGINAL_DST: куда реально шло соединение до редиректа iptables.
func originalDst(c *net.TCPConn) (string, error) {
	f, err := c.File()
	if err != nil {
		return "", err
	}
	defer f.Close()
	fd := int(f.Fd())
	var addr [16]byte
	size := uint32(16)
	_, _, e := syscall.Syscall6(syscall.SYS_GETSOCKOPT, uintptr(fd),
		uintptr(syscall.IPPROTO_IP), uintptr(soOriginalDst),
		uintptr(unsafe.Pointer(&addr[0])), uintptr(unsafe.Pointer(&size)), 0)
	if e != 0 {
		return "", e
	}
	ip := net.IPv4(addr[4], addr[5], addr[6], addr[7])
	port := int(addr[2])<<8 | int(addr[3])
	return fmt.Sprintf("%s:%d", ip.String(), port), nil
}

// peekConn буферизует прочитанные при подглядывании байты и отдаёт их заново.
type peekConn struct {
	net.Conn
	buf      bytes.Buffer
	replay   *bytes.Reader
	replayed bool
}

func (p *peekConn) Read(b []byte) (int, error) {
	if p.replay != nil && p.replay.Len() > 0 {
		return p.replay.Read(b)
	}
	return p.Conn.Read(b)
}

// peekSNI читает ClientHello, достаёт SNI и готовит повтор прочитанных байт.
func peekSNI(p *peekConn) string {
	hdr := make([]byte, 5)
	if _, err := io.ReadFull(p.Conn, hdr); err != nil {
		p.replay = bytes.NewReader(append([]byte{}, hdr...))
		return ""
	}
	if hdr[0] != 0x16 { // не handshake
		p.replay = bytes.NewReader(hdr)
		return ""
	}
	recLen := int(hdr[3])<<8 | int(hdr[4])
	body := make([]byte, recLen)
	if _, err := io.ReadFull(p.Conn, body); err != nil {
		p.replay = bytes.NewReader(append(hdr, body...))
		return ""
	}
	p.replay = bytes.NewReader(append(append([]byte{}, hdr...), body...))
	return parseSNI(body)
}

// parseSNI вытаскивает server_name из тела ClientHello-рукопожатия.
func parseSNI(b []byte) string {
	// b: handshake msg. [0]=type(1=ClientHello),[1..4]=len,[4..6]=version,
	// [6..38]=random(32), затем session id, cipher suites, compression, extensions.
	if len(b) < 38 || b[0] != 0x01 {
		return ""
	}
	pos := 38
	if pos >= len(b) {
		return ""
	}
	sidLen := int(b[pos])
	pos += 1 + sidLen
	if pos+2 > len(b) {
		return ""
	}
	csLen := int(b[pos])<<8 | int(b[pos+1])
	pos += 2 + csLen
	if pos+1 > len(b) {
		return ""
	}
	compLen := int(b[pos])
	pos += 1 + compLen
	if pos+2 > len(b) {
		return ""
	}
	extLen := int(b[pos])<<8 | int(b[pos+1])
	pos += 2
	end := pos + extLen
	if end > len(b) {
		end = len(b)
	}
	for pos+4 <= end {
		etype := int(b[pos])<<8 | int(b[pos+1])
		elen := int(b[pos+2])<<8 | int(b[pos+3])
		pos += 4
		if pos+elen > end {
			return ""
		}
		if etype == 0x0000 { // server_name
			ext := b[pos : pos+elen]
			if len(ext) >= 5 {
				nameLen := int(ext[3])<<8 | int(ext[4])
				if 5+nameLen <= len(ext) {
					return string(ext[5 : 5+nameLen])
				}
			}
			return ""
		}
		pos += elen
	}
	return ""
}
