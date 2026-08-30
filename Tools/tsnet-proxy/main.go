// Copyright (c) 2026 MOE AI LLC
//
// This program embeds Tailscale's userspace networking stack in herdrm. It is
// deliberately a small companion process rather than a system extension: the
// app talks to it over a private Unix socket and OpenSSH uses the same socket
// as a ProxyCommand. See NOTICE for the Tailscale license.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
)

const (
	protocolVersion = 1
	maxControlLine  = 16 * 1024
)

type daemonConfig struct {
	AuthKey   string `json:"auth_key"`
	ForceDERP bool   `json:"force_derp"`
}

type controlRequest struct {
	Op   string `json:"op"`
	Host string `json:"host,omitempty"`
	Port string `json:"port,omitempty"`
}

type readyResponse struct {
	Type     string `json:"type"`
	Protocol int    `json:"protocol"`
	Error    string `json:"error,omitempty"`
}

type controlResponse struct {
	Result any           `json:"result,omitempty"`
	Error  *controlError `json:"error,omitempty"`
}

type controlError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type statusResponse struct {
	State        string         `json:"state"`
	Version      string         `json:"version"`
	AuthURL      string         `json:"auth_url,omitempty"`
	Tailnet      string         `json:"tailnet,omitempty"`
	MagicDNS     string         `json:"magic_dns,omitempty"`
	TailscaleIPs []string       `json:"tailscale_ips"`
	Peers        []peerResponse `json:"peers"`
}

type peerResponse struct {
	ID          string   `json:"id"`
	Hostname    string   `json:"hostname"`
	DNSName     string   `json:"dns_name"`
	OS          string   `json:"os"`
	Addresses   []string `json:"addresses"`
	Online      bool     `json:"online"`
	Connection  string   `json:"connection"`
	Relay       string   `json:"relay,omitempty"`
	PeerRelay   string   `json:"peer_relay,omitempty"`
	CurrentAddr string   `json:"current_addr,omitempty"`
	PingMS      *float64 `json:"ping_ms,omitempty"`
}

func main() {
	if len(os.Args) < 2 {
		fatal("usage: tsnet-proxy daemon --control PATH --state PATH | proxy --control PATH HOST PORT")
	}
	switch os.Args[1] {
	case "daemon":
		runDaemon(os.Args[2:])
	case "proxy":
		runProxy(os.Args[2:])
	default:
		fatal("unknown command %q", os.Args[1])
	}
}

func runDaemon(args []string) {
	controlPath, statePath, err := daemonArgs(args)
	if err != nil {
		writeReadyError(err)
		return
	}

	var config daemonConfig
	if err := json.NewDecoder(bufio.NewReader(os.Stdin)).Decode(&config); err != nil {
		writeReadyError(fmt.Errorf("reading startup configuration: %w", err))
		return
	}

	if err := os.MkdirAll(statePath, 0700); err != nil {
		writeReadyError(fmt.Errorf("creating state directory: %w", err))
		return
	}
	if err := os.Chmod(statePath, 0700); err != nil {
		writeReadyError(fmt.Errorf("protecting state directory: %w", err))
		return
	}
	if err := os.MkdirAll(filepath.Dir(controlPath), 0700); err != nil {
		writeReadyError(fmt.Errorf("creating control directory: %w", err))
		return
	}
	_ = os.Remove(controlPath)

	// These are Tailscale's supported debug knobs. ALWAYS_USE_DERP disables
	// UDP entirely. With it off, tsnet's current magicsock chooses direct UDP,
	// LAN paths, or the current peer-relay implementation automatically.
	if config.ForceDERP {
		envknob.Setenv("TS_DEBUG_ALWAYS_USE_DERP", "1")
	} else {
		envknob.Setenv("TS_DEBUG_ALWAYS_USE_DERP", "")
	}

	server := &tsnet.Server{
		Dir:      statePath,
		Hostname: "herdrm",
		AuthKey:  strings.TrimSpace(config.AuthKey),
		UserLogf: func(format string, args ...any) { log.Printf(format, args...) },
		Logf:     func(format string, args ...any) { log.Printf(format, args...) },
	}
	defer server.Close()

	status, err := server.Up(context.Background())
	if err != nil {
		writeReadyError(err)
		return
	}

	listener, err := net.Listen("unix", controlPath)
	if err != nil {
		writeReadyError(fmt.Errorf("opening control socket: %w", err))
		return
	}
	defer listener.Close()
	if err := os.Chmod(controlPath, 0600); err != nil {
		writeReadyError(fmt.Errorf("protecting control socket: %w", err))
		return
	}

	if err := writeJSON(os.Stdout, readyResponse{Type: "ready", Protocol: protocolVersion}); err != nil {
		return
	}
	_ = status

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()

	localClient, err := server.LocalClient()
	if err != nil {
		return
	}
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		go handleConnection(ctx, conn, server, localClient)
	}
}

func daemonArgs(args []string) (controlPath, statePath string, err error) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--control":
			if i+1 >= len(args) {
				return "", "", errors.New("--control needs a path")
			}
			controlPath = args[i+1]
			i++
		case "--state":
			if i+1 >= len(args) {
				return "", "", errors.New("--state needs a path")
			}
			statePath = args[i+1]
			i++
		default:
			return "", "", fmt.Errorf("unknown daemon argument %q", args[i])
		}
	}
	if controlPath == "" || statePath == "" {
		return "", "", errors.New("--control and --state are required")
	}
	if len(controlPath) >= 104 {
		return "", "", errors.New("control socket path is too long")
	}
	return controlPath, statePath, nil
}

func writeReadyError(err error) {
	_ = writeJSON(os.Stdout, readyResponse{Type: "error", Protocol: protocolVersion, Error: err.Error()})
}

type statusClient interface {
	Status(context.Context) (*ipnstate.Status, error)
	Ping(context.Context, netip.Addr, tailcfg.PingType) (*ipnstate.PingResult, error)
}

func handleConnection(ctx context.Context, conn net.Conn, server *tsnet.Server, localClient statusClient) {
	defer conn.Close()
	// Do not use bufio.Reader here. ProxyCommand sends the SSH stream
	// immediately after this JSON line, and a buffered read could consume the
	// beginning of the SSH banner and lose it before the transparent handoff.
	line, err := readControlLine(conn)
	if err != nil {
		return
	}
	var request controlRequest
	if err := json.Unmarshal(line, &request); err != nil {
		_ = writeJSON(conn, controlResponse{Error: &controlError{Code: "invalid_request", Message: "invalid control request"}})
		return
	}

	switch request.Op {
	case "status":
		status, err := localClient.Status(ctx)
		if err != nil {
			_ = writeJSON(conn, controlResponse{Error: &controlError{Code: "status_failed", Message: err.Error()}})
			return
		}
		_ = writeJSON(conn, controlResponse{Result: makeStatus(status, localClient)})
	case "proxy":
		proxyConnection(ctx, conn, server, request.Host, request.Port)
	default:
		_ = writeJSON(conn, controlResponse{Error: &controlError{Code: "unknown_operation", Message: "unknown control operation"}})
	}
}

func proxyConnection(ctx context.Context, conn net.Conn, server *tsnet.Server, host, port string) {
	host = strings.TrimPrefix(strings.TrimSuffix(host, "]"), "[")
	if host == "" || !validPort(port) {
		return
	}
	proxyCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	remote, err := server.Dial(proxyCtx, "tcp", net.JoinHostPort(host, port))
	if err != nil {
		return
	}
	defer remote.Close()

	// There is intentionally no acknowledgement: OpenSSH expects the first
	// byte from ProxyCommand to be the SSH banner. The control connection is
	// now a transparent bidirectional byte pipe.
	copyDone := make(chan struct{}, 1)
	go func() {
		_, _ = io.Copy(conn, remote)
		_ = conn.SetDeadline(time.Now())
		copyDone <- struct{}{}
	}()
	_, _ = io.Copy(remote, conn)
	<-copyDone
}

func runProxy(args []string) {
	if len(args) != 4 || args[0] != "--control" {
		os.Exit(2)
	}
	controlPath, host, port := args[1], args[2], args[3]
	conn, err := net.DialTimeout("unix", controlPath, 5*time.Second)
	if err != nil {
		return
	}
	defer conn.Close()
	request := controlRequest{Op: "proxy", Host: host, Port: port}
	if err := writeJSON(conn, request); err != nil {
		return
	}

	go func() {
		_, _ = io.Copy(conn, os.Stdin)
		_ = conn.(*net.UnixConn).CloseWrite()
	}()
	_, _ = io.Copy(os.Stdout, conn)
}

type peerPing struct {
	latencyMS  float64
	connection string
}

func makeStatus(status *ipnstate.Status, client statusClient) statusResponse {
	pings := peerPings(status, client)
	result := statusResponse{
		State:        status.BackendState,
		Version:      status.Version,
		AuthURL:      status.AuthURL,
		TailscaleIPs: stringifyIPs(status.TailscaleIPs),
	}
	if status.CurrentTailnet != nil {
		result.Tailnet = status.CurrentTailnet.Name
		result.MagicDNS = status.CurrentTailnet.MagicDNSSuffix
	}
	result.Peers = make([]peerResponse, 0, len(status.Peer))
	for _, peer := range status.Peer {
		peerID := fmt.Sprint(peer.ID)
		var pingMS *float64
		connection := connectionKind(peer)
		if ping, ok := pings[peerID]; ok {
			pingMS = &ping.latencyMS
			if ping.connection != "" {
				connection = ping.connection
			}
		}
		result.Peers = append(result.Peers, peerResponse{
			ID:          peerID,
			Hostname:    peer.HostName,
			DNSName:     strings.TrimSuffix(peer.DNSName, "."),
			OS:          peer.OS,
			Addresses:   stringifyIPs(peer.TailscaleIPs),
			Online:      peer.Online,
			Connection:  connection,
			Relay:       peer.Relay,
			PeerRelay:   peer.PeerRelay,
			CurrentAddr: peer.CurAddr,
			PingMS:      pingMS,
		})
	}
	sort.Slice(result.Peers, func(i, j int) bool {
		return strings.ToLower(result.Peers[i].displayName()) < strings.ToLower(result.Peers[j].displayName())
	})
	return result
}

func peerPings(status *ipnstate.Status, client statusClient) map[string]peerPing {
	result := make(map[string]peerPing)
	type response struct {
		id         string
		pingMS     float64
		connection string
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	responses := make(chan response, len(status.Peer))
	pending := 0
	for _, peer := range status.Peer {
		if !peer.Online || len(peer.TailscaleIPs) == 0 {
			continue
		}
		pending++
		go func(peer *ipnstate.PeerStatus) {
			// PingDisco is the same path probe used by `tailscale ping`: it
			// reports whether the selected route is direct, peer relay, or
			// DERP. TSMP gives an IP-layer RTT but intentionally does not
			// expose the chosen path.
			ping, err := client.Ping(ctx, peer.TailscaleIPs[0], tailcfg.PingDisco)
			if err == nil && ping != nil && ping.Err == "" && ping.LatencySeconds >= 0 {
				responses <- response{
					id:         fmt.Sprint(peer.ID),
					pingMS:     ping.LatencySeconds * 1000,
					connection: pingConnectionKind(ping),
				}
				return
			}
			responses <- response{id: fmt.Sprint(peer.ID)}
		}(peer)
	}
	for i := 0; i < pending; i++ {
		select {
		case response := <-responses:
			if response.pingMS > 0 {
				result[response.id] = peerPing{
					latencyMS:  response.pingMS,
					connection: response.connection,
				}
			}
		case <-ctx.Done():
			return result
		}
	}
	return result
}

func (p peerResponse) displayName() string {
	if p.Hostname != "" {
		return p.Hostname
	}
	return p.DNSName
}

func pingConnectionKind(ping *ipnstate.PingResult) string {
	if ping.PeerRelay != "" {
		return "peer-relay"
	}
	if ping.Endpoint != "" {
		return "direct"
	}
	if ping.DERPRegionID != 0 || ping.DERPRegionCode != "" {
		return "derp"
	}
	return ""
}

func connectionKind(peer *ipnstate.PeerStatus) string {
	// PeerRelay must win over the DERP field. This is the modern peer-relay
	// transport and is deliberately shown separately in the UI.
	if peer.PeerRelay != "" {
		return "peer-relay"
	}
	if peer.CurAddr != "" {
		return "direct"
	}
	if peer.Relay != "" {
		return "derp"
	}
	if peer.Online {
		return "connecting"
	}
	return "offline"
}

func stringifyIPs(ips []netip.Addr) []string {
	result := make([]string, 0, len(ips))
	for _, ip := range ips {
		if ip.IsValid() {
			result = append(result, ip.String())
		}
	}
	return result
}

func validPort(value string) bool {
	port, err := strconv.Atoi(value)
	return err == nil && port > 0 && port <= 65535
}

func readControlLine(r io.Reader) ([]byte, error) {
	line := make([]byte, 0, 256)
	one := []byte{0}
	for len(line) < maxControlLine {
		if _, err := io.ReadFull(r, one); err != nil {
			return nil, err
		}
		line = append(line, one[0])
		if one[0] == '\n' {
			return line, nil
		}
	}
	return nil, errors.New("control request is too long")
}

func writeJSON(w io.Writer, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = w.Write(data)
	return err
}

func fatal(message string, args ...any) {
	fmt.Fprintf(os.Stderr, message+"\n", args...)
	os.Exit(2)
}
