本文详细分析了`cgroup`初始化的过程。


> 本文基于`3.10.0-862.el7.x86_64`版本kernel进行分析。

<!--more-->


在分析初始化之前，我们需要看一下层级和子系统对应的结构体以及几个重要的全局变量。

层级对应的结构体为：`cgroupfs_root`，子系统对应的结构体为`cgroup_subsys`.

### cgroupfs_root 结构

```C
/*
 * A cgroupfs_root represents the root of a cgroup hierarchy, and may be
 * associated with a superblock to form an active hierarchy.  This is
 * internal to cgroup core.  Don't access directly from controllers.
 */
struct cgroupfs_root {
        struct super_block *sb;

        /*
         * The bitmask of subsystems intended to be attached to this
         * hierarchy
         */
        unsigned long subsys_mask;

        /* Unique id for this hierarchy. */
        int hierarchy_id;

        /* The bitmask of subsystems currently attached to this hierarchy */
        unsigned long actual_subsys_mask;

        /* A list running through the attached subsystems */
        struct list_head subsys_list;

        /* The root cgroup for this hierarchy */
        struct cgroup top_cgroup;

        /* Tracks how many cgroups are currently defined in hierarchy.*/
        int number_of_cgroups;

        /* A list running through the active hierarchies */
        struct list_head root_list;

        /* All cgroups on this root, cgroup_mutex protected */
        struct list_head allcg_list;

        /* Hierarchy-specific flags */
        unsigned long flags;

        /* IDs for cgroups in this hierarchy */
        struct ida cgroup_ida;

        /* The path to use for release notifications. */
        char release_agent_path[PATH_MAX];

        /* The name for this hierarchy - may be empty */
        char name[MAX_CGROUP_ROOT_NAMELEN];
};
```

* `sb`指向该层级关联的文件系统超级块
* `subsys_mask`和`actual_subsys_mask`分别指向将要附加到层级的子系统和现在实际附加到层级的子系统，在子系统附加到层级时使用。
* `hierarchy_id`是该层级唯一的id
* `top_cgroup`指向该层级的根cgroup
* `number_of_cgroups`记录该层级cgroup的个数
* `root_list`是一个嵌入的list_head，用于将系统所有的层级连成链表
* `subsys_list`是一个链表，该链表将附着于该挂载点上的子系统链接到一起



### cgroup_subsys 结构

子系统对应的数据结构为：`cgroup_subsys`

```C
/*
 * Control Group subsystem type.
 * See Documentation/cgroups/cgroups.txt for details
 */

struct cgroup_subsys {
        struct cgroup_subsys_state *(*css_alloc)(struct cgroup *cgrp);
        int (*css_online)(struct cgroup *cgrp);
        void (*css_offline)(struct cgroup *cgrp);
        void (*css_free)(struct cgroup *cgrp);

        int (*can_attach)(struct cgroup *cgrp, struct cgroup_taskset *tset);
        void (*cancel_attach)(struct cgroup *cgrp, struct cgroup_taskset *tset);
        void (*attach)(struct cgroup *cgrp, struct cgroup_taskset *tset);
        RH_KABI_REPLACE(void (*fork)(struct task_struct *task),
                        void (*fork)(struct task_struct *task, void *priv))
        void (*exit)(struct cgroup *cgrp, struct cgroup *old_cgrp,
                     struct task_struct *task);
        void (*bind)(struct cgroup *root);

        int subsys_id;
        int disabled;
        int early_init;
        /*
         * True if this subsys uses ID. ID is not available before cgroup_init()
         * (not available in early_init time.)
         */
        bool use_id;

        /*
         * If %false, this subsystem is properly hierarchical -
         * configuration, resource accounting and restriction on a parent
         * cgroup cover those of its children.  If %true, hierarchy support
         * is broken in some ways - some subsystems ignore hierarchy
         * completely while others are only implemented half-way.
         *
         * It's now disallowed to create nested cgroups if the subsystem is
         * broken and cgroup core will emit a warning message on such
         * cases.  Eventually, all subsystems will be made properly
         * hierarchical and this will go away.
         */
        bool broken_hierarchy;
        bool warned_broken_hierarchy;

#define MAX_CGROUP_TYPE_NAMELEN 32
        const char *name;

        /*
         * Link to parent, and list entry in parent's children.
         * Protected by cgroup_lock()
         */
        struct cgroupfs_root *root;
        struct list_head sibling;
        /* used when use_id == true */
        struct idr idr;
        spinlock_t id_lock;

        /* list of cftype_sets */
        struct list_head cftsets;

        /* base cftypes, automatically [de]registered with subsys itself */
        struct cftype *base_cftypes;
        struct cftype_set base_cftset;

        /* should be defined only by modular subsystems */
        struct module *module;

        RH_KABI_EXTEND(int (*can_fork)(struct task_struct *task, void **priv_p))
        RH_KABI_EXTEND(void (*cancel_fork)(struct task_struct *task, void *priv))
};	
```

`cgroup_subsys`定义了一组操作，让各个子系统根据各自的需要去实现。这个相当于`C++`中抽象基类，然后各个特定的子系统对应`cgroup_subsys`则是实现了相应操作的子类。

类似的思想还被用在了`cgroup_subsys_state`中，`cgroup_subsys_state`并未定义控制信息，而只是定义了各个子系统都需要的共同信息，比如该`cgroup_subsys_state`从属的`cgroup`。然后各个子系统再根据各自的需要去定义自己的进程控制信息结构体，最后在各自的结构体中将`cgroup_subsys_state`包含进去，这样通过`Linux`内核的`container_of`等宏就可以通过`cgroup_subsys_state`来获取相应的结构体。


### 几个全局变量

* `init_css_set`是默认的`css_set`。在还没有其他`cgroup子系统`被`mount`时，它被`init`和`其子进程`来使用。
* `css_set_count`用来描述当前系统上有多少个`css_set`。
* `rootnode`是一个`dummy hierarchy`，它只有一个`cgroup`，所有的进程都属于这个`cgroup`。
* `dummytop`是一个指向`rootnode.top_cgroup`的缩写。
* `roots` 是一个链表头，将所有的`cgroupfs_root`都链接到了一起。
* `root_count`表示有多少个`cgroupfs_root`。
* `init_css_set_link`: 用于链接`init_css_set`和`dummytop`的`cg_cgroup_link`。
* `struct cgroup_subsys *subsys[CGROUP_SUBSYS_COUNT]`数组，该数组保存了所有子系统（`cgroup_subsys`）的信息


### cgroups的初始

在内核过程中，由于各个`cgroup`子系统的特点，`cgroup`的初始分为两部分：

* `cgroup_init_early`
* `cgroup_init`


#### cgroup_init_early

`cgroup_init_early`用来初始化需要尽早初始化的子系统。一般这些需要尽早初始化的子系统都包括：`cpuset`，`cpu`，`cpuacct`。

```c
/**
 * cgroup_init_early - cgroup initialization at system boot
 *
 * Initialize cgroups at system boot, and initialize any
 * subsystems that request early init.
 */
int __init cgroup_init_early(void)
{
        int i;
        atomic_set(&init_css_set.refcount, 1);
        INIT_LIST_HEAD(&init_css_set.cg_links);
        INIT_LIST_HEAD(&init_css_set.tasks);
        INIT_HLIST_NODE(&init_css_set.hlist);
        css_set_count = 1;
        init_cgroup_root(&rootnode);
        root_count = 1;
        init_task.cgroups = &init_css_set;

        init_css_set_link.cg = &init_css_set;
        init_css_set_link.cgrp = dummytop;
        list_add(&init_css_set_link.cgrp_link_list,
                 &rootnode.top_cgroup.css_sets);
        list_add(&init_css_set_link.cg_link_list,
                 &init_css_set.cg_links);

        for (i = 0; i < CGROUP_SUBSYS_COUNT; i++) {
                struct cgroup_subsys *ss = subsys[i];

                /* at bootup time, we don't worry about modular subsystems */
                if (!ss || ss->module)
                        continue;
				// 这里做了一些基本的检查
                BUG_ON(!ss->name);
                BUG_ON(strlen(ss->name) > MAX_CGROUP_TYPE_NAMELEN);
                BUG_ON(!ss->css_alloc);
                BUG_ON(!ss->css_free);
                if (ss->subsys_id != i) {
                        printk(KERN_ERR "cgroup: Subsys %s id == %d\n",
                               ss->name, ss->subsys_id);
                        BUG();
                }

                if (ss->early_init)//只有当early_init为1时，才会进行初始化
                        cgroup_init_subsys(ss);
        }
        return 0;
}
```

该函数的主要功能如下：

* 初始化`init_css_set`中的成员变量和几个全局变量`css_set_count`、`root_count`、`rootnode`和`init_css_set_link`。
* 初始化`cgroup`子系统`cpuset`，`cpu`，`cpuacct`。

#### cgroup_init

`cgroup_init`用来完成`cgroup`的初始化，其代码如下：

```c
/**
 * cgroup_init - cgroup initialization
 *
 * Register cgroup filesystem and /proc file, and initialize
 * any subsystems that didn't request early init.
 */
int __init cgroup_init(void)
{       
        int err;
        int i;
        unsigned long key;
        
        err = bdi_init(&cgroup_backing_dev_info);
        if (err)
                return err;
        
        for (i = 0; i < CGROUP_SUBSYS_COUNT; i++) {
                struct cgroup_subsys *ss = subsys[i];
                
                /* at bootup time, we don't worry about modular subsystems */
                if (!ss || ss->module)
                        continue;
                if (!ss->early_init)
                        cgroup_init_subsys(ss);
                if (ss->use_id)
                        cgroup_init_idr(ss, init_css_set.subsys[ss->subsys_id]);
        }
        
        /* Add init_css_set to the hash table */
        key = css_set_hash(init_css_set.subsys);
        hash_add(css_set_table, &init_css_set.hlist, key);
        BUG_ON(!init_root_id(&rootnode));
        
        err = sysfs_create_mount_point(fs_kobj, "cgroup");
        if (err)
                goto out;
        
        err = register_filesystem(&cgroup_fs_type);
        if (err < 0) {
                sysfs_remove_mount_point(fs_kobj, "cgroup");
                goto out;
        }
        
        proc_create("cgroups", 0, NULL, &proc_cgroupstats_operations);

out:    
        if (err)
                bdi_destroy(&cgroup_backing_dev_info);
        
        return err;
}
```
主要完成了如下工作：

* 初始化了其他几个子系统
* 初始化`cgroup_backing_dev_info`
* 根据`use_id`是否为`true`，进行必要的初始化
* 将`init_css_set`这个目前唯一的`css_set`添加到`hash`表`css_set_table`中
* 创建目录`/sys/fs/cgroup`
* 注册`cgroup`文件系统类型
* 创建`/proc/cgroups`


#### cgroup_init_subsys

以上两个方法中都调用了`cgroup_init_subsys`，其代码如下：

```c
static void __init cgroup_init_subsys(struct cgroup_subsys *ss)                                                                          
{                                                                                                                                        
        struct cgroup_subsys_state *css;                                                                                                 
                                                                                                                                         
        printk(KERN_INFO "Initializing cgroup subsys %s\n", ss->name);                                                                   
                                                                                                                                         
        mutex_lock(&cgroup_mutex);                                                                                                       
                                                                                                                                         
        /* init base cftset */                                                                                                           
        cgroup_init_cftsets(ss);                                                                                                         
                                                                                                                                         
        /* Create the top cgroup state for this subsystem */                                                                             
        list_add(&ss->sibling, &rootnode.subsys_list);                 //只是临时添加到   rootnode.subsys_list 链表中，后面会移走的。                                                               
        ss->root = &rootnode;                                                                                                            
        css = ss->css_alloc(dummytop);                                                                                                   
        /* We don't handle early failures gracefully */                                                                                  
        BUG_ON(IS_ERR(css));                                                                                                             
        init_cgroup_css(css, ss, dummytop);                                                                                              
                                                                                                                                         
        /* Update the init_css_set to contain a subsys                                                                                   
         * pointer to this state - since the subsystem is                                                                                
         * newly registered, all tasks and hence the                                                                                     
         * init_css_set is in the subsystem's top cgroup. */                                                                             
        init_css_set.subsys[ss->subsys_id] = css;                                                                                        
                                                                                                                                         
        need_forkexit_callback |= ss->fork || ss->exit;                                                                                  
                                                                                                                                         
        /* At system boot, before all subsystems have been                                                                               
         * registered, no tasks have been forked, so we don't                                                                            
         * need to invoke fork callbacks here. */                                                                                        
        BUG_ON(!list_empty(&init_task.tasks));                                                                                           
                                                                                                                                         
        BUG_ON(online_css(ss, dummytop));                                                                                                
                                                                                                                                         
        mutex_unlock(&cgroup_mutex);                                                                                                     
                                                                                                                                         
        /* this function shouldn't be used with modular subsystems, since they                                                           
         * need to register a subsys_id, among other things */                                                                           
        BUG_ON(ss->module);                                                                                                              
}                                                                                                                                        
    
```

*   初始化`cgroup_subsys`的`cftsets`
*   分配`css`
*   初始化`dummytop`和`init_css_set`中对应的`subsys`数组
*   调用`online_css`


`cgroup_init_early` 和`cgroup_init` 执行完后，这些数据结构之间的关系如下图所示：

![enter description here][1]



### /proc/cgroups 实现分析

在`cgroup`初始化函数`cgroup_init`中会调用如下函数进行注册`/proc/cgroups`接口：

```c
int __init cgroup_init(void) 
{
...
...
		proc_create("cgroups", 0, NULL, &proc_cgroupstats_operations);
...
...
}
```

`proc_cgroupstats_operations`的实现如下：


```c
/* Display information about each subsystem and each hierarchy */
static int proc_cgroupstats_show(struct seq_file *m, void *v)
{
        int i;

        seq_puts(m, "#subsys_name\thierarchy\tnum_cgroups\tenabled\n");
        /*   
         * ideally we don't want subsystems moving around while we do this.
         * cgroup_mutex is also necessary to guarantee an atomic snapshot of
         * subsys/hierarchy state.
         */
        mutex_lock(&cgroup_mutex);
        for (i = 0; i < CGROUP_SUBSYS_COUNT; i++) {
                struct cgroup_subsys *ss = subsys[i];
                if (ss == NULL) // ss 可能为空
                        continue;
                seq_printf(m, "%s\t%d\t%d\t%d\n",
                           ss->name, ss->root->hierarchy_id,
                           ss->root->number_of_cgroups, !ss->disabled);
        }    
        mutex_unlock(&cgroup_mutex);
        return 0;
}

static int cgroupstats_open(struct inode *inode, struct file *file)
{
        return single_open(file, proc_cgroupstats_show, NULL);
}

static const struct file_operations proc_cgroupstats_operations = {
        .open = cgroupstats_open,
        .read = seq_read,
        .llseek = seq_lseek,
        .release = single_release,
};
```

从上可以看出，这些信息都来自于数组`subsys`和其成员`subsys->root`（类型为`cgroupfs_root`）。`/proc/cgroups`示例如下：

```bash
~  # cat /proc/cgroups
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

从上可以看出，
* 第一列是`cgroup`子系统的名称
* 第二列的`hierarchy`从`2`开始，那么编号为`1`的`hierarchy`是什么呢？`hierarchy_id`是动态分配，`linux`系统启动时，先挂载了一个未附加任何子系统的层级`systemd`,所以`systemd`的`hierarchy_id`为1
* 第三列说明该子系统中`cgroups`的个数
* 第四列说明该子系统是否使能。

内核中数组`subsys`保存了系统上的不同的`cgroup`子系统信息。

```c
#define SUBSYS(_x) [_x ## _subsys_id] = &_x ## _subsys,
#define IS_SUBSYS_ENABLED(option) IS_BUILTIN(option)
#define ENABLE_NETPRIO_NOW
static struct cgroup_subsys *subsys[CGROUP_SUBSYS_COUNT] = {
#include <linux/cgroup_subsys.h>
};
#undef ENABLE_NETPRIO_NOW
};
```

其中`CGROUP_SUBSYS_COUNT`的值为系统上支持的`cgroup`的个数，包括编译进内核的和编译成模块的。

> 注意，由于`IS_SUBSYS_ENABLED`的定义，这里只会初始化编译进内核模块的子cgroup。



使用`crash`工具，可以查看内核中`cgroup`子系统的情况：

```crash
crash> p subsys[0].name
$5 = 0xffffffffa3ea6abb "cpuset"
crash> p subsys[1].name
$6 = 0xffffffffa3e99ec6 "debug"
crash> p subsys[2].name
$7 = 0xffffffffa3e9baca "cpu"
crash> p subsys[3].name
$8 = 0xffffffffa3e97b50 "cpuacct"
crash> p subsys[4].name
$9 = 0xffffffffa3eaf4d8 "memory"
crash> p subsys[5].name
$10 = 0xffffffffa3ecb432 "devices"
crash> p subsys[6].name
$11 = 0xffffffffa3e97da3 "freezer"
crash> p subsys[7].name
$12 = 0xffffffffa3f22a9e "net_cls"
crash> p subsys[8].name
$13 = 0xffffffffa3ec4e39 "blkio"
crash> p subsys[9].name
$14 = 0xffffffffa3e9e4ec "perf_event"
crash> p subsys[10].name
$15 = 0xffffffffa3ea7164 "hugetlb"
crash> p subsys[11].name
$16 = 0xffffffffa3e9a8cc "pids"
crash> p subsys[12].name
$17 = 0xffffffffa3f2289a "net_prio"
```

在内核中，每个`cgroup`子系统，都会有一个`subsys`的定义的结构体。对于`pids`子系统，其对应的`subsys`定义为：

```c
struct cgroup_subsys pids_subsys = { 
        .name           = "pids",
        .subsys_id      = pids_subsys_id,
        .css_alloc      = pids_css_alloc,
        .css_free       = pids_css_free,
        .can_attach     = pids_can_attach,
        .cancel_attach  = pids_cancel_attach,
        .can_fork       = pids_can_fork,
        .cancel_fork    = pids_cancel_fork,
        .fork           = pids_fork,                                                                                                           
        .exit           = pids_exit,
        .base_cftypes   = pids_files,
};
```

### crash 查看cgroup的一些数据结构的关系

```
crash> struct -o cgroupfs_root rootnode
struct cgroupfs_root {
  [ffffffffa57ff000] struct super_block *sb;
  [ffffffffa57ff008] unsigned long subsys_mask;
  [ffffffffa57ff010] int hierarchy_id;
  [ffffffffa57ff018] unsigned long actual_subsys_mask;
  [ffffffffa57ff020] struct list_head subsys_list;
  [ffffffffa57ff030] struct cgroup top_cgroup;
  [ffffffffa57ff300] int number_of_cgroups;
  [ffffffffa57ff308] struct list_head root_list;
  [ffffffffa57ff318] struct list_head allcg_list;
  [ffffffffa57ff328] unsigned long flags;
  [ffffffffa57ff330] struct ida cgroup_ida;
  [ffffffffa57ff3a8] char release_agent_path[4096];
  [ffffffffa58003a8] char name[64];
}
SIZE: 5096
crash> list -l cgroup.allcg_node -s cgroup.name,id,root,count -H ffffffffa57ff318
ffffffffa57ff108
  name = 0xffffffffa3ff9740
  id = 0
  root = 0xffffffffa57ff000
  count = {
    counter = 47
  }
crash> cgroup_name.name 0xffffffffa3ff9740
  name = 0xffffffffa3ff9750 "/"
crash> p rootnode.number_of_cgroups
$1 = 1
```

从上可以看出，`rootnode`的成员`allcg_list`将属于该`cgroupfs_root`的所有的`cgroup`的链接到了一起，一般情况下，系统上属于`rootnode`的`cgroup`只有一个，即`dummy_top`，其名称为`/`。



当系统`mount`很多`cgroup` 层级后，全局变量`roots`作为链表头，将系统上所有的层级都链接到了一起。

```
crash> list -l cgroupfs_root.root_list  -s cgroupfs_root.hierarchy_id,name,actual_subsys_mask -H roots
ffff9047143be308
  hierarchy_id = 12
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 4224
ffff9047143b8308
  hierarchy_id = 11
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 32
ffff9047143ba308
  hierarchy_id = 10
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 64
ffff9047143bc308
  hierarchy_id = 9
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 2048
ffff9047143c0308
  hierarchy_id = 8
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 256
ffff9047143c2308
  hierarchy_id = 7
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 1024
ffff9047143c4308
  hierarchy_id = 6
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 512
ffff9047143c6308
  hierarchy_id = 5
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 12
ffff90471418c308
  hierarchy_id = 4
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 2
ffff90471418e308
  hierarchy_id = 3
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 1
ffff904714188308
  hierarchy_id = 2
  name = "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 16
ffff90471418a308
  hierarchy_id = 1
  name = "systemd\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000"
  actual_subsys_mask = 0
```

可以看出，`roots`这个链表将系统上所有的`cgroupfs_root`链接到了一起，注意，这个链表中不包括`rootnode`这个`cgroupfs_root`,因为这个`rootnode`的`hierarchy_id`为`0`，这个链表中没有`hierarchy_id`为`0`的结点。

```
crash> p rootnode.hierarchy_id
$1 = 0
```

关于`dummytop`:

```
crash> struct -o cgroupfs_root.top_cgroup  rootnode
struct cgroupfs_root {
  [ffffffffa57ff030] struct cgroup top_cgroup;
}
crash> struct -o cgroup ffffffffa57ff030
struct cgroup {
  [ffffffffa57ff030] unsigned long flags;
  [ffffffffa57ff038] atomic_t count;
  [ffffffffa57ff03c] int id;
  [ffffffffa57ff040] struct list_head sibling;
  [ffffffffa57ff050] struct list_head children;
  [ffffffffa57ff060] struct list_head files;
  [ffffffffa57ff070] struct cgroup *parent;
  [ffffffffa57ff078] struct dentry *dentry;
  [ffffffffa57ff080] struct cgroup_name *name;
  [ffffffffa57ff088] struct cgroup_subsys_state *subsys[13];
  [ffffffffa57ff0f0] struct cgroupfs_root *root;
  [ffffffffa57ff0f8] struct list_head css_sets;
  [ffffffffa57ff108] struct list_head allcg_node;
  [ffffffffa57ff118] struct list_head cft_q_node;
  [ffffffffa57ff128] struct list_head release_list;
  [ffffffffa57ff138] struct list_head pidlists;
  [ffffffffa57ff148] struct mutex pidlist_mutex;
  [ffffffffa57ff1f0] struct callback_head callback_head;
  [ffffffffa57ff200] struct work_struct free_work;
  [ffffffffa57ff250] struct list_head event_list;
  [ffffffffa57ff260] spinlock_t event_list_lock;
  [ffffffffa57ff2a8] struct simple_xattrs xattrs;
}
SIZE: 720
crash> list -H ffffffffa57ff040
(empty)
crash> list -H ffffffffa57ff050
(empty)
crash> list -H ffffffffa57ff060
(empty)
crash> p rootnode.top_cgroup.subsys
$2 = {0xffffffffa3ffb2a0, 0xffff90471e913a00, 0xffffffffa49ac1c0, 0xffffffffa3ff1560, 0xffff90471e96d000, 0xffff90471e919480, 0xffff90471e919540, 0xffff90471e913a80, 0xffffffffa40990c0, 0xffff90471e913b00, 0xffff90471e919600, 0xffff90471e9196c0, 0xffff90471e913b80}
crash> p rootnode.top_cgroup.name
$3 = (struct cgroup_name *) 0xffffffffa3ff9740
crash> cgroup_name.name 0xffffffffa3ff9740
  name = 0xffffffffa3ff9750 "/"
```

`dummytop` 是一个特殊的`cgroup`，其没有兄弟和孩子`cgroup`，其`subsys`包含了所有的控制子系统，即`rootnode.top_cgroup.subsys`数组中每个成员都不为`null`。这些`css`是在`cgroup_init_subsys`函数中创建的。初始化时这些`css`的`cgroup`成员都指向了`dummytop`，在后续`mount`各个`cgroup`子系统时会进行调整。即`mount`时会创建新的`cgroupfs_root`, 并将对应的`subsys`跟新创建的`cgroupfs_root`建立对应的关系，当`umount`或者`remount`时，需要删除的子系统，将会移动到`rootnode`这个`cgroupfs_root`中。


### cgroup subsys中的use_id

只有`memory cgroup`中的`use_id`为`true`。


  [1]: ./cgroup_init.svg "cgroup_init"
