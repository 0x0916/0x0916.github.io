本系列文章主要从源码入手，分析`linux kernel`中`cgroup`的实现。


> 本文基于`3.10.0-862.el7.x86_64`版本kernel进行分析。

<!--more-->

## 基本概念

在进行源码分析之前， 我们有必要了解一下cgroup的基本概念。

### cgroup功能

`Cgroups`是`control groups`的缩写，是`Linux`内核提供的一种可以限制、记录、隔离进程组（`process groups`）所使用的物理资源（如：`cpu,memory,IO`等等）的机制。`cgroups`也是**LXC**和**Docker**为实现虚拟化所使用的资源管理手段。 

`Cgroups` 最初的目标是为资源管理提供的一个统一的框架，既整合现有的 cpuset 等子系统，也为未来开发新的子系统提供接口。现在的 `cgroups` 适用于多种应用场景，从单个进程的资源控制，到实现操作系统层次的虚拟化(OS Level Virtualization)。`Cgroups` 提供了一下功能:

- 限制进程组可以使用的资源数量（Resource limiting ）。比如：memory子系统可以为进程组设定一个memory使用上限，一旦进程组使用的内存达到限额再申请内存，就会出发OOM（out of memory）。
- 进程组的优先级控制（Prioritization ）。比如：可以使用cpu子系统为某个进程组分配特定cpu share。
- 记录进程组使用的资源数量（Accounting ）。比如：可以使用cpuacct子系统记录某个进程组使用的cpu时间。
- 进程组隔离（Isolation）。比如：使用ns子系统可以使不同的进程组使用不同的namespace，以达到隔离的目的，不同的进程组有各自的进程、网络、文件系统挂载空间。
- 进程组控制（Control）。比如：使用freezer子系统可以将进程组挂起和恢复。

### 概念

- 任务（`task`）。在cgroups中，任务就是系统的一个进程。
- 控制族群（`coontrol group`）就是一组按照某种标准划分的进程。`Cgroups`中的资源控制都是以控制族群为单位实现。一个进程可以加入到某个控制族群，也从一个进程组迁移到另一个控制族群。一个进程组的进程可以使用`cgroups`以控制族群为单位分配的资源，同时受到`cgroups`以控制族群为单位设定的限制。
- 层级（`hierarchy`）。控制族群可以组织成`hierarchical`的形式，既一颗控制族群树。控制族群树上的子节点控制族群是父节点控制族群的孩子，继承父控制族群的特定的属性。
- 子系统（`subsytem`）。一个子系统就是一个资源控制器，比如cpu子系统就是控制cpu时间分配的一个控制器。子系统必须附加（attach）到一个层级上才能起作用，一个子系统附加到某个层级以后，这个层级上的所有控制族群都受到这个子系统的控制

## css_set 和 cgroup 的多对多的关系

我们先从进程的角度出发，来剖析`cgroups`相关数据结构之间的关系。


### task_struct 结构

在 `Linux` 中，管理进程的数据结构是 `task_struct`，其中与 `cgroups` 有关的是如下两个成员:

```c
#ifdef CONFIG_CGROUPS
	/* Control Group info protected by css_set_lock */
	struct css_set __rcu *cgroups;
	/* cg_list protected by css_set_lock and tsk->alloc_lock */
	struct list_head cg_list;
#endif
```
其中`cgroups`指向了一个`css_set`结构，而`css_set`存储了与进程相关的`cgroups`信息。`cg_list`将使用同一个`css_set`的进程链接在一起。


### css_set 结构

我们来看`css_set`结构：

```c
/*
 * A css_set is a structure holding pointers to a set of
 * cgroup_subsys_state objects. This saves space in the task struct
 * object and speeds up fork()/exit(), since a single inc/dec and a
 * list_add()/del() can bump the reference count on the entire cgroup
 * set for a task.
 */
struct css_set {

	/* Reference count */
	atomic_t refcount;
	
	/*
	 * List running through all cgroup groups in the same hash
	 * slot. Protected by css_set_lock
	 */
	struct hlist_node hlist;
	
	/*
	 * List running through all tasks using this cgroup
	 * group. Protected by css_set_lock
	 */
	struct list_head tasks;
	
	/*
	 * List of cg_cgroup_link objects on link chains from
	 * cgroups referenced from this css_set. Protected by
	 * css_set_lock
	 */
	struct list_head cg_links;
	
	/*
	 * Set of subsystem states, one for each subsystem. This array
	 * is immutable after creation apart from the init_css_set
	 * during subsystem registration (at boot time) and modular subsystem
	 * loading/unloading.
	 */
	struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT];
	
	/* For RCU-protected deletion */
	struct rcu_head rcu_head;
};
```

* 其中`refcount`是该`css_set`的引用计数，因为一个`css_set`可以被多个进程共用,只要这些进程的`cgroups`信息相同。比如：在所有已经创建的层级里面都在同一个`cgroup`里的进程。
* `hlist`是嵌入的`hlist_node`，用于把所有的`css_set`组成一个`hash`表，这样内核可以快速查找特定的`css_set`（后续单独有文字分析这个）。
* `tasks`是将所有引用此`css_set`的进程连接成链表。
* `cg_links`指向一个由`struct cg_cgroup_link`组成的链表。
* `subsys`是一个指针数组，存储一组指向`cgroup_subsys_state`的指针。一个`cgroup_subsys_state`就是进程与一个特定的子系统相关的信息。通过这个指针，进程就可以获得相应的`cgroups`控制信息了。


我们可以通过实验，观察一下`css_set`中的`tasks`链表。

```bash
# 启动两个sleep进程
~ # sleep 72000 &
[1] 1968
~ # sleep 72000 &
[2] 1973
~ # # 创建一个新的memory cgroup
~ # mkdir /sys/fs/cgroup/memory/test1
~ # # 将这两个进程加入到新创建的cgroup中
~ # echo 1968 > /sys/fs/cgroup/memory/test1/cgroup.procs 
~ # echo 1973 > /sys/fs/cgroup/memory/test1/cgroup.procs
~ # cat /sys/fs/cgroup/memory/test1/cgroup.procs
1968
1973
```

通过`crash`，我们可以看到这两个进程使用同一个`css_set`, 而使用同一个`css_set`的进程被`cg_list`链接到了一起，其链表头为`css_set`中的成员`tasks`。

```
crash> task -R cgroups 1968
PID: 1968   TASK: ffff904710fdc000  CPU: 0   COMMAND: "sleep"
  cgroups = 0xffff90460d67b9c0, 

crash> task -R cgroups 1973
PID: 1973   TASK: ffff90463b61c000  CPU: 0   COMMAND: "sleep"
  cgroups = 0xffff90460d67b9c0, 

crash> struct -o css_set 0xffff90460d67b9c0
struct css_set {
  [ffff90460d67b9c0] atomic_t refcount;
  [ffff90460d67b9c8] struct hlist_node hlist;
  [ffff90460d67b9d8] struct list_head tasks;
  [ffff90460d67b9e8] struct list_head cg_links;
  [ffff90460d67b9f8] struct cgroup_subsys_state *subsys[13];
  [ffff90460d67ba60] struct callback_head callback_head;
}
SIZE: 176
crash> list -l task_struct.cg_list -s task_struct.comm -H ffff90460d67b9d8
ffff90463b61d508
  comm = "sleep\000\000\000\060\000\000\000\000\000\000"
ffff904710fdd508
  comm = "sleep\000\000\000\060\000\000\000\000\000\000"
```

### cgroup_subsys_state 结构

接着，我们来看`cgroup_subsys_state`结构

```c
/* Per-subsystem/per-cgroup state maintained by the system. */
struct cgroup_subsys_state {
	/*
	 * The cgroup that this subsystem is attached to. Useful
	 * for subsystems that want to know about the cgroup
	 * hierarchy structure
	 */
	struct cgroup *cgroup;
	
	/*
	 * State maintained by the cgroup system to allow subsystems
	 * to be "busy". Should be accessed via css_get(),
	 * css_tryget() and css_put().
	 */
	atomic_t refcnt;
	
	unsigned long flags;
	/* ID for this css, if possible */
	struct css_id __rcu *id;
	
	/* Used to put @cgroup->dentry on the last css_put() */
	struct work_struct dput_work;
};
```

* `cgroup`指针指向了一个`cgroup`结构，也就是进程属于的`cgroup`。进程受到子系统的控制，实际上是通过加入到特定的`cgroup`实现的，因为`cgroup`在特定的层级上，而子系统又是附加到层级上的。


通过以上三个结构，`task_struct`就可以和`cgroup` 连接起来了 :`task_struct->css_set->cgroup_subsys_state->cgroup`


### cgroup 结构

我们再来看`cgroup`结构：

```c
struct cgroup {
	unsigned long flags;		/* "unsigned long" so bitops work */
	
	/*
	 * count users of this cgroup. >0 means busy, but doesn't
	 * necessarily indicate the number of tasks in the cgroup
	 */
	atomic_t count;
	
	int id;				/* ida allocated in-hierarchy ID */
	/*
	 * We link our 'sibling' struct into our parent's 'children'.
	 * Our children link their 'sibling' into our 'children'.
	 */
	struct list_head sibling;	/* my parent's children */
	struct list_head children;	/* my children */
	struct list_head files;		/* my files */
	
	struct cgroup *parent;		/* my parent */
	struct dentry *dentry;		/* cgroup fs entry, RCU protected */

	/*
	 * This is a copy of dentry->d_name, and it's needed because
	 * we can't use dentry->d_name in cgroup_path().
	 *
	 * You must acquire rcu_read_lock() to access cgrp->name, and
	 * the only place that can change it is rename(), which is
	 * protected by parent dir's i_mutex.
	 *
	 * Normally you should use cgroup_name() wrapper rather than
	 * access it directly.
	 */
	struct cgroup_name __rcu *name;
	
	/* Private pointers for each registered subsystem */
	struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT];
	struct cgroupfs_root *root;

	/*
	 * List of cg_cgroup_links pointing at css_sets with
	 * tasks in this cgroup. Protected by css_set_lock
	 */
	struct list_head css_sets;
	struct list_head allcg_node;	/* cgroupfs_root->allcg_list */
	struct list_head cft_q_node;	/* used during cftype add/rm */

	/*
	 * Linked list running through all cgroups that can
	 * potentially be reaped by the release agent. Protected by
	 * release_list_lock
	 */
	struct list_head release_list;

	/*
	 * list of pidlists, up to two for each namespace (one for procs, one
	 * for tasks); created on demand.
	 */
	struct list_head pidlists;
	struct mutex pidlist_mutex;

	/* For RCU-protected deletion */
	struct rcu_head rcu_head;
	struct work_struct free_work;

	/* List of events which userspace want to receive */
	struct list_head event_list;
	spinlock_t event_list_lock;

	/* directory xattrs */
	struct simple_xattrs xattrs;
};
```

* `sibling`,`children`和`parent`三个嵌入的`list_head`负责将同一层级的`cgroup`连接成一颗`cgroup`树。
* `subsys`是一个指针数组，存储一组指向`cgroup_subsys_state`的指针。这组指针指向了此`cgroup`跟各个子系统相关的信息，这个跟`css_set`中的道理是一样的。
* `root`指向了一个`cgroupfs_root`的结构，就是`cgroup`所在的层级对应的结构体。
* `root->top_cgroup`指向了所在层级的根`cgroup`，也就是创建层级时自动创建的那个`cgroup`。`cgroup->root->top_cgroup` 可以获取层级的根`cgroup`信息
* `css_sets`指向一个由`struct cg_cgroup_link`连成的链表，跟`css_set`中`cg_links`一样



### `css_set`和`cgroup`之间的关系

#### cg_cgroup_link 结构

下面我们来分析一个`css_set`和`cgroup`之间的关系。我们先看一下`cg_cgroup_link`的结构

```C
/* Link structure for associating css_set objects with cgroups */
struct cg_cgroup_link {
	/*
	 * List running through cg_cgroup_links associated with a
	 * cgroup, anchored on cgroup->css_sets
	 */
	struct list_head cgrp_link_list;
	struct cgroup *cgrp;
	/*
	 * List running through cg_cgroup_links pointing at a
	 * single css_set object, anchored on css_set->cg_links
	 */
	struct list_head cg_link_list;
	struct css_set *cg;
};
```

* `cgrp_link_list`连入到`cgroup->css_sets`指向的链表
* `cgrp`则指向此`cg_cgroup_link`相关的`cgroup`。
* `cg_link_list`则连入到`css_set->cg_links`指向的链表
* `cg`则指向此`cg_cgroup_link`相关的`css_set`。

#### **那为什么要这样设计呢?**

那是因为`cgroup`和`css_set`是一个**多对多**的关系，必须添加一个中间结构来将两者联系起来，这跟数据库模式设计是一个道理。

`cg_cgroup_link`中的`cgrp`和`cg`就是此结构体的联合主键，而`cgrp_link_list`和`cg_link_list`分别连入到`cgroup`和`css_set`相应的链表，使得能从`cgroup`或`css_set`都可以进行遍历查询。

#### **那为什么cgroup和css_set是多对多的关系呢?**

一个进程对应`css_set`，一个`css_set`就存储了一组进程跟各个子系统相关的信息，但是这些信息有可能不是从一个`cgroup`那里获得的，因为一个进程可以同时属于几个`cgroup`，只要这些`cgroup`不在同一个层级。

> 举个例子：我们创建一个层级A，A上面附加了cpu和memory两个子系统，进程x属于A的根cgroup; 然后我们再创建一个层级B，B上面附加了pids和blkio两个子系统，进程x同样属于B的根cgroup; 那么进程x对应的cpu和memory的信息是从A的根cgroup获得的，pids和blkio信息则是从B的根cgroup获得的。

因此，**一个`css_set`存储的`cgroup_subsys_state`可以对应多个`cgroup`**。

另一方面，`cgroup`也存储了一组`cgroup_subsys_state`，这一组`cgroup_subsys_state`则是`cgroup`从所在的层级附加的子系统获得的。一个`cgroup`中可以有多个进程，而这些进程的`css_set`不一定都相同，因为有些进程可能还加入了其他`cgroup`。但是同一个`cgroup`中的进程与该`cgroup`关联的`cgroup_subsys_state`都受到该`cgroup`的管理(`cgroups`中进程控制是以`cgroup`为单位的)的，**所以一个`cgroup`也可以对应多个`css_set`。**

经过前面的分析，我们可以看出从`task_struct`到`cgroup`是很容易定位的（`task_struct->css_set->cgroup_subsys_state->cgroup`），当然我们也可以通过`cg_cgroup_link`定位到进程对应的所有cgroup，示意图如下：

![css_set-to-cgroup][1]

但是从`cgroup`获取此`cgroup`所有的`task_struct`就必须通过`cg_cgroup_link`这个结构了。

每个进程都会指向一个`css_set`，而与这个`css_set`关联的所有进程都会链入到`css_set->tasks`链表.而`cgroup`又通过一个中间结构`cg_cgroup_link`来寻找所有与之关联的所有`css_set`，从而可以得到与`cgroup`关联的所有进程。示意图如下：

![cgroup-to-css_set][2]

#### 实验

在后台启动两个睡眠进程（睡眠足够长，为了后续好观察）:

```bash
~  # sleep 36000 &
[1] 28889
~  # sleep 36000 &
[2] 28894
```

新创建一个`memory`的`cgroup`和一个`pids`的`cgroup`。并分布将两个睡眠进程加入到新创建的`cgroup`中。

```bash
~  # cd /sys/fs/cgroup/
/sys/fs/cgroup  # mkdir memory/test
/sys/fs/cgroup  # echo 28889 > memory/test/cgroup.procs 
/sys/fs/cgroup  # mkdir pids/test
/sys/fs/cgroup  # echo 28894 > pids/test/cgroup.procs 
```

**通过`task_struct->css_set->cgroup_subsys_state->cgroup` 查找cgroup**

我们通过`crash`可以查看这两个进程，可以看出两个进程对应的`css_set`不同。

```
crash> task -R cgroups 28889
PID: 28889  TASK: ffff904653b10000  CPU: 3   COMMAND: "sleep"
  cgroups = 0xffff9046d1ef1a80, 

crash> task -R cgroups 28894
PID: 28894  TASK: ffff90470446c000  CPU: 1   COMMAND: "sleep"
  cgroups = 0xffff9047076a8540, 
```

我们输出`css_set`的详细信息：

```
crash> css_set.cg_links,subsys 0xffff9046d1ef1a80
  cg_links = {
    next = 0xffff904713f68958, 
    prev = 0xffff904713f68558
  }
  subsys = {0xffffffffa3ffb2a0, 0xffff90471e913a00, 0xffffffffa49ac1c0, 0xffffffffa3ff1560, 0xffff904688253000, 0xffff9046d6aa4180, 0xffff90471e919540, 0xffff90471e913a80, 0xffffffffa40990c0, 0xffff90471e913b00, 0xffff90471e919600, 0xffff9046db1d1e40, 0xffff90471e913b80}
crash> css_set.cg_links,subsys 0xffff9047076a8540
  cg_links = {
    next = 0xffff904646222958, 
    prev = 0xffff904646222098
  }
  subsys = {0xffffffffa3ffb2a0, 0xffff90471e913a00, 0xffffffffa49ac1c0, 0xffffffffa3ff1560, 0xffff90471e96d000, 0xffff9046d6aa4180, 0xffff90471e919540, 0xffff90471e913a80, 0xffffffffa40990c0, 0xffff90471e913b00, 0xffff90471e919600, 0xffff9046448959c0, 0xffff90471e913b80}
```

这两个进程除了`memory cgroup` 和`pids cgroup `不同外，其他的`cgroup`都相同。这可以通过如上的`css_set`的`subsys`观察到。

通过`cgroup_subsys_state`可以找到`cgroup`，`cgroup`中也存在着`cgroup_subsys_state`。不同的控制器结构体种第一个字段都是`cgroup_subsys_state`。

他们的关系如下：

```
crash> cgroup_subsys_state.cgroup 0xffffffffa3ffb2a0
  cgroup = 0xffff90471418e030
crash> cgroup.subsys 0xffff90471418e030
  subsys = {0xffffffffa3ffb2a0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0}
crash> 
```

**通过`css_set`的`cg_links`找`cgroup`**

```
crash> struct -o css_set.cg_links 0xffff9046d1ef1a80
struct css_set {
  [ffff9046d1ef1aa8] struct list_head cg_links;
}
crash> struct -o css_set.cg_links 0xffff9047076a8540
struct css_set {
  [ffff9047076a8568] struct list_head cg_links;
}
crash> list -l cg_cgroup_link.cg_link_list  -s  cg_cgroup_link.cgrp -H ffff9047076a8568
ffff904646222958
  cgrp = 0xffffffffa57ff030
ffff904646222758
  cgrp = 0xffff9046894d0c00
ffff9046462227d8
  cgrp = 0xffff904714188030
ffff904646222b18
  cgrp = 0xffff90471418e030
ffff904646222c98
  cgrp = 0xffff90471418c030
ffff904646222698
  cgrp = 0xffff9047143c6030
ffff904646222458
  cgrp = 0xffff9047143c4030
ffff904646222498
  cgrp = 0xffff9047143c2030
ffff904646222e98
  cgrp = 0xffff9047143c0030
ffff904646222a18
  cgrp = 0xffff9046881b5c00
ffff904646222618
  cgrp = 0xffff9047143ba030
ffff904646222798
  cgrp = 0xffff9046db3e7400
ffff904646222098
  cgrp = 0xffff9047143be030
crash> list -l cg_cgroup_link.cg_link_list  -s  cg_cgroup_link.cgrp -H ffff9046d1ef1aa8
ffff904713f68958
  cgrp = 0xffffffffa57ff030
ffff904713f68bd8
  cgrp = 0xffff9046894d0c00
ffff904713f68fd8
  cgrp = 0xffff90464b624000
ffff904713f68158
  cgrp = 0xffff90471418e030
ffff904713f687d8
  cgrp = 0xffff90471418c030
ffff904713f685d8
  cgrp = 0xffff9047143c6030
ffff904713f68118
  cgrp = 0xffff9047143c4030
ffff904713f68a98
  cgrp = 0xffff9047143c2030
ffff904713f68658
  cgrp = 0xffff9047143c0030
ffff904713f684d8
  cgrp = 0xffff904634e32000
ffff904713f68418
  cgrp = 0xffff9047143ba030
ffff904713f68998
  cgrp = 0xffff9046db3e7400
ffff904713f68558
  cgrp = 0xffff9047143be030
```

可以看出，我们的系统上有`13`个`cgroup`子系统

```
# cat /proc/cgroups 
#subsys_name    hierarchy       num_cgroups     enabled
cpuset  3       2       1
debug   4       3       1
cpu     5       40      1
cpuacct 5       40      1
memory  2       44      1
devices 11      42      1
freezer 10      2       1
net_cls 12      2       1
blkio   8       42      1
perf_event      6       2       1
hugetlb 7       2       1
pids    9       109     1
net_prio        12      2       1
```

** 通过`cgroup`的`css_sets`找`css_set`, 进而找到task_struct**


我们以刚才新创建的`cgroup`为例，其应该只有一个对应的`css_set`

```
crash> css_set.cg_links,subsys 0xffff9046d1ef1a80
  cg_links = {
    next = 0xffff904713f68958, 
    prev = 0xffff904713f68558
  }
  subsys = {0xffffffffa3ffb2a0, 0xffff90471e913a00, 0xffffffffa49ac1c0, 0xffffffffa3ff1560, 0xffff904688253000, 0xffff9046d6aa4180, 0xffff90471e919540, 0xffff90471e913a80, 0xffffffffa40990c0, 0xffff90471e913b00, 0xffff90471e919600, 0xffff9046db1d1e40, 0xffff90471e913b80}
crash> cgroup_subsys_state.cgroup 0xffff904688253000
  cgroup = 0xffff90464b624000
crash> struct -o cgroup.css_sets  0xffff90464b624000
struct cgroup {
  [ffff90464b6240c8] struct list_head css_sets;
}
crash> list -l cg_cgroup_link.cgrp_link_list -s cg_cgroup_link.cg -H ffff90464b6240c8
ffff904713f68fc0
  cg = 0xffff9046d1ef1a80
```

以第一个`cgroup`(cpuset)为例，可以看到其关联了系统上所有的`css_set`。

```
crash> cgroup_subsys_state.cgroup  0xffffffffa3ffb2a0
  cgroup = 0xffff90471418e030
crash> struct -o cgroup.css_sets 0xffff90471418e030
struct cgroup {
  [ffff90471418e0f8] struct list_head css_sets;
}
crash> list -H ffff90471418e0f8 | wc -l
48
crash> p css_set_count
css_set_count = $1 = 48
```


## 参考文档

* http://editor.method.ac/

  [1]: ./css_set-to-cgroup.svg "css_set-to-cgroup"
  [2]: ./cgroup-to-css_set.svg "cgroup-to-css_set"

