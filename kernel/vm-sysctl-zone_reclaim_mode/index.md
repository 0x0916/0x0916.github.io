
在`Linux`系统中，有很多内存管理的配置参数，本文就详细分析`zone_reclaim_mode`参数。

<!--more-->

![](./pic.jpg "")

### 系统环境

* 发行版：`centos7.5`
* 内核版本：[3.10.0-862.14.4.el7.x86_64](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.14.4.el7.src.rpm)
* 处理器：`40core（Intel(R) Xeon(R) CPU E5-2630 v4 @ 2.20GHz）`
* 内存：`128GB`，两个`NUMA node` 


###  官方解释

```
zone_reclaim_mode:

Zone_reclaim_mode allows someone to set more or less aggressive approaches to
reclaim memory when a zone runs out of memory. If it is set to zero then no
zone reclaim occurs. Allocations will be satisfied from other zones / nodes
in the system.

This is value ORed together of

1	= Zone reclaim on
2	= Zone reclaim writes dirty pages out
4	= Zone reclaim swaps pages

zone_reclaim_mode is disabled by default.  For file servers or workloads
that benefit from having their data cached, zone_reclaim_mode should be
left disabled as the caching effect is likely to be more important than
data locality.

zone_reclaim may be enabled if it's known that the workload is partitioned
such that each partition fits within a NUMA node and that accessing remote
memory would cause a measurable performance reduction.  The page allocator
will then reclaim easily reusable pages (those page cache pages that are
currently not used) before allocating off node pages.

Allowing zone reclaim to write out pages stops processes that are
writing large amounts of data from dirtying pages on other nodes. Zone
reclaim will write out dirty pages if a zone fills up and so effectively
throttle the process. This may decrease the performance of a single process
since it cannot use all of system memory to buffer the outgoing writes
anymore but it preserve the memory on other nodes so that the performance
of other processes running on other nodes will not be affected.

Allowing regular swap effectively restricts allocations to the local
node unless explicitly overridden by memory policies or cpuset
configurations.
```

`zone_reclaim_mode`是用来控制内存`zone`回收模式，在内存分配中，用来管理当一个内存区域内部的内存耗尽时，是从其内部进行内存回收来满足分配还是直接从其它内存区域中分配内存。

### 调整方法

我们可以通过`/proc/sys/vm/zone_reclaim_mode`文件对这个参数进行调整。


在申请内存时(内核的`get_page_from_freelist()`方法中)，内核在当前`zone`内没有足够内存可用的情况下，会根据`zone_reclaim_mode`的设置来决策是从下一个`zone`找空闲内存还是在`zone`内部进行回收。这个值为`0`时表示可以从下一个`zone`找可用内存，`非0`表示在本地回收。这个文件可以设置的值及其含义如下：

```bash
# echo 0 > /proc/sys/vm/zone_reclaim_mode
# # 意味着关闭zone_reclaim模式，可以从其他zone或NUMA节点回收内存
# echo 1 > /proc/sys/vm/zone_reclaim_mode
# # 表示打开zone_reclaim模式，这样内存回收只会发生在本地节点内
# echo 2 > /proc/sys/vm/zone_reclaim_mode
# # 在本地回收内存时，可以将cache中的脏数据写回硬盘，以回收内存。
# echo 4 > /proc/sys/vm/zone_reclaim_mode
# # 可以用swap方式回收内存。
```
> 注意：`zone_reclaim_mode`的只有低`3`位有效，所以还可以设置的值为，`3、5、6、7`。
> 此外，内核中对该值没有限制，可以写入任意的值到该接口中。


不同的参数配置会在`NUMA`环境中对其他内存节点的内存使用产生不同的影响，大家可以根据自己的情况进行设置以优化你的应用。


### 调整的影响

* 默认情况下，`zone_reclaim模式`是关闭的。这在很多应用场景下可以提高效率，比如文件服务器，或者依赖内存中`cache`比较多的应用场景。这样的场景对内存`cache`速度的依赖要高于进程进程本身对内存速度的依赖，所以我们宁可让内存从其他`zone`申请使用，也不愿意清本地`cache`。

* 如果确定应用场景是**内存需求大于缓存**，而且尽量要避免内存访问跨越`NUMA`节点造成的性能下降的话，则可以打开`zone_reclaim`模式。此时页分配器会优先回收容易回收的可回收内存（**主要是当前不用的`page cache`页**），然后再回收其他内存。

* 打开本地回收模式的写回可能会引发其他内存节点上的大量的脏数据写回处理。如果一个内存`zone`已经满了，那么脏数据的写回也会导致进程处理速度收到影响，产生处理瓶颈。这会降低某个内存节点相关的进程的性能，因为进程不再能够使用其他节点上的内存。但是会增加节点之间的隔离性，其他节点的相关进程运行将不会因为另一个节点上的内存回收导致性能下降。

> 注意：最新的内核上，已经没有了该内存管理参数，在centos的内核上，依然存在该参数。

###  参考资料

* https://blog.csdn.net/AXW2013/article/details/79659055
* https://www.kernel.org/doc/Documentation/sysctl/vm.txt
