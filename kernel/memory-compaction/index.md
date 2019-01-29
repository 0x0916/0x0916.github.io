伙伴系统是基于页来管理的内存的，内存碎片也是基于页的，即由大量离散且不连续的页面导致的。本文详细分析一下去内存碎片的机制：**内存规整**。

包括如下内容：

* 内存规整相关的内存管理参数
* 描述内存碎片化程度的指数：`extfrag_index`和`unusable_index`
* `extfrag_threshold`内存管理参数

<!--more-->

![](./pic.jpg "")

### 系统环境

* 发行版：`centos7.5`
* 内核版本：[3.10.0-862.14.4.el7.x86_64](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.14.4.el7.src.rpm)
* 处理器：`40core（Intel(R) Xeon(R) CPU E5-2630 v4 @ 2.20GHz）`
* 内存：`128GB`，两个`NUMA node`



### 内存规整的时机

内存规整的时机包括如下两个：

* 分配大块内存时(order > 1) ，在低水位情况下分配失败，唤醒kswapd线程后依然无法分配内存，这时调用`__alloc_pages_direct_compact`来进行内存规整，然后再尝试分配所需的内存。
* 手动进行内存规整`echo 1 > /proc/sys/vm/compact_memory`


### 内存碎片化相关`extfag`文件


在开启了内核配置 `CONFIG_DEBUG_FS`和`CONFIG_COMPACTION`后，内核通过`module_init(extfrag_debug_init);`在`debugfs`中创建了如下两个文件：

* `/sys/kernel/debug/extfrag/extfrag_index`
* `/sys/kernel/debug/extfrag/unusable_index`

这两个文件的含义是什么呢？下面我们仔细分析一下:


#### 内存碎片化指数`unusable_index`


`unusable_index`表示某个内存区域中各个`order`的内存碎片情况：

在我的系统上输出如下：

```bash
# cat /sys/kernel/debug/extfrag/unusable_index 
Node 0, zone      DMA 0.000 0.000 0.000 0.002 0.004 0.010 0.010 0.031 0.073 0.157 0.326 
Node 0, zone    DMA32 0.000 0.036 0.124 0.275 0.490 0.703 0.822 0.849 0.854 1.000 1.000 
Node 0, zone   Normal 0.000 0.036 0.119 0.264 0.478 0.725 0.910 0.984 0.997 0.999 1.000 
Node 1, zone   Normal 0.000 0.025 0.088 0.202 0.382 0.620 0.845 0.964 0.991 0.997 0.998 
```
首先解释一下该值的含义：

* 该值表示一个`zone`中所有的空闲内存中，有多少是不能满足分配`order`大小的内存
* 该值的范围最小为`0`，最大为`1`
*  `0`代表没有内存碎片，表示所有的空闲内存都能满足内存分配
*  `1`代表内存碎片严重，表示所有的空闲内存都不能满足内存分配


例如：`Node1` 的`Normal` 区中，`order`为`10`的`unusable_index`的值为` 0.998`，表示`99.8%`的空闲内存都不能满足`2^10`大小的内存分配请求。

内核中计算该`unusable_index`的代码如下：

```c
struct contig_page_info {
        unsigned long free_pages;               // 空闲page个数
        unsigned long free_blocks_total;        // 总得空闲blocks
        unsigned long free_blocks_suitable;     // 能够满足需求的空闲blocks
};

/*
 * Calculate the number of free pages in a zone, how many contiguous
 * pages are free and how many are large enough to satisfy an allocation of
 * the target size. Note that this function makes no attempt to estimate
 * how many suitable free blocks there *might* be if MOVABLE pages were
 * migrated. Calculating that is possible, but expensive and can be
 * figured out from userspace
 */
static void fill_contig_page_info(struct zone *zone,
                                unsigned int suitable_order,
                                struct contig_page_info *info)
{
        unsigned int order;

        info->free_pages = 0;
        info->free_blocks_total = 0;
        info->free_blocks_suitable = 0;

        for (order = 0; order < MAX_ORDER; order++) {
                unsigned long blocks;

                /* Count number of free blocks */
                blocks = zone->free_area[order].nr_free;
                info->free_blocks_total += blocks;

                /* Count free base pages */
                info->free_pages += blocks << order;

                /* Count the suitable free blocks */
                if (order >= suitable_order)
                        info->free_blocks_suitable += blocks <<
                                                (order - suitable_order);
        }
}
/*
 * Return an index indicating how much of the available free memory is
 * unusable for an allocation of the requested size.
 */
static int unusable_free_index(unsigned int order,
                                struct contig_page_info *info)
{
        /* No free memory is interpreted as all free memory is unusable */
        if (info->free_pages == 0)
                return 1000; // 没有空闲内存，直接返回1000

        /*
         * Index should be a value between 0 and 1. Return a value to 3
         * decimal places.
         *
         * 0 => no fragmentation
         * 1 => high fragmentation
         */
        return div_u64((info->free_pages - (info->free_blocks_suitable << order)) * 1000ULL, info->free_pages);

}

static void unusable_show_print(struct seq_file *m,
                                        pg_data_t *pgdat, struct zone *zone)
{
        unsigned int order;
        int index;
        struct contig_page_info info;

        seq_printf(m, "Node %d, zone %8s ",
                                pgdat->node_id,
                                zone->name);
        for (order = 0; order < MAX_ORDER; ++order) {
                fill_contig_page_info(zone, order, &info);
                index = unusable_free_index(order, &info);
                seq_printf(m, "%d.%03d ", index / 1000, index % 1000);
        }

        seq_putc(m, '\n');
}
```

计算公式为：

$$
unusable\ index = \frac{ free\ pages - free\ blocks\ suitable << order}{free\ pages}
$$


#### 内存分配失败原因`extfrag_index`


在我的系统上，输出如下：

```bash
$ cat /sys/kernel/debug/extfrag/extfrag_index 
Node 0, zone      DMA -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 
Node 0, zone    DMA32 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 0.988 0.994 
Node 0, zone   Normal -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 0.994 
Node 1, zone   Normal -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 
```

首先解释一下该值的含义：

* 该值有意义的是有前提的，只有内存预计内存分配将失败时，该值用来反映导致失败的原因
* `0` 代表是由于内存不足导致
* `1` 代表是由于内存碎片导致
* 该值有特殊的值`-1`：表示内存分配不会失败


内核中计算该`extfrag_index`的代码如下：


```c
/*
 * A fragmentation index only makes sense if an allocation of a requested
 * size would fail. If that is true, the fragmentation index indicates
 * whether external fragmentation or a lack of memory was the problem.
 * The value can be used to determine if page reclaim or compaction
 * should be used
 */
static int __fragmentation_index(unsigned int order, struct contig_page_info *info)
{
        unsigned long requested = 1UL << order;

        if (!info->free_blocks_total) // 说明没有内存了
                return 0;

        /* Fragmentation index only makes sense when a request would fail */
        if (info->free_blocks_suitable) // 说明有更大的内存blocks可以分割,来满足内存分配请求
                return -1000;

        /*
         * Index is between 0 and 1 so return within 3 decimal places
         *
         * 0 => allocation would fail due to lack of memory
         * 1 => allocation would fail due to fragmentation
         */
        return 1000 - div_u64( (1000+(div_u64(info->free_pages * 1000ULL, requested))), info->free_blocks_total);
}

/* Same as __fragmentation index but allocs contig_page_info on stack */
int fragmentation_index(struct zone *zone, unsigned int order)
{
        struct contig_page_info info;

        fill_contig_page_info(zone, order, &info);
        return __fragmentation_index(order, &info);
}

static void extfrag_show_print(struct seq_file *m,
                                        pg_data_t *pgdat, struct zone *zone)
{
        unsigned int order;
        int index;

        /* Alloc on stack as interrupts are disabled for zone walk */
        struct contig_page_info info;

        seq_printf(m, "Node %d, zone %8s ",
                                pgdat->node_id,
                                zone->name);
        for (order = 0; order < MAX_ORDER; ++order) {
                fill_contig_page_info(zone, order, &info);
                index = __fragmentation_index(order, &info);
                seq_printf(m, "%d.%03d ", index / 1000, index % 1000);
        }

        seq_putc(m, '\n');
}

```

计算公式为：

$$ extfrag\ index = 1000 - \frac{ \frac{free\ pages * 1000}{requested} + 1000 }{free\ blocks\ total} $$

其中也遇到了上面提到的`fill_contig_page_info`函数，其用来统计内存信息，并填充数据结构`struct contig_page_info info`。

另外，`fragmentation_index`的计算结果还被用来决策是否需要进行页面回收或者内存规整。


### 如何决定一个内存区是否需要内存规整

`compaction_suitable()`函数主要根据当前`zone`的水位来判断是否需要内存规整:

```c?linenums
/*
 * compaction_suitable: Is this suitable to run compaction on this zone now?
 * Returns
 *   COMPACT_SKIPPED  - If there are too few free pages for compaction
 *   COMPACT_PARTIAL  - If the allocation would succeed without compaction
 *   COMPACT_CONTINUE - If compaction should run now
 */
unsigned long compaction_suitable(struct zone *zone, int order)
{
        int fragindex;
        unsigned long watermark;

        /*
         * order == -1 is expected when compacting via
         * /proc/sys/vm/compact_memory
         */ // 当order = -1 时，无条件进行内存规整，一般发生是由于手动触发内存规整
        if (order == -1)
                return COMPACT_CONTINUE;

        /*
         * Watermarks for order-0 must be met for compaction. Note the 2UL.
         * This is because during migration, copies of pages need to be 
         * allocated and for a short time, the footprint is higher
         */
        watermark = low_wmark_pages(zone) + (2UL << order);
        if (!zone_watermark_ok(zone, 0, watermark, 0, 0))
                return COMPACT_SKIPPED; //空闲内存太少了，没有办法执行内存规整

        /*
         * fragmentation index determines if allocation failures are due to
         * low memory or external fragmentation
         *
         * index of -1000 implies allocations might succeed depending on
         * watermarks
         * index towards 0 implies failure is due to lack of memory
         * index towards 1000 implies failure is due to fragmentation 
         *
         * Only compact if a failure would be due to fragmentation.
         */
        fragindex = fragmentation_index(zone, order); //计算碎片化指数，用来决定是否需要进行内存规整
        if (fragindex >= 0 && fragindex <= sysctl_extfrag_threshold)
                return COMPACT_SKIPPED;

        if (fragindex == -1000 && zone_watermark_ok(zone, order, watermark,
            0, 0))
                return COMPACT_PARTIAL;

        return COMPACT_CONTINUE;
}

```

该函数的逻辑如下：

1. 如果`order = -1`，无条件进行内存规整，这种情况一般是用户手动触发了内存规整（`echo 1 > /proc/sys/vm/compact_memory`）
1. 接下来判断`zone`是否在`low_wmark_pages(zone) + (2UL << order);`之上，如果达不到这个条件，说明`zone`中只有很少的空闲内存，不适合做内存规整，跳过这个`zone`
1. 使用`fragmentation_index`函数计算该`zone`的碎片化指数
	* `-1000`： 表示分配可能会成功，不需要内存规整
	* 趋向于`0`：表示是由于内存不足导致分配失败，不应该进行内存规整，因为规整完毕，也释放不出来足够的内存
	* 趋向于`1000`： 表示是由于内存碎片导致内存分配失败，如果该指数大于`/proc/sys/vm/extfrag_threshold`的值，则进行内存规整，该值默认为`500`.

再次看一下extfrag_index 的输出：

```bash
$ cat /sys/kernel/debug/extfrag/extfrag_index 
Node 0, zone      DMA -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 
Node 0, zone    DMA32 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 0.988 0.994 
Node 0, zone   Normal -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 0.994 
Node 1, zone   Normal -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 
```
`extfrag_index` 大于`500`的一般处于`order`比较大的位置。


### 统计内存规整信息

一个系统上，内存规整模块的运行信息，可以通过文件`/proc/vmstat`来查看，如下：

```bash
$ cat /proc/vmstat  | grep compact
compact_migrate_scanned 26654488
compact_free_scanned 857655344
compact_isolated 2530461
compact_stall 355
compact_fail 70
compact_success 285
```

* `compact_stall` 可以简单理解为系统进行内存规整的次数（不包括手动触发内存规整）
* `compact_fail` 表示内存规整失败的次数
* `compact_success` 表示内存规整成功的次数

### 参考文章
