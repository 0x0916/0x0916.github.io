
`flex proportions`基础设施的作用是：根据不同类型的事件，计算其所占的比例部分。

> 注意，本文中的代码是基于稳定版本的内核`v4.4.128`。

<!--more-->

其数学公式如下：

$$ p\_j=\frac{\sum_{i>=0} \frac{x\_{i,j}}{2^{i+1}}}{\sum\_{i>=0} \frac{x\_i}{2^{i+1}}} $$

其中 `j`代表事件类型，$p\_j$为j类型的事件所占总体的比例。$x_{i,j}$为`j`类型的事件，在第`i`周期的计数，$x_i$ 为第`i`周期内各种类型的事件总数。


所以，有如下的等式：

$$ \sum\_{j>0} p\_{j} = 1 $$


该算法可以简单的通过维护分母来计算。假设`d`表示总事件的计数，$n_j$代表`j`类型事件的计数，当一个`j`类型事件发生时，我们只需要做如下操作：

$$ n_j=n_j+1;d=d+1 $$

当新的统计周期被声明时，执行如下操作即可

```c
d /= 2;
for_each j
	n_j /= 2;
```

为了避免循环计算每种类型事件的技术，这里的算法进行了优化，只有当询问该类型事件所占的比例，或者该类型事件发生时，才进行计算。
## 数据结构

### fprop_global

用于描述全局事件计数：

{{< lts "4.4.128" "include/linux/flex_proportions.h" "24">}}
```c
/*
 * ---- Global proportion definitions ----
 */
struct fprop_global {
        /* Number of events in the current period */
        struct percpu_counter events;
        /* Current period */
        unsigned int period;
        /* Synchronization with period transitions */
        seqcount_t sequence;
};
```


### fprop_local_single

用于描述每种类型的事件计数：

{{< lts "4.4.128" "include/linux/flex_proportions.h" "40">}}
```c
/*
 *  ---- SINGLE ----
 */
struct fprop_local_single {
        /* the local events counter */
        unsigned long events;
        /* Period in which we last updated events */
        unsigned int period;
        raw_spinlock_t lock;    /* Protect period and numerator */
};

```
### fprop_local_percpu

用于描述每种类型的事件计数，不过其计数使用的`percpu_counter `。

{{< lts "4.4.128" "include/linux/flex_proportions.h" "72">}}
```c
/*
 * ---- PERCPU ----
 */
struct fprop_local_percpu {
        /* the local events counter */
        struct percpu_counter events;
        /* Period in which we last updated events */
        unsigned int period;
        raw_spinlock_t lock;    /* Protect period and numerator */
};
```

##  编程接口

以下函数所在的文件为：{{< lts "4.4.128" "include/linux/flex_proportions.h">}}和{{< lts "4.4.128" "lib/flex_proportions.c" >}}。

### global

#### fprop_global_init

该函数完成以下任务：

* 初始化`period`为`0`
* 分配用于全局计数的`percpu_counter`变量`events`，并初始化计数为`1`
* 初始化顺序锁`sequence`

#### fprop_global_destroy

该函数用于释放`fprop_global_init`分配的`percpu_counter`变量`events`。

#### fprop_new_period

该函数用于增加周期`period`，并根据`period`来调整`events`的值。同时该函数使用顺序锁`sequence`保证了不会并发修改`period`和`events`的值。


### local_single

#### fprop_local_init_single

该函数完成以下工作：

* 初始化`period`为`0`
* 初始化`events`为`0`
* 初始化自旋锁`lock`

#### fprop_local_destroy_single

该函数为空

#### __fprop_inc_single

该函数将某种类型的事件计数和全局计数都递增1，同时也根据需要调整特定事件的计数`events`和周期`period`。当然调整过程需要使用自旋锁进行保护，保证其不会并发的被修改。

#### fprop_inc_single

用于在关闭本地中断的情况下，调用函数`__fprop_inc_single`。

#### fprop_fraction_single

该函数用于计算某种特定事件在整体事件中所占的比例，其结果通过函数参数`numerator`和`denominator`返回，分别代表分子和分母。

* 分子返回特定类型事件的计数
* 分母返回所有事件的计数
* 同时做了修正，保证分子除以分母的结果永远保证在`0`和`1`之间。


### local_percpu

#### fprop_local_init_percpu

该函数完成以下工作:

* 初始化特定类型事件的`period`为`0`
* 分配用于计数特定类型事件的`percpu_counter`变量`events`，并初始化为0
* 初始化自旋锁`lock`

#### fprop_local_destroy_percpu

释放由`fprop_local_init_percpu`分配的`percpu_counter`变量`events`


#### __fprop_inc_percpu

该函数将某种类型的事件计数和全局计数都递增`1`，同时也根据需要调整特定事件的计数`events`和周期`period`。当然调整过程需要使用自旋锁进行保护，保证其不会并发的被修改。唯一跟`__fprop_inc_single`不同的是计数使用的是`percpu_counter`。

#### fprop_fraction_percpu

跟`fprop_fraction_single`类似，用于计算某种特定事件在整体事件中所占的比例，只不过计数使用的`percpu_counter`。

#### fprop_inc_percpu

用于在关闭本地中断的情况下，调用函数 `__fprop_inc_percpu`。

#### __fprop_inc_percpu_max

该函数跟 `__fprop_inc_percpu`类似，唯一不同的时，可以确保特定事件计数所占的比例不会超过某个指定的比例。

## 内核中的用途

TODO
