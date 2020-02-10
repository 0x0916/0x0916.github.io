
红黑树在linux上的实现比较高效，本文详细介绍了如何在一个用户态的C程序中复用linux 内核的红黑树的实现。

> 注意：本文中的代码来自于：http://vault.centos.org/7.4.1708/updates/Source/SPackages/kernel-3.10.0-693.11.6.el7.src.rpm
<!--more-->

### 准备代码

拷贝内核中的如下代码到一个单独的目录中：

```
lib/rbtree.c
include/linux/rbtree.h
include/linux/rbtree_augmented.h
```


### 删除EXPORT_SYMBOL

```diff
diff --git a/rbtree_3/rbtree.c b/rbtree_3/rbtree.c
index 65f4eff..cb6c066 100644
--- a/rbtree_3/rbtree.c
+++ b/rbtree_3/rbtree.c
@@ -22,7 +22,6 @@
 */
 
 #include <linux/rbtree_augmented.h>
-#include <linux/export.h>
 
 /*
  * red-black trees properties:  http://en.wikipedia.org/wiki/Rbtree
@@ -366,7 +365,6 @@ void __rb_erase_color(struct rb_node *parent, struct rb_root *root,
 {
        ____rb_erase_color(parent, root, augment_rotate);
 }
-EXPORT_SYMBOL(__rb_erase_color);
 
 /*
  * Non-augmented rbtree manipulation functions.
@@ -387,7 +385,6 @@ void rb_insert_color(struct rb_node *node, struct rb_root *root)
 {
        __rb_insert(node, root, dummy_rotate);
 }
-EXPORT_SYMBOL(rb_insert_color);
 
 void rb_erase(struct rb_node *node, struct rb_root *root)
 {
@@ -396,7 +393,6 @@ void rb_erase(struct rb_node *node, struct rb_root *root)
        if (rebalance)
                ____rb_erase_color(rebalance, root, dummy_rotate);
 }
-EXPORT_SYMBOL(rb_erase);
 
 /*
  * Augmented rbtree manipulation functions.
@@ -410,7 +406,6 @@ void __rb_insert_augmented(struct rb_node *node, struct rb_root *root,
 {
        __rb_insert(node, root, augment_rotate);
 }
-EXPORT_SYMBOL(__rb_insert_augmented);
 
 /*
  * This function returns the first node (in sort order) of the tree.
@@ -426,7 +421,6 @@ struct rb_node *rb_first(const struct rb_root *root)
                n = n->rb_left;
        return n;
 }
-EXPORT_SYMBOL(rb_first);
 
 struct rb_node *rb_last(const struct rb_root *root)
 {
@@ -439,7 +433,6 @@ struct rb_node *rb_last(const struct rb_root *root)
                n = n->rb_right;
        return n;
 }
-EXPORT_SYMBOL(rb_last);
 
 struct rb_node *rb_next(const struct rb_node *node)
 {
@@ -471,7 +464,6 @@ struct rb_node *rb_next(const struct rb_node *node)
 
        return parent;
 }
-EXPORT_SYMBOL(rb_next);
 
 struct rb_node *rb_prev(const struct rb_node *node)
 {
@@ -500,7 +492,6 @@ struct rb_node *rb_prev(const struct rb_node *node)
 
        return parent;
 }
-EXPORT_SYMBOL(rb_prev);
 
 void rb_replace_node(struct rb_node *victim, struct rb_node *new,
                     struct rb_root *root)
@@ -517,7 +508,6 @@ void rb_replace_node(struct rb_node *victim, struct rb_node *new,
        /* Copy the pointers/colour from the victim to the replacement */
        *new = *victim;
 }
-EXPORT_SYMBOL(rb_replace_node);
 
 static struct rb_node *rb_left_deepest_node(const struct rb_node *node)
 {
@@ -548,7 +538,6 @@ struct rb_node *rb_next_postorder(const struct rb_node *node)
                 * should be next */
                return (struct rb_node *)parent;
 }
-EXPORT_SYMBOL(rb_next_postorder);
 
 struct rb_node *rb_first_postorder(const struct rb_root *root)
 {
@@ -557,4 +546,3 @@ struct rb_node *rb_first_postorder(const struct rb_root *root)
 
        return rb_left_deepest_node(root->rb_node);
 }
-EXPORT_SYMBOL(rb_first_postorder);
```

### 调整头文件

```diff
diff --git a/rbtree_3/rbtree.c b/rbtree_3/rbtree.c
index cb6c066..ccaf59b 100644
--- a/rbtree_3/rbtree.c
+++ b/rbtree_3/rbtree.c
@@ -21,7 +21,7 @@
   linux/lib/rbtree.c
 */
 
-#include <linux/rbtree_augmented.h>
+#include "rbtree_augmented.h"
 
 /*
  * red-black trees properties:  http://en.wikipedia.org/wiki/Rbtree
diff --git a/rbtree_3/rbtree.h b/rbtree_3/rbtree.h
index 57e75ae..a029d55 100644
--- a/rbtree_3/rbtree.h
+++ b/rbtree_3/rbtree.h
@@ -29,8 +29,28 @@
 #ifndef        _LINUX_RBTREE_H
 #define        _LINUX_RBTREE_H
 
-#include <linux/kernel.h>
-#include <linux/stddef.h>
+#include <stdio.h>
+
+#define NULL ((void *)0)
+enum {
+       false   = 0,
+       true    = 1
+};
+
+
+#define offsetof(TYPE, MEMBER)  ((size_t)&((TYPE *)0)->MEMBER)
+
+/**
+ * container_of - cast a member of a structure out to the containing structure
+ * @ptr:        the pointer to the member.
+ * @type:       the type of the container struct this is embedded in.
+ * @member:     the name of the member within the struct.
+ *
+ */
+#define container_of(ptr, type, member) ({                      \
+       const typeof( ((type *)0)->member ) *__mptr = (ptr);    \
+       (type *)( (char *)__mptr - offsetof(type,member) );})
+
 
 struct rb_node {
        unsigned long  __rb_parent_color;
diff --git a/rbtree_3/rbtree_augmented.h b/rbtree_3/rbtree_augmented.h
index fea49b5..079eb97 100644
--- a/rbtree_3/rbtree_augmented.h
+++ b/rbtree_3/rbtree_augmented.h
@@ -24,8 +24,7 @@
 #ifndef _LINUX_RBTREE_AUGMENTED_H
 #define _LINUX_RBTREE_AUGMENTED_H
 
-#include <linux/compiler.h>
-#include <linux/rbtree.h>
+#include "rbtree.h"
 
 /*
  * Please note - only struct rb_augment_callbacks and the prototypes for
```

### 添加测试用例

添加测试用例文件：main.c

Makefile如下：

```
# cat Makefile 
all: rbtree 

rbtree:
        gcc main.c rbtree.c  -g -o rbtree

test: all
        ./rbtree

clean:
        rm -fr rbtree *.o
```

### 代码

调整好的代码地址为：https://github.com/0x0916/rbtree/tree/master/rbtree_3
