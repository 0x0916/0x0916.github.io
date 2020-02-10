

最近分析了内核`cpuset`的实现，发现在目前的常见的系统中应用不是很广泛。目前最火的`docker`也只是使用了其最简单的功能。本文对`cpuset`进行了简要总结，并总结了`docker`如何使用它。

>  注意：本文中引用的内核代码版本为`v5.2`

<!--more-->

![](./pic.jpg)

## 什么是cpuset ?

man手册中对其的描述为：`cpuset - confine processes to processor and memory node subsets`，`cpuset`用于限制一组进程只运行在特定的`cpu`节点上和只在特定的`mem`节点上分配内存。


具体为什么需要`cpuset`，其和`sched_setaffinity(2)`，` mbind(2)`和`set_mempolicy(2)`系统调用的实现关系，可以参考[cpuset文档][1]。

## cpusets 是如何实现的？

由于`linux kernel`在实现`cpusets`之前，就有`sched_setaffinity(2)`，` mbind(2)`和`set_mempolicy(2)`等系统调用完成类似的功能。`cpusets`扩展了这些机制。

刚开始，`cpusets`作为一个单独的实现，有一个文件系统类型为`cpusets`。后面随着`cgroup`的发展，`cpusets`又集成到了`cgroup`中，成了`cgroup`的一个子系统。

目前，作为`cgroup`的一个子系统，其遵循如下原则：

 - 每个进程的`cpuset信息，保存在其`task_struct`中的`cgroup`的数据结构中。
 - `sched_setaffinity`系统调用只被允许设置为进程的`cpuset`中的`cpu`。
 - `mbind` and `set_mempolicy`系统调用只被允许设置为进程的`cpuset`中的`mem`。
 - `root cpuset`包含系统上所有的`cpu`和`mem`。
 - 对于每一个`cpuset`，可以定义其子`cpuset`，子`cpuset`包含的`mem`和`cpu`是其`parent`的子集。
 - 可以查看某个`cpuset`中的所有进程列表。

为了实现`cpuset`，只需在内核中添加一些`hook`，这些`hook`都不在性能关键路径中：

 - 在`init/main.c`, 在内核启动时，初始化`root cpuset`
 - 在`fork`和`exit`接口中，`attach`和`detach`一个进程到对应的`cpuset`中
 - 在`sched_setaffinity`实现中，添加`cpuset`的过滤
 - 在`mbind` and `set_mempolicy`的实现中，添加`cpuset`的过滤
 - 在 `sched.c migrate_live_tasks()`中，限制目标`cpu`为`cpuset`中所允许的
 - 在`page_alloc.c`，限制内存分配的节点为`cpuset`中所允许的内存节点上
 - 在`vmscan.c`,现在内存恢复到`cpuset`中所允许的内存节点上


另外，每一个进程对应的文件` /proc/<pid>/status`中有四行信息描述其`cpuset`信息：

```
  Cpus_allowed:   ffffffff,ffffffff,ffffffff,ffffffff
  Cpus_allowed_list:      0-127
  Mems_allowed:   ffffffff,ffffffff
  Mems_allowed_list:      0-63
```

每一个进程对应的文件` /proc/<pid>/cpuset`中展示了其对应的`cgroup`路径信息。


## cpuset cgroup控制文件

每一个`cpuset`中，都会对应一组`cgroup`的控制文件，包括如下：

|文件| 说明|
|---|---|
|cpuset.cpus | 限制一组进程所能使用的`cpu`, 供用户进行设置 |
|cpuset.mems | 限制一组进程所能使用的`mem`，供用户进行设置 |
|cpuset.effective_cpus | 显示实际进程可以使用的`cpu`|
|cpuset.effective_mems | 显示实际进程可以使用的`mem`| 
|cpuset.memory_migrate |`flag`: 设置为`1`时，使能`memory migration`, 即内存结点改变后迁移内存，默认为`0`|
|cpuset.cpu_exclusive|`flag`：设置为`1`时，说明独占指定`cpus`，默认为`0`|
|cpuset.mem_exclusive|`flag`：设置为`1`时，说明独占指定`mem`，默认为`0`|
|cpuset.mem_hardwall |`flag`：设置为`1`时，说明`cpuset`为`Hardwall`，默认为`0`|
|cpuset.memory_pressure|显示该`cpuset`中的内存压力，只读文件|
|cpuset.memory_spread_page |`flag`：设置为`1`时，内核`page cache`将会均匀的分布在不同的节点上，默认值为`0`|
|cpuset.memory_spread_slab|`flag`：设置为`1`时，内核`slab cache`将会均匀的分布在不同的节点上，默认值为`0`|
|cpuset.sched_load_balance |`flag`：默认为值`1`，表示进程会在该`cpuset`中允许的`cpu`上进行负载均衡|
|cpuset.sched_relax_domain_level|可设置的值为`-1`到一个较小的整数值，只有`sched_load_balance`为`1`时生效，值越大，表示负载均衡时查找的`cpu`范围越大|

另外，在`root cpuset`中除了上面提到的文件外，还包括控制文件：

|文件| 说明|
|---|---|
|cpuset.memory_pressure_enabled|`flag`: 设置为`1`，表示计算每个`cpuset`的内存压力，此时`memory_pressure`的输出才有意义，该值默认为`0`|



## docker中cpuset的使用

`docker`中对`cpuset`的复杂功能都没有使用，即上面提到的各种`flags`都是用的默认值（即都未使能），`docker`只导出了两个接口：`mems`和`cpus`：

```
# docker run --help

Usage:  docker run [OPTIONS] IMAGE [COMMAND] [ARG...]

Run a command in a new container

Options:
...
...

      --cpuset-cpus string                    CPUs in which to allow execution (0-3, 0,1)
      --cpuset-mems string                    MEMs in which to allow execution (0-3, 0,1)
...
...
```

其实现请参考：[runc代码][2]

在实现中，新建`cpuset`时`mems`和`cpus`的值默认为其`parent cpuset`的`mems`和`cpus`的值。


## cpuset 扩展功能

### 什么是 exclusive cpusets ?

如果一个`cpuset`是`cpu 或者`mem exclusive`，那么没有其他`cpuset`（直接`parent`和其子`cpuset`除外）会和其共享相同的`cpus`和`mems`。


###  什么是 memory_pressure ?

`memory_pressure`反应了`cpuset`中的这组进程尝试释放内存的频率，一般用户可以监控该文件，然后做出合理的反应。默认情况下，该功能是`disable`的。


###  什么是  memory spread ?

当进行内存分配时，默认从当前运行的`cpu`所在的`node`上分配内存（`page cache` or  `slab cache`），当配置了`memory_spread_page`和`memory_spread_slab`后，分配内存时就会使用轮询算法。默认情况下，该功能是`disable`的。

代码如下：{{< linux tag="5.2" file="kernel/cgroup/cpuset.c" from="3449" to="3472">}}

```c
static int cpuset_spread_node(int *rotor)
{
	return *rotor = next_node_in(*rotor, current->mems_allowed);
}

int cpuset_mem_spread_node(void)
{
	if (current->cpuset_mem_spread_rotor == NUMA_NO_NODE)
		current->cpuset_mem_spread_rotor =
			node_random(&current->mems_allowed);

	return cpuset_spread_node(&current->cpuset_mem_spread_rotor);
}

int cpuset_slab_spread_node(void)
{
	if (current->cpuset_slab_spread_rotor == NUMA_NO_NODE)
		current->cpuset_slab_spread_rotor =
			node_random(&current->mems_allowed);

	return cpuset_spread_node(&current->cpuset_slab_spread_rotor);
}

EXPORT_SYMBOL_GPL(cpuset_mem_spread_node);
```

### 什么是 sched_load_balance ?


该值默认为`1`，即打开调度`CPU`的负载均衡，这里指的是`cpuset`拥有的`sched_domain`，默认全局的`CPU`调度是本来就有负载均衡的。

简单说一下`sched_domain`的作用，其实就是划定了负载均衡的`CPU`范围，默认是有一个全局的`sched_domain`，对所有`CPU`做负载均衡的，现在再划分出一个`sched_domain`把`CPU`的某个子集作为负载均衡的单元。

对应到`cpuset`中，即将该`cpuset`所运行的`cpu`集合作为一个负载均衡在单元。


###  什么是 sched_relax_domain_level ?

当`sched_load_balance`使能后，该值代表寻找`cpu`的范围,该值有几个等级，越大越优先，表示迁移时搜索`CPU`的范围，这个主要开启了负载均衡选项的时候才有用。具体值代表的范围如下：

```
  -1  : no request. use system default or follow request of others.
   0  : no search.
   1  : search siblings (hyperthreads in a core).
   2  : search cores in a package.
   3  : search cpus in a node [= system wide on non-NUMA system]
   4  : search nodes in a chunk of node [on NUMA system]
   5  : search system wide [on NUMA system]
```

什么时候有用呢？

1. 当进程在cpu间迁移时代价足够小
1. searching cost 足够小，对我们没有影响
1. 低延迟是相比cache miss更重要的场景

## 参考文档

http://man7.org/linux/man-pages/man7/cpuset.7.html


  [1]: https://www.kernel.org/doc/Documentation/cgroup-v1/cpusets.txt
  [2]: https://github.com/opencontainers/runc/blob/v1.0.0-rc5/libcontainer/cgroups/fs/cpuset.go#L32:L44
