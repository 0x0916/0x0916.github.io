
本文详细介绍了Linux的XArray数据结构。

>  注意：本文分析中引用的代码来自于：[linux-5.1.21.tar.xz](https://kernel.org/pub/linux/kernel/v5.x/linux-5.1.21.tar.xz)

<!--more-->

### Xarray的由来

Matthew Wilcox认为内核的基数树的API设计不合理，比如

* （1）“树”这个术语就很有迷惑性。基数树跟传统的，教科书上那种树，并不是很像。举例来说，树上的增加entry的操作，一直都被称为“插入”。但对基数树而言，“插入”并不是字面上发生的事情，尤其是当key已经存在的时候。基数树也支持“异常entry“，光是这个名字，就让用户听着不敢用了。

* （2）基数树还要求用户自己处理锁。

Wilcox决定改良接口。基数树本身不变，它本身没什么问题。改变的是接口，现在接口暗示用户，把它当做数组来用，而不是当做树来用。因为基数树看起来就像是一个自动增长的数组：一个用unsigned long来索引的指针数组。这种视图，更好地描述了基数树的用途。

* （1）XArray默认自己处理了锁，简化了使用
* （2）基数树的“预加载”机制允许用户获取锁之前先预先分配内存，这个机制在XArray中被取消了，它太复杂又没有太多实际价值。
* （3）XArray API被分为两部分，普通API和高级API。后者给用户更多可控性，比如用户可以显式管理锁。API可以用于不同的场景，满足不同的需求。比如Page Cache就可以用XArray。普通API完全在高级API的基础上实现，所以普通API也是高级API的使用范例。

另外：Xarray的全称为：eXtensible Arrays

### XArray 基本数据结构

XArray主要包括结构体struct xarray和结构体struct xa_node.

#### xarray
```c
/**
 * struct xarray - The anchor of the XArray.
 * @xa_lock: Lock that protects the contents of the XArray.
 *
 * To use the xarray, define it statically or embed it in your data structure.
 * It is a very small data structure, so it does not usually make sense to
 * allocate it separately and keep a pointer to it in your data structure.
 *
 * You may use the xa_lock to protect your own data structures as well.
 */
/*
 * If all of the entries in the array are NULL, @xa_head is a NULL pointer.
 * If the only non-NULL entry in the array is at index 0, @xa_head is that
 * entry.  If any other entry in the array is non-NULL, @xa_head points
 * to an @xa_node.
 */
struct xarray {
	spinlock_t	xa_lock;
/* private: The rest of the data structure is not to be used directly. */
	gfp_t		xa_flags;
	void __rcu *	xa_head;
};
```
成员说明：

* xa_lock: 用于包含XArray内容的锁。
* xa_head：用于顶级的xa_node节点。

#### xa_node
```c
/*
 * @count is the count of every non-NULL element in the ->slots array
 * whether that is a value entry, a retry entry, a user pointer,
 * a sibling entry or a pointer to the next level of the tree.
 * @nr_values is the count of every element in ->slots which is
 * either a value entry or a sibling of a value entry.
 */
struct xa_node {
	unsigned char	shift;		/* Bits remaining in each slot */
	unsigned char	offset;		/* Slot offset in parent */
	unsigned char	count;		/* Total entry count */
	unsigned char	nr_values;	/* Value entry count */
	struct xa_node __rcu *parent;	/* NULL at top of tree */
	struct xarray	*array;		/* The array we belong to */
	union {
		struct list_head private_list;	/* For tree user */
		struct rcu_head	rcu_head;	/* Used when freeing node */
	};
	void __rcu	*slots[XA_CHUNK_SIZE];
	union {
		unsigned long	tags[XA_MAX_MARKS][XA_MARK_LONGS];
		unsigned long	marks[XA_MAX_MARKS][XA_MARK_LONGS];
	};
};
```
成员说明

* （1）shift成员用于指定当前xa_node的slots数组中成员的单位，当shift为0时，说明当前xa_node的slots数组中成员为叶子节点，当shift为6时，说明当前xa_node的slots数组中成员指向的xa_node可以最多包含2^6(即64）个节点，
* （2）offset成员表示该xa_node在父节点的slots数组中的偏移。（这里要注意，如果xa_node在父节点为NULL，offset是任意的值，因为没有被初始化）
* （3）count成员表示该xa_node有多少个slots已经被使用。
* （4）nr_values成员表示该xa_node有多少个slots存储的Value Entry。
* （5）parent成员指向该xa_node的父节点
* （6）array成员指向该xa_node所属的xarray
* （7）slots是个指针数组，该数组既可以存储下一级的节点, 也可以用于存储即将插入的对象指针

#### 理解一下slots中存放的Entry的规则

slots中存储的entry中的低两位决定了Xarray如何解析其内容。

1. 低2位是00时，它是一个Pointer Entry
2. 低2位是10时，它是一个Internal Entry，一般指向下一级的xa_node.但是有些Internal Entry有特别的含义，比如：
 * 0-62: Sibling entries
 * 256: Zero entry
 * 257: Retry entry
3. 低2为是x1时，它是一个Value Entry，或者tagged pointer

### Xarray在linux下的图解

#### 初始化后的图示

当一个XArray初始化后，其只有`struct xrray`结点，如下图：
<center>
![][1]
</center>

#### 插入0后的图示

当插入0时，仍然只有xarray一个结构，如下图所示：

<center>
![][2]
</center>

#### 插入0 和4的图示

当插入0和4时，树的高度增加1，如下图所示：

<center>
![][3]
</center>

#### 插入131的图示

当插入131时，高度需要再增加1，如下图所示：

<center>
![][4]
</center>

#### 插入4100的图示

当插入4100时，高度需要再增加1，如下图所示：

<center>
![][5]
</center>

### 普通 API
（1）定义一个XArray数组：
```
DEFINE_XARRAY(array_name);
/* or */
struct xarray array;
xa_init(&array);
```

（2）在XArray里存放一个值：
```
void *xa_store(struct xarray *xa, unsigned long index, void *entry, gfp_t gfp);
```
这个函数会把参数给出的entry，放到请求的index这个地方。如果要XArray需要分配内存，会使用给定的gfp来分配。如果成功，返回值是之前存放在index的值。删除一个entry可以通过在这里存放NULL来实现，或者调用
```
void *xa_erase(struct xarray *xa, unsigned long index);
```

（3）xa_store的变体：
* xa_insert用于存放但不覆盖现有的entry
* 另一个变体：xa_cmpxchg，只有当存的值和old参数匹配上时，才会将entry存在index处。
```
static inline int __must_check xa_insert(struct xarray *xa,
		unsigned long index, void *entry, gfp_t gfp);
static inline void *xa_cmpxchg(struct xarray *xa, unsigned long index,
			void *old, void *entry, gfp_t gfp);
```

（4）用xa_load()从XArray里取出一个值：
```
void *xa_load(struct xarray *xa, unsigned long index);
```
返回值是存放在index处的值。XArray里，空entry和存入NULL的entry是等价的。因此xa_load不会对空entry有特殊的处理。

（5）非空entry上还可以设置最多3个比特的标签，标签管理函数：
```
bool xa_get_mark(struct xarray *xa, unsigned long index, xa_mark_t mark);
void xa_set_mark(struct xarray *xa, unsigned long index, xa_mark_t mark);
void xa_clear_mark(struct xarray *xa, unsigned long index, xa_mark_t mark);
```

mark的值是XA_MARK_0, XA_MARK_1, XA_MARK_2三者之一。
xa_set_mark用于在index处的entry上设置标签 xa_clear_mark用于清除标签 xa_get_mark用于返回index处的entry的标签

（6）XArray是很稀疏的，因此一个普遍的准则是，不要进行低效的遍历查找非空项。要查找多个非空项，应该使用这个宏：
```
xa_for_each(xa, entry, index, max, filter) {
    /* Process "entry" */
}
```

在进入循环之前，需要把index设为遍历的起点，max设为遍历的最大index，filter指定需要过滤的mark。
循环执行时，index会被设为当前匹配到的entry。可以在循环里修改index，来改变迭代过程。修改XArray自身也是允许的。

（7）删除一个Xarray中所有的Entry
```
void xa_destroy(struct xarray *xa);
```

还有其他很多操作XArray的普通API。特殊情况下还可以使用高级API。
其它普通API包括：
```
xa_for_each_marked()
xa_marked()
xa_extract()
xa_for_each_start()
xa_for_each_range()
xa_find()
xa_find_after() 
xa_empty() 
xa_reserve() 
xa_release()
xa_err()
xa_is_err() 
DEFINE_XARRAY_ALLOC() 
xa_init_flags()
xa_alloc() 
xa_alloc_bh()
xa_alloc_irq()
xa_alloc_cyclic().
DEFINE_XARRAY_ALLOC1()
```
### 高级 API

高级API我们留在下节文章分享。


### 参考文章

* https://mp.weixin.qq.com/s/ZpFACWDEMI5d7ADzaa3BJw
* http://sourcelink.top/2019/09/26/linux-kernel-radix-tree-analysis/
* https://kernel.taobao.org/2018/05/The-XArray-data-structure/ 

 [1]: ./xarray-init.svg  
 [2]: ./insert-0.svg           
 [3]: ./insert-0-and-4.svg           
 [4]: ./insert-0-and-4-and-131.svg   
 [5]: ./insert-0-and-4-and-131-and-4100.svg      
