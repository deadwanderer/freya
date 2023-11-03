package jobs_test

import f "../../../freya"

import "core:fmt"
import "core:intrinsics"
import "core:os"
import "core:runtime"
import "core:thread"
import "core:time"

WorkerContext :: struct {
	thread:    ^thread.Thread,
	sched:     ^f.Scheduler,
	queue_idx: uint,
	thread_id: uint,
}

SCHED: ^f.Scheduler
COUNT: uint
WORKER_COUNT: uint = 0

MAX_WORKERS :: 256
WORKERS: [MAX_WORKERS]WorkerContext

task_increment :: proc(task: ^f.Job) {
	intrinsics.atomic_add(&COUNT, 1)
	fmt.println("Incremented")
}

task_more_tasks :: proc(task: ^f.Job) {
	f.scheduler_enqueue_batch(
		SCHED,
		[]f.JobDescription{
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_increment},
			{func = task_more_tasks},
		},
		nil,
		0,
	)

	intrinsics.atomic_add(&COUNT, 1)
}

worker_body :: proc(data: rawptr) {
	ctx: ^WorkerContext = transmute(^WorkerContext)data
	fmt.println("Running scheduler on thread", ctx.thread_id)
	f.scheduler_run(ctx.sched, ctx.queue_idx, .Loop)
}

start_worker_threads :: proc(thread_count: uint, sched: ^f.Scheduler, queue_idx: uint) {
	if thread_count > 0 {
		WORKER_COUNT = thread_count
	} else {
		WORKER_COUNT = uint(os.processor_core_count())
		fmt.printf("%v CPUs detected.\n", WORKER_COUNT)
	}

	fmt.println("Creating WORKERS.")
	for i in 0 ..< WORKER_COUNT {
		WORKERS[i] = {
			sched     = sched,
			queue_idx = queue_idx,
			thread_id = i,
			thread    = thread.create_and_start_with_data(&WORKERS[i], worker_body),
		}

	}
}

destroy_worker_threads :: proc() {
	for i in 0 ..< WORKER_COUNT {
		thread.join(WORKERS[i].thread)
	}
}

main :: proc() {
	COUNT = 0

	SCHED = f.scheduler_new(1024, 1, 64, 64 * 1024)
	start_worker_threads(1, SCHED, 0)

	for i in 0 ..< 16 {
		f.scheduler_enqueue(SCHED, task_more_tasks, nil, 0, 0, nil)
	}

	fmt.println("Waiting")
	seconds: uint = 10

	time.accurate_sleep(10 * time.Second)

	f.scheduler_interrupt(SCHED, 0)
	destroy_worker_threads()

	fmt.printf("Exiting with count: %vK tasks/sec\n", COUNT / 1000 / 10)
}
