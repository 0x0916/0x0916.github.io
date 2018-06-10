CPU统计（CPU accounting）`cpuacct子系统`会自动生成报告来显示cgroup任务所使用的CPU资源，其中包括子群组任务。报告有三种：

* `cpuacct.usage`：报告此cgroup中所有任务（包括其子孙层级中的所有任务）使用CPU的总时间（纳秒）,该文件时可以写入0值的，用来进行重置统计信息。
* `cpuacct.stat`：报告cgroup的所有任务（包括其子孙层级中的所有任务）使用的用户和系统CPU时间，方式如下：
  * `user`——用户模式中任务使用的CPU时间
  * `system`——系统模式中任务使用的CPU时间
  * 其单位为`USER_HZ`

* `cpuacct.usage_percpu`:报告cgroup的所有任务（包括其子孙层级中的所有任务）在每个CPU中使用的CPU时间（纳秒）

>  注意：本文中引用的内核代码版本为`v4.4.128`

<!--more-->

## 示例

### 查看使用cpu的总时间

```Bash
$ cat /sys/fs/cgroup/cpuacct/cpuacct.usage
9564131657896
```
### 查看用户时间和系统时间

```bash
$ cat /sys/fs/cgroup/cpuacct/cpuacct.stat 
user 805389
system 131491
```
### 查看每个cpu core的时间

```bash
$ cat /sys/fs/cgroup/cpuacct/cpuacct.usage_percpu 
637358491256 277363499820 315319354313 262949375399 266258588259 222694029292 243511265151 271766486802 296183439108 187266048691 350328567867 202707870444 219737114177 204076133037 208793307513 170673884207 167408270598 170118215735 143558044613 258292673744 273473635687 1910497659425 229618074925 99164716015 42271944626 45446517389 34458890249 45563767142 25218323972 20379223760 20791799486 1315535916629 153794699753 77972099731 38310521396 32196073743 40292640344 59351377303 29113752724 29925834137
```
### 重置统计值

```bash
$ echo 0 > /sys/fs/cgroup/cpuacct/cpuacct.usage
```


## 内核实现

### 结构体struct cpuacct

数据结构定义如下：{{< lts tag="4.4.128" file="kernel/sched/cpuacct.c" line="29">}}

```C
/* track cpu usage of a group of tasks and its child groups */
struct cpuacct {
	struct cgroup_subsys_state css;
	/* cpuusage holds pointer to a u64-type object on every cpu */
	u64 __percpu *cpuusage;
	struct kernel_cpustat __percpu *cpustat;
};
```

除了css外，其他两个成员都是`__percpu`类型。

* `cpuusge` 记录每个cpu使用的时间
* `cpustat` 记录每个cpu使用的用户和系统CPU时间

### 结构体 struct kernel_cpustat


数据结构定义如下：{{< lts tag="4.4.128" file="include/linux/kernel_stat.h" line="20">}}


```C
/*
 * 'kernel_stat.h' contains the definitions needed for doing
 * some kernel statistics (CPU usage, context switches ...),
 * used by rstatd/perfmeter
 */

enum cpu_usage_stat {
	CPUTIME_USER,
	CPUTIME_NICE,
	CPUTIME_SYSTEM,
	CPUTIME_SOFTIRQ,
	CPUTIME_IRQ,
	CPUTIME_IDLE,
	CPUTIME_IOWAIT,
	CPUTIME_STEAL,
	CPUTIME_GUEST,
	CPUTIME_GUEST_NICE,
	NR_STATS,
};

struct kernel_cpustat {
	u64 cpustat[NR_STATS];
};
```

### 变量root_cpuacct

定义如下：{{< lts tag="4.4.128" file="kernel/sched/cpuacct.c" line="52">}} 和{{< lts tag="4.4.128" file="include/linux/kernel_stat.h" line="38">}}

```C
struct kernel_cpustat {                                                                                                           
        u64 cpustat[NR_STATS];
};

DECLARE_PER_CPU(struct kernel_cpustat, kernel_cpustat);


static DEFINE_PER_CPU(u64, root_cpuacct_cpuusage);
static struct cpuacct root_cpuacct = {
	.cpustat	= &kernel_cpustat,
	.cpuusage	= &root_cpuacct_cpuusage,
};
```


`/sys/fs/cgroup/cpuacct`就是通过`cpuacct`结构体中的统计值来输出信息的。而cpu时间信息的更新则由如下函数完成({{< lts tag="4.4.128" file="kernel/sched/cpuacct.h" line="3">}})。

* `cpuacct_charge`

  > 用于更新cpuusage({{< lts tag="4.4.128" file="kernel/sched/cpuacct.c" line="235">}})

* `cpuacct_account_field`

  > 用于更新cpustat({{< lts tag="4.4.128" file="kernel/sched/cpuacct.c" line="263">}})


### 那么哪些函数会调用`cpuacct_charge`呢？

如下函数会去调用`cpuacct_charge`:

* update_curr(struct cfs_rq *cfs_rq)
* update_curr_rt(struct rq *rq)
* update_curr_dl(struct rq *rq)
* put_prev_task_stop(struct rq *rq, struct task_struct *prev)

### 那么哪些函数会调用`cpuacct_account_field`呢？

如下函数会去调用`cpuacct_account_field`:

* `account_system_time`->`__account_system_time`->`task_group_account_field`->`cpuacct_account_field`
* `irqtime_account_process_tick`->`__account_system_time`->`task_group_account_field`->`cpuacct_account_field`
* `account_user_time`->`task_group_account_field`->`cpuacct_account_field`

除此之外，还有如下函数会更新cupstat

* `account_idle_time`
* `account_steal_time`
* `account_guest_time`

### 总结一下

更新cpustat的接口有如下四个：

* account_user_time
* account_system_time
* irqtime_account_process_tick
* account_idle_time
* account_steal_time
* account_guest_time

## 分析更新cpustat的接口实现

### account_user_time

代码地址为：{{< lts tag="4.4.128" file="kernel/sched/cputime.c" line="135">}}

该接口根据`task_nice(p)`是否为真，更新`CPUTIME_NICE`或者`CPUTIME_NICE`

### account_system_time

代码地址为：{{< lts tag="4.4.128" file="kernel/sched/cputime.c" line="211">}}

该接口根据不同的情况可能更新`CPUTIME_IRQ` 或者 `CPUTIME_SOFTIRQ` 或者 `CPUTIME_SYSTEM`

> 注意，该接口还有可能通过接口`account_guest_time`进行时间的更新。

### account_idle_time

代码地址为：{{< lts tag="4.4.128" file="kernel/sched/cputime.c" line="246">}}

该接口更新了` CPUTIME_IDLE`或者`CPUTIME_IOWAIT`，只更新了顶级的cpuacct，即idle时间不是cgroup aware的。

### account_steal_time

代码地址为：{{< lts tag="4.4.128" file="kernel/sched/cputime.c" line="235">}}

该接口更新了` CPUTIME_STEAL`，只更新了顶级的cpuacct，即steal时间不是cgroup aware的。

### account_guest_time

代码地址为：{{< lts tag="4.4.128" file="kernel/sched/cputime.c" line="160">}}

该接口根据`task_nice(p)`是否为真，更新`CPUTIME_NICE and CPUTIME_GUEST_NICE`或者`CPUTIME_USER and CPUTIME_GUEST`, 只更新了顶级的cpuacct，即guest时间不是cgroup aware的。

