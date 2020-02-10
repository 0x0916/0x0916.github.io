
在`Linux`系统中，有很多内存管理的配置参数，本文就详细分析`lowmem_reserve_ratio`参数。

<!--more-->

![](./pic.jpg "")

### 系统环境介绍

* 发行版：`centos7.5`
* 内核版本：[3.10.0-862.14.4.el7.x86_64](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.14.4.el7.src.rpm)
* 处理器：`40core（Intel(R) Xeon(R) CPU E5-2630 v4 @ 2.20GHz）`
* 内存：`128GB`，两个`NUMA node`

### 官方解释

`lowmem_reserve_ratio`的官方解释如下：

```
For some specialised workloads on highmem machines it is dangerous for
the kernel to allow process memory to be allocated from the "lowmem"
zone.  This is because that memory could then be pinned via the mlock()
system call, or by unavailability of swapspace.

And on large highmem machines this lack of reclaimable lowmem memory
can be fatal.

So the Linux page allocator has a mechanism which prevents allocations
which _could_ use highmem from using too much lowmem.  This means that
a certain amount of lowmem is defended from the possibility of being
captured into pinned user memory.

(The same argument applies to the old 16 megabyte ISA DMA region.  This
mechanism will also defend that region from allocations which could use
highmem or lowmem).

The `lowmem_reserve_ratio' tunable determines how aggressive the kernel is
in defending these lower zones.

If you have a machine which uses highmem or ISA DMA and your
applications are using mlock(), or if you are running with no swap then
you probably should change the lowmem_reserve_ratio setting.

```

总的来说，就是防止进程过多的使用`lower zones`中的内存。 具体实现如下：

* 系统上每个`zone`都会有一个`protection` 数组，在内存分配时，用它和对用的zone的`watermark[high]`来判断是否能够分配内存
* 而每个`zone`的`protection` 的计算方法跟`lowmem_reserve_ratio`有关。


接下来我们看一下每个`zone`的`protection`数组的计算方法。

### `zone`的`protection`计算方法

`lowmem_reserve_ratio`是一个数组，可以通过文件`/proc/sys/vm/lowmem_reserve_ratio`查看其值：

```
$ cat /proc/sys/vm/lowmem_reserve_ratio 
256     256     32
```

目前该值为：

*  `256`： 如果`zone`为`DMA`或者`DMA32`
*  `32`： 其它`zone`

内核利用上述的`lowmem_reserve_ratio`数组计算每个`zone`的预留`page`量，计算出来也是数组形式，从`/proc/zoneinfo`里可以查看：

```
Node 0, zone      DMA
  pages free     1355
        min      3
        low      3
        high     4
	:
	:
    numa_other   0
        protection: (0, 2004, 2004, 2004)
	^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  pagesets
    cpu: 0 pcp: 0
        :
```

在进行内存分配时，这些预留页数值和`watermark`相加来一起决定现在是满足分配请求，还是认为空闲内存量过低需要启动回收。

例如，如果一个`normal`区(`index = 2`)的页申请来试图分配`DMA`区的内存，且现在使用的判断标准是`watermark[high]`时，内核计算出 `page_free = 1355`，而`watermark + protection[2] = 4 + 2004 = 2008 > page_free`，则认为空闲内存太少而不予以分配。如果分配请求本就来自`DMA zone`，则 `protection[0] = 0`会被使用，而满足分配申请。

`zone[i]` 的 `protection[j]` 计算规则如下：

```
(i < j):
  zone[i]->protection[j]
  = (total sums of managed_pages from zone[i+1] to zone[j] on the node)
    / lowmem_reserve_ratio[i];
(i = j):
   (should not be protected. = 0;
(i > j):
   (not necessary, but looks 0)
```

从上面的计算规则可以看出，预留内存值是`ratio`的倒数关系，如果是`256`则代表 `1/256`，即为 `0.39%` 的高端`zone`内存大小。
如果想要预留更多页，应该设更小一点的值，最小值是`1`（`1/1 -> 100%`）。


### 计算示例

根据上述计算方法，结合我的系统环境，计算出的每个`zone`的`protection`数组如下：

| node | zone |   manage_pages  |  protection[0]   |protection[1]  | protection[2]  |protection[3]  |
| ---- | ---- | --- | --- | ---- | --- | --- |
|   0   |   DMA   |   3976  |   0  |  1383 | 63848  |  83848  |
|   0  |  DMM32    |   354201  |     |  0| 62464  |   62464 |
|  0    |   NORAML   |   15991024  |     | |  0 |  0  |
|  0    |    MOVABLE  |  0   |     | |   |  0  |
|   1   |   DMA   |  0   |   0  | 0| 64508  |  64508  |
|   1   |  DMA32    |   0  |     | 0|  64508 |  64508  |
|   1   |   NORMAL   |    16514229 |     | |  0 |  0  |
|   1   |   MOVABLE   |   0  |     | |   |   0 |


通过`/proc/zoneinfo`和`crash`命令，我们可以验证一下计算结果是否正确：

```
$ cat /proc/zoneinfo | grep protection
        protection: (0, 1383, 63848, 63848)
        protection: (0, 0, 62464, 62464)
        protection: (0, 0, 0, 0)
        protection: (0, 0, 0, 0)
		
		
crash> struct zone.lowmem_reserve  ffff88107ffd9000
  lowmem_reserve = {0, 1383, 63848, 63848}
crash> struct zone.lowmem_reserve  ffff88107ffd9800
  lowmem_reserve = {0, 0, 62464, 62464}
crash> struct zone.lowmem_reserve  ffff88107ffda000
  lowmem_reserve = {0, 0, 0, 0}
crash> struct zone.lowmem_reserve  ffff88107ffda800
  lowmem_reserve = {0, 0, 0, 0}
crash> struct zone.lowmem_reserve  ffff88207ffd6000
  lowmem_reserve = {0, 0, 64508, 64508}
crash> struct zone.lowmem_reserve  ffff88207ffd6800
  lowmem_reserve = {0, 0, 64508, 64508}
crash> struct zone.lowmem_reserve  ffff88207ffd7000
  lowmem_reserve = {0, 0, 0, 0}
crash> struct zone.lowmem_reserve  ffff88207ffd7800
  lowmem_reserve = {0, 0, 0, 0}
```

### `lowmem_reserve_ratio`影响

通过分析，我们知道`lowmem_reserve_ratio`会影响系统预留内存的大小，且预留的数量是`ratio`的倒数，所以，如果系统预留稍微多一点的内存，应该将`lowmem_reserve_ratio`适当调小。

> 一般情况下，很少回调整`lowmem_reserve_ratio`的值。

#### 参考文档

* https://www.kernel.org/doc/Documentation/sysctl/vm.txt
* https://blog.csdn.net/joyeu/article/details/20063429

