内核里很多模块都需要对一些事件进行统计，有一个叫做`percpu_counter`的基础设施，来完成该任务。本文简单介绍了其用法和内核中的实现。

>  注意：本文中引用的内核代码版本为`v4.4.128`。

<!--more-->

### 对于单核

其数据结构定义{{< lts tag="4.4.128" file="include/linux/percpu_counter.h" line="94">}}如下：

```c
struct percpu_counter {
        s64 count;
};
```

对于单核来说，比较简单，其操作主要是对计数器`count`进行操作。

### 对于多核

其数据结构定义{{< lts tag="4.4.128" file="include/linux/percpu_counter.h" line="19">}}如下：

```c
struct percpu_counter {
        raw_spinlock_t lock;
        s64 count;
#ifdef CONFIG_HOTPLUG_CPU
        struct list_head list;  /* All percpu_counters are on a list */
#endif
        s32 __percpu *counters;
};
```

相比较于单核，多核稍微复杂一些，其为了提高效率，引用了`__percpu`变量`counters`，另外为了考虑`cpu`的热插拔，其有引入了字段`list`，用来将所有的`percpu_counter`链接到一起。


### API接口

其接口如下：

* percpu_counter_init
* percpu_counter_set
* percpu_counter_destroy
* percpu_counter_inc
* percpu_counter_dec
* percpu_counter_add
* percpu_counter_sub
* percpu_counter_sum
* percpu_counter_sum_positive
* percpu_counter_read
* percpu_counter_read_positive
* percpu_counter_compare
* percpu_counter_initialized

对结构体`percpu_counter`操作时，如果只访问`s32 __percpu *counters;`则不需要加锁，如果访问`s64 count;`则需要加锁，防止竞争。

内核为了尽可能少的加锁，使用了一些编程技巧，对计数器增加或者减少计数时，大多数情况下不用加锁，只修改每`cpu`变量`s32 __percpu *counters;`，当计数超过一个范围时`[-batch, batch]`,则进行加锁，将每cpu变量`s32 __percpu *counters;`中的计数累计到`s64 count;`中。

* `percpu_counter_init`初始化`percpu_counter`中成员`count`特定的值，并分配每`cpu`变量`counters`;

* `percpu_counter_set` 设置`percpu_counter`中成员`count`特定的值，并修改每cpu变量`counters`的值为`0`；

* `percpu_counter_destroy` 释放`percpu_counter_init`中分配的每`cpu`变量`counters`;

* `percpu_counter_inc/percpu_counter_dec/percpu_counter_add/percpu_counter_sub`四个方法主要对计数器进行操作，修改其值。修改过程中，就是用上面提到的技巧，尽可能少的加锁。{{< lts tag="4.4.128" file="lib/percpu_counter.c" line="75"  >}}

```c
void __percpu_counter_add(struct percpu_counter *fbc, s64 amount, s32 batch)
{
        s64 count;

        preempt_disable();
        count = __this_cpu_read(*fbc->counters) + amount;
        if (count >= batch || count <= -batch) {
                unsigned long flags;
                raw_spin_lock_irqsave(&fbc->lock, flags);
                fbc->count += count;
                __this_cpu_sub(*fbc->counters, count - amount); // 清零
                raw_spin_unlock_irqrestore(&fbc->lock, flags);
        } else {
                this_cpu_add(*fbc->counters, amount);
        }
        preempt_enable();
}
EXPORT_SYMBOL(__percpu_counter_add);
```

> 技巧：这里特别注意`__this_cpu_sub(*fbc->counters, count - amount)`，乍一看，这里就是清零，为什么要写这么复杂呢？因为在计算`count`值到该行代码之间，该`cpu`对应的`percpu_counter`计数可能增加，所以只有这样写才是最正确的。

* `percpu_counter_sum_positive/percpu_counter_sum`计算该计数器的数值（精确值），需要加锁，区别是`percpu_counter_sum_positive`返回值最小为0；;

* `percpu_counter_read/percpu_counter_read_positive`读出该计数器的粗略的数值，不需要加锁, 区别是`percpu_counter_read_positive`返回值最小为0；

* `percpu_counter_compare` 用来比较计数器的数值和给定的数值的大小，这里也用到了上面提到的编程技巧，尽可能少的加锁。先通过`percpu_counter_read`计算计数器的粗略值，此时不需要加锁，如果可以判断结果的话，就直接返回；如果判断不了结果的话，就得通过`percpu_counter_sum`来进一步加锁计算精确的计数值来进行比较，代码可参考：{{< lts tag="4.4.128" file="lib/percpu_counter.c" line="200">}}

```c
/*                                                                                                                                             
 * Compare counter against given value.
 * Return 1 if greater, 0 if equal and -1 if less
 */
int __percpu_counter_compare(struct percpu_counter *fbc, s64 rhs, s32 batch)
{
        s64     count;

        count = percpu_counter_read(fbc);       // 读出大概值
        /* Check to see if rough count will be sufficient for comparison */
        if (abs(count - rhs) > (batch * num_online_cpus())) {
                if (count > rhs)
                        return 1;
                else
                        return -1;
        }
        /* Need to use precise count */
        count = percpu_counter_sum(fbc);
        if (count > rhs)
                return 1;
        else if (count < rhs)
                return -1;
        else
                return 0;
}
EXPORT_SYMBOL(__percpu_counter_compare);
```

### batch大小

该基础设施全名叫`Fast batching percpu counters`，其能够减少加锁，提高效率，是由于选定了一个`batch`值，只有每`cpu`变量中计数器的值超过该范围后，才会加锁进行处理。

> 注意：只有在多核的系统上，才需要batch这个机制。

那么该值如何选定呢？

内核中`batch`的大小为`cpu`个数的**两倍**，但最小值为`32`, 具体逻辑请查阅如下代码{{< lts tag="4.4.128" file="lib/percpu_counter.c" line="158" >}}:

```c
int percpu_counter_batch __read_mostly = 32; // 最小值为32
EXPORT_SYMBOL(percpu_counter_batch);
                                                                                                                                               
static void compute_batch_value(void)
{
        int nr = num_online_cpus();

        percpu_counter_batch = max(32, nr*2);
}
```

**当然用户可以自己指定`batch`的大小**，比如`BDI`中

```
// nr_cpu_ids    result
//  1            8
//  2            16
//  4            24
//  8            32
// 16            40
// 32            48
// 40            48
#define BDI_STAT_BATCH (8*(1+ilog2(nr_cpu_ids))) 


static inline void __add_bdi_stat(struct backing_dev_info *bdi,
                enum bdi_stat_item item, s64 amount)
{
        __percpu_counter_add(&bdi->bdi_stat[item], amount, BDI_STAT_BATCH);
}
```


那该值为什么选定` (8*(1+ilog2(nr_cpu_ids))) `? 


内核中使用到`ilog2(nr_cpu_ids)`的地方如下：

```bash
~/linux (master) # grep -nr --color "ilog2(nr_cpu_ids"  ./
./fs/btrfs/disk-io.c:2596:                                      (1 + ilog2(nr_cpu_ids));
./fs/btrfs/disk-io.c:2851:      fs_info->dirty_metadata_batch = nodesize * (1 + ilog2(nr_cpu_ids));
./fs/btrfs/disk-io.c:2852:      fs_info->delalloc_batch = sectorsize * 512 * (1 + ilog2(nr_cpu_ids));
./include/linux/backing-dev-defs.h:45:#define WB_STAT_BATCH (8*(1+ilog2(nr_cpu_ids)))
./lib/flex_proportions.c:170:#define PROP_BATCH (8*(1+ilog2(nr_cpu_ids)))
./net/ipv4/udp.c:2855:  udp_busylocks_log = ilog2(nr_cpu_ids) + 4;
```

对于`#define WB_STAT_BATCH (8*(1+ilog2(nr_cpu_ids)))` , 我们可以得到`CPU`个数和结果直接的关系如下：

```
// nr_cpu_ids    result            比较时的误差范围
//  1            8			8
//  2            16			32
//  4            24			96
//  8            32			256
// 16            40                    	640
// 32            48                 	1536
// 40            48 			1920
// 64            56                    	3584
```

从上面的列表可以看出：

* `cpu`个数为`1`时，结果为`8`
* 此后如果`cpu`个数翻倍的话，结果递增`8`


### hotplug


对于支持`cpu热插拔`的系统，内核定义了静态的变量`percpu_counters`，将所有的`percpu_count`在链接到一起。

```c
#ifdef CONFIG_HOTPLUG_CPU
static LIST_HEAD(percpu_counters);	//所有的percpu_count在一个全局链表上
static DEFINE_SPINLOCK(percpu_counters_lock);
#endif
```

`percpu_counters_lock`自旋锁用来保护链表`percpu_counters`。

在cpu下线时，需要完成以下动作：

* 因为`batch`的大小跟`cpu`个数有关，所以要重新计算一下`batch`的大小。
* 将要下线`cpu`对应的计数器添加到总的计数中，并清零该`cpu`对应的每`cpu`变量的值。

详细的逻辑，请参考代码{{< lts tag="4.4.128" file="lib/percpu_counters.c" line="168" >}}
 
我的虚拟机器上，一共有`379`多个`percpu_count`。

