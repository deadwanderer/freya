//+private
package freya

import win "core:sys/windows"

mtx_type_flags :: enum u8 {
	Plain     = 0,
	Recursive = 1,
}
mtx_type :: bit_set[mtx_type_flags;u8]

Mtx :: struct {
	cs:             win.CRITICAL_SECTION,
	already_locked: b8,
	recursive:      b8,
}

Cnd :: struct {
	events:             [2]win.HANDLE,
	waiters_count:      u32,
	waiters_count_lock: win.CRITICAL_SECTION,
}

mtx_init :: proc(mtx: ^Mtx, type: mtx_type) -> b8 {
	mtx.already_locked = false
	mtx.recursive = .Recursive in type

	win.InitializeCriticalSection(&mtx.cs)

	return true
}

mtx_destroy :: proc(mtx: ^Mtx) {
	win.DeleteCriticalSection(&mtx.cs)
}

mtx_lock :: proc(mtx: ^Mtx) -> b8 {
	win.EnterCriticalSection(&mtx.cs)

	if !mtx.recursive {
		for mtx.already_locked {win.Sleep(1)}
		mtx.already_locked = true
	}

	return true
}

// mtx_timedlock :: proc(mtx: ^Mtx, ts: timespec) -> b8 {
// 	return true
// }

// mtx_trylock :: proc(mtx: ^Mtx) -> b8 {
// 	return true
// }

mtx_unlock :: proc(mtx: ^Mtx) -> b8 {
	mtx.already_locked = false
	win.LeaveCriticalSection(&mtx.cs)
	return true
}

_CONDITION_EVENT_ONE :: 0
_CONDITION_EVENT_ALL :: 1

cnd_init :: proc(cond: ^Cnd) -> b8 {
	cond.waiters_count = 0
	win.InitializeCriticalSection(&cond.waiters_count_lock)
	cond.events[_CONDITION_EVENT_ONE] = win.CreateEventW(nil, false, false, nil)
	if cond.events[_CONDITION_EVENT_ONE] == nil {
		cond.events[_CONDITION_EVENT_ALL] = nil
		return false
	}
	cond.events[_CONDITION_EVENT_ALL] = win.CreateEventW(nil, true, false, nil)
	if cond.events[_CONDITION_EVENT_ALL] == nil {
		win.CloseHandle(cond.events[_CONDITION_EVENT_ONE])
		cond.events[_CONDITION_EVENT_ONE] = nil
		return false
	}

	return true
}

cnd_destroy :: proc(cond: ^Cnd) {
	if cond.events[_CONDITION_EVENT_ONE] != nil {
		win.CloseHandle(cond.events[_CONDITION_EVENT_ONE])
	}
	if cond.events[_CONDITION_EVENT_ALL] != nil {
		win.CloseHandle(cond.events[_CONDITION_EVENT_ALL])
	}
	win.DeleteCriticalSection(&cond.waiters_count_lock)
}

cnd_signal :: proc(cond: ^Cnd) -> b8 {
	have_waiters: b8 = false
	win.EnterCriticalSection(&cond.waiters_count_lock)
	have_waiters = (cond.waiters_count > 0)
	win.LeaveCriticalSection(&cond.waiters_count_lock)

	if have_waiters {
		if win.SetEvent(cond.events[_CONDITION_EVENT_ONE]) == false {
			return false
		}
	}
	return true
}

cnd_broadcast :: proc(cond: ^Cnd) -> b8 {
	have_waiters: b8 = false
	win.EnterCriticalSection(&cond.waiters_count_lock)
	have_waiters = (cond.waiters_count > 0)
	win.LeaveCriticalSection(&cond.waiters_count_lock)

	if have_waiters {
		if win.SetEvent(cond.events[_CONDITION_EVENT_ALL]) == false {
			return false
		}
	}
	return true
}

cnd_wait :: proc(cond: ^Cnd, mtx: ^Mtx) -> b8 {
	return _cnd_timedwait(cond, mtx, win.INFINITE)
}

// cnd_timedwait :: proc(cond: ^Cnd, mtx: ^Mtx, ts: timespec) -> b8 {
// 	return true
// }

@(private = "file")
_cnd_timedwait :: proc(cond: ^Cnd, mtx: ^Mtx, timeout: win.DWORD) -> b8 {
	result: win.DWORD
	last_waiter: b8

	win.EnterCriticalSection(&cond.waiters_count_lock)
	cond.waiters_count += 1
	win.LeaveCriticalSection(&cond.waiters_count_lock)

	mtx_unlock(mtx)

	result = win.WaitForMultipleObjects(2, &cond.events[0], false, timeout)
	if result == win.WAIT_TIMEOUT {
		mtx_lock(mtx)
		return false // timedout
	} else if result == win.WAIT_FAILED {
		mtx_lock(mtx)
		return false // error
	}

	win.EnterCriticalSection(&cond.waiters_count_lock)
	cond.waiters_count -= 1
	last_waiter =
		((result == (win.WAIT_OBJECT_0 + _CONDITION_EVENT_ALL)) && (cond.waiters_count == 0))
	win.LeaveCriticalSection(&cond.waiters_count_lock)

	if last_waiter {
		if win.ResetEvent(cond.events[_CONDITION_EVENT_ALL]) == false {
			mtx_lock(mtx)
			return false // error
		}
	}

	mtx_lock(mtx)
	return true
}
