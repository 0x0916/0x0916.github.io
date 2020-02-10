
cgroup中有一些默认的文件，本文详细分析了这些文件背后的内核实现细节，以便更深入的理解cgroup。

这些文件包括：

* notify_on_release
* release_agent
* cgroup.procs
* tasks
* cgroup.clone_children
* cgroup.event_control
* cgroup.sane_behavior

>  注意：本文分析中引用的代码来自于centos系统自带的内核：[kernel-3.10.0-862.9.1.el7](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.9.1.el7.src.rpm)

<!--more-->

### notify_on_release

`notify_on_release`接口在每个cgroup都存在，对其读写本质上是修改该`cgroup->flags`的`CGRP_NOTIFY_ON_RELEASE`, 后续cgroup释放时，会根据该flags进行相应的操作。

```c
static struct cftype files[] = {
	... 
	... 
	{
                .name = "notify_on_release",
                .read_u64 = cgroup_read_notify_on_release,
                .write_u64 = cgroup_write_notify_on_release,
        },
	... 
	... 
	{}
};

static u64 cgroup_read_notify_on_release(struct cgroup *cgrp,
                                            struct cftype *cft)
{
        return notify_on_release(cgrp);
}

static int cgroup_write_notify_on_release(struct cgroup *cgrp,
                                          struct cftype *cft,
                                          u64 val)
{
        clear_bit(CGRP_RELEASABLE, &cgrp->flags);
        if (val)
                set_bit(CGRP_NOTIFY_ON_RELEASE, &cgrp->flags);
        else
                clear_bit(CGRP_NOTIFY_ON_RELEASE, &cgrp->flags);
        return 0;
}

```

从`cgroup_write_notify_on_release`可以看出:

* 写入0或者空都可以清除CGRP_NOTIFY_ON_RELEASE这个flags
* 写入1或者任意正整数，都可以置位CGRP_NOTIFY_ON_RELEASE这个flags

示例如下：

```bash
~  # # 进入memory cgroup，准备实验
~  # cd /sys/fs/cgroup/memory/
/sys/fs/cgroup/memory  # # 创建测试用的cgroup
/sys/fs/cgroup/memory  # mkdir test1 test2
/sys/fs/cgroup/memory  # cat test1/notify_on_release 
0
/sys/fs/cgroup/memory  # cat test2/notify_on_release 
0
/sys/fs/cgroup/memory  # # 写入0或者一个正数
/sys/fs/cgroup/memory  # echo 1 > test1/notify_on_release 
/sys/fs/cgroup/memory  # echo 40 > test2/notify_on_release 
/sys/fs/cgroup/memory  # # 查看结果，notify_on_release都置位为1
/sys/fs/cgroup/memory  # cat test1/notify_on_release 
1
/sys/fs/cgroup/memory  # cat test2/notify_on_release 
1
/sys/fs/cgroup/memory  # # 写入0或者空清除该flags
/sys/fs/cgroup/memory  # echo > test1/notify_on_release 
/sys/fs/cgroup/memory  # echo 0 > test2/notify_on_release 
/sys/fs/cgroup/memory  # # 查看结果，notify_on_release都置位为0
/sys/fs/cgroup/memory  # cat test1/notify_on_release 
0
/sys/fs/cgroup/memory  # cat test2/notify_on_release 
0
/sys/fs/cgroup/memory  # # 清理
/sys/fs/cgroup/memory  # rmdir test1 test2
```

### release_agent

release_agent里面包含了cgroup退出时将会执行的命令，系统调用该命令时会将相应cgroup的相对路径当作参数传进去。

> 注意：这个文件只会存在于root cgroup下面，其他cgroup里面不会有这个文件。

当cgroup退出是，如果notify_on_release为1，则会调用release_agent里面配置的命令。

内核中，该文件对应的就是一个字符串，其保存在`cgroup->root->release_agent_path`中。 对该文件的读写就不分析了，这里主要分析一下内核中如何实现`cgroup`退出时，执行`release_agent`中指定的命令。

```
/* the list of cgroups eligible for automatic release. Protected by
 * release_list_lock */
static LIST_HEAD(release_list);
static DEFINE_RAW_SPINLOCK(release_list_lock);
static void cgroup_release_agent(struct work_struct *work);
static DECLARE_WORK(release_agent_work, cgroup_release_agent);
static void check_for_release(struct cgroup *cgrp);
```

* 在`cgroup_destroy_locked`和`__put_css_set`等`cgroup`退出的代码路径中，都会调用`check_for_release`函数，该函数用来判断是否需要执行`release_agent`指定的命令，如果需要，就将该cgroup添加到链表`release_list`中,并调度`schedule_work(&release_agent_work);`。
* `cgroup_release_agent`这个方法，从`release_list`链表中循环读取要退出的cgroup，然后构建执行环境，去执行指定的命令。

```c
static void cgroup_release_agent(struct work_struct *work)
{
        BUG_ON(work != &release_agent_work);
        mutex_lock(&cgroup_mutex);
        raw_spin_lock(&release_list_lock);
        while (!list_empty(&release_list)) {
                char *argv[3], *envp[3];
                int i;
                char *pathbuf = NULL, *agentbuf = NULL;
                struct cgroup *cgrp = list_entry(release_list.next,
                                                    struct cgroup,
                                                    release_list);
                list_del_init(&cgrp->release_list);
                raw_spin_unlock(&release_list_lock);
                pathbuf = kmalloc(PAGE_SIZE, GFP_KERNEL);
                if (!pathbuf)
                        goto continue_free;
                if (cgroup_path(cgrp, pathbuf, PAGE_SIZE) < 0)
                        goto continue_free;
                agentbuf = kstrdup(cgrp->root->release_agent_path, GFP_KERNEL);
                if (!agentbuf)
                        goto continue_free;

                i = 0;
                argv[i++] = agentbuf;
                argv[i++] = pathbuf;
                argv[i] = NULL;

                i = 0;
                /* minimal command environment */
                envp[i++] = "HOME=/";
                envp[i++] = "PATH=/sbin:/bin:/usr/sbin:/usr/bin";
                envp[i] = NULL;

                /* Drop the lock while we invoke the usermode helper,
                 * since the exec could involve hitting disk and hence
                 * be a slow process */
                mutex_unlock(&cgroup_mutex);
                call_usermodehelper(argv[0], argv, envp, UMH_WAIT_EXEC);
                mutex_lock(&cgroup_mutex);
 continue_free:
                kfree(pathbuf);
                kfree(agentbuf);
                raw_spin_lock(&release_list_lock);
        }
        raw_spin_unlock(&release_list_lock);
        mutex_unlock(&cgroup_mutex);
}
```

可以看出，`release_agent` 中指定的命令的执行时，其`HOME`目录为`/`。另外，这种设计可以让`cgroup`退出和执行`release_agent` 中指定的命令异步进行。


### cgroup.procs 和tasks

cgroup.procs和tasks的区别，请参考[这篇博客](../../posts/hierarchy-without-controller-group/#procs-和tasks-的区别)。

想这两个文件中写入一个进程号或者线程号时，内核中最终调用的函数为：`attach_task_by_pid`,其原型如下：

```c
/*
 * Find the task_struct of the task to attach by vpid and pass it along to the
 * function to attach either it or all tasks in its threadgroup. Will lock
 * cgroup_mutex and threadgroup; may take task_lock of task.
 */
static int attach_task_by_pid(struct cgroup *cgrp, u64 pid, bool threadgroup);
```

根据threadgroup 是否为true，来决定写入的pid代表的是进程还是线程。即该函数是通过写cgroup.procs进入的时，threadgroup为ture，通过写tasks进入的时，threadgroup为false。


读取这两个文件的内容时,执行的函数分别为`cgroup_tasks_open`和`cgroup_procs_open`，最终都调用函数`cgroup_pidlist_open`，只是其中的第二个参数不同，内核中的实现如下：

```c
/*
 * The following functions handle opens on a file that displays a pidlist
 * (tasks or procs). Prepare an array of the process/thread IDs of whoever's
 * in the cgroup.
 */
/* helper function for the two below it */
static int cgroup_pidlist_open(struct file *file, enum cgroup_filetype type)
{
        struct cgroup *cgrp = __d_cgrp(file->f_dentry->d_parent);
        struct cgroup_pidlist *l;
        int retval;

        /* Nothing to do for write-only files */
        if (!(file->f_mode & FMODE_READ))
                return 0;

        /* have the array populated */
        retval = pidlist_array_load(cgrp, type, &l);
        if (retval)
                return retval;
        /* configure file information */
        file->f_op = &cgroup_pidlist_operations;

        retval = seq_open(file, &cgroup_pidlist_seq_operations);
        if (retval) {
                cgroup_release_pid_array(l);
                return retval;
        }
        ((struct seq_file *)file->private_data)->private = l;
        return 0;
}
static int cgroup_tasks_open(struct inode *unused, struct file *file)
{
        return cgroup_pidlist_open(file, CGROUP_FILE_TASKS);
}
static int cgroup_procs_open(struct inode *unused, struct file *file)
{
        return cgroup_pidlist_open(file, CGROUP_FILE_PROCS);
}
```

在`cgroup_pidlist_open`中，关键的获取进程/线程 ID的函数为`pidlist_array_load`:

```c
/*
 * Load a cgroup's pidarray with either procs' tgids or tasks' pids
 */
static int pidlist_array_load(struct cgroup *cgrp, enum cgroup_filetype type,
                              struct cgroup_pidlist **lp)
{
        pid_t *array;
        int length;
        int pid, n = 0; /* used for populating the array */
        struct cgroup_iter it;
        struct task_struct *tsk;
        struct cgroup_pidlist *l;

        /*
         * If cgroup gets more users after we read count, we won't have
         * enough space - tough.  This race is indistinguishable to the
         * caller from the case that the additional cgroup users didn't
         * show up until sometime later on.
         */
        length = cgroup_task_count(cgrp);
        array = pidlist_allocate(length);
        if (!array)
                return -ENOMEM;
        /* now, populate the array */
        cgroup_iter_start(cgrp, &it);
        while ((tsk = cgroup_iter_next(cgrp, &it))) {
                if (unlikely(n == length))
                        break;
                /* get tgid or pid for procs or tasks file respectively */
                if (type == CGROUP_FILE_PROCS)
                        pid = task_tgid_vnr(tsk);
                else
                        pid = task_pid_vnr(tsk);
                if (pid > 0) /* make sure to only use valid results */
                        array[n++] = pid;
        }
        cgroup_iter_end(cgrp, &it);
        length = n;
        /* now sort & (if procs) strip out duplicates */
        sort(array, length, sizeof(pid_t), cmppid, NULL);
        if (type == CGROUP_FILE_PROCS)
                length = pidlist_uniq(array, length);
        l = cgroup_pidlist_find(cgrp, type);
        if (!l) {
                pidlist_free(array);
                return -ENOMEM;
        }
        /* store array, freeing old if necessary - lock already held */
        pidlist_free(l->list);
        l->list = array;
        l->length = length;
        l->use_count++;
        up_write(&l->mutex);
        *lp = l;
        return 0;
}
```

* 第20行通过cgroup_task_count获取该cgroup中的进程个数
* 第21行分配存放结果的数组array
* 第25-37行代码填充数组array
* 第40-42行代码对array进行排序，并当时cgroup.procs时进行去重


### cgroup.clone_children

这个文件只对`cpuset（subsystem）`有影响，当该文件的内容为`1`时，新创建的`cgroup`将会继承父`cgroup`的配置，即从父`cgroup`里面拷贝配置文件来初始化新`cgroup`

其内核代码实现也比较简单，对其读写本质上是修改该`cgroup->flags`的`CGRP_CPUSET_CLONE_CHILDREN` 位。

> More: 按理说，该配置只对`cpuset（subsystem）`有用，应该放到cpuset的subsystem中，但是由于历史原因，其放到了全局cgroup文件中。

在 `centos 7.5`中，`cgroup.clone_children`的值默认为0.

### cgroup.event_control

该文件是用于eventfd的接口。

具体用法，请参考： [文章引用](url)

TODO： 其内核实现分析，稍后补充。


### cgroup.sane_behavior

这个文件只会存在于root cgroup下面，其他cgroup里面不会有这个文件。该文件也是控制了`cgroup->flags`的一个叫做`CGRP_ROOT_SANE_BEHAVIOR`的位。


由于cgroup一直再发展，很多子系统有很多不同的特性，内核用`CGRP_ROOT_SANE_BEHAVIOR`来控制使能某些特性和关闭某些特性。

> 注意： 该文件是只读的，也就是说不能随便修改该值，只有在mount各个子系统时，指定mount选项`__DEVEL__sane_behavior`是，该位的值才会置位1。

```c
static struct cftype files[] = {
	... 
	... 
        {
                .name = "cgroup.sane_behavior",
                .flags = CFTYPE_ONLY_ON_ROOT,
                .read_seq_string = cgroup_sane_behavior_show,
        },
	... 
	... 
        {}
};

// 关于CGRP_ROOT_SANE_BEHAVIOR的描述信息：

        /*
         * Unfortunately, cgroup core and various controllers are riddled
         * with idiosyncrasies and pointless options.  The following flag,
         * when set, will force sane behavior - some options are forced on,
         * others are disallowed, and some controllers will change their
         * hierarchical or other behaviors.
         *
         * The set of behaviors affected by this flag are still being
         * determined and developed and the mount option for this flag is
         * prefixed with __DEVEL__.  The prefix will be dropped once we
         * reach the point where all behaviors are compatible with the
         * planned unified hierarchy, which will automatically turn on this
         * flag.
         *
         * The followings are the behaviors currently affected this flag.
         *
         * - Mount options "noprefix" and "clone_children" are disallowed.
         *   Also, cgroupfs file cgroup.clone_children is not created.
         *
         * - When mounting an existing superblock, mount options should
         *   match.
         *
         * - Remount is disallowed.
         *
         * - cpuset: tasks will be kept in empty cpusets when hotplug happens
         *   and take masks of ancestors with non-empty cpus/mems, instead of
         *   being moved to an ancestor.
         *
         * - cpuset: a task can be moved into an empty cpuset, and again it
         *   takes masks of ancestors.
         *
         * - memcg: use_hierarchy is on by default and the cgroup file for
         *   the flag is not created.
         *
         * - blkcg: blk-throttle becomes properly hierarchical.
         *
         * The followings are planned changes.
         *
         * - release_agent will be disallowed once replacement notification
         *   mechanism is implemented.
         */
        CGRP_ROOT_SANE_BEHAVIOR = (1 << 0),

```

在centos 7.5 上，该flags默认都没有打开：

```bash
~  # mount | grep cgroup
tmpfs on /sys/fs/cgroup type tmpfs (ro,nosuid,nodev,noexec,mode=755)
cgroup on /sys/fs/cgroup/systemd type cgroup (rw,nosuid,nodev,noexec,relatime,xattr,release_agent=/usr/lib/systemd/systemd-cgroups-agent,name=systemd)
cgroup on /sys/fs/cgroup/memory type cgroup (rw,nosuid,nodev,noexec,relatime,memory)
cgroup on /sys/fs/cgroup/cpuset type cgroup (rw,nosuid,nodev,noexec,relatime,cpuset)
cgroup on /sys/fs/cgroup/debug type cgroup (rw,nosuid,nodev,noexec,relatime,debug)
cgroup on /sys/fs/cgroup/cpu,cpuacct type cgroup (rw,nosuid,nodev,noexec,relatime,cpuacct,cpu)
cgroup on /sys/fs/cgroup/perf_event type cgroup (rw,nosuid,nodev,noexec,relatime,perf_event)
cgroup on /sys/fs/cgroup/hugetlb type cgroup (rw,nosuid,nodev,noexec,relatime,hugetlb)
cgroup on /sys/fs/cgroup/blkio type cgroup (rw,nosuid,nodev,noexec,relatime,blkio)
cgroup on /sys/fs/cgroup/pids type cgroup (rw,nosuid,nodev,noexec,relatime,pids)
cgroup on /sys/fs/cgroup/freezer type cgroup (rw,nosuid,nodev,noexec,relatime,freezer)
cgroup on /sys/fs/cgroup/devices type cgroup (rw,nosuid,nodev,noexec,relatime,devices)
cgroup on /sys/fs/cgroup/net_cls,net_prio type cgroup (rw,nosuid,nodev,noexec,relatime,net_prio,net_cls)
root@3(NXDOMAIN)::[20:05:09]::[Exit Code: 0] ->
~  # cd /sys/fs/cgroup/
/sys/fs/cgroup  # find . -name "cgroup.sane_behavior"
./net_cls,net_prio/cgroup.sane_behavior
./devices/cgroup.sane_behavior
./freezer/cgroup.sane_behavior
./pids/cgroup.sane_behavior
./blkio/cgroup.sane_behavior
./hugetlb/cgroup.sane_behavior
./perf_event/cgroup.sane_behavior
./cpu,cpuacct/cgroup.sane_behavior
./debug/cgroup.sane_behavior
./cpuset/cgroup.sane_behavior
./memory/cgroup.sane_behavior
./systemd/cgroup.sane_behavior
/sys/fs/cgroup  # find . -name "cgroup.sane_behavior" | xargs cat 
0
0
0
0
0
0
0
0
0
0
0
0
```


### 参考文章

