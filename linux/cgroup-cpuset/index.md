最近分析了内核`cpuset`的实现，发现在目前的常见的系统中应用不是很广泛。目前最火的docker也只是使用了其最简单的功能。本文对cpuset进行了简要总结，并总结了docker如何使用它。

<!--more-->

## 什么是cpuset ?

man手册中对其的描述为：`cpuset - confine processes to processor and memory node subsets`，cpuset用于限制一组进程只运行在特定的cpu节点上和只在特定的mem节点上分配内存。


具体为什么需要`cpuset`，其和`sched_setaffinity(2)`，` mbind(2)`和`set_mempolicy(2)`系统调用的实现关系，可以参考[https://www.kernel.org/doc/Documentation/cgroup-v1/cpusets.txt][1]

## cpusets 是如何实现的？


由于linux kernel在实现cpusets之前，就有`sched_setaffinity(2)`，` mbind(2)`和`set_mempolicy(2)`等系统调用完成类似的功能。cpusets扩展了这些机制。

刚开始，cpusets作为一个单独的实现，有一个文件系统类型为cpusets。后面随着cgroup的发展，cpusets又集成到了cgroup中，成了cgroup的一个子系统。

目前，作为cgroup的一个子系统，其遵循如下原则：

 - 每个进程的cpuset信息，保存在其task_struct中的cgroup的数据结构中。
 - sched_setaffinity系统调用只被允许设置为进程的cpuset中的cpu。
 - mbind and set_mempolicy系统调用只被允许设置为进程的cpuset中的mem。
 - root cpuset包含系统上所有的cpu和mem。
 - 对于每一个cpuset，可以定义其子cpuset，子cpuset包含的mem和cpu是其parent的子集。
 - 可以查看某个cpuset中的所有进程列表。

为了实现cpuset，只需在内核中添加一些hook，这些hook都不在性能关键路径中：

 - 在 init/main.c, 在内核启动时，初始化root cpuset
 - 在fork和exit接口中，attach和detach一个进程到对应的cpuset中
 - 在sched_setaffinity实现中，添加cpuset的过滤
 - 在mbind and set_mempolicy的实现中，添加cpuset的过滤
 - 在 sched.c migrate_live_tasks()中，限制目标cpu为cpuset中所允许的
 - 在page_alloc.c，限制内存分配的节点为cpuset中所允许的内存节点上
 - 在vmscan.c,现在内存恢复到cpuset中所允许的内存节点上


另外，每一个进程对应的文件` /proc/<pid>/status`中有四行信息描述其cpuset信息：

```
  Cpus_allowed:   ffffffff,ffffffff,ffffffff,ffffffff
  Cpus_allowed_list:      0-127
  Mems_allowed:   ffffffff,ffffffff
  Mems_allowed_list:      0-63
```
每一个进程对应的文件` /proc/<pid>/cpuset`中展示了其对应的cgroup路径信息。


## cpuset cgroup控制文件

每一个`cpuset`中，都会对应一组`cgroup`的控制文件，包括如下：

|文件| 说明|
|---|---|
| cpuset.cpus | 限制一组进程所能使用的cpu |
| cpuset.mems | 限制一组进程所能使用的mem |
| cpuset.memory_migrate |flag: 设置为1时，使能memory migration，默认为0|
|cpuset.cpu_exclusive|flag：设置为1时，说明独占cpus，默认为0|
|cpuset.mem_exclusive|flag：设置为1时，说明独占mem，默认为0|
|cpuset.mem_hardwall |flag：设置为1时，说明cpuset为Hardwall，默认为0|
|cpuset.memory_pressure|显示该cpuset中的内存压力，只读文件|
|cpuset.memory_spread_page |flag：设置为1时，内核page cache将会均匀的分布在不同的节点上，默认值为0|
|cpuset.memory_spread_slab|flag：设置为1时，内核slab cache将会均匀的分布在不同的节点上，默认值为0|
|cpuset.sched_load_balance |flag：默认为值1，表示进程会在该cpuset中允许的cpu上进行负载均衡|
|cpuset.sched_relax_domain_level|可设置的值为-1到一个较小的整数值，只有sched_load_balance为1时生效，值越大，表示负载均衡时查找的cpu范围越大|

另外，在`root cpuset`中除了上面提到的文件外，还包括控制文件：

|文件| 说明|
|---|---|
|cpuset.memory_pressure_enabled|flag: 设置为1，表示计算每个cpuset的内核压力，此时memory_pressure的输出才有意义，该值默认为0|



## docker中cpuset的使用

docker中对cpuset的复杂功能都没有使用，即上面提到的各种flags都是用的默认值（即都未使能），docker只导出了两个接口：mems和cpus：

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
其实现请参考：[https://github.com/opencontainers/runc/blob/v1.0.0-rc5/libcontainer/cgroups/fs/cpuset.go#L32:L44][2]

在实现中，新建cpuset时mems和cpus的值默认为其parent cpuset的mems和cpus的值。


## cpuset 扩展功能

### 什么是 exclusive cpusets ?

如果一个cpuset是cpu 或者mem exclusive，那么没有其他cpuset（直接parent和其子cpuset除外）会和其共享相同的cpus和mems。


###  什么是 memory_pressure ?

`memory_pressure`反应了cpuset中的这组进程尝试释放内存的频率，一般用户可以监控该文件，然后做出合理的反应。默认情况下，该功能是disable的。


###  什么是  memory spread ?

当进行内存分配时，默认从当前运行的cpu所在的node上分配内存（page cache or  slab cache），当配置了memory_spread_page和memory_spread_slab后，分配内存时就会使用轮询算法。默认情况下，该功能是disable的。



### 什么是 sched_load_balance ?

默认使能，表示进程会在所允许的cpus上进行负载均衡。

###  什么是 sched_relax_domain_level ?

当sched_load_balance使能后，该值代表寻找cpu的范围：

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
（1）当进程在cpu间迁移时代价足够小
（2）searching cost 足够小，对我们没有影响
（3）低延迟是相比cache miss更重要的场景

## 参考文档

http://man7.org/linux/man-pages/man7/cpuset.7.html


  [1]: https://www.kernel.org/doc/Documentation/cgroup-v1/cpusets.txt
  [2]: https://github.com/opencontainers/runc/blob/v1.0.0-rc5/libcontainer/cgroups/fs/cpuset.go#L32:L44
