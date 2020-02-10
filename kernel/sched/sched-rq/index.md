
本文介绍了Linux调度中的CPU运行队列。

<!--more-->

每个`CPU`都有自己的 `struct rq` 结构，其用于描述在此`CPU`上所运行的所有进程，其包括一个**实时进程队列**和一个**根CFS**运行队列，在调度时，调度器首先会先去实时进程队列找是否有实时进程需要运行，如果没有才会去`CFS`运行队列是否有进行需要运行，这就是为什么常说的实时进程优先级比普通进程高，不仅仅体现在`prio`优先级上，还体现在调度器的设计上。

> 注意： 在该版本的内核中，`struct rq`中还包括一个`Deadline`调度类需要的队列`dl_rq`


```c
//CPU运行队列，每个CPU包含一个struct rq 
/*
 * This is the main, per-CPU runqueue data structure.
 *
 * Locking rule: those places that want to lock multiple runqueues
 * (such as the load balancing or the thread migration code), lock
 * acquire operations must be ordered by ascending &runqueue.
 */
struct rq {
        /* runqueue lock: */
        raw_spinlock_t lock;

        /*
         * nr_running and cpu_load should be in the same cacheline because
         * remote CPUs use both these fields when doing load calculation.
         */
        unsigned int nr_running; //此CPU上总共就绪的进程数，包括cfs，rt和正在运行的 
#ifdef CONFIG_NUMA_BALANCING
        unsigned int nr_numa_running;
        unsigned int nr_preferred_running;
#endif
        #define CPU_LOAD_IDX_MAX 5
        unsigned long cpu_load[CPU_LOAD_IDX_MAX]; //根据CPU历史情况计算的负载，cpu_load[0]一直等于load.weight，当达到负载平衡时，cpu_load[1]和cpu_load[2]都应该等于load.weight
        unsigned long last_load_update_tick; //最后一次更新 cpu_load 的时间
#ifdef CONFIG_NO_HZ_COMMON
        u64 nohz_stamp;
        unsigned long nohz_flags;
#endif
#ifdef CONFIG_NO_HZ_FULL
        unsigned long last_sched_tick;
#endif
        int skip_clock_update; //是否需要更新rq的运行时

        /* capture load from *all* tasks on this cpu: */
        struct load_weight load; //CPU负载，该CPU上所有可运行进程的load之和，nr_running更新时这个值也必须更新
        unsigned long nr_load_updates;
        u64 nr_switches; //进行上下文切换次数，只有proc会使用这个

        struct cfs_rq cfs; //cfs调度运行队列，包含红黑树的根
        struct rt_rq rt; //实时调度运行队列

#ifdef CONFIG_FAIR_GROUP_SCHED
        /* list of leaf cfs_rq on this cpu: */
        struct list_head leaf_cfs_rq_list;
#ifdef CONFIG_SMP
        RH_KABI_DEPRECATE(unsigned long, h_load_throttle)
#endif /* CONFIG_SMP */
#endif /* CONFIG_FAIR_GROUP_SCHED */

#ifdef CONFIG_RT_GROUP_SCHED
        struct list_head leaf_rt_rq_list;
#endif

        /*
         * This is part of a global counter where only the total sum
         * over all CPUs matters. A task can increase this counter on
         * one CPU and if it got migrated afterwards it may decrease
         * it on another CPU. Always updated under the runqueue lock:
         */
        unsigned long nr_uninterruptible; //曾经处于队列但现在处于TASK_UNINTERRUPTIBLE状态的进程数量
        //curr: 当前正在此CPU上运行的进程
        //idle: 当前CPU上idle进程的指针，idle进程用于当CPU没事做的时候调用，它什么都不执行 
        struct task_struct *curr, *idle, *stop;
        unsigned long next_balance; //下次进行负载平衡执行时间
        struct mm_struct *prev_mm; //在进程切换时用来存放换出进程的内存描述符地址

        u64 clock; //rq运行时间
        u64 clock_task;

        atomic_t nr_iowait;

#ifdef CONFIG_SMP
        struct root_domain *rd;
        // 当前CPU所在基本调度域，每个调度域包含一个或多个CPU组，每个CPU组包含该调度域中一个或多个CPU子集，负载均衡都是在调度域中的组之间完成的，不能跨域进行负载均衡
        struct sched_domain *sd;

        unsigned long cpu_power;

        unsigned char idle_balance;
        /* For active balancing */
        int post_schedule;
        int active_balance; //如果需要把进程迁移到其他运行队列，就需要设置这个位
        int push_cpu;
        struct cpu_stop_work active_balance_work;
        /* cpu of this runqueue: */
        int cpu; //该运行队列所属CPU 
        int online;

        struct list_head cfs_tasks;

        u64 rt_avg;
        //该运行队列存活时间
        u64 age_stamp;
        u64 idle_stamp;
        u64 avg_idle;

        /* This is used to determine avg_idle's max value */
        u64 max_idle_balance_cost;
#endif

#ifdef CONFIG_IRQ_TIME_ACCOUNTING
        u64 prev_irq_time;
#endif
#ifdef CONFIG_PARAVIRT
        u64 prev_steal_time;
#endif
#ifdef CONFIG_PARAVIRT_TIME_ACCOUNTING
        u64 prev_steal_time_rq;
#endif

        /* calc_load related fields */
        unsigned long calc_load_update; //用于负载均衡
        long calc_load_active;

#ifdef CONFIG_SCHED_HRTICK
#ifdef CONFIG_SMP
        int hrtick_csd_pending;
        struct call_single_data hrtick_csd;
#endif
        struct hrtimer hrtick_timer; //调度使用的高精度定时
#endif

#ifdef CONFIG_SMP
        struct llist_head wake_list;
#endif

        struct sched_avg avg;

        RH_KABI_EXTEND(struct dl_rq dl)

#ifndef __GENKSYMS__
        /* CONFIG_SCHEDSTATS */
        /* latency stats */
        struct sched_info rq_sched_info;
        unsigned long long rq_cpu_time;
        /* could above be rq->cfs_rq.exec_clock + rq->rt_rq.rt_runtime ? */

        /* sys_sched_yield() stats */
        unsigned int yld_count;

        /* schedule() stats */
        unsigned int sched_count;
        unsigned int sched_goidle;

        /* try_to_wake_up() stats */
        unsigned int ttwu_count;
        unsigned int ttwu_local;

        unsigned long cpu_capacity_orig;
#endif /* __GENKSYMS__ */
};
```

内核中定义了`runqueues`这个每cpu变量，来描述系统上的所运行的所有进程：


```c
DECLARE_PER_CPU(struct rq, runqueues);
DEFINE_PER_CPU_SHARED_ALIGNED(struct rq, runqueues);
```

以一个有`4`个逻辑`cpu`的虚拟机为例，通过`crash`查看`runqueues`这个`每cpu变量`如下：

```bash
crash> p runqueues
PER-CPU DATA TYPE:
  struct rq runqueues;
PER-CPU ADDRESSES:
  [0]: ffff9236dfc18b80
  [1]: ffff9236dfc98b80
  [2]: ffff9236dfd18b80
  [3]: ffff9236dfd98b80
```

`struct rq`和各个调度算法的运行队列的关系如下图：

![](./runqueues.svg "")
