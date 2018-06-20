> 注意：本文中的代码参考于linux v4.16。

## 数据结构

`hlist_head`和`hlist_node`用于散列表，分别表示列表头（数组中的一项）和列表头所在双向链表中的某项，两者结构如下:


{{< lts tag="4.16" file="include/linux/types.h" line="190" >}}

```c
struct hlist_head {
	struct hlist_node *first;
};
```

{{< lts tag="4.16" file="include/linux/types.h" line="194" >}}

```c
struct hlist_node {
	struct hlist_node *next, **pprev;
};

```

<!--more-->

在内核中的普通双向链表基本上都是通过`list_head`实现的：

{{< lts tag="4.16" file="include/linux/types.h" line="186" >}}
```c
struct list_head {
	struct list_head *next, *prev;
};
```

`list_head`很好理解，但是`hlist_head`和`hlist_node`为何要这样设计呢？


先看下`hlist_head`和`hlist_node`的示意图:

![hlist_head and hlist_node][1]

`hash_table`为散列表（数组），其中的元素类型为`struct hlist_head`。以`hlist_head`为链表头的链表，其中的节点`hash`值是相同的（也叫冲突）。`first`指针指向链表中的节点①，然后节点①的`pprev`指针指向`hlist_head`中的`first`，节点①的`next`指针指向节点②。以此类推。

`hash_table`的列表头仅存放一个指针,也就是`first`指针,指向的是对应链表的头结点,没有`tail`指针,也就是指向链表尾节点的指针,这样的考虑是为了节省空间——尤其在`hash bucket`(数组size)很大的情况下可以节省一半的指针空间。

**为什么`pprev`是一个指向指针的指针呢**？按照这个设计，我们如果想要得到尾节点，必须遍历整个链表，可如果是一个指向节点的指针，那么头结点现在的`pprev`便可以直接指向尾节点，也就是`list_head`的做法。

对于散列表来说，一般发生冲突的情况并不多（除非`hash`设计出现了问题），所以一个链表中的元素数量比较有限，遍历的劣势基本可以忽略。

**在删除链表头结点的时候，`pprev`这个设计无需判断删除的节点是否为头结点**。如果是普通双向链表的设计，那么删除头结点之后，hlist_head中的first指针需要指向新的头结点。通过下面2个函数来加深理解:


{{< lts tag="4.16" file="include/linux/list.h" line="669" >}}

```c
static inline void hlist_add_head(struct hlist_node *n, struct hlist_head *h)
{
	struct hlist_node *first = h->first;
	n->next = first; //新节点的next指针指向原头结点
	if (first) 
		first->pprev = &n->next;//原头结点的pprev指向新节点的next字段
	WRITE_ONCE(h->first, n);//first指针指向新的节点（更换了头结点）
	n->pprev = &h->first;//此时n是链表的头结点,将它的pprev指向list_head的first字段
}
```
{{< lts tag="4.16" file="include/linux/list.h" line="644" >}}

```c
static inline void __hlist_del(struct hlist_node *n)
{
	struct hlist_node *next = n->next;
	struct hlist_node **pprev = n->pprev;

	WRITE_ONCE(*pprev, next); // pprev指向的是前一个节点的next指针,当该节点是头节点时指向 hlist_head的first,两种情况下不论该节点是一般的节点还是头结点都可以通过这个操作删除掉所需删除的节点。
	if (next)
		next->pprev = pprev;//使删除节点的后一个节点的pprev指向删除节点的前一个节点的next字段，节点成功删除。
}
```


## 参考文档

* https://vinoit.me/2016/09/01/linux-kernel-hlist_head-and-hlist_node/
* http://blog.sina.com.cn/s/blog_508d2c500100gdnp.html



  [1]: ./list_head-and-hlist_node.png "list_head-and-hlist_node"
