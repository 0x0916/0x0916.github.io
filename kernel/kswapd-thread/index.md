`Linux` 内核在系统内存紧张时，会唤醒内核线程`kswapd`进行内存回收，从而释放掉一些不用的内存。本文将详细分析`kswapd`的工作流程。
<!--more-->

![](./pic.jpg "")

### 系统环境

* 发行版：`centos7.5`
* 内核版本：[3.10.0-862.14.4.el7.x86_64](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.14.4.el7.src.rpm)
* 处理器：`40core（Intel(R) Xeon(R) CPU E5-2630 v4 @ 2.20GHz）`
* 内存：`128GB`，两个`NUMA node`

### kswapd内核线程
  
`Linux`内核中有一个非常重要的内核线程`kswapd`，负责在内存不足的情况下回收页面，系统初始化时，会为每一个`NUMA`内存节点创建一个名为`kswapd%d`的内核线程：
  
```c
static int __init kswapd_init(void)
{
        int nid;

        swap_setup(); //初始化swap使用的bdi和page_cluster, page_cluser 一般为3
        for_each_node_state(nid, N_MEMORY)
                kswapd_run(nid); //对于每个有内存的node结点，创建一个kswpad%d的内核线程
        hotcpu_notifier(cpu_callback, 0);
        return 0;
}
module_init(kswapd_init)

/*
 * This kswapd start function will be called by init and node-hot-add.
 * On node-hot-add, kswapd will moved to proper cpus if cpus are hot-added.
 */ // 在启动时和热插拔时会执行该函数
int kswapd_run(int nid)
{
        pg_data_t *pgdat = NODE_DATA(nid);
        int ret = 0;

        if (pgdat->kswapd)
                return 0;
        // 为系统上每个numa 内存结点创建一个kswaped%d的内核线程,线程的task_struct保存到node对应的pg_data_t->kswpad成员中
        pgdat->kswapd = kthread_run(kswapd, pgdat, "kswapd%d", nid);
        if (IS_ERR(pgdat->kswapd)) {
                /* failure at boot is fatal */
                BUG_ON(system_state == SYSTEM_BOOTING);
                pr_err("Failed to start kswapd on node %d\n", nid);
                ret = PTR_ERR(pgdat->kswapd);
                pgdat->kswapd = NULL;
        }
        return ret;
}
```
  
在`NUMA`系统中，每一个`node`节点都有一个类型为`pg_data_t` 的数据结构描述物理内存布局，`kswapd`传递的参数就是这个`pg_data_t`数据结构。
 
```c
typedef struct pglist_data { 
	...
	wait_queue_head_t kswapd_wait;
	struct task_struct *kswapd; 
	
	int kswapd_max_order;
	enum zone_type classzone_idx;
	...
} pg_data_t;
 ```
 
和`kswapd`相关的参数有`kswapd_wait`、`kswapd`、`kswapd_max_order`和`classzone_idx`等。
 
* `kswapd_wait` 时一个等待队列，每个`pg_data_t`数据结构都有这样一个队列。它是在`free_area_init_core`函数中被初始化的；
* `kswapd`保存的是内核线程`kswapd%d`对应的`task_struct`结构体；
* `kswapd_max_order`和`classzone_idx`是作为参数传递给`kswapd`内核线程的，一般在页面分配路径上的唤醒函数`wakeup_kswapd`会给这两个参数赋值。

在分配内存的路径上，如果在低水位的情况下还无法成功分配内存，那么会通过`wakeup_kswapd()`函数唤醒`kswapd`内核线程来回收页面，以便释放一些内存。


```c?linenums
/*                                                                                                                                       
 * A zone is low on free memory, so wake its kswapd task to service it. 
 */ //当一个zone的空闲内存不足时，会唤醒kswpad内核线程 
void wakeup_kswapd(struct zone *zone, int order, enum zone_type classzone_idx)
{                                                                                                                                        
        pg_data_t *pgdat;
		
        if (!populated_zone(zone)) // 当zone中没有页面时，直接返回 
                return;                                                                                                                
        if (!cpuset_zone_allowed_hardwall(zone, GFP_KERNEL)) 
                return;                                                                                                                  
        pgdat = zone->zone_pgdat; //这里是通过pg_data_t数据结构传递数据的。
//传递的信息有两个：（1）kswapd_max_order 表示要回收内存的order，其不能小于分配内存的order    
// （2）classzone_idx 时计算的第一个合适分配内存的zone序号 
        if (pgdat->kswapd_max_order < order) {
                pgdat->kswapd_max_order = order;   
                pgdat->classzone_idx = min(pgdat->classzone_idx, classzone_idx);
        }                                                                                                                                
        if (!waitqueue_active(&pgdat->kswapd_wait)) 
                return;                                                                                                                  
        if (zone_watermark_ok_safe(zone, order, low_wmark_pages(zone), 0, 0)) //如果此时满足水位需求，则不进行唤醒  
                return;                                                                                                                  
                                                                                                                                         
        trace_mm_vmscan_wakeup_kswapd(pgdat->node_id, zone_idx(zone), order);  
        wake_up_interruptible(&pgdat->kswapd_wait); //唤醒操作                                                                           
} 
```

第`16-17`行给`kswapd_max_order`和`classzone_idx`赋值，其中`kswapd_max_order`不能小于`alloc_pages()`分配内存的`order`，`classzone_idx`是在`__alloc_pages_nodemask()`中计算第一个最合适分配内存的`zone`序号。 这两个参数会传递给`kswapd`内核线程中，`classzone_idx`是理解页面分配器和页面回收内核线程`kswapd`如何协同工作的一个关键点。

```c
struct page *
__alloc_pages_nodemask(gfp_t gfp_mask, unsigned int order,
		struct zonelist *zonelist, nodemask_t *nodemask) 
{
...
...
        /* The preferred zone is used for statistics later */                                                                            
        first_zones_zonelist(zonelist, high_zoneidx,                                                                                     
                                nodemask ? : &cpuset_current_mems_allowed,                                                               
                                &preferred_zone);  
...
...
                page = __alloc_pages_slowpath(gfp_mask, order,
                                zonelist, high_zoneidx, nodemask,
                                preferred_zone, migratetype);
...
...
}


static inline struct page *
__alloc_pages_slowpath(gfp_t gfp_mask, unsigned int order,
        struct zonelist *zonelist, enum zone_type high_zoneidx,
        nodemask_t *nodemask, struct zone *preferred_zone,
        int migratetype)
{
...
...
        if (!(gfp_mask & __GFP_NO_KSWAPD))
                wake_all_kswapds(order, zonelist, high_zoneidx, preferred_zone);
...
...
}

static void wake_all_kswapds(unsigned int order,
                             struct zonelist *zonelist,
                             enum zone_type high_zoneidx,
                             struct zone *preferred_zone)
{
        struct zoneref *z;
        struct zone *zone;

        for_each_zone_zonelist(zone, z, zonelist, high_zoneidx)
                wakeup_kswapd(zone, order, zone_idx(preferred_zone));
}
```



`kswapd` 内核线程的执行函数如下：


```c?linenums

/*
 * The background pageout daemon, started as a kernel thread
 * from the init process.
 *
 * This basically trickles out pages so that we have _some_
 * free memory available even if there is no other activity
 * that frees anything up. This is needed for things like routing
 * etc, where we otherwise might have all activity going on in
 * asynchronous contexts that cannot page things out.
 *
 * If there are applications that are active memory-allocators
 * (most normal use), this basically shouldn't matter.
 */ 
static int kswapd(void *p)
{
        unsigned long order, new_order;
        unsigned balanced_order;
        int classzone_idx, new_classzone_idx;
        int balanced_classzone_idx;
        pg_data_t *pgdat = (pg_data_t*)p;
        struct task_struct *tsk = current;
		
		...
		...

        order = new_order = 0;
        balanced_order = 0;
        classzone_idx = new_classzone_idx = pgdat->nr_zones - 1;
        balanced_classzone_idx = classzone_idx;
        for ( ; ; ) {
                bool ret;

                /*
                 * If the last balance_pgdat was unsuccessful it's unlikely a
                 * new request of a similar or harder type will succeed soon
                 * so consider going to sleep on the basis we reclaimed at
                 */
                if (balanced_classzone_idx >= new_classzone_idx &&
                                        balanced_order == new_order) {
                        new_order = pgdat->kswapd_max_order;
                        new_classzone_idx = pgdat->classzone_idx;
                        pgdat->kswapd_max_order =  0;
                        pgdat->classzone_idx = pgdat->nr_zones - 1;
                }

                if (order < new_order || classzone_idx > new_classzone_idx) {
                        /*
                         * Don't sleep if someone wants a larger 'order'
                         * allocation or has tigher zone constraints
                         */
                        order = new_order;
                        classzone_idx = new_classzone_idx;
                } else {
                        kswapd_try_to_sleep(pgdat, balanced_order, //启动时，在这里睡眠并让出CPU控制权
                                                balanced_classzone_idx);
                        order = pgdat->kswapd_max_order;
                        classzone_idx = pgdat->classzone_idx;
                        new_order = order;
                        new_classzone_idx = classzone_idx;
                        pgdat->kswapd_max_order = 0;
                        pgdat->classzone_idx = pgdat->nr_zones - 1;
                }

                ret = try_to_freeze();
                if (kthread_should_stop())
                        break;

                /*
                 * We can speed up thawing tasks if we don't call balance_pgdat
                 * after returning from the refrigerator
                 */
                if (!ret) {
                        trace_mm_vmscan_kswapd_wake(pgdat->node_id, order);
                        balanced_classzone_idx = classzone_idx;
                        balanced_order = balance_pgdat(pgdat, order, //关键函数，调用balance_pgdat来回收页面
                                                &balanced_classzone_idx);
                }
        }

        tsk->flags &= ~(PF_MEMALLOC | PF_SWAPWRITE | PF_KSWAPD);

		...
		...

        return 0;
}
```

函数的核心部分集中在`31-79`行代码的`for`循环中。这里有很多局部变量控制程序的走向。其中最重要的就是前面提到的`kswapd_max_order`和`classzone_idx`。

系统启动时，会在`kswapd_try_to_sleep()`函数中睡眠并且让出`CPU`控制权。当系统内存紧张时，一般在`alloc_pages()`在低水位中无法分配出内存，这时分配器会调用`wakeup_kswapd()`来唤醒`kswapd`内核线程，唤醒点在`kswapd_try_to_sleep()`中，`kswapd`内核线程被唤醒后，调用`balance_pgdat()`来回收页面。再我所分析的内核中调用逻辑如下：

```
alloc_pages()
	alloc_pages_current()
		__alloc_pages_nodemask()
			如果在低水位分配失败
			__alloc_pages_slowpath()
				wake_all_kswapds()
					wakeup_kswapd()
						wake_up(kswapd_wait)
										kswapd内核线程被唤醒
											->balance_pgdat()
```

### balance_pgdat函数

`balance_pgdat()`是回收页面的主函数，该函数比较长，首先看一下框架：

```c
static unsigned long balance_pgdat(pg_data_t *pgdat, int order,int *classzone_idx)
{
	do {
		//从高段zone向低端zone方向查找第一个处于不平衡状态的end_zone
		for (i = pgdat->nr_zones - 1; i >= 0; i--) {
			struct zone *zone = pgdat->node_zones + i;
			if (!zone_balanced(zone, order, 0, 0)) {
					end_zone = i;
					break;
			}
		}
		
		
		// 从低端zone开始进行页面回收,一直到end_zone
		for (i = 0; i <= end_zone; i++) {
			struct zone *zone = pgdat->node_zones + i;
			
			mem_cgroup_soft_limit_reclaim();
			kswapd_shrink_zone();
		}
	
	//不断加大扫描粒度，并且检查最低端的zone到classzone_idx的zone是否处于平衡状态
	}while(sc.priority >= 1 && !pgdat_balanced(pgdat, order, *classzone_idx));
}

```

* `zone_balanced()`函数用于判断一个内存`zone`是否处于平衡状态，返回`true`，表示处于平衡状态。
	* 如果一个内存`zone`中，其空闲页面处于`WMARK_HIGH`水位之上，则返回`TRUE`，说明该`zone`是平衡的。

* `pgdat_balanced()`函数判断一个内存节点上的物理页面是否处于平衡状态，返回`true`，表示处于平衡状态。
	* 对于`order`为`0`的情况，所有的`zone`都是平衡的
	* 对于`order`大于`0`的内存分配，需要统计从**最低端zone**到**classzone_idx zone**中所有处于平衡状态`zone`的页面数量（`balanced_pages`），当大于这个节点从**最低端zone**到**classzone_idx zone**中的所有管理的页面`managed_pages`的**25%**，那么就认为这个内存节点已经处于平衡状态。


### kswapd_shrink_zone函数

```c?linenums
static bool kswapd_shrink_zone(struct zone *zone,
                               int classzone_idx,
                               struct scan_control *sc,
                               unsigned long lru_pages,
                               unsigned long *nr_attempted)
{
        unsigned long nr_slab;
        int testorder = sc->order;
        unsigned long balance_gap;
        struct reclaim_state *reclaim_state = current->reclaim_state;
        struct shrink_control shrink = {
                .gfp_mask = sc->gfp_mask,
        };
        bool lowmem_pressure;

        /* Reclaim above the high watermark. *///计算一轮回收最多回收的页面个数sc->nr_to_reclaim
        sc->nr_to_reclaim = max(SWAP_CLUSTER_MAX, high_wmark_pages(zone)); //SWAP_CLUSTER_MAX=32

        /*
         * Kswapd reclaims only single pages with compaction enabled. Trying
         * too hard to reclaim until contiguous free pages have become
         * available can hurt performance by evicting too much useful data
         * from memory. Do not reclaim more than needed for compaction.
         */
        if (IS_ENABLED(CONFIG_COMPACTION) && sc->order &&
                        compaction_suitable(zone, sc->order) !=
                                COMPACT_SKIPPED)
                testorder = 0;

        /*
         * We put equal pressure on every zone, unless one zone has way too
         * many pages free already. The "too many pages" is defined as the
         * high wmark plus a "gap" where the gap is either the low
         * watermark or 1% of the zone, whichever is smaller.
         */ // balance_gap 一般值为低水位或者zone所管理的的页面的1%,取最小的那个值
        balance_gap = min(low_wmark_pages(zone),
                (zone->managed_pages + KSWAPD_ZONE_BALANCE_GAP_RATIO-1) /
                KSWAPD_ZONE_BALANCE_GAP_RATIO);

        /*
         * If there is no low memory pressure or the zone is balanced then no
         * reclaim is necessary
         */ //如果处于平衡状态，就不需要进行回收了
        lowmem_pressure = (buffer_heads_over_limit && is_highmem(zone));
        if (!lowmem_pressure && zone_balanced(zone, testorder,
                                                balance_gap, classzone_idx))
                return true;

        shrink_zone(zone, sc); //核心函数

        reclaim_state->reclaimed_slab = 0;
        nr_slab = shrink_slab(&shrink, sc->nr_scanned, lru_pages); //调用内存管理系统的shrinker接口,很多子系统会注册shrinker接口来回收内存
        sc->nr_reclaimed += reclaim_state->reclaimed_slab;

        /* Account for the number of pages attempted to reclaim */
        *nr_attempted += sc->nr_to_reclaim;

        if (nr_slab == 0 && !zone_reclaimable(zone)) // 整整扫描了6倍的可回收页面并且,没有回收到slab对象，则表示该zone不可回收
                zone->all_unreclaimable = 1;

        zone_clear_flag(zone, ZONE_WRITEBACK);

        /*
         * If a zone reaches its high watermark, consider it to be no longer
         * congested. It's possible there are dirty pages backed by congested
         * BDIs but as pressure is relieved, speculatively avoid congestion
         * waits.
         */ //如果zone已经处于平衡状态，则不考虑block层的堵塞问题，即使还有一些页面处于回写状态也是可以控制的，清除ZONE_CONGESTED标记
        if (!zone->all_unreclaimable &&
            zone_balanced(zone, testorder, 0, classzone_idx)) {
                zone_clear_flag(zone, ZONE_CONGESTED);
                zone_clear_flag(zone, ZONE_TAIL_LRU_DIRTY);
        }
        //如果扫描的页面个数大于等于扫描目标的话，表示扫描了足够的页面，则返回true。
        //扫描足够多的页面，也可能一无所获。
        //当zone处于平衡状态时也会返回true，返回true只会影响balance_pgdat函数的扫描粒度
        return sc->nr_scanned >= sc->nr_to_reclaim;
}
```

* 第`17`行代码计算一轮扫描最多回收的页面个数。`SWAP_CLUSTER_MAX`宏定义为`32`个页面，`high_wmark_pages()`宏计算需要最多回收多少个页面才能达到`WMARK_HIGH`水位，这里比较两者，去其最大值。

* 第`36`行代码，`balance_gap`相当于再判断`zone`是否处于平衡状态时增加了一些难度，原来只要判断空闲页面是否超过了高水位`WMARK_HIGH`即可，现在需要判断是否超过了（高水位`WMARK_HIGH+balance_gap`）。`balance_gap`的值比较小，一般取低水位或者`zone`管理页面的1%。

* 在调用`shrink_zone`函数前，需要判断当前`zone`的页面是否已经处于平衡状态，即当前水位是否已经高于`WMARK_HIGH+balance_gap`。如果已经处于平衡状态，直接返回即可。

* 第`49`行代码，`shrink_zone`函数去尝试回收`zone`页面，它是`kswapd`内核线程的核心函数。后面会继续介绍这个函数。

* 第`52`行代码，`shrink_slab`函数会调用内存管理系统中的`shrinker`接口，很多系统都会注册`shrinker`接口来回收内存。

* 第`69-73`行代码，回收完内存后，继续判断当前`zone`的页面是否已经处于平衡状态

如果扫描的页面大于等于扫描目标的话，表示扫描了足够的页面，则返回`true`，扫描了足够多的页面，也可能一无所获。返回`true`只会影响`balance_pgdat`函数的扫描粒度。

### shrink_zone

```c?linenums
//用于扫描zone中所有可回收的页面
static void shrink_zone(struct zone *zone, struct scan_control *sc)
{
        unsigned long nr_reclaimed, nr_scanned;

        do { //外循环
                struct mem_cgroup *root = sc->target_mem_cgroup;
                struct mem_cgroup_reclaim_cookie reclaim = {
                        .zone = zone,
                        .priority = sc->priority,
                };
                struct mem_cgroup *memcg;

                nr_reclaimed = sc->nr_reclaimed;
                nr_scanned = sc->nr_scanned;
                //root为null时，memcg返回的是跟memcg
                memcg = mem_cgroup_iter(root, NULL, &reclaim);
                do {//变量所有mem_cgroup在该zone上的lruvec，进行内存页面回收
                        struct lruvec *lruvec;

                        if (mem_cgroup_low(root, memcg)) {
                                if (!sc->memcg_low_reclaim) {
                                        sc->memcg_low_skipped = 1;
                                        continue;
                                }
                        }

                        lruvec = mem_cgroup_zone_lruvec(zone, memcg);

                        shrink_lruvec(lruvec, sc); //关键函数

                        /*
                         * Direct reclaim and kswapd have to scan all memory
                         * cgroups to fulfill the overall scan target for the
                         * zone.
                         *
                         * Limit reclaim, on the other hand, only cares about
                         * nr_to_reclaim pages to be reclaimed and it will
                         * retry with decreasing priority if one round over the
                         * whole hierarchy is not sufficient.
                         */
                        if (!global_reclaim(sc) &&
                                        sc->nr_reclaimed >= sc->nr_to_reclaim) {
                                mem_cgroup_iter_break(root, memcg);
                                break;
                        }
                } while ((memcg = mem_cgroup_iter(root, memcg, &reclaim)));

                vmpressure(sc->gfp_mask, sc->target_mem_cgroup,
                           sc->nr_scanned - nr_scanned,
                           sc->nr_reclaimed - nr_reclaimed);

        } while (should_continue_reclaim(zone, sc->nr_reclaimed - nr_reclaimed,
                                         sc->nr_scanned - nr_scanned, sc));
}
```

`shrink_zone`函数用于扫描`zone`中所有可回收的页面，参数`zone`表示即将要扫描的`zone`，`sc`表示扫描控制参数。

* `6-53`行代码是大循环，判断添加是`should_continue_reclaim`函数，通过一轮的回收页面的数量和扫描页面的数量来判断是否要需要继续扫描。`should_continue_reclaim`的判断标准为：
	* 已经回收的页面数小于`2 << sc->order`，且不活跃页面数大于`2 << sc->order`则继续回收页面。

* 第`18-47`行代码是内部的`while`循环，遍历所有的`memory cgroup`，`28`行获取`memory cgroup`对应的`LRU`链表(`lruvec`)。

* 第`30`行调用`shrink_lruvec`来进行内存的回收，它是扫描`LRU`链表的核心函数，后面会专门的去分析该函数。

* `shrink_lruvec`和`shrink_slab`会有专门的文章去分析。
