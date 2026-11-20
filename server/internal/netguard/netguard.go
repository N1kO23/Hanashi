// Package netguard makes HTTP clients for addresses that others choose (push
// endpoints, other servers), which must not reach into the server's own
// network.
package netguard

import (
	"errors"
	"net"
	"net/http"
	"syscall"
	"time"
)

var ErrPrivateAddress = errors.New("the address is loopback, private or link-local")

// Client makes an HTTP client that, unless allowPrivate, refuses to connect
// to loopback, private and link-local addresses. The check runs on the
// resolved address, so DNS tricks cannot get around it. It follows no
// redirects. A request takes at most timeout (none if 0: then its context
// must say).
func Client(allowPrivate bool, timeout time.Duration) *http.Client {
	dialer := &net.Dialer{
		Timeout: 10 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			if allowPrivate {
				return nil
			}
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			if ip := net.ParseIP(host); ip == nil || !IsPublic(ip) {
				return ErrPrivateAddress
			}
			return nil
		},
	}
	return &http.Client{
		Transport: &http.Transport{
			DialContext:         dialer.DialContext,
			TLSHandshakeTimeout: 10 * time.Second,
			MaxIdleConnsPerHost: 4,
			IdleConnTimeout:     90 * time.Second,
		},
		Timeout: timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

var sharedAddressSpace = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

func IsPublic(ip net.IP) bool {
	return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsInterfaceLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() || sharedAddressSpace.Contains(ip))
}
