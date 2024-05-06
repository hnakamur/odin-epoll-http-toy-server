package main

import "core:fmt"
import "core:net"
import "core:sys/linux"

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

	if client, source, err := net.accept_tcp(server_fd.(net.TCP_Socket)); err != nil {
		fmt.eprintf("accept_tcp failed: err=%v\n", err)
		return
	} else {
		// fmt.printf("accepted, source=%v\n", source)
		buf: [1024]byte = ---
		n, err := net.recv_tcp(client, buf[:])
		if err != nil {
			fmt.eprintf("recv_tcp failed: err=%v\n", err)
			return
		}
		// fmt.printf("recv_tcp, n=%d, req=%s\n", n, buf[:n])

		content := "Hello, world!\n"
		res := fmt.bprintf(
			buf[:],
			"HTTP/1.1 200 OK\r\n" +
			"Content-Type: text/plain\r\n" +
			"Content-Length: %d\r\n" +
			"Connection: close\r\n" +
			"\r\n" +
			"%s",
			len(content),
			content,
		)
		n, err = net.send_tcp(client, buf[:len(res)])
		if err != nil {
			fmt.eprintf("send_tcp failed: err=%v\n", err)
			return
		}
	}
}
