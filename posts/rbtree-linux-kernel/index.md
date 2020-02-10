

本文介绍了红黑树在linux kernel中实现，使用的内核版本为：[centos 3.10.0-693.11.6][1]
  
<!--more-->
 
## 内核中的实现
  
### 源码位置
  内核中关于红黑树的文件如下：
  
  ```
 include/linux/rbtree_augmented.h
 include/linux/rbtree.h
 lib/rbtree.c 
 lib/rbtree_test.c 
 Documentation/rbtree.txt
  ```
  
### rb_node

先说说红黑树的基本数据结构吧：

```c
//本结构体四字节对齐，因而其地址中低位两个bit永远是0
//内核中用其中一个空闲的位来存储颜色信息
//__rb_parent_color成员实际上包含了父节点指针和自己的颜色信息
struct rb_node {
        unsigned long  __rb_parent_color; //保存父节点的指针值（父节点的地址）同时保存节点的color
        struct rb_node *rb_right;
        struct rb_node *rb_left;
} __attribute__((aligned(sizeof(long))));
```

`rb_node`结构体描述了红黑树中的一个结点，但在`linux`的实现中没有`key`域，这是`linux`数据结构的一大特色，就是结构不包括数据，而是由数据和基本结构被包括在同一个`struct`中，就像`list_head`中没有`data`域，需要用链表的`struct`中要包含`list_head`域一样。（由结构体获取数据信息是通过`container_of`这个宏来实现的，它利用了一些编译器的特性，有兴趣的可以参考`Linux的链表`源码。）

`rb_node`结构体，被一个`__attribute__((aligned(sizeof(long))))`所包装(非常重要，技巧就在这!)，
`__attribute__((aligned(sizeof(long))))`的意思是把结构体的地址按`sizeof(long)`对齐，对于`32`位机,`sizeof(long)`为`4`(即结构体内的数据类型的地址为4的倍数) ,对于`64`位机，`sizeof(long)`为`8`(即结构体内的数据类型的地址为8的倍数)。


所以以4（或8）为倍数的地址以二进制表示的特点是：以4为倍数(字节对齐)的地址（32位机器）最后两位肯定为零(看好了是存储变量的地址，而不是变量)，对于**64位机器是后三位肯定为零**。

对于红黑树中每一个节点，都需要标记一个颜色(要么是红、要么是黑)，而这里的技巧就在`__attribute__((aligned(sizeof(long))))`,因为红黑树的每个节点都用`rb_node`结构来表示，利用字节对齐技巧，任何`rb_node`结构体的地址的**低两位肯定都是零**，与其空着不用，还不如用它们表示颜色，反正颜色就两种，其实一位就已经够了。`unsigned long rb_parent_color`变量有两个作用（见名知义）：

* 存储父节点的地址
* 用后2位，标识此节点的color

### rb_parent_color 相关的宏
  
  
  `rb_parent_color` 成员保存了上提到的两个重要的信息，`include/linux/rbtree_augmented.h`和`include/linux/rbtree.h`有些与其相关的宏：
  
```c
 //获得父结点的地址
#define rb_parent(r)   ((struct rb_node *)((r)->__rb_parent_color & ~3))
#define __rb_parent(pc)    ((struct rb_node *)(pc & ~3))

// 判断结点的颜色
#define __rb_color(pc)     ((pc) & 1)
#define __rb_is_black(pc)  __rb_color(pc)
#define __rb_is_red(pc)    (!__rb_color(pc))
#define rb_color(rb)       __rb_color((rb)->__rb_parent_color)
#define rb_is_red(rb)      __rb_is_red((rb)->__rb_parent_color)
#define rb_is_black(rb)    __rb_is_black((rb)->__rb_parent_color)

// 设置结点的父结点
static inline void rb_set_parent(struct rb_node *rb, struct rb_node *p) 
{
        rb->__rb_parent_color = rb_color(rb) | (unsigned long)p;
}

// 设置结点的父结点和颜色
static inline void rb_set_parent_color(struct rb_node *rb,
                                       struct rb_node *p, int color)
{
        rb->__rb_parent_color = (unsigned long)p | color;
}

//设置结点颜色为黑色
static inline void rb_set_black(struct rb_node *rb)
{
        rb->__rb_parent_color |= RB_BLACK;
}
```

### 基本接口

* `rb_erase`： 删除结点
* `rb_insert_color`： 插入结点


### 用于遍历的接口

* `rb_first`: 寻找中序遍历的第一个结点，即最左的结点
* `rb_last`: 寻找中序遍历的最后一个结点，即最右的结点
* `rb_next`: 寻找中序遍历的下一个结点
* `rb_prev`: 寻找中序遍历的上一个结点
* `rb_next_postorder`: 找后续遍历的下一个结点
* `rb_first_postorder`: 找后续遍历的第一个结点
* `rbtree_postorder_for_each_entry_safe`： 后续遍历红黑树

### 其他接口

* `rb_insert_augmented`： 增强的插入接口
* `__rb_insert_augmented`： 增强的插入接口


## 内核或者模块中红黑树的使用方法

本来想详细写内核中如何使用红黑树的，发现内核中的红黑树的测试代码逻辑很清晰，大家可以参考，代码位置：`lib/rbtree_test.c`。


另外，内核中的红黑树实现了增强的接口，称之为`Augmented rbtrees`，具体信息，请参阅：https://elixir.bootlin.com/linux/v4.17/source/Documentation/rbtree.txt#L229




  [1]: http://vault.centos.org/7.4.1708/updates/Source/SPackages/kernel-3.10.0-693.11.6.el7.src.rpm
  



