package tests

// A network between the two rollback sessions of a netplay test: each
// send, through the wire format, arrives `latency` steps after it was
// sent, in the order sent. A test drops a send by not making it.

import "dr:net"
import "dr:sim"

// The input frames each send carries.
LINK_WINDOW :: 8

Link :: struct {
	latency: int,
	queues:  [2][dynamic]Link_Delivery, // to each session
}

Link_Delivery :: struct {
	at:  int,
	pkt: net.Input_Packet,
}

link_make :: proc(latency: int, allocator := context.allocator) -> Link {
	return {latency, {make([dynamic]Link_Delivery, allocator), make([dynamic]Link_Delivery, allocator)}}
}

// Gives each session what has arrived for it by `tick`.
link_deliver :: proc(l: ^Link, rs: []net.Rollback_Session, tick: int) {
	for &q, k in l.queues {
		w := 0
		for d in q {
			if d.at <= tick {
				net.rollback_session_receive(&rs[k], d.pkt)
			} else {
				q[w] = d
				w += 1
			}
		}
		resize(&q, w)
	}
}

// Sends session `k`'s newest input window to the other, at `tick`.
link_send :: proc(l: ^Link, rs: []net.Rollback_Session, k: int, tick: int) {
	win: [LINK_WINDOW]sim.Buttons
	start, count := net.rollback_session_local_window(&rs[k], LINK_WINDOW, win[:])
	if count == 0 {
		return
	}
	buf: [128]byte
	n := net.encode_input(buf[:], u8(k), start, win[:count])
	pkt, _ := net.decode_input(buf[:n])
	append(&l.queues[1 - k], Link_Delivery{tick + l.latency, pkt})
}
