本文详细介绍了Linux的Radix树。


>  注意：本文分析中引用的代码来自于centos系统自带的内核：[kernel-3.10.0-862.9.1.el7](http://vault.centos.org/7.5.1804/updates/Source/SPackages/kernel-3.10.0-862.9.1.el7.src.rpm)

<!--more-->
### Radix Tree介绍 

Linux基数树（radix tree）是将`指针`与`long整数键值`相关联的机制，它存储有效率，并且可快速查询，用于指针与整数值的映射（如：IDR机制）、内存管理等。

Linux radix树最广泛的用途是用于内存管理，结构`address_space`通过`radix树`跟踪绑定到地址映射上的核心页，该`radix树允`许内存管理代码快速查找标识为`dirty`或`writeback`的页。`Linux radix树`的`API`函数在`lib/radix-tree.c`中实现。


### 基本数据结构

#### radix_tree_root

```c
/* root tags are stored in gfp_mask, shifted by __GFP_BITS_SHIFT */
struct radix_tree_root {
        RH_KABI_DEPRECATE(unsigned int, height)
        gfp_t                   gfp_mask;       //内存申请的标识
        struct radix_tree_node  __rcu *rnode;   //子节点指针
};

```
`radix_tree_root`用来表示树的根：

* `height`在这个版本中已经废弃了
* `gfp_mask`用于保存内存申请的标识
* `rnode`用于指向基数的结点，一个空的基数，该指针为NULL

#### radix_tree_node

```c
/*
 * The radix_tree_node structure is never embedded in other data structures.
 * As a result, there's no need to preserve the size.  Because the structure
 * is reachable via others, though, we need to preserve the original contents
 * for the kabi checker.
 */

struct radix_tree_node {
        RH_KABI_REPLACE2(       /* shift & offset replaces path */
                unsigned int    path,   /* Offset in parent & height from the bottom */
                unsigned char   shift,  /* Bits remaining in each slot */
                unsigned char   offset  /* Slot offset in parent */
        )
        unsigned int    count; //子节点个数
        union {
                struct {
                        /* Used when ascending tree */
                        struct radix_tree_node *parent; //父节点指针
                        /* For tree user */
                        void *private_data;
                };
                /* Used when freeing node */
                struct rcu_head rcu_head; //用于节点释放的RCU链表
        };
        /* For tree user */
        struct list_head private_list;
        void __rcu      *slots[RADIX_TREE_MAP_SIZE];// slots[64] //指向存储数据指针
        unsigned long   tags[RADIX_TREE_MAX_TAGS][RADIX_TREE_TAG_LONGS]; // tags[3][1]
};
```

`radix_tree_node`用于表示基数树的内部结点：

* `offset`： 表示该结点在其父结点的slots中的偏移值
* `shift`： 该node中的slots的指针中有多少位用于继续寻址，当node是最底层的叶子结点时，shift为0，每上一层，shift递增6
* `count`：表示该node的孩子的数量
* `parent`： 指向该node的父结点
* `slots`： 64个指针，每层可以有64个子节点
* `tags`： tags域用于记录该结点下面的子结点有没有相应的标志位,这是一个典型的用空间换时间的应用


### Radix Tree在linux下的图解

#### 初始化后的图示

当一个radix tree初始化后，其只有`radix_tree_root`结点，如下图：

![][1]

#### 插入0 和4的图示

当插入0和4时，树的高度增加1，如下图所示：

![][2]

#### 插入131的图示

当插入131时，高度需要再增加1，如下图所示：

![][3]

#### 插入4100的图示

当插入4100时，高度需要再增加1，如下图所示：

![][4]

### Linux API 介绍

#### 初始化

使用radix tree时，需要初始化，可以分为静态初始化和动态初始化两种方法：

静态初始化`RADIX_TREE`：

```c
RADIX_TREE(mytree, GFP_KERNEL);
```

动态初始化：`INIT_RADIX_TREE`

```c
struct radix_tree_root mytree;
INIT_RADIX_TREE(&mytree, GFP_KERNEL);
```

#### 插入条目

```c
int radix_tree_insert(struct radix_tree_root *root,
                        unsigned long index, void *entry)
```

函数`radix_tree_insert`插入条目`entry`到树`root`中，如果插入条目中内存分配错误，将返回错误`-ENOMEM`。该函数不能覆盖写正存在的条目。如果索引键值`index`已存在于树中，返回错误`-EEXIST`。插入操作成功返回0。

对于插入条目操作失败将引起严重问题的场合，下面的一对函数可避免插入操作失败：

```c
int radix_tree_preload(gfp_t gfp_mask);                                                                                                                       
void radix_tree_preload_end(void);
```

函数`radix_tree_preload`尝试用给定的`gfp_mask`分配足够的内存，保证下一个插入操作不会失败。在调用插入操作函数之前调用此函数，分配的结构将存放在`每CPU`变量中。函数`radix_tree_preload`操作成功后，将关闭内核抢占。因此，在插入操作完成之后，用户应调用函数`radix_tree_preload_end`打开内核抢占。


`radix_tree_preload`有如下连个变种：

```c
int radix_tree_maybe_preload(gfp_t gfp_mask);                                                                        
int radix_tree_maybe_preload_order(gfp_t gfp_mask, int order);  
```

#### 删除条目

函数`radix_tree_delete`删除与索引键值`index`相关的条目，如果删除条目在树中，返回该条目的指针，否则返回NULL。
函数`radix_tree_delete_item`删除与索引键值`index`相关的条目`item`，如果删除条目在树中，返回该条目的指针，否则返回NULL。

```c
void *radix_tree_delete(struct radix_tree_root *root, unsigned long index);
void *radix_tree_delete_item(struct radix_tree_root *root, unsigned long index, void *item);
```

#### 查询条目

```c
void *radix_tree_lookup(struct radix_tree_root *root, unsigned long index);
void **radix_tree_lookup_slot(struct radix_tree_root *root, unsigned long index);
```

* `radix_tree_lookup`在树中查找指定键值的条目，查找成功，返回该条目的指针，否则，返回NULL.
* `radix_tree_lookup_slot`返回指向slot的指针，该slot含有指向查找到条目的指针

```c
unsigned int radix_tree_gang_lookup(struct radix_tree_root *root,                                                                                             
                        void **results, unsigned long first_index,                                                   
                        unsigned int max_items);                                                                     
unsigned int radix_tree_gang_lookup_slot(struct radix_tree_root *root,                                               
                        void ***results, unsigned long *indices,                                                     
                        unsigned long first_index, unsigned int max_items); 

```
`radix_tree_gang_lookup`多键值查找，max_items为需要查找的item个数，results表示查询结果。查询时键值索引从first_index开始


#### 标签操作

```
void *radix_tree_tag_set(struct radix_tree_root *root,                                                               
                        unsigned long index, unsigned int tag);                                                      
void *radix_tree_tag_clear(struct radix_tree_root *root,                                                             
                        unsigned long index, unsigned int tag);                                                      
int radix_tree_tag_get(struct radix_tree_root *root,                                                                 
                        unsigned long index, unsigned int tag);  
int radix_tree_tagged(struct radix_tree_root *root, unsigned int tag);
```

* `radix_tree_tag_set`: 将键值index对应的条目设置标签tag，返回值为设置标签的条目
* `radix_tree_tag_clear`: 从键值index对应的条目清除标签tag，返回值为清除标签的条目
* `radix_tree_tag_get`: 检查键值index对应的条目tag是否设置。tag参数为0或者1
* `radix_tree_tagged`: 如果树root中有任何条目使用tag标签，返回键值

### 参考文章

* https://blog.csdn.net/xiaofeng_yan/article/details/78600190
* https://www.cnblogs.com/mingziday/p/3969269.html
* http://blog.csdn.net/joker0910/article/details/8250085

 [1]: ./radix-tree-init.svg  
 [2]: ./insert-0-and-4.svg           
 [3]: ./insert-0-and-4-and-131.svg   
 [4]: ./insert-0-and-4-and-131-and-4100.svg                                                                         
