
在`Linux`系统中，有很多内存管理的配置参数，本文就详细分析`min_free_kbytes`参数。

<!--more-->

![](./pic.jpg)

### 系统环境介绍

* 发行版：`centos7.5`
* 内核版本：[3.10.0-862.14.4.el7.x86_64](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.14.4.el7.src.rpm)
* 处理器：`40core（Intel(R) Xeon(R) CPU E5-2630 v4 @ 2.20GHz）`
* 内存：`128GB`，两个`NUMA node`

### `min_free_kbytes` 解释

在我的系统上，其值如下：

```
cat /proc/sys/vm/min_free_kbytes 
90112
```

我们先看其官方解释：

```
min_free_kbytes:

This is used to force the Linux VM to keep a minimum number
of kilobytes free.  The VM uses this number to compute a
watermark[WMARK_MIN] value for each lowmem zone in the system.
Each lowmem zone gets a number of reserved free pages based
proportionally on its size.

Some minimal amount of memory is needed to satisfy PF_MEMALLOC
allocations; if you set this to lower than 1024KB, your system will
become subtly broken, and prone to deadlock under high loads.

Setting this too high will OOM your machine instantly.
```

从上面的解释中主要有如下两个点：

* 代表系统所保留空闲内存的最低限
* 用于计算影响内存回收的三个参数 `watermark[min/low/high]`


### 系统所保留空闲内存的最低限

在系统初始化时会根据内存大小计算一个默认值，计算规则是：

```
/*
 * Initialise min_free_kbytes.
 *
 * For small machines we want it small (128k min).  For large machines
 * we want it large (64MB max).  But it is not linear, because network
 * bandwidth does not increase linearly with machine size.  We use
 *
 *      min_free_kbytes = 4 * sqrt(lowmem_kbytes), for better accuracy:
 *      min_free_kbytes = sqrt(lowmem_kbytes * 16)
 *
 * which yields
 *
 * 16MB:        512k
 * 32MB:        724k
 * 64MB:        1024k
 * 128MB:       1448k
 * 256MB:       2048k
 * 512MB:       2896k
 * 1024MB:      4096k
 * 2048MB:      5792k
 * 4096MB:      8192k
 * 8192MB:      11584k
 * 16384MB:     16384k
 */
```

`lowmem_kbytes`可以认为是系统的内存大小。精确的算法是：`lowmem_kbytes`等于所有`zone`中`managed-high`之和。

在我的系统上各个`zone`的`page`个数如下：

| zone   | managed | min | low | high |  managed - high |
|---|---|---|---|---|---|
| dma    |       3976       |  2   |  3   | 3 | 3973 |
| dma32  |      354201        |  242   |  302   | 363  | 353838 |
| normal |       15991024       |  10962   |  13702   |  16443 | 15974581|
| normal |       16514229       |  11320   |  14150   |  16980 | 16497249|
| total |  32863430 | 22526| 28157| 33789| 32829641|

结合上面的算法:

```
lowmem_kbytes = 32829641 * (PAGE_SIZE >> 10) = 32829641 * 4
min_free_kbytes = sqrt(lowmem_kbytes * 16)
				= sqrt(32829641 * 4 * 16)
				= sqrt(2101097024)
				= 45837
```

另外，计算出来的值有最小最大限制，最小为`128K`，最大为`64M`。
可以看出，`min_free_kbytes`随着内存的增大不是线性增长，注释里也提到了原因：**because network bandwidth does not increase linearly with machine size**。随着内存的增大，没有必要也线性的预留出过多的内存，能保证紧急时刻的使用量便足矣。


这里计算出的`45837`是在内存大小为`128G`的服务器上的`min_free_kbytes`的初始值。但实际上该服务上`min_free_kbytes`的值为`90112`，显然超过了最大的`64M`。
```
cat /proc/sys/vm/min_free_kbytes 
90112
```

这是为什么呢？经过查看内核源代码，发现`min_free_kbytes`根据如上算法初始化后，如果系统支持大页，会在`set_recommended_min_free_kbytes`函数中根据情况调整该值：
```
        if (recommended_min > min_free_kbytes) 
                min_free_kbytes = recommended_min;
```

### 用于计算影响内存回收的三个参数 `watermark[min/low/high]`

`watermark[high] > watermark [low] > watermark[min]`，各个`zone`各一套。

在系统空闲内存低于 `watermark[low]`时，开始启动内核线程`kswapd`进行内存回收，直到该`zone`的空闲内存数量达到`watermark[high]`后停止回收。如果上层申请内存的速度太快，导致空闲内存降至`watermark[min]`后，内核就会进行`direct reclaim`（直接回收），即直接在应用程序的进程上下文中进行回收，再用回收上来的空闲页满足内存申请，因此实际会阻塞应用程序，带来一定的响应延迟，而且可能会触发系统`OOM`。这是因为`watermark[min]`以下的内存属于系统的自留内存，用以满足特殊使用，所以不会给用户态的普通申请来用。


三个watermark的计算方法：

 `watermark[min] = min_free_kbytes`换算为`page`单位即可，假设为`min_free_pages`。（因为是每个`zone`各有一套`watermark`参数，实际计算效果是根据各个`zone`大小所占内存总大小的比例，而算出来的`per zone min_free_pages`）
 `watermark[low] = watermark[min] * 5 / 4`
 `watermark[high] = watermark[min] * 3 / 2`
 
所以中间的`buffer`量为 : 

```
watermark[high] - watermark[low] 
		= watermark[min] * 3 / 2 - watermark[min] * 5 / 4 
		= watermark[min] * 1 / 4 
		= per_zone_min_free_pages * 1/4
```

因为`min_free_kbytes = 4* sqrt(lowmem_kbytes）`，也可以看出中间的`buffer`量也是跟内存的增长速度成开方关系。

我们计算一下当前系统上的各个`zone`的值水位值：

1.  `min_free_kbytes`的值为`90112`，换算成`page`数为：`22528`，即系统上所有`zone`的`watermark[min]`总共为`22528`。
2.  系统上所有`zone`的总的`managed`为：`32863430`,计算出下表：

| zone   | managed | 比例 | min | `low = 1.25*min`|  `high=1.5*min` |
| :------: | ------------: | ---: | ---: | ---: | ---: |
| DMA    |      3976       |3976/32863430  |   2 | 2.5 |  3|
| DMA32  |      354201      |354201/32863430   |  242   | 302.50  | 363 |
| NORMAL |      15991024   |15991024/32863430    |  10961   |13701.25   |16441.5 |
| NORMAL |      16514229   |16514229/32863430   |  11320   |  14150.00 |16980.0 | 
| Total|  32863430 | | | | |


可以通过`/proc/zoneinfo`查看每个`zone`的`watermark`

```
$ cat /proc/zoneinfo | grep Node -A8
Node 0, zone      DMA
  pages free     3039
        min      2
        low      2
        high     3
        scanned  0
        spanned  4095
        present  3997
        managed  3976
--
Node 0, zone    DMA32
  pages free     92138
        min      242
        low      302
        high     363
        scanned  0
        spanned  1044480
        present  417248
        managed  354201
--
Node 0, zone   Normal
  pages free     3049742
        min      10962
        low      13702
        high     16443
        scanned  0
        spanned  16252928
        present  16252928
        managed  15991024
--
Node 1, zone   Normal
  pages free     2318057
        min      11320
        low      14150
        high     16980
        scanned  0
        spanned  16777216
        present  16777216
        managed  16514229
```

### `min_free_kbytes`大小的影响

`min_free_kbytes`设的越大，`watermark`的线越高，同时三个线之间的`buffer`量也相应会增加。这意味着会较早的启动`kswapd`进行回收，且会回收上来较多的内存（直至`watermark[high]`才会停止），这会使得系统预留过多的空闲内存，从而在一定程度上降低了应用程序可使用的内存量。极端情况下设置`min_free_kbytes`接近内存大小时，留给应用程序的内存就会太少而可能会频繁地导致`OOM`的发生。

`min_free_kbytes`设的过小，则会导致系统预留内存过小。`kswapd`回收的过程中也会有少量的内存分配行为（会设上`PF_MEMALLOC`）标志，这个标志会允许`kswapd`使用预留内存；另外一种情况是被`OOM`选中杀死的进程在退出过程中，如果需要申请内存也可以使用预留部分。这两种情况下让他们使用预留内存可以避免系统进入`deadlock`状态。


### 参考文章

* https://www.kernel.org/doc/Documentation/sysctl/vm.txt
* https://blog.csdn.net/joyeu/article/details/20063429

