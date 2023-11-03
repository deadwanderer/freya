#ifndef FREYA_JOBS_H
#define FREYA_JOBS_H
#define FREYA_JOBS_IMPLEMENTATION
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque type for a scheduler.
typedef struct freya_scheduler freya_scheduler;
// Opaque type for a job.
typedef struct freya_job freya_job;

// Job body function prototype.
typedef void freya_job_func(freya_job* job);

typedef struct {
  // Job name. (optional)
  const char* name;
  // Job body function.
  freya_job_func* func;
  // User defined job context pointer. (optional)
  void* user_data;
  // User defined job index. (optional, useful for parallel-for constructs)
  uintptr_t user_idx;
  // Index of the queue to run the job on.
  unsigned queue_idx;
} freya_job_description;

// Get the scheduler for a job.
freya_scheduler* freya_job_get_scheduler(freya_job* job);
// Get the description for a job.
const freya_job_description* freya_job_get_description(freya_job* job);

// Counter used to signal when a group of jobs is done.
// Note: Must be zero-initialized before use.
typedef struct {
  // Private:
  freya_job* _job_list;
  unsigned _count;
} freya_group;

typedef freya* _freya_fiber_factory(freya_scheduler* sched,
                                    unsigned fiber_idx,
                                    void* buffer,
                                    size_t stack_size,
                                    void* user_ptr);

// Get the allocation size for a scheduler instance.
size_t freya_scheduler_size(unsigned job_count,
                            unsigned queue_count,
                            unsigned fiber_count,
                            size_t stack_size);
// Initialize memory for a scheduler. Use freya_scheduler_size() to figure out
// how much you need.
freya_scheduler* freya_scheduler_init(void* buffer,
                                      unsigned job_count,
                                      unsigned queue_count,
                                      unsigned fiber_count,
                                      size_t stack_size);

// Initialize memory for a scheduler, with extra options.
freya_scheduler* freya_scheduler_init_ex(void* buffer,
                                         unsigned job_count,
                                         unsigned queue_count,
                                         unsigned fiber_count,
                                         size_t stack_size,
                                         _freya_fiber_factory* fiber_factory,
                                         void* fiber_data);
// Destroy a scheduler. Any unfinished jobs will be lost. Flush your queues if
// you need them to finish gracefully.
void freya_scheduler_destroy(freya_scheduler* sched);

#ifndef FREYA_NO_CRT
// Convenience constructor. Allocate and initialize a scheduler.
freya_scheduler* freya_scheduler_new(unsigned job_count,
                                     unsigned queue_count,
                                     unsigned fiber_count,
                                     size_t stack_size);
// Convenience destructor. Destroy and free a scheduler.
void freya_scheduler_free(freya_scheduler* sched);
#endif

// Link a pair of queues for job prioritization. When the 'queue_idx' is empty
// it will steal jobs from 'fallback_idx'.
void freya_scheduler_queue_priority(freya_scheduler* sched,
                                    unsigned queue_idx,
                                    unsigned fallback_idx);

typedef enum {
  FREYA_RUN_LOOP,   // Run jobs from a queue until scheduler_interrupt() is
                    // called.
  FREYA_RUN_FLUSH,  // Run jobs from a queue until empty, or until all remaining
                    // jobs are waiting.
  FREYA_RUN_SINGLE,  // Run a single non-waiting job from a queue.
} freya_run_mode;

// Run jobs in the given queue based on the mode, returns false if no jobs were
// run.
bool freya_scheduler_run(freya_scheduler* sched,
                         unsigned queue_idx,
                         freya_run_mode mode);
// Interrupt FREYA_RUN_LOOP execution of a queue on all active threads as soon
// as their current jobs finish.
void freya_scheduler_interrupt(freya_scheduler* sched, unsigned queue_idx);

// Add jobs to the scheduler, optionally pass the address of a freya_group to
// track when the jobs have completed. If 'max_group_count' is non-zero, then
// 'count' will be adjusted based on the number of jobs already in the group.
// Returns the number of jobs added.
unsigned freya_scheduler_enqueue_batch(freya_scheduler* sched,
                                       const freya_job_description* list,
                                       unsigned count,
                                       freya_group* group,
                                       unsigned max_group_count);
// Add many jobs to the scheduler that share the same description, but use
// sequential indexes. It will schedule 'count' jobs with indexes from 0 to
// count - 1.
void freya_scheduler_enqueue_n(freya_scheduler* sched,
                               freya_job_func* func,
                               void* user_data,
                               unsigned count,
                               unsigned queue_idx,
                               freya_group* group);
// Yield the current job until the group has 'threshold' or fewer remaining
// jobs. 'threshold' is useful to throttle a producer job. Allowing it to keep a
// consumers busy without a lot of queued items.
unsigned freya_job_wait(freya_job* job, freya_group* group, unsigned threshold);
// Yield the current job and reschedule at the back of the queue.
void freya_job_yield(freya_job* job);
// Yield the current job and reschedule it at the back of a different queue.
// Returns the old queue the job was scheduled on.
unsigned freya_job_switch_queue(freya_job* job, unsigned queue_idx);

// Increment a group's value directly. Allows associating jobs (or some other
// unit of work) with multiple groups. Returns the count added which will be
// adjusted similarly to freya_scheduler_enqueue_batch().
unsigned freya_group_increment(freya_scheduler* scheduler,
                               freya_group* group,
                               unsigned count,
                               unsigned max_count);
// Decrement a group's value directly to manually mark completion of some work.
void freya_group_decrement(freya_scheduler* scheduler,
                           freya_group* group,
                           unsigned count);

// Convenience method. Enqueue a single job.
static inline void freya_scheduler_enqueue(freya_scheduler* sched,
                                           freya_job_func* func,
                                           void* user_data,
                                           uintptr_t user_idx,
                                           unsigned queue_idx,
                                           freya_group* group) {
  freya_job_description desc = {.name = NULL,
                                .func = func,
                                .user_data = user_data,
                                .user_idx = user_idx,
                                .queue_idx = queue_idx};
  freya_scheduler_enqueue_batch(sched, &desc, 1, group, 0);
}

#ifdef FREYA_JOBS_IMPLEMENTATION

  // Override these. Based on C11 primitives.
  // Save yourself some trouble and grab
  // https://github.com/tinycthread/tinycthread
  #ifndef _FREYA_MUTEX_T
    #define _FREYA_MUTEX_T SDL_mutex*
    #define _FREYA_MUTEX_INIT(_LOCK_) _LOCK_ = SDL_CreateMutex()
    #define _FREYA_MUTEX_DESTROY(_LOCK_) SDL_DestroyMutex(_LOCK_)
    #define _FREYA_MUTEX_LOCK(_LOCK_) SDL_LockMutex(_LOCK_);
    #define _FREYA_MUTEX_UNLOCK(_LOCK_) SDL_UnlockMutex(_LOCK_);
    #define _FREYA_COND_T SDL_cond*
    #define _FREYA_COND_INIT(_SIG_) _SIG_ = SDL_CreateCond()
    #define _FREYA_COND_DESTROY(_SIG_) SDL_DestroyCond(_SIG_)
    #define _FREYA_COND_WAIT(_SIG_, _LOCK_) SDL_CondWait(_SIG_, _LOCK_)
    #define _FREYA_COND_SIGNAL(_SIG_) \
      { SDL_CondSignal(_SIG_); }
    #define _FREYA_COND_BROADCAST(_SIG_) SDL_CondBroadcast(_SIG_)
  #endif

  #ifndef _FREYA_PROFILE_ENTER
    #define _FREYA_PROFILE_ENTER(_JOB_)
    #define _FREYA_PROFILE_LEAVE(_JOB_, _STATUS_)
  #endif

struct freya_job {
  freya_job_description desc;
  void* user_data;
  freya* fiber;
  freya_group* group;
  freya_job* wait_next;
  unsigned wait_threshold;
};

freya_scheduler* freya_job_get_scheduler(freya_job* job) {
  return (freya_scheduler*)job->fiber->user_data;
}
const freya_job_description* freya_job_get_description(freya_job* job) {
  return &job->desc;
}

typedef struct {
  void** arr;
  size_t count;
} _freya_stack;

// Simple power of two circular queues.
typedef struct _freya_queue _freya_queue;
struct _freya_queue {
  void** arr;
  size_t head, tail, mask;

  // Higher priority queue in the chain. Used for signaling worker threads.
  _freya_queue* parent;
  // Lower priority queue in the chain. Used as a fallback when this queue is
  // empty.
  _freya_queue* fallback;
  // Semaphore to wait for more work in this queue.
  _FREYA_COND_T semaphore_signal;
  unsigned semaphore_count;
  // Incremented each time the queue is interrupted.
  unsigned interrupt_stamp;
};

struct freya_scheduler {
  _FREYA_MUTEX_T _lock;

  _freya_queue* _queues;
  size_t _queue_count;

  // Keep the jobs and fiber pools in a stack so recently used items are fresh
  // in the cache.
  _freya_stack _fibers, _job_pool;
};

typedef enum {
  _FREYA_STATUS_COMPLETED,
  _FREYA_STATUS_WAITING,
  _FREYA_STATUS_YIELDING,
} _freya_job_status;

static void* _freya_jobs_fiber(freya* fiber, void* value) {
  while (true) {
    freya_job* job = (freya_job*)value;
    job->desc.func(job);
    value = freya_yield(fiber, (void*)_FREYA_STATUS_COMPLETED);
  }

  return 0;  // Unreachable.
}

static inline size_t _freya_jobs_align(size_t n) {
  return -(-n & -_FREYA_MAX_ALIGN);
}

size_t freya_scheduler_size(unsigned job_count,
                            unsigned queue_count,
                            unsigned fiber_count,
                            size_t stack_size) {
  size_t size = 0;
  // Size of scheduler.
  size += _freya_jobs_align(sizeof(freya_scheduler));
  // Size of queues.
  size += _freya_jobs_align(queue_count * sizeof(_freya_queue));
  // Size of fiber pool array.
  size += _freya_jobs_align(fiber_count * sizeof(void*));
  // Size of job pool array.
  size += _freya_jobs_align(job_count * sizeof(void*));
  // Size of queue arrays.
  size += queue_count * _freya_jobs_align(job_count * sizeof(void*));
  // Size of jobs.
  size += job_count * _freya_jobs_align(sizeof(freya_job));
  // Size of fibers.
  size += fiber_count * stack_size;
  return size;
}

static freya* _freya_jobs_default_fiber_factory(freya_scheduler* sched,
                                                unsigned fiber_idx,
                                                void* buffer,
                                                size_t stack_size,
                                                void* factory_data) {
  (void)fiber_idx;
  return freya_init(buffer, stack_size, (freya_func*)factory_data, sched);
}

static freya_scheduler* _freya_scheduler_init2(
    void* buffer,
    unsigned job_count,
    unsigned queue_count,
    unsigned fiber_count,
    size_t stack_size,
    _freya_fiber_factory* fiber_factory,
    void* factory_data) {
  _FREYA_ASSERT((job_count & (job_count - 1)) == 0,
                "Freya Jobs Error: Job count must be a power of two.");
  _FREYA_ASSERT((stack_size & (stack_size - 1)) == 0,
                "Freya Jobs Error: Stack size must be a power of two.");
  uint8_t* cursor = (uint8_t*)buffer;

  // Sub allocate all of the memory for the various arrays.
  freya_scheduler* sched = (freya_scheduler*)cursor;
  cursor += _freya_jobs_align(sizeof(freya_scheduler));
  sched->_queues = (_freya_queue*)cursor;
  cursor += _freya_jobs_align(queue_count * sizeof(_freya_queue));
  _freya_stack fibers = {.arr = (void**)cursor, .count = 0};
  sched->_fibers = fibers;
  cursor += _freya_jobs_align(fiber_count * sizeof(void*));
  _freya_stack job_pool = {.arr = (void**)cursor, .count = 0};
  sched->_job_pool = job_pool;
  cursor += _freya_jobs_align(job_count * sizeof(void*));

  // Initialize the queues arrays.
  sched->_queue_count = queue_count;
  for (unsigned i = 0; i < queue_count; i++) {
    _freya_queue* queue = &sched->_queues[i];
    queue->arr = (void**)cursor;
    queue->head = queue->tail = 0;
    queue->mask = job_count - 1;
    queue->parent = queue->fallback = NULL;
    _FREYA_COND_INIT(queue->semaphore_signal);
    queue->semaphore_count = 0;

    cursor += _freya_jobs_align(job_count * sizeof(void*));
  }

  // Fill the job pool.
  sched->_job_pool.count = job_count;
  for (unsigned i = 0; i < job_count; i++) {
    sched->_job_pool.arr[i] = cursor;
    cursor += _freya_jobs_align(sizeof(freya_job));
  }

  // Initialize the fibers and fill the pool.
  sched->_fibers.count = fiber_count;
  for (unsigned i = 0; i < fiber_count; i++) {
    sched->_fibers.arr[i] =
        fiber_factory(sched, i, cursor, stack_size, factory_data);
    cursor += stack_size;
  }

  _FREYA_MUTEX_INIT(sched->_lock);
  return sched;
}

freya_scheduler* freya_scheduler_init(void* buffer,
                                      unsigned job_count,
                                      unsigned queue_count,
                                      unsigned fiber_count,
                                      size_t stack_size) {
  return _freya_scheduler_init2(buffer, job_count, queue_count, fiber_count,
                                stack_size, _freya_jobs_default_fiber_factory,
                                (void*)_freya_jobs_fiber);
}

freya_scheduler* freya_scheduler_init_ex(void* buffer,
                                         unsigned job_count,
                                         unsigned queue_count,
                                         unsigned fiber_count,
                                         size_t stack_size,
                                         _freya_fiber_factory* fiber_factory,
                                         void* fiber_data) {
  return _freya_scheduler_init2(buffer, job_count, queue_count, fiber_count,
                                stack_size, fiber_factory, fiber_data);
}

void freya_scheduler_destroy(freya_scheduler* sched) {
  _FREYA_MUTEX_DESTROY(sched->_lock);
  for (unsigned i = 0; i < sched->_queue_count; i++)
    _FREYA_COND_DESTROY(sched->_queues[i].semaphore_signal);
}

  #ifndef FREYA_NO_CRT
freya_scheduler* freya_scheduler_new(unsigned job_count,
                                     unsigned queue_count,
                                     unsigned fiber_count,
                                     size_t stack_size) {
  void* buffer = malloc(
      freya_scheduler_size(job_count, queue_count, fiber_count, stack_size));
  return freya_scheduler_init(buffer, job_count, queue_count, fiber_count,
                              stack_size);
}

void freya_scheduler_free(freya_scheduler* sched) {
  freya_scheduler_destroy(sched);
  free(sched);
}
  #endif

static inline _freya_queue* _freya_get_queue(freya_scheduler* sched,
                                             unsigned queue_idx) {
  _FREYA_ASSERT(queue_idx < sched->_queue_count,
                "Freya Jobs Error: Invalid queue index.");
  return &sched->_queues[queue_idx];
}

void freya_scheduler_queue_priority(freya_scheduler* sched,
                                    unsigned queue_idx,
                                    unsigned fallback_idx) {
  _freya_queue* parent = _freya_get_queue(sched, queue_idx);
  _freya_queue* fallback = _freya_get_queue(sched, fallback_idx);
  _FREYA_ASSERT(!parent->fallback,
                "Freya Jobs Error: Queue already has a fallback assigned.");
  _FREYA_ASSERT(!fallback->parent,
                "Freya Jobs Error: Queue already has a fallback assigned.");

  parent->fallback = fallback;
  fallback->parent = parent;
}

static freya_job* _freya_queue_next_job(_freya_queue* queue) {
  if (queue->head != queue->tail) {
    return (freya_job*)queue->arr[queue->tail++ & queue->mask];
  } else if (queue->fallback) {
    return _freya_queue_next_job(queue->fallback);
  } else {
    return NULL;
  }
}

static void _freya_queue_signal(_freya_queue* queue) {
  if (queue->semaphore_count) {
    _FREYA_COND_SIGNAL(queue->semaphore_signal);
    queue->semaphore_count--;
  } else if (queue->parent) {
    _freya_queue_signal(queue->parent);
  }
}

static freya_job* _freya_group_process_wait_list(freya_scheduler* sched,
                                                 freya_group* group,
                                                 freya_job* job) {
  if (job) {
    freya_job* next =
        _freya_group_process_wait_list(sched, group, job->wait_next);
    if (group->_count <= job->wait_threshold) {
      // Push the waiting job to the back of it's queue.
      _freya_queue* queue = &sched->_queues[job->desc.queue_idx];
      queue->arr[queue->head++ & queue->mask] = job;
      _freya_queue_signal(queue);

      // Unlink from wait list.
      job->wait_next = NULL;
      return next;
    } else {
      job->wait_next = next;
    }
  }

  return job;
}

static inline unsigned _freya_group_increment(freya_group* group,
                                              unsigned count,
                                              unsigned max_count) {
  if (max_count > 0) {
    // Handle already full.
    if (group->_count >= max_count)
      return 0;
    // Adjust count.
    unsigned remaining = max_count - group->_count;
    if (count > remaining)
      count = remaining;
  }

  group->_count += count;
  return count;
}

static inline void _freya_group_decrement(freya_scheduler* sched,
                                          freya_group* group,
                                          unsigned count) {
  group->_count -= count;
  group->_job_list =
      _freya_group_process_wait_list(sched, group, group->_job_list);
}

static inline void _freya_scheduler_execute_job(freya_scheduler* sched,
                                                freya_job* job) {
  _FREYA_ASSERT(sched->_fibers.count > 0,
                "Freya Jobs Error: Ran out of fibers.");
  // Assign a fiber and the thread data. (Jobs that are resuming already have a
  // fiber)
  if (job->fiber == NULL)
    job->fiber = (freya*)sched->_fibers.arr[--sched->_fibers.count];

  // Unlock the scheduler while executing the job. Fibers re-lock it before
  // yielding back.
  _FREYA_MUTEX_UNLOCK(sched->_lock);

  _FREYA_PROFILE_ENTER(job);
  _freya_job_status status =
      (_freya_job_status)(uintptr_t)freya_resume(job->fiber, job);
  _FREYA_PROFILE_LEAVE(job, status);

  switch (status) {
    case _FREYA_STATUS_COMPLETED: {
      _FREYA_MUTEX_LOCK(sched->_lock);
      // Return the components to the pools.
      sched->_job_pool.arr[sched->_job_pool.count++] = job;
      sched->_fibers.arr[sched->_fibers.count++] = job->fiber;

      // Did it have a group, and was it the last job being waited for?
      freya_group* group = job->group;
      if (group)
        _freya_group_decrement(sched, group, 1);
    } break;
    case _FREYA_STATUS_YIELDING: {
      _FREYA_MUTEX_LOCK(sched->_lock);
      // Push the job to the back of the queue.
      _freya_queue* queue = &sched->_queues[job->desc.queue_idx];
      queue->arr[queue->head++ & queue->mask] = job;
      _freya_queue_signal(queue);
    } break;
    case _FREYA_STATUS_WAITING: {
      // Do nothing. The job will be re-enqueued when it's done waiting.
      // freya_job_wait() locks the scheduler before yielding.
    } break;
  }
}

bool freya_scheduler_run(freya_scheduler* sched,
                         unsigned queue_idx,
                         freya_run_mode mode) {
  bool ran = false;
  _FREYA_MUTEX_LOCK(sched->_lock);
  {
    _freya_queue* queue = _freya_get_queue(sched, queue_idx);

    // Keep looping until the interrupt stamp is incremented.
    unsigned stamp = queue->interrupt_stamp;
    while (mode != FREYA_RUN_LOOP || queue->interrupt_stamp == stamp) {
      freya_job* job = _freya_queue_next_job(queue);
      if (job) {
        _freya_scheduler_execute_job(sched, job);
        ran = true;
        if (mode == FREYA_RUN_SINGLE)
          break;
      } else if (mode == FREYA_RUN_LOOP) {
        // Sleep until more work is added to the queue.
        queue->semaphore_count++;
        _FREYA_COND_WAIT(queue->semaphore_signal, sched->_lock);
      } else {
        break;
      }
    }
  }
  _FREYA_MUTEX_UNLOCK(sched->_lock);
  return ran;
}

void freya_scheduler_interrupt(freya_scheduler* sched, unsigned queue_idx) {
  _FREYA_MUTEX_LOCK(sched->_lock);
  {
    _freya_queue* queue = _freya_get_queue(sched, queue_idx);
    queue->interrupt_stamp++;

    _FREYA_COND_BROADCAST(queue->semaphore_signal);
    queue->semaphore_count = 0;
  }
  _FREYA_MUTEX_UNLOCK(sched->_lock);
}

unsigned freya_scheduler_enqueue_batch(freya_scheduler* sched,
                                       const freya_job_description* list,
                                       unsigned count,
                                       freya_group* group,
                                       unsigned max_group_count) {
  _FREYA_MUTEX_LOCK(sched->_lock);
  {
    if (group)
      count = _freya_group_increment(group, count, max_group_count);

    _FREYA_ASSERT(sched->_job_pool.count >= count,
                  "Freya Jobs Error: Ran out of jobs.");
    for (size_t i = 0; i < count; i++) {
      _FREYA_ASSERT(list[i].func,
                    "Freya Jobs Error: Job must have a body function.");

      // Pop a job from the pool.
      freya_job* job =
          (freya_job*)sched->_job_pool.arr[--sched->_job_pool.count];
      freya_job job_value = {.desc = list[i],
                             .user_data = NULL,
                             .fiber = NULL,
                             .group = group,
                             .wait_next = NULL,
                             .wait_threshold = 0};
      (*job) = job_value;

      // Push it to the proper queue.
      _freya_queue* queue = _freya_get_queue(sched, list[i].queue_idx);
      queue->arr[queue->head++ & queue->mask] = job;
      _freya_queue_signal(queue);
    }
  }
  _FREYA_MUTEX_UNLOCK(sched->_lock);

  return count;
}

void freya_scheduler_enqueue_n(freya_scheduler* sched,
                               freya_job_func* func,
                               void* user_data,
                               unsigned count,
                               unsigned queue_idx,
                               freya_group* group) {
  unsigned cursor = 0;
  freya_job_description desc[256];

  for (unsigned i = 0; i < count; i++) {
    // Push description
    freya_job_description description = {.name = NULL,
                                         .func = func,
                                         .user_data = user_data,
                                         .user_idx = i,
                                         .queue_idx = queue_idx};
    desc[cursor++] = description;

    // Check if the buffer is full.
    if (cursor == 256) {
      freya_scheduler_enqueue_batch(sched, desc, cursor, group, 0);
      cursor = 0;
    };
  }

  // Queue the remainder.
  if (cursor)
    freya_scheduler_enqueue_batch(sched, desc, cursor, group, 0);
}

unsigned freya_job_wait(freya_job* job,
                        freya_group* group,
                        unsigned threshold) {
  _FREYA_MUTEX_LOCK(freya_job_get_scheduler(job)->_lock);

  // Check if we need to wait at all.
  unsigned count = group->_count;
  if (count > threshold) {
    // Push onto wait list.
    job->wait_next = group->_job_list;
    group->_job_list = job;

    job->wait_threshold = threshold;
    // NOTE: Scheduler will be unlocked after yielding.
    freya_yield(job->fiber, (void*)_FREYA_STATUS_WAITING);
    job->wait_threshold = 0;

    return group->_count;
  } else {
    _FREYA_MUTEX_UNLOCK(freya_job_get_scheduler(job)->_lock);
    return count;
  }
}

void freya_job_yield(freya_job* job) {
  freya_yield(job->fiber, (void*)_FREYA_STATUS_YIELDING);
}

unsigned freya_job_switch_queue(freya_job* job, unsigned queue_idx) {
  unsigned old_queue = job->desc.queue_idx;
  if (queue_idx == old_queue)
    return queue_idx;

  job->desc.queue_idx = queue_idx;
  freya_yield(job->fiber, (void*)_FREYA_STATUS_YIELDING);
  return old_queue;
}

unsigned freya_group_increment(freya_scheduler* scheduler,
                               freya_group* group,
                               unsigned count,
                               unsigned max_count) {
  _FREYA_MUTEX_LOCK(scheduler->_lock);
  count = _freya_group_increment(group, count, max_count);
  _FREYA_MUTEX_UNLOCK(scheduler->_lock);
  return count;
}

void freya_group_decrement(freya_scheduler* scheduler,
                           freya_group* group,
                           unsigned count) {
  _FREYA_MUTEX_LOCK(scheduler->_lock);
  _FREYA_ASSERT(group->_count >= count,
                "Freya Jobs Error: Group count underflow.");
  _freya_group_decrement(scheduler, group, count);
  _FREYA_MUTEX_UNLOCK(scheduler->_lock);
}

#endif  // FREYA_JOB_IMPLEMENTATION

#ifdef __cplusplus
}
#endif

#endif  // FREYA_JOBS_H
