package freya

// Enums
RunMode :: enum {
	Loop, // Run jobs from a queue until scheduler_interrupt() is called.
	Flush, // Run jobs from a queue until empty, or until all remaining jobs are waiting.
	Single, // Run a single non-waiting job from a queue.
}

// Structs
Job :: struct {}

JobDescription :: struct {
	// Job name. (optional)
	name:      string,
	// Job body function.
	func:      JobFunc,
	// User defined job context pointer. (optional)
	user_data: rawptr,
	// User defined job index. (optional, useful for parallel-for constructs)
	user_idx:  uintptr,
	// Index of the queue to run the job on.
	queue_idx: uint,
}


Scheduler :: struct {}

Group :: struct {
	_job_list: [dynamic]^Job, // Should this be a pointer-to-Job + count?
	_count:    uint, // Alternatively, just a dynarray or slice?
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
job_get_scheduler :: proc(job: ^Job) -> ^Scheduler {}

// Get the description for a job.
job_get_description :: proc(job: ^Job) -> ^JobDescription {}

// Get the allocation size for a scheduler instance.
scheduler_size :: proc(job_count, queue_count, fiber_count: uint, stack_size: uint) -> uint {}

// Initialize memory for a scheduler. Use tina_scheduler_size() to figure out
// how much you need.
scheduler_init :: proc(
	buffer: rawptr,
	job_count, queue_count, fiber_count: uint,
	stack_size: uint,
) -> ^Scheduler {}

// Initialize memory for a scheduler, with extra options.
scheduler_init_full :: proc(
	buffer: rawptr,
	job_count, queue_count, fiber_count: uint,
	stack_size: uint,
	fiber_factory: ^_FiberFactoryFunc,
	fiber_data: rawptr,
) -> ^Scheduler {}

// Destroy a scheduler. Any unfinished jobs will be lost. Flush your queues if
// you need them to finish gracefully.
scheduler_destroy :: proc(sched: ^Scheduler) {}

// Convenience constructor. Allocate and initialize a scheduler.
scheduler_new :: proc(job_count, queue_count, fiber_count: uint, stack_size: uint) -> ^Scheduler {}

// Convenience destructor. Destroy and free a scheduler.
scheduler_free :: proc(sched: ^Scheduler) {}

// Link a pair of queues for job prioritization. When the 'queue_idx' is empty
// it will steal jobs from 'fallback_idx'.
scheduler_queue_priority :: proc(sched: ^Scheduler, queue_idx: uint, fallback_idx: uint) {}

// Run jobs in the given queue based on the mode, returns false if no jobs were
// run.
scheduler_run :: proc(sched: ^Scheduler, queue_idx: uint, mode: RunMode) -> bool {}

// Interrupt .Loop execution of a queue on all active threads as soon as
// their current jobs finish.
scheduler_interrupt :: proc(sched: ^Scheduler, queue_idx: uint) {}

// Add jobs to the scheduler, optionally pass the address of a tina_group to
// track when the jobs have completed. If 'max_group_count' is non-zero, then
// 'count' will be adjusted based on the number of jobs already in the group.
// Returns the number of jobs added.
scheduler_enqueue_batch :: proc(
	sched: ^Scheduler,
	list: []JobDescription,
	group: ^Group,
	max_group_count: uint,
) -> uint {}

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
) {}

// Yield the current job until the group has 'threshold' or fewer remaining
// jobs. 'threshold' is useful to throttle a producer job. Allowing it to keep a
// consumers busy without a lot of queued items.
job_wait :: proc(job: ^Job, group: ^Group, threshold: uint) -> uint {}

// Yield the current job and reschedule at the back of the queue.
job_yield :: proc(job: ^Job) {}

// Yield the current job and reschedule it at the back of a different queue.
// Returns the old queue the job was scheduled on.
job_switch_queue :: proc(job: ^Job, queue_idx: uint) -> uint {}

// Increment a group's value directly. Allows associating jobs (or some other
// unit of work) with multiple groups. Returns the count added which will be
// adjusted similarly to scheduler_enqueue_batch().
group_increment :: proc(sched: ^Scheduler, group: ^Group, count, max_count: uint) -> uint {}

// Decrement a group's value directly to manually mark completion of some work.
group_decrement :: proc(sched: ^Scheduler, group: ^Group, count: uint) -> uint {}

scheduler_enqueue :: #force_inline proc(
	sched: ^Scheduler,
	func: JobFunc,
	user_data: rawptr,
	user_idx: uintptr,
	queue_idx: uint,
	group: ^Group,
) {
	desc: []JobDescription = {
		{
      name      = "",
		  func      = func,
		  user_data = user_data,
		  user_idx  = user_idx,
		  queue_idx = queue_idx,
    }
	}
	scheduler_enqueue_batch(sched, desc, group, 0)
}
