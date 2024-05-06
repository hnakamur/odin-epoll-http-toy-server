package main

import "core:fmt"
import "core:net"
import "core:sys/linux"

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
					fmt.eprintf("accept failed: errno=%v\n", errno)
					return
				}
				client_socket: net.Any_Socket = cast(net.TCP_Socket)client_fd
				if err := net.set_blocking(client_socket, false); err != nil {
					fmt.eprintf("set_blocking failed: errno=%v\n", errno)
					return
				}

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
				client_socket: net.TCP_Socket = cast(net.TCP_Socket)client_fd
				buf: [1024]byte = ---
				n, err := net.recv_tcp(client_socket, buf[:])
				if err != nil {
					fmt.eprintf("recv_tcp failed: err=%v\n", err)
					return
				}
				if n <= 0 {
					net.close(client_socket)
				} else {
					content := "Hello, world!\n"
					res := fmt.bprintf(
						buf[:],
						"HTTP/1.1 200 OK\r\n" +
						"Content-Type: text/plain\r\n" +
						"Content-Length: %d\r\n" +
						"Connection: close\r\n" +
						"Server: %s\r\n" +
						"\r\n" +
						"%s",
						len(content),
						"toy-server",
						content,
					)
					n, err = net.send_tcp(client_socket, buf[:len(res)])
					if err != nil {
						fmt.eprintf("send_tcp failed: err=%v\n", err)
						return
					}
				}
			}
		}
	}
}

main :: proc() {
	server_fd, err := net.create_socket(.IP4, .TCP)
	if err != nil {
		fmt.eprintf("create_socket failed: err=%v\n", err)
		return
	}
	defer net.close(server_fd)

	server_addr := net.Endpoint {
		address = net.IP4_Any,
		port    = 3000,
	}

	os_sock := linux.Fd(server_fd.(net.TCP_Socket))
	do_reuse_addr: b32 = true
	if errno := linux.setsockopt(
		os_sock,
		linux.SOL_SOCKET,
		linux.Socket_Option.REUSEADDR,
		&do_reuse_addr,
	); errno != .NONE {
		fmt.eprintf("setsockopt REUSEADDR failed: err=%v\n", net.Listen_Error(errno))
	}

	if err = net.bind(server_fd, server_addr); err != nil {
		fmt.eprintf("bind failed: err=%v\n", err)
		return
	}

	if err := linux.listen(os_sock, 511); err != nil {
		fmt.eprintf("listen failed: err=%v\n", err)
		return
	}

	serve(os_sock)
}
