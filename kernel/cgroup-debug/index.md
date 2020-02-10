


`cgroup`的`debug子系统`其实没有什么用处，要说作用的话，其实它就是一个示例子系统，给内核的开发者展示了内核`cgroup`框架的使用方法，同时也展示了`cgroup`框架中各个数据结构之间的关系。

本文就通过研究`debug`子系统，来展示`cgroup`框架中各个数据结构的关系。

> 注意: 内核代码采用`linux-3.10.0-862.9.1.el7` 

<!--more-->

### 使能debug子系统

默认情况下，`debug`子系统是未使能的，使能它的话，需要打开内核配置选项`CONFIG_CGROUP_DEBUG`。

重新编译内核、安装并重启后，`debug`子系统会自动挂载到`/sys/fs/cgroup/debug`目录下:

```bash
/sys/fs/cgroup/debug  # pwd
/sys/fs/cgroup/debug
root@127.0.0.1::[04:21:37]::[Exit Code: 0] ->
/sys/fs/cgroup/debug  # ls -l
total 0
-rw-r--r--. 1 root root 0 Sep  8 20:49 cgroup.clone_children
--w--w--w-. 1 root root 0 Sep  8 20:49 cgroup.event_control
-rw-r--r--. 1 root root 0 Sep  8 20:49 cgroup.procs
-r--r--r--. 1 root root 0 Sep  8 20:49 cgroup.sane_behavior
-r--r--r--. 1 root root 0 Sep  8 20:49 debug.cgroup_css_links
-r--r--r--. 1 root root 0 Sep  8 20:49 debug.cgroup_refcount
-r--r--r--. 1 root root 0 Sep  8 20:49 debug.current_css_set
-r--r--r--. 1 root root 0 Sep  8 20:49 debug.current_css_set_cg_links
-r--r--r--. 1 root root 0 Sep  8 20:49 debug.current_css_set_refcount
-r--r--r--. 1 root root 0 Sep  8 20:49 debug.releasable
-r--r--r--. 1 root root 0 Sep  8 20:49 debug.taskcount
-rw-r--r--. 1 root root 0 Sep  8 20:49 notify_on_release
-rw-r--r--. 1 root root 0 Sep  8 20:49 release_agent
-rw-r--r--. 1 root root 0 Sep  8 20:49 tasks
```

除了`cgroup`中基本的文件外，`debug`子系统特有的文件包括如下：

* debug.taskcount
* debug.releaseable
* debug.cgroup_refcount
* debug.cgroup_css_links
* debug.current_css_set
* debug.current_css_set_cg_links
* debug.current_css_set_refcount

下面我们就通过研究这个几个文件的实现，来学习`cgroup`框架中的基本数据结构的关系。

### debug.cgroup_refcount

该文件输出当前`cgroup`引用计数，注意，这个计数不是该`cgroup`中`tasks`的个数。

```c
struct cgroup {
	...
	/*
	 * count users of this cgroup. >0 means busy, but doesn't
	 * necessarily indicate the number of tasks in the cgroup
	 */
	atomic_t count;
	...
}
```
通过下面的shell操作，我们可以看出，顶级`debug cgroup`中，其引用计数为`44`，而新建一个`debug cgroup`后，其引用计数为`0`。

```bash
/sys/fs/cgroup/debug  # # the top debug subsystem
/sys/fs/cgroup/debug  # cat debug.cgroup_refcount 
44
/sys/fs/cgroup/debug  # # create a new debug cgroup
/sys/fs/cgroup/debug  # mkdir test
/sys/fs/cgroup/debug  # cd test/
/sys/fs/cgroup/debug/test  # # the new debug cgroup's refcount should be zero
/sys/fs/cgroup/debug/test  # cat debug.cgroup_refcount 
0
```

这里的`44`说明，目前系统上有`44`个`css_set`中引用了该`debug cgroup`，而新创建的`cgroup`，目前还没有进程引用它。

### debug.taskcount

该文件输出加入到当前`cgroup`中的`task`的数量。其实现方式时通过调用函数`int cgroup_task_count(const struct cgroup *cgrp);`得到进程的数量。

其实现代码如下：

```c
/**
 * cgroup_task_count - count the number of tasks in a cgroup.
 * @cgrp: the cgroup in question
 *
 * Return the number of tasks in the cgroup.
 */
int cgroup_task_count(const struct cgroup *cgrp)
{
	int count = 0;
	struct cg_cgroup_link *link;

	read_lock(&css_set_lock);
	list_for_each_entry(link, &cgrp->css_sets, cgrp_link_list) {
		count += atomic_read(&link->cg->refcount);
	}
	read_unlock(&css_set_lock);
	return count;
}
```

该段代码很简单，通过`cgroup`可以得到所有的`cg_cgroup_link`，继而得到所有的`css_set`，而`css_set`的`refcount`则保存了引用该`css_set`的进程数量。所以通过对该`cgroup`对应的所有的`css_set`的`refcount`求和，其结果就是该`cgroup`中的进程的数量。



### debug.current_css_set

该文件输出了当前进程对应的`task_struct->cgroups`的地址：

```c
static u64 current_css_set_read(struct cgroup *cont, struct cftype *cft)
{
	return (u64)(unsigned long)current->cgroups;
}
```

从下面的输出来看，不管输出的是哪一个`cgroup`的文件，其输出结果都一样。这是为什么呢？因为其输出都是当前进程对应的`task_struct->cgroups`的地址，而当前进程`cat`默认属于顶级`debug` 的`cgroup`，其对应的`css_set`的地址就是`18446612137015537216`。

```bash
/sys/fs/cgroup/debug  # cat debug.current_css_set
18446612137015537216
/sys/fs/cgroup/debug  # cat test/debug.current_css_set
18446612137015537216
/sys/fs/cgroup/debug  # mkdir test1
/sys/fs/cgroup/debug  # cat test1/debug.current_css_set
18446612137015537216
```


### debug.current_css_set_refcount

该文件输出了当前进程的对应的`css_set`的引用计数。

```c
static u64 current_css_set_refcount_read(struct cgroup *cont,
					   struct cftype *cft)
{
	u64 count;

	rcu_read_lock();
	count = atomic_read(&current->cgroups->refcount);
	rcu_read_unlock();
	return count;
}
```

跟`debug.current_css_set`类似，不管输出的是哪一个`cgroup`的文件，其输出结果都一样，因为当前进程都是`cat`。

```bash
/sys/fs/cgroup/debug  # cat debug.current_css_set_refcount 
3
/sys/fs/cgroup/debug  # cat test/debug.current_css_set_refcount 
3
/sys/fs/cgroup/debug  # cat test1/debug.current_css_set_refcount 
3
```

### debug.current_css_set_cg_links

该文件输出了当前进程所有的`cgroup`子系统信息：

```c
static int current_css_set_cg_links_read(struct cgroup *cont,
					 struct cftype *cft,
					 struct seq_file *seq)
{
	struct cg_cgroup_link *link;
	struct css_set *cg;

	read_lock(&css_set_lock);
	rcu_read_lock();
	cg = rcu_dereference(current->cgroups);
	list_for_each_entry(link, &cg->cg_links, cg_link_list) {
		struct cgroup *c = link->cgrp;
		const char *name;

		if (c->dentry)
			name = c->dentry->d_name.name;
		else
			name = "?";
		seq_printf(seq, "Root %d group %s\n",
			   c->root->hierarchy_id, name);
	}
	rcu_read_unlock();
	read_unlock(&css_set_lock);
	return 0;
}
```

其实现如上，也很简单。通过`current`指针，可以找到当前进程对应的`css_set`，而`css_set`中的`cg_links`将所有的`cg_cgroup_link`链接到了一起，而每个`cg_cgroup_link`中都记录其关连的`cgroup`的地址。

输出示例如下：

```bash
/sys/fs/cgroup/debug  # cat debug.current_css_set_cg_links 
Root 0 group ?
Root 1 group session-55.scope
Root 2 group user.slice
Root 3 group /
Root 4 group /
Root 5 group user.slice
Root 6 group user.slice
Root 7 group /
Root 8 group /
Root 9 group /
Root 10 group user.slice
Root 11 group /
/sys/fs/cgroup/debug  # cat test/debug.current_css_set_cg_links 
Root 0 group ?
Root 1 group session-55.scope
Root 2 group user.slice
Root 3 group /
Root 4 group /
Root 5 group user.slice
Root 6 group user.slice
Root 7 group /
Root 8 group /
Root 9 group /
Root 10 group user.slice
Root 11 group /
```

> 注意： 第一个`cgroup`输出的名称为？，说明其`name`字段为空，这个`cgroup`到底是什么呢？第一个`cgroup`就是`dummytop`这个`cgroup`。

### debug.cgroup_css_links

该文件输出了当前`cgroup`中所有进程对应的进程`ID`。该文件的输出，跟`cgroup`中基本文件**tasks**的作用类似。

```c
#define MAX_TASKS_SHOWN_PER_CSS 25
static int cgroup_css_links_read(struct cgroup *cont,
				 struct cftype *cft,
				 struct seq_file *seq)
{
	struct cg_cgroup_link *link;

	read_lock(&css_set_lock);
	list_for_each_entry(link, &cont->css_sets, cgrp_link_list) {
		struct css_set *cg = link->cg;
		struct task_struct *task;
		int count = 0;
		seq_printf(seq, "css_set %p\n", cg);
		list_for_each_entry(task, &cg->tasks, cg_list) {
			if (count++ > MAX_TASKS_SHOWN_PER_CSS) {
				seq_puts(seq, "  ...\n");
				break;
			} else {
				seq_printf(seq, "  task %d\n",
					   task_pid_vnr(task));
			}
		}
	}
	read_unlock(&css_set_lock);
	return 0;
}
```

`cgroup`的`css_sets`成员通过`cg_cgroup_link`将该`cgroup`中进程对应的`css_set`链接到了一起，通过遍历该链表，可以找到跟该`cgroup`相关的所有的`css_set`，而`css_set`中的成员`tasks`将引用给`css_set`的进程链接到了一起。


其输出示例如下：

```bash
/sys/fs/cgroup/debug  # cat test/debug.cgroup_css_links 
/sys/fs/cgroup/debug  # cat debug.cgroup_css_links 
css_set ffff880118386e40
  task 9268
  task 8084
  task 8078
css_set ffff8800c9248780
  task 2782
  task 2781
  task 2765
  task 2760
  task 2759
css_set ffff8800c2cfb000
  task 2727
  task 2726
  task 2725
css_set ffff8800c2cfb9c0
  task 2712
css_set ffff8800d0b430c0
  task 2531
  task 2530
  task 2525
css_set ffff880035d08480
  task 2522
  task 2520
  task 2510
css_set ffff8800ccee2900
  task 2427
  task 2422
  task 2415
css_set ffff8800d0a39e40
  task 2851
  task 2850
  task 2849
  task 2833
  task 2832
  task 2831
  task 2829
  task 2827
  task 2826
  ...
```

### debug.releaseable

该文件输出了指定`cgroup`的标记`CGRP_RELEASABLE`是否设置了：

```c
static u64 releasable_read(struct cgroup *cgrp, struct cftype *cft)
{
	return test_bit(CGRP_RELEASABLE, &cgrp->flags);
}
```
