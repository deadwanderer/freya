package freya

import "core:fmt"
import "core:mem"
import "core:sync"

// Enums
RunMode :: enum {
	Loop, // Run jobs from a queue until scheduler_interrupt() is called.
	Flush, // Run jobs from a queue until empty, or until all remaining jobs are waiting.
	Single, // Run a single non-waiting job from a queue.
}

JobStatus :: enum {
	Completed,
	Waiting,
	Yielding,
}

// Structs
Job :: struct {
	desc:           JobDescription,
	user_data:      rawptr,
	fiber:          ^Freya,
	group:          ^Group,
	wait_next:      ^Job,
	wait_threshold: uint,
}

JobDescription :: struct {
	// Job name. (optional)
	name:      string,
	// Job body function.
	func:      JobFunc,
	// User defined job context pointer. (optional)
	user_data: rawptr,
	// User defined job index. (optional, useful for parallel-for constructs)
	user_idx:  uint,
	// Index of the queue to run the job on.
	queue_idx: uint,
}


Scheduler :: struct {
	_lock:        sync.Mutex,
	_queues:      []_Queue,
	_fibers:      []^Freya,
	_fiber_count: uint,
	_job_pool:    []Job,
	_job_count:   uint,
}

Group :: struct {
	_job_list: ^Job, // Should this be a pointer-to-Job + count?
	_count:    uint, // Alternatively, just a dynarray or slice?
}

// _Stack :: struct {
// 	arr:   ^rawptr,
// 	count: uint,
// }

_Queue :: struct {
	arr:              []^Job,
	head, tail, mask: uint,
	parent:           ^_Queue,
	fallback:         ^_Queue,
	semaphore_signal: sync.Cond,
	semaphore_count:  uint,
	interrupt_stamp:  uint,
}

// Proc defs

// Job body function prototype.
JobFunc :: proc(job: ^Job)
_FiberFactoryFunc :: proc(
	sched: ^Scheduler,
	fiber_idx: uint,
	buffer: rawptr,
	stack_size: uint,
	user_ptr: rawptr,
) -> ^Freya

// Get the scheduler for a job.
job_get_scheduler :: proc(job: ^Job) -> ^Scheduler {
	return cast(^Scheduler)job.fiber.user_data
}

// Get the description for a job.
job_get_description :: proc(job: ^Job) -> ^JobDescription {
	return &job.desc
}

// Get the allocation size for a scheduler instance.
scheduler_size :: proc(job_count, queue_count, fiber_count: uint, stack_size: uint) -> uint {
	size: uint = 0
	size += _jobs_align(size_of(Scheduler))
	size += _jobs_align(queue_count * size_of(_Queue))
	size += _jobs_align(fiber_count * size_of(rawptr))
	size += _jobs_align(job_count * size_of(rawptr))
	size += queue_count * _jobs_align(job_count * size_of(rawptr))
	size += job_count * _jobs_align(size_of(Job))
	size += fiber_count * stack_size
	return size
}

// Initialize memory for a scheduler. Use tina_scheduler_size() to figure out
// how much you need.
scheduler_init :: proc(
	buffer: rawptr,
	job_count, queue_count, fiber_count: uint,
	stack_size: uint,
) -> ^Scheduler {
	return _scheduler_init(
		buffer,
		job_count,
		queue_count,
		fiber_count,
		stack_size,
		_default_fiber_factory,
		cast(rawptr)_jobs_fiber,
	)
}

// Initialize memory for a scheduler, with extra options.
scheduler_init_full :: proc(
	buffer: rawptr,
	job_count, queue_count, fiber_count: uint,
	stack_size: uint,
	fiber_factory: _FiberFactoryFunc,
	fiber_data: rawptr,
) -> ^Scheduler {
	return _scheduler_init(
		buffer,
		job_count,
		queue_count,
		fiber_count,
		stack_size,
		fiber_factory,
		fiber_data,
	)
}

// Destroy a scheduler. Any unfinished jobs will be lost. Flush your queues if
// you need them to finish gracefully.
scheduler_destroy :: proc(sched: ^Scheduler) {
	sched._lock = {}
	for i in 0 ..< len(sched._queues) {
		sched._queues[i].semaphore_signal = {}
	}
}

// Convenience constructor. Allocate and initialize a scheduler.
scheduler_new :: proc(job_count, queue_count, fiber_count: uint, stack_size: uint) -> ^Scheduler {
	buffer, err := mem.alloc(int(scheduler_size(job_count, queue_count, fiber_count, stack_size)))
	if err != .None {
		fmt.eprintln("Freya Jobs Error: Scheduler buffer allocation failed:", err)
		return nil
	}
	return scheduler_init(buffer, job_count, queue_count, fiber_count, stack_size)
}

// Convenience destructor. Destroy and free a scheduler.
scheduler_free :: proc(sched: ^Scheduler) {
	scheduler_destroy(sched)
	mem.free(sched)
}

// Link a pair of queues for job prioritization. When the 'queue_idx' is empty
// it will steal jobs from 'fallback_idx'.
scheduler_queue_priority :: proc(sched: ^Scheduler, queue_idx: uint, fallback_idx: uint) {
	parent := _get_queue(sched, queue_idx)
	fallback := _get_queue(sched, fallback_idx)
	assert(parent.fallback == nil, "Freya Jobs Error: Queue already has a fallback assigned.")
	assert(fallback.parent == nil, "Freya Jobs Error: Queue already has a fallback assigned.")
	parent.fallback = fallback
	fallback.parent = parent
}

// Run jobs in the given queue based on the mode, returns false if no jobs were
// run.
scheduler_run :: proc(sched: ^Scheduler, queue_idx: uint, mode: RunMode) -> bool {
	ran := false
	sync.mutex_lock(&sched._lock)
	{
		queue := _get_queue(sched, queue_idx)

		// Keep looping until the interrupt stamp is incremented
		stamp := queue.interrupt_stamp
		for mode != .Loop || queue.interrupt_stamp == stamp {
			job := _queue_next_job(queue)
			if job != nil {
				_execute_job(sched, job)
				ran = true
				if mode == .Single {
					break
				} else if mode == .Loop {
					// Sleep until more work is added to the queue
					fmt.println("Loop sleep.")
					queue.semaphore_count += 1
					sync.cond_wait(&queue.semaphore_signal, &sched._lock)
				} else {
					break
				}
			}
		}
	}
	sync.mutex_unlock(&sched._lock)
	fmt.printf("Queue Idx %v ran: %v\n", queue_idx, ran)
	return ran
}

// Interrupt .Loop execution of a queue on all active threads as soon as
// their current jobs finish.
scheduler_interrupt :: proc(sched: ^Scheduler, queue_idx: uint) {
	sync.mutex_lock(&sched._lock)
	{
		queue := _get_queue(sched, queue_idx)
		queue.interrupt_stamp += 1

		sync.cond_broadcast(&queue.semaphore_signal)
		queue.semaphore_count = 0
	}
	sync.mutex_unlock(&sched._lock)
}

// Add jobs to the scheduler, optionally pass the address of a tina_group to
// track when the jobs have completed. If 'max_group_count' is non-zero, then
// 'count' will be adjusted based on the number of jobs already in the group.
// Returns the number of jobs added.
scheduler_enqueue_batch :: proc(
	sched: ^Scheduler,
	list: []JobDescription,
	group: ^Group,
	max_group_count: uint,
) -> uint { 	// count: uint,
	count := uint(len(list))
	sync.mutex_lock(&sched._lock)
	{
		if group != nil {
			count = _group_increment(group, count, max_group_count)
		}

		assert(sched._job_count >= count, "Freya Jobs Error: Ran out of jobs.")
		for i in 0 ..< count {
			assert(list[i].func != nil, "Freya Jobs Error: Jobs must have a body function.")

			// Pop a job from the pool
			sched._job_count -= 1
			sched._job_pool[sched._job_count] = {
				desc           = list[i],
				user_data      = nil,
				fiber          = nil,
				group          = group,
				wait_next      = nil,
				wait_threshold = 0,
			}

			// Push it to the proper queue
			queue := _get_queue(sched, list[i].queue_idx)
			queue.arr[queue.head] = &sched._job_pool[sched._job_count]
			queue.head = (queue.head + 1) & queue.mask
			_queue_signal(queue)
			fmt.println("Job pushed.")
		}
	}
	sync.mutex_unlock(&sched._lock)
	return count
}

// Add many jobs to the scheduler that share the same description, but use
// sequential indexes. It will schedule 'count' jobs with indexes from 0 to
// count - 1.
scheduler_enqueue_n :: proc(
	sched: ^Scheduler,
	func: JobFunc,
	user_data: rawptr,
	count: uint,
	queue_idx: uint,
	group: ^Group,
) {
	cursor: uint = 0
	desc: [256]JobDescription

	for i in 0 ..< count {
		desc[cursor] = {
			name      = "",
			func      = func,
			user_data = user_data,
			user_idx  = i,
			queue_idx = queue_idx,
		}
		cursor += 1

		if cursor == 256 {
			scheduler_enqueue_batch(sched, desc[:], group, 0)
			cursor = 0
		}
	}

	if cursor > 0 {
		scheduler_enqueue_batch(sched, desc[0:cursor], group, 0)
	}
}

// Yield the current job until the group has 'threshold' or fewer remaining
// jobs. 'threshold' is useful to throttle a producer job. Allowing it to keep a
// consumers busy without a lot of queued items.
job_wait :: proc(job: ^Job, group: ^Group, threshold: uint) -> uint {
	sync.mutex_lock(&job_get_scheduler(job)._lock)

	// Check if we need to wait at all
	count := group._count
	if count > threshold {
		// Push onto wait list.
		job.wait_next = group._job_list
		group._job_list = job

		job.wait_threshold = threshold
		// NOTE: Scheduler will be unlocked after yielding
		yield(job.fiber, rawptr(uintptr(JobStatus.Waiting)))
		job.wait_threshold = 0

		return group._count
	} else {
		sync.mutex_unlock(&job_get_scheduler(job)._lock)
		return count
	}
}

// Yield the current job and reschedule at the back of the queue.
job_yield :: proc(job: ^Job) {
	yield(job.fiber, rawptr(uintptr(JobStatus.Yielding)))
}

// Yield the current job and reschedule it at the back of a different queue.
// Returns the old queue the job was scheduled on.
job_switch_queue :: proc(job: ^Job, queue_idx: uint) -> uint {
	old_queue := job.desc.queue_idx
	if queue_idx == old_queue {return queue_idx}

	job.desc.queue_idx = queue_idx
	yield(job.fiber, rawptr(uintptr(JobStatus.Yielding)))
	return old_queue
}

// Increment a group's value directly. Allows associating jobs (or some other
// unit of work) with multiple groups. Returns the count added which will be
// adjusted similarly to scheduler_enqueue_batch().
group_increment :: proc(sched: ^Scheduler, group: ^Group, count, max_count: uint) -> uint {
	sync.mutex_lock(&sched._lock)
	count := _group_increment(group, count, max_count)
	sync.mutex_unlock(&sched._lock)
	return count
}

// Decrement a group's value directly to manually mark completion of some work.
group_decrement :: proc(sched: ^Scheduler, group: ^Group, count: uint) {
	sync.mutex_lock(&sched._lock)
	assert(group._count >= count, "Freya Jobs Error: Group count underflow.")
	_group_decrement(sched, group, count)
	sync.mutex_unlock(&sched._lock)
}

scheduler_enqueue :: #force_inline proc(
	sched: ^Scheduler,
	func: JobFunc,
	user_data: rawptr,
	user_idx: uint,
	queue_idx: uint,
	group: ^Group,
) {
	desc: []JobDescription = {
		{
			name = "",
			func = func,
			user_data = user_data,
			user_idx = user_idx,
			queue_idx = queue_idx,
		},
	}
	scheduler_enqueue_batch(sched, desc, group, 0)
}

_jobs_fiber :: proc(fiber: ^Freya, value: ^rawptr) -> rawptr {
	for true {
		job: ^Job = cast(^Job)value
		job.desc.func(job)
		value^ = yield(fiber, rawptr(uintptr(JobStatus.Completed)))
	}
	return nil
}

_jobs_align :: #force_inline proc(n: uint) -> uint {
	return -(-n & transmute(uint)-int(_MAX_ALIGN))
}

_default_fiber_factory :: proc(
	sched: ^Scheduler,
	fiber_idx: uint,
	buffer: rawptr,
	stack_size: uint,
	factory_data: rawptr,
) -> ^Freya {
	return init(buffer, stack_size, cast(FreyaFunc)factory_data, sched)
}

_scheduler_init :: proc(
	buffer: rawptr,
	job_count, queue_count, fiber_count: uint,
	stack_size: uint,
	fiber_factory: _FiberFactoryFunc,
	factory_data: rawptr,
) -> ^Scheduler {
	assert((job_count & (job_count - 1)) == 0, "Freya Jobs Error: Job count must be a power of 2.")
	assert(
		(stack_size & (stack_size - 1)) == 0,
		"Freya Jobs Error: Stack size must be a power of 2.",
	)

	cursor: rawptr = buffer
	sched: ^Scheduler = cast(^Scheduler)cursor
	cursor = rawptr(uintptr(cursor) + uintptr(_jobs_align(size_of(Scheduler))))
	sched._queues = transmute([]_Queue)mem.Raw_Slice{data = cursor, len = int(queue_count)}
	cursor = rawptr(uintptr(cursor) + uintptr(_jobs_align(queue_count * size_of(_Queue))))
	fibers := make([]^Freya, fiber_count)
	sched._fibers = fibers
	sched._fiber_count = fiber_count
	cursor = rawptr(
		uintptr(cursor) +
		uintptr(_jobs_align(size_of(fibers))) +
		uintptr(size_of(sched._fiber_count)),
	)
	job_pool := make([]Job, job_count)
	sched._job_pool = job_pool
	sched._job_count = job_count
	cursor = rawptr(
		uintptr(cursor) +
		uintptr(_jobs_align(size_of(job_pool))) +
		uintptr(size_of(sched._job_count)),
	)

	// Initialize the queues arrays.
	sched._queues = make([]_Queue, queue_count)
	for i in 0 ..< queue_count {
		sched._queues[i] = {
			arr = make([]^Job, job_count),
			head = 0,
			tail = 0,
			mask = job_count - 1,
			parent = nil,
			fallback = nil,
			semaphore_count = 0,
			semaphore_signal = {},
		}
		cursor = rawptr(uintptr(cursor) + uintptr(_jobs_align(job_count * size_of(rawptr))))
	}

	// Fill the job pool
	for i in 0 ..< job_count {
		sched._job_pool[i] = {}
	}
	for i in 0 ..< fiber_count {
		sched._fibers[i] = fiber_factory(sched, i, cursor, stack_size, factory_data)
		cursor = rawptr(uintptr(cursor) + uintptr(stack_size))
	}
	sched._lock = {}
	return sched
}

_get_queue :: #force_inline proc(sched: ^Scheduler, queue_idx: uint) -> ^_Queue {
	assert(queue_idx < len(sched._queues), "Freya Jobs Error: Invalid queue index.")

	return &sched._queues[queue_idx]
}

_queue_next_job :: proc(queue: ^_Queue) -> ^Job {
	if queue.head != queue.tail {
		result := queue.arr[queue.tail]
		queue.tail = (queue.tail + 1) & queue.mask
		return result
	} else if queue.fallback != nil {
		return _queue_next_job(queue.fallback)
	} else {
		return nil
	}
}

_queue_signal :: proc(queue: ^_Queue) {
	if queue.semaphore_count > 0 {
		sync.cond_signal(&queue.semaphore_signal)
		queue.semaphore_count -= 1
	} else if queue.parent != nil {
		_queue_signal(queue.parent)
	}
}

_group_process_wait_list :: proc(sched: ^Scheduler, group: ^Group, job: ^Job) -> ^Job {
	if job != nil {
		next := _group_process_wait_list(sched, group, job.wait_next)
		if group._count <= job.wait_threshold {
			queue := &sched._queues[job.desc.queue_idx]
			queue.arr[queue.head] = job
			queue.head = (queue.head + 1) & queue.mask
			_queue_signal(queue)

			// Unlink from wait list
			job.wait_next = nil
			return next
		} else {
			job.wait_next = next
		}
	}

	return job
}

_group_increment :: #force_inline proc(group: ^Group, count, max_count: uint) -> uint {
	count := count
	if max_count > 0 {
		// Handle already full
		if group._count >= max_count {
			return 0
		}
		// Adjust count
		remaining := max_count - group._count
		if count > remaining {
			count = remaining
		}
	}
	group._count += count
	return count
}

_group_decrement :: #force_inline proc(sched: ^Scheduler, group: ^Group, count: uint) {
	group._count -= count
	group._job_list = _group_process_wait_list(sched, group, group._job_list)
}

_execute_job :: #force_inline proc(sched: ^Scheduler, job: ^Job) {
	assert(sched._fiber_count > 0, "Freya Jobs Error: Ran out of fibers.")

	// Assign a fiber and the thread data. (Jobs that are resuming already have a fiber)
	if job.fiber == nil {
		sched._fiber_count -= 1
		job.fiber = sched._fibers[sched._fiber_count]
	}

	// Unlock the scheduler while executing the job. Fibers re-lock it before yielding back
	sync.mutex_unlock(&sched._lock)

	// profile_enter(job)
	status: JobStatus = cast(JobStatus)uintptr(resume(job.fiber, job))
	// profile_leave(job, status)

	switch status {
	case .Completed:
		{
			sync.mutex_lock(&sched._lock)
			// REturn the components to the pools.
			sched._job_pool[sched._job_count] = job^
			sched._job_count += 1
			sched._fibers[sched._fiber_count] = job.fiber
			sched._fiber_count += 1

			// Did it have a group, and was it the last job being waited for?
			group := job.group
			if group != nil {
				_group_decrement(sched, group, 1)
			}
		}
	case .Yielding:
		{
			sync.mutex_lock(&sched._lock)
			// Push the job to the back of the queue.
			queue := &sched._queues[job.desc.queue_idx]
			queue.arr[queue.head] = job
			queue.head = (queue.head + 1) & queue.mask
			_queue_signal(queue)
		}
	case .Waiting:
		{
			// Do nothing. The job will be re-enqueued when it's done waiting.
			// job_wait() locks the scheduler before yielding
		}
	}
}
