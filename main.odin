package main

import "core:fmt"
import "core:net"
import "core:sys/linux"
import "core:thread"

MAX_EVENTS :: 512

serve :: proc(server_fd: linux.Fd) {
	epoll_fd, errno := linux.epoll_create(1)
	if errno != .NONE {
		fmt.eprintf("epoll_create failed: errno=%v\n", errno)
		return
	}

	ev := linux.EPoll_Event {
		events = .IN | .EXCLUSIVE,
		data = linux.EPoll_Data{fd = server_fd},
	}
	if errno := linux.epoll_ctl(epoll_fd, .ADD, server_fd, &ev); errno != .NONE {
		fmt.eprintf("epoll_ctl failed: errno=%v\n", errno)
		return
	}

	server_fd_requests: u64
	events: [MAX_EVENTS]linux.EPoll_Event = ---
	for {
		nfds, errno := linux.epoll_wait(epoll_fd, raw_data(events[:]), MAX_EVENTS, -1)
		if errno != .NONE {
			fmt.eprintf("epoll_wait failed: errno=%v\n", errno)
			return
		}

		for i := i32(0); i < nfds; i += 1 {
			if events[i].data.fd == server_fd {
				addr: linux.Sock_Addr_Any
				sockflags: linux.Socket_FD_Flags = {.NONBLOCK}
				client_fd, errno := linux.accept(server_fd, &addr, sockflags)
				if errno != .NONE {
					if errno == .EAGAIN {
						continue
					}
					fmt.eprintf("accept failed: errno=%v\n", errno)
					return
				}

				/*
                 * Re-add the socket periodically so that other worker threads
                 * will get a chance to accept connections.
                 * See ngx_reorder_accept_events.
                 */
				server_fd_requests += 1
				if server_fd_requests % 16 == 0 {
					ev: linux.EPoll_Event
					if errno := linux.epoll_ctl(epoll_fd, .DEL, server_fd, &ev); errno != .NONE {
						fmt.eprintf("epoll_ctl failed: errno=%v\n", errno)
						return
					}

					ev = linux.EPoll_Event {
						events = .IN | .EXCLUSIVE,
						data = linux.EPoll_Data{fd = server_fd},
					}
					if errno := linux.epoll_ctl(epoll_fd, .ADD, server_fd, &ev); errno != .NONE {
						fmt.eprintf("epoll_ctl failed: errno=%v\n", errno)
						return
					}
				}

				// NOTE: Not vital to succeed; error ignored
				no_delay: b32 = true
				_ = linux.setsockopt(
					client_fd,
					linux.SOL_TCP,
					linux.Socket_TCP_Option.NODELAY,
					&no_delay,
				)

				ev := linux.EPoll_Event {
					events = .IN | .RDHUP | .ET,
					data = linux.EPoll_Data{fd = client_fd},
				}
				if errno := linux.epoll_ctl(epoll_fd, .ADD, client_fd, &ev); errno != .NONE {
					fmt.eprintf("epoll_ctl failed: errno=%v\n", errno)
					return
				}
			} else {
				client_fd := events[i].data.fd
				buf: [1024]byte = ---
				n, errno := linux.recv(client_fd, buf[:], {})
				if errno != .NONE {
					fmt.eprintf("recv_tcp failed: errno=%v\n", errno)
					return
				}
				if n <= 0 {
					linux.close(client_fd)
				} else {
					content := "Hello, world!\n"
					res := fmt.bprintf(
						buf[:],
						"HTTP/1.1 200 OK\r\n" +
						"Content-Type: text/plain\r\n" +
						"Content-Length: %d\r\n" +
						"Server: %s\r\n" +
						"\r\n" +
						"%s",
						len(content),
						"toy-server",
						content,
					)
					iov := [1]linux.IO_Vec{
						{base = raw_data(buf[:]), len = len(res)},
					}
					if _, errno := linux.writev(client_fd, iov[:]); errno != nil {
						fmt.eprintf("send_tcp failed: errno=%v\n", errno)
						return
					}
				}
			}
		}
	}
}

// Copied from https://github.com/odin-lang/Odin/pull/3125/files
ioctl :: proc "contextless" (fd: linux.Fd, request: i32, arg: uintptr) -> int {
	return linux.syscall(linux.SYS_ioctl, fd, request, arg)
}

FIONBIO :: 0x5421

main :: proc() {
	server_fd, errno := linux.socket(.INET, .STREAM, {}, {})
	if errno != nil {
		fmt.eprintf("create_socket failed: errno=%v\n", errno)
		return
	}
	defer linux.close(server_fd)

	do_reuse_addr: b32 = true
	if errno := linux.setsockopt(
		server_fd,
		linux.SOL_SOCKET,
		linux.Socket_Option.REUSEADDR,
		&do_reuse_addr,
	); errno != .NONE {
		fmt.eprintf("setsockopt REUSEADDR failed: errno=%v\n", errno)
	}

	nb: b32 = true;
	if ioctl(server_fd, FIONBIO, uintptr(&nb)) == -1 {
		fmt.eprintf("ioctl FIONBIO failed\n")
		return
	}

	server_addr := linux.Sock_Addr_Any {
		ipv4 = {
			sin_family = .INET,
			sin_port = u16be(3000),
			sin_addr = transmute([4]u8) net.IP4_Any,
		}
	}
	if errno := linux.bind(server_fd, &server_addr); errno != .NONE {
		fmt.eprintf("bind failed: errno=%v\n", errno)
		return
	}

	if err := linux.listen(server_fd, 511); errno != .NONE {
		fmt.eprintf("listen failed: errno=%v\n", errno)
		return
	}

	worker_proc :: proc(t: ^thread.Thread) {
		serve(linux.Fd(t.user_index))
	}

	THREAD_POOL_SIZE := 24
	threads := make([dynamic]^thread.Thread, 0, THREAD_POOL_SIZE)
	defer delete(threads)

	for i := 0; i < THREAD_POOL_SIZE; i += 1 {
		if t := thread.create(worker_proc); t != nil {
			t.init_context = context
			t.user_index = int(server_fd)
			append(&threads, t)
			thread.start(t)
		}
	}

	for len(threads) > 0 {
		for i := 0; i < len(threads);  /**/{
			if t := threads[i]; thread.is_done(t) {
				fmt.printf("Thread %d is done\n", t.user_index)
				thread.destroy(t)

				ordered_remove(&threads, i)
			} else {
				i += 1
			}
		}
	}

}
