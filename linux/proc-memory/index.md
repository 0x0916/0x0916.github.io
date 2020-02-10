
 在`linux`内核中，整个内存信息和状态的展示可以通过以下几个文件获得：
 
| 文件| 描述|
|---|---|
| `/proc/buddyinfo`|展示系统上各个`zone`的`buddy`信息，主要用来分析内存碎片问题|
| `/proc/pagetypeinfo`|输出系统上各个`zone`中的不同迁移类型的详细状态信息|
| `/proc/vmstat`|描述内存统计信息|
| `/proc/zoneinfo`|输出系统上各个内存`zone`的详细信息|

在详细介绍这些接口之前，我们先要明确一下几点：

* 现在的内核中，内存管理最大概念为`node`。
* 在node上再分为一个或者几个`zone`
* 每个`zone`中又分为不同的迁移类型

<!--more-->

![](./pic.jpg "")

### 系统环境

* 发行版：`centos7.5`
* 内核版本：[3.10.0-862.14.4.el7.x86_64](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.14.4.el7.src.rpm)
* 处理器：`40core（Intel(R) Xeon(R) CPU E5-2630 v4 @ 2.20GHz）`
* 内存：`128GB`，两个`NUMA node`

### /proc/vmstat

该文件输出了当前系统上虚拟内存的统计信息，这里的信息大约分为以下几类：

* 所有`zone`中各种类型页面数的统计信息，从`nr_free_pages` 到`nr_free_cma`
* `writeback`相关的统计信息：`nr_dirty_threshold` 和 `nr_dirty_background_threshold`
* `vm`相关事件的统计信息：`pgpgin` 到`balloon_migrate`

简单讨论一下这几类数据的内核实现：

（1）各种类型的页面统计信息：

使用数组`vm_stat`来记录各种类型的页面统计信息，其类型为原子变量：`atomic_long_t`

```c
atomic_long_t vm_stat[NR_VM_ZONE_STAT_ITEMS] __cacheline_aligned_in_smp; 
```
（2）`writeback`相关的统计信息，是通过函数`global_dirty_limits`来获取的，这里就不具体分析了。

（3）`vm`相关事件的统计信息是通过函数`all_vm_events`来计算,内核定义了`vm_event_states`每`cpu`变量，`all_vm_events`用于将所有处理器上的这些事件进行累加。

```c
DEFINE_PER_CPU(struct vm_event_state, vm_event_states) = {{0}};  
```

该文件的输出示例如下：
```bash
$ cat /proc/vmstat
nr_free_pages 29655945 			//各种类型页面数的统计信息
nr_alloc_batch 5265
nr_inactive_anon 1105696
nr_active_anon 145571
nr_inactive_file 77585
nr_active_file 146995
nr_unevictable 0
nr_mlock 0
nr_anon_pages 91904
nr_mapped 31031
nr_file_pages 1284682
nr_dirty 111
nr_writeback 0
nr_slab_reclaimable 945919
nr_slab_unreclaimable 144386
nr_page_table_pages 3120
nr_kernel_stack 983
nr_unstable 0
nr_bounce 0
nr_vmscan_write 132
nr_vmscan_immediate_reclaim 0
nr_writeback_temp 0
nr_isolated_anon 0
nr_isolated_file 0
nr_shmem 1060098
nr_dirtied 1100238982
nr_written 764546994
numa_hit 117570377080
numa_miss 2104051815
numa_foreign 2104051815
numa_interleave 71023
numa_local 117569971886
numa_other 2104457009
workingset_refault 1414110
workingset_activate 127292
workingset_nodereclaim 0
nr_anon_transparent_hugepages 194
nr_free_cma 0
nr_dirty_threshold 8921519		//writeback相关统计信息
nr_dirty_background_threshold 1482076
pgpgin 47745153				//vm相关事件统计信息
pgpgout 3334426145
pswpin 0
pswpout 132
pgalloc_dma 2440
pgalloc_dma32 906331246
pgalloc_normal 122337837001
pgalloc_movable 0
pgfree 123275102844
pgactivate 866958575
pgdeactivate 35134007
pgfault 200181149428
pgmajfault 302912
pgrefill_dma 0
pgrefill_dma32 330384
pgrefill_normal 33572221
pgrefill_movable 0
pgsteal_kswapd_dma 0
pgsteal_kswapd_dma32 217561
pgsteal_kswapd_normal 20754709
pgsteal_kswapd_movable 0
pgsteal_direct_dma 0
pgsteal_direct_dma32 44442
pgsteal_direct_normal 5791306
pgsteal_direct_movable 0
pgscan_kswapd_dma 0
pgscan_kswapd_dma32 217623
pgscan_kswapd_normal 20758866
pgscan_kswapd_movable 0
pgscan_direct_dma 0
pgscan_direct_dma32 44444
pgscan_direct_normal 5801646
pgscan_direct_movable 0
pgscan_direct_throttle 0
zone_reclaim_failed 0
pginodesteal 521563
slabs_scanned 19199872
kswapd_inodesteal 830416
kswapd_low_wmark_hit_quickly 7589
kswapd_high_wmark_hit_quickly 3308
pageoutrun 13365
allocstall 1873
pgrotated 1079550
drop_pagecache 2
drop_slab 0
numa_pte_updates 10414340982
numa_huge_pte_updates 348659
numa_hint_faults 9485402037
numa_hint_faults_local 8163824272
numa_pages_migrated 1233051066
pgmigrate_success 1234311263
pgmigrate_fail 4573711
compact_migrate_scanned 26654488
compact_free_scanned 857655344
compact_isolated 2530461
compact_stall 355
compact_fail 70
compact_success 285
htlb_buddy_alloc_success 0
htlb_buddy_alloc_fail 0
unevictable_pgs_culled 0
unevictable_pgs_scanned 0
unevictable_pgs_rescued 0
unevictable_pgs_mlocked 0
unevictable_pgs_munlocked 0
unevictable_pgs_cleared 0
unevictable_pgs_stranded 0
thp_fault_alloc 4953381
thp_fault_fallback 35453294
thp_collapse_alloc 15648
thp_collapse_alloc_failed 55693
thp_split 494944
thp_zero_page_alloc 1
thp_zero_page_alloc_failed 0
balloon_inflate 0
balloon_deflate 0
balloon_migrate 0

```

### /proc/buddyinfo

该文件输出了系统内存管理中，伙伴系统的状态。该文件每一行代表一个`zone`中`buddy`的信息。每一行先输出` node` 编号，然后是`zone`的名称，紧接着是各个`order（0-10）`剩余的块个数。

* 每个`order`对应的大小为：`2^(order)*PAGE_SIZE`
* 当内存系统碎片化比较严重时，`order`比较大的计数一般为`0`，此时分配大的内存将会失败

该文件的内核实现比较简单，直接输出每个`zone`对应的`free_area[order].nr_free`

```c
static void frag_show_print(struct seq_file *m, pg_data_t *pgdat,                                                                                                  
                                                struct zone *zone)                                                                                                 
{                                                                                                                                                                  
        int order;                                                                                                                                                 
                                                                                                                                                                   
        seq_printf(m, "Node %d, zone %8s ", pgdat->node_id, zone->name);
        for (order = 0; order < MAX_ORDER; ++order)
                seq_printf(m, "%6lu ", zone->free_area[order].nr_free);
        seq_putc(m, '\n');
}
```

输出示例如下：

```bash
$ cat /proc/buddyinfo 
Node 0, zone      DMA      1      1      1      1      1      0      1      1      1      1      2 
Node 0, zone    DMA32    688   2080   1420    995    596    357    278    241    276     32    133 
Node 0, zone   Normal 195748 204074 161167 119070  70791  33578   9556   2070   1034   2533   7328 
Node 1, zone   Normal  11705  51467  36752  21326  11343   7309   5024   3403   2597   3056  10898
```


### /proc/pagetypeinfo

`pagetypeinfo`输出系统上各个`zone`中的不同迁移类型的详细状态信息，其比`/proc/buddyinfo `中的信息更加详细。同时该文件也输出了如下信息：

* 系统上`page block`的大小和`page block order`的值：一般情况下，`Page block order` 为`9`， 所以每个`page block`中有`512`个`page`页。
* 每个`zone`中的`page block`个数

> 注意：跟`buddyinfo`不同，这里直接输出的`page`的个数，而不是`order`对应的伙伴系统的空闲块的个数


输出示例信息如下：

```bash
$ cat /proc/pagetypeinfo 
Page block order: 9
Pages per block:  512

Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10 
Node    0, zone      DMA, type    Unmovable      1      1      1      1      1      0      1      1      1      0      0 
Node    0, zone      DMA, type  Reclaimable      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone      DMA, type      Movable      0      0      0      0      0      0      0      0      0      1      2 
Node    0, zone      DMA, type      Reserve      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone      DMA, type          CMA      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone      DMA, type      Isolate      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone    DMA32, type    Unmovable     95    216    141     63     27      3      2      1      5      0      0 
Node    0, zone    DMA32, type  Reclaimable      0    871    900    605    255     62     21     10     15      0      0 
Node    0, zone    DMA32, type      Movable    566    981    382    327    313    291    255    230    256     32    133 
Node    0, zone    DMA32, type      Reserve      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone    DMA32, type          CMA      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone    DMA32, type      Isolate      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone   Normal, type    Unmovable   3635   2151   1535    962    927    352     24      0      0      0      0 
Node    0, zone   Normal, type  Reclaimable   4235  36693  29792  13837   2886    318     23      4      4      0      1 
Node    0, zone   Normal, type      Movable 186666 165228 129840 104268  66977  32908   9510   2066   1030   2534   7327 
Node    0, zone   Normal, type      Reserve      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone   Normal, type          CMA      0      0      0      0      0      0      0      0      0      0      0 
Node    0, zone   Normal, type      Isolate      0      0      0      0      0      0      0      0      0      0      0 

Number of blocks type     Unmovable  Reclaimable      Movable      Reserve          CMA      Isolate 
Node 0, zone      DMA            3            0            5            0            0            0 
Node 0, zone    DMA32           69           59          760            0            0            0 
Node 0, zone   Normal         1256         1426        29062            0            0            0 
Page block order: 9
Pages per block:  512

Free pages count per migrate type at order       0      1      2      3      4      5      6      7      8      9     10 
Node    1, zone   Normal, type    Unmovable   5911   2837   1059    495    341    132     67     34     29      0      0 
Node    1, zone   Normal, type  Reclaimable   4972  34049  27480  12864   2317    547     29      4      3      0      0 
Node    1, zone   Normal, type      Movable    374  14707   8209   7967   8685   6630   4928   3365   2565   3056  10898 
Node    1, zone   Normal, type      Reserve      0      0      0      0      0      0      0      0      0      0      0 
Node    1, zone   Normal, type          CMA      0      0      0      0      0      0      0      0      0      0      0 
Node    1, zone   Normal, type      Isolate      0      0      0      0      0      0      0      0      0      0      0 

Number of blocks type     Unmovable  Reclaimable      Movable      Reserve          CMA      Isolate 
Node 1, zone   Normal         1009         1602        30157            0            0            0 
```

* 从输出来看，我们系统上每个`pageblock`的大小为`512 * 4k = 2MB`
* 我们看到`DMA`区的总共有`8`个`pageblock`，所以`DMA`的大小为`8 * 2MB = 16MB` 


### /proc/zoneinfo 

`/proc/zoneinfo`输出了系统上`zone`的信息，其信息主要分为以下几类：

1. `zone`的一些基本信息，包括名称，空闲页面个数，三个水位，以及管理的页的个数等等
1. `zone`中各个类型页面个数的统计信息
1. `protection`信息，决定是否可以内存分配请求时，需要用到
1. 输出`zone`的每个`cpu`对应的`pagesets`信息
1. 其它信息

* 在本示例输出中，`node0`有`DMA`、 `DMA32`、`Normal`这三个`zone`，`node1`只有一个`Normal zone`。

```bash
$ cat /proc/zoneinfo
Node 0, zone      DMA		// node信息，zone名称
  pages free     3039		// 空闲page个数
        min      2			// min水位
        low      2			//low 水位
        high     3			// high 水位
        scanned  0
        spanned  4095		// spanned_pages = zone_end_pfn - zone_start_pfn (包含hole)
        present  3997		// present_pages = spanned_pages - absent_pages(pages in holes)
        managed  3976		// managed_pages = present_pages - reserved_pages(buddy管理的页面个数)
    nr_free_pages 3039  // 以下38行统计了该zone中不同用途类型的page的个数
    nr_alloc_batch 1
    nr_inactive_anon 0
    nr_active_anon 0
    nr_inactive_file 0
    nr_active_file 0
    nr_unevictable 0
    nr_mlock     0
    nr_anon_pages 0
    nr_mapped    0
    nr_file_pages 0
    nr_dirty     0
    nr_writeback 0
    nr_slab_reclaimable 0
    nr_slab_unreclaimable 0
    nr_page_table_pages 0
    nr_kernel_stack 0
    nr_unstable  0
    nr_bounce    0
    nr_vmscan_write 0
    nr_vmscan_immediate_reclaim 0
    nr_writeback_temp 0
    nr_isolated_anon 0
    nr_isolated_file 0
    nr_shmem     0
    nr_dirtied   0
    nr_written   0
    numa_hit     1675
    numa_miss    0
    numa_foreign 0
    numa_interleave 0
    numa_local   1586
    numa_other   89
    workingset_refault 0
    workingset_activate 0
    workingset_nodereclaim 0
    nr_anon_transparent_hugepages 0
    nr_free_cma  0
        protection: (0, 1383, 63848, 63848)
  pagesets
    cpu: 0
              count: 0
              high:  0
              batch: 1
  vm stats threshold: 12
    cpu: 1
              count: 0
              high:  0
              batch: 1
  vm stats threshold: 12
...
...
...
...
    cpu: 38
              count: 0
              high:  0
              batch: 1
  vm stats threshold: 12
    cpu: 39
              count: 0
              high:  0
              batch: 1
  vm stats threshold: 12
  all_unreclaimable: 0
  start_pfn:         1
  inactive_ratio:    1
Node 0, zone    DMA32
  pages free     310887
        min      242
        low      302
        high     363
        scanned  0
        spanned  1044480
        present  417248
        managed  354201
    nr_free_pages 310887
    nr_alloc_batch 61
    nr_inactive_anon 13164
    nr_active_anon 477
    nr_inactive_file 806
    nr_active_file 1797
    nr_unevictable 0
    nr_mlock     0
    nr_anon_pages 729
    nr_mapped    194
    nr_file_pages 14973
    nr_dirty     0
    nr_writeback 0
    nr_slab_reclaimable 7453
    nr_slab_unreclaimable 1325
    nr_page_table_pages 37
    nr_kernel_stack 6
    nr_unstable  0
    nr_bounce    0
    nr_vmscan_write 0
    nr_vmscan_immediate_reclaim 0
    nr_writeback_temp 0
    nr_isolated_anon 0
    nr_isolated_file 0
    nr_shmem     12370
    nr_dirtied   8381421
    nr_written   5315197
    numa_hit     854956447
    numa_miss    153095
    numa_foreign 0
    numa_interleave 0
    numa_local   854952367
    numa_other   157175
    workingset_refault 10804
    workingset_activate 97
    workingset_nodereclaim 0
    nr_anon_transparent_hugepages 1
    nr_free_cma  0
        protection: (0, 0, 62464, 62464)
  pagesets
    cpu: 0
              count: 158
              high:  186
              batch: 31
  vm stats threshold: 60
    cpu: 1
              count: 170
              high:  186
              batch: 31
  vm stats threshold: 60
    cpu: 2
              count: 182
              high:  186
              batch: 31
  vm stats threshold: 60
...
...
...
    cpu: 38
              count: 0
              high:  186
              batch: 31
  vm stats threshold: 60
    cpu: 39
              count: 0
              high:  186
              batch: 31
  vm stats threshold: 60
  all_unreclaimable: 0
  start_pfn:         4096				// 开始的pfn号
  inactive_ratio:    3
Node 0, zone   Normal
  pages free     14351077
        min      10962
        low      13702
        high     16443
        scanned  0
        spanned  16252928
        present  16252928
        managed  15991024
    nr_free_pages 14351077
    nr_alloc_batch 1381
    nr_inactive_anon 557945
    nr_active_anon 49324
    nr_inactive_file 30342
    nr_active_file 56404
    nr_unevictable 0
    nr_mlock     0
    nr_anon_pages 31468
    nr_mapped    12918
    nr_file_pages 643281
    nr_dirty     59
    nr_writeback 0
    nr_slab_reclaimable 416893
    nr_slab_unreclaimable 71886
    nr_page_table_pages 1351
    nr_kernel_stack 519
    nr_unstable  0
    nr_bounce    0
    nr_vmscan_write 25
    nr_vmscan_immediate_reclaim 0
    nr_writeback_temp 0
    nr_isolated_anon 0
    nr_isolated_file 0
    nr_shmem     556532
    nr_dirtied   598988584
    nr_written   419469120
    numa_hit     60842388353
    numa_miss    2044762264
    numa_foreign 59136456
    numa_interleave 35507
    numa_local   60842226428
    numa_other   2044924189
    workingset_refault 610786
    workingset_activate 22873
    workingset_nodereclaim 0
    nr_anon_transparent_hugepages 37
    nr_free_cma  0
        protection: (0, 0, 0, 0)
  pagesets
    cpu: 0
              count: 125
              high:  186
              batch: 31
  vm stats threshold: 120
    cpu: 1
              count: 162
              high:  186
              batch: 31
  vm stats threshold: 120
...
...
...
...
    cpu: 38
              count: 176
              high:  186
              batch: 31
  vm stats threshold: 120
    cpu: 39
              count: 174
              high:  186
              batch: 31
  vm stats threshold: 120
  all_unreclaimable: 0
  start_pfn:         1048576
  inactive_ratio:    24
Node 1, zone   Normal
  pages free     14993432
        min      11320
        low      14150
        high     16980
        scanned  0
        spanned  16777216
        present  16777216
        managed  16514229
    nr_free_pages 14993432
    nr_alloc_batch 894
    nr_inactive_anon 534587
    nr_active_anon 95276
    nr_inactive_file 46704
    nr_active_file 87189
    nr_unevictable 0
    nr_mlock     0
    nr_anon_pages 59220
    nr_mapped    17798
    nr_file_pages 625093
    nr_dirty     90
    nr_writeback 0
    nr_slab_reclaimable 521541
    nr_slab_unreclaimable 71127
    nr_page_table_pages 1682
    nr_kernel_stack 459
    nr_unstable  0
    nr_bounce    0
    nr_vmscan_write 107
    nr_vmscan_immediate_reclaim 0
    nr_writeback_temp 0
    nr_isolated_anon 0
    nr_isolated_file 0
    nr_shmem     491196
    nr_dirtied   492864604
    nr_written   339759696
    numa_hit     55865496981
    numa_miss    59136456
    numa_foreign 2044915359
    numa_interleave 35516
    numa_local   55865257923
    numa_other   59375514
    workingset_refault 792520
    workingset_activate 104322
    workingset_nodereclaim 0
    nr_anon_transparent_hugepages 155
    nr_free_cma  0
        protection: (0, 0, 0, 0)
  pagesets
    cpu: 0
              count: 157
              high:  186
              batch: 31
  vm stats threshold: 120
    cpu: 1
              count: 181
              high:  186
              batch: 31
  vm stats threshold: 120
...
...
...
...
    cpu: 38
              count: 158
              high:  186
              batch: 31
  vm stats threshold: 120
    cpu: 39
              count: 125
              high:  186
              batch: 31
  vm stats threshold: 120
  all_unreclaimable: 0
  start_pfn:         17301504
  inactive_ratio:    24
```

### 参考文章

* http://man7.org/linux/man-pages/man5/proc.5.html
