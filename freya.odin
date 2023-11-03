package freya

when ODIN_OS == .Windows {
	// @(extra_linker_flags = "/NODEFAULTLIB:libcmt")
	foreign import lib "windows/freya.lib"
}
FreyaFunc :: proc "c" (coro: ^Freya, value: rawptr) -> rawptr
Freya :: struct {
	body:           FreyaFunc,
	user_data:      rawptr,
	name:           cstring,
	buffer:         rawptr,
	size:           uint,
	completed:      bool,
	_caller:        ^Freya,
	_stack_pointer: rawptr,
	_canary_end:    ^u32,
	_canary:        u32,
}

@(default_calling_convention = "c", link_prefix = "freya_")
foreign lib {
	init :: proc(buffer: rawptr, size: uint, body: FreyaFunc, user_data: rawptr) -> ^Freya ---
	resume :: proc(coro: ^Freya, value: rawptr) -> rawptr ---
	yield :: proc(coro: ^Freya, value: rawptr) -> rawptr ---
	swap :: proc(from, to: ^Freya, value: rawptr) -> rawptr ---
}
