package netplay

// Phase 6 stage 2: a thin, non-blocking wrapper over core:net's UDP socket,
// cross-platform by construction -- core:net has socket_linux.odin,
// socket_windows.odin and socket_posix.odin backing the same calls used
// here, so nothing platform-specific is written in this package at all.

import core_net "core:net"

Socket :: struct {
	udp: core_net.UDP_Socket,
}

// port = 0 lets the OS pick an ephemeral port (a joining client does this;
// a host binds an agreed port instead).
open :: proc(port: int) -> (sock: Socket, ok: bool) {
	udp, err := core_net.make_bound_udp_socket(core_net.IP4_Any, port)
	if err != nil {
		return {}, false
	}
	if bl_err := core_net.set_blocking(udp, false); bl_err != nil {
		core_net.close(udp)
		return {}, false
	}
	return Socket{udp = udp}, true
}

close :: proc(sock: ^Socket) {
	core_net.close(sock.udp)
	sock^ = {}
}

local_endpoint :: proc(sock: ^Socket) -> (core_net.Endpoint, bool) {
	ep, err := core_net.bound_endpoint(sock.udp)
	return ep, err == nil
}

// "host:port" or a bare "host" (port 0), same format core:net itself parses.
resolve :: proc(address: string) -> (core_net.Endpoint, bool) {
	return core_net.parse_endpoint(address)
}

send :: proc(sock: ^Socket, to: core_net.Endpoint, data: []byte) -> bool {
	n, err := core_net.send_udp(sock.udp, data, to)
	return err == nil && n == len(data)
}

// Non-blocking: ok is false with n == 0 whenever nothing was waiting
// (core:net's Would_Block), which is not an error -- callers poll this once
// per frame rather than blocking the render loop on it.
poll_recv :: proc(sock: ^Socket, buf: []byte) -> (n: int, from: core_net.Endpoint, ok: bool) {
	read, remote, err := core_net.recv_udp(sock.udp, buf)
	if err != nil {
		return 0, {}, false
	}
	return read, remote, true
}
