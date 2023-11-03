package freya_test

import "../../freya"
import "core:fmt"
import "core:runtime"

coro_body :: proc "c" (coro: ^freya.Freya, value: rawptr) -> rawptr {
	context = runtime.default_context()
	fmt.println("coro_body() entered")
	fmt.printf("user_data: '%s'\n", cstring(coro.user_data))

	for i in 0 ..< 5 {
		fmt.printf("coro_body(): %v\n", i)
		freya.yield(coro, nil)
	}

	fmt.println("coro_body() return")
	return nil
}

main :: proc() {
	buffer_size: uint = 256 * 1024
	buffer: rawptr = nil

	user_data := raw_data(string("An optional user data pointer"))
	coro := freya.init(buffer, buffer_size, coro_body, user_data)

	coro.name = "MyCoro"

	value := freya.resume(coro, raw_data(string("hello")))

	for !coro.completed {
		freya.resume(coro, nil)
	}

	fmt.println("Coroutine done. Calling it again will crash, like this")
	freya.resume(coro, nil)
}
