在描述进程的结构体`task_struct`中有一个类型为`css_set`的成员`cgroups`，它描述了进程的所有`cgroup`信息，从前面的分析文章中我们已经知道通过`task_struct->cgroups`可以找到进程的所有不同`cgroup`控制器的信息。

当我们新创建一个进程时，新进程的`task_struct->cgroups`的值继承自其`父进程`。此后，如果我们将新创建的进程添加到一个新的`cgroup`中时，就需要重新给`task_struct->cgroups`赋值，这个值要么是一个已经存在的`css_set`结构的指针，要么是新创建的`css_set`的结构的指针。

所以，我们就需要通过`进程的cgroup信息`，快速查找其对应的`css_set结构`是否存在，如果不存在的话就去创建它。`linux kernel` 使用一个`hash`表来完成这个工作。本文主要分析该`hash`表的实现。

> 注意：本文基于`3.10.0-862.el7.x86_64`版本`kernel`进行分析。

<!--more-->

### 数据结构 

```c
/*
 * hash table for cgroup groups. This improves the performance to find
 * an existing css_set. This hash doesn't (currently) take into
 * account cgroups in empty hierarchies.
 */
#define CSS_SET_HASH_BITS       7
static DEFINE_HASHTABLE(css_set_table, CSS_SET_HASH_BITS);
```

其中`CSS_SET_HASH_BITS`的值为7，所以定义的`css_set_table`这个hash数组由128个元素(1<<7)。

```
crash> whatis css_set_table
struct hlist_head css_set_table[128];
```

`css_set`有成员`hlist`，用来将具有相同`hash`值的`css_set`链接到一起，如下：

```c
struct css_set {

	...
        /*
         * List running through all cgroup groups in the same hash
         * slot. Protected by css_set_lock
         */
        struct hlist_node hlist;
	...
};
```

### hash 方法

此种场景下，如果进程的`cgroup`信息都相同的话，他们的`css_set`也应该相同，所以`css_set`的`hash`方法如下：

使用各个`cgroup`的`cgroup_subsys_state`的地址来计算`hash`值，计算方法如下：

```c
static unsigned long css_set_hash(struct cgroup_subsys_state *css[])
{
        int i;
        unsigned long key = 0UL;

        for (i = 0; i < CGROUP_SUBSYS_COUNT; i++)
                key += (unsigned long)css[i];
        key = (key >> 16) ^ key;

        return key;
}
```

> 注意：这里的返回值`key`肯定是一个大于`127`的数字，而我们的`css_set_table`数组只有`128`个，其实不用担心，再`hash_add`方法中会自动根据hash数组的大小进行调整的。

### 向css_set_table中添加css_set

当系统初始化时，需要将`init_css_set`添加到`css_set_table`中：

```c
        /* Add init_css_set to the hash table */
        key = css_set_hash(init_css_set.subsys);
        hash_add(css_set_table, &init_css_set.hlist, key);  
```

在`find_css_set`函数中，如果没有找到`css_set`，新建一个新的`css_set`后，需要将这个新的`css_set`添加到`css_set_table`：

```c
/*
 * find_css_set() takes an existing cgroup group and a
 * cgroup object, and returns a css_set object that's
 * equivalent to the old group, but with the given cgroup
 * substituted into the appropriate hierarchy. Must be called with
 * cgroup_mutex held
 */
static struct css_set *find_css_set(
        struct css_set *oldcg, struct cgroup *cgrp)
{
	....
        read_lock(&css_set_lock);
        res = find_existing_css_set(oldcg, cgrp, template);
        if (res)
                get_css_set(res);
        read_unlock(&css_set_lock);
	// 找到了直接返回
        if (res)
                return res;

	// 没有找到，新创建一个css_set
        res = kmalloc(sizeof(*res), GFP_KERNEL);
        if (!res)
                return NULL;

	...
	...
        css_set_count++;

        /* Add this cgroup group to the hash table */
        key = css_set_hash(res->subsys);
        hash_add(css_set_table, &res->hlist, key);

        write_unlock(&css_set_lock);

        return res;
}
```

在`cgroup_load_subsys`函数中，由于添加了新的cgroup子系统，导致系统上所有`css_set`的hash值都发生了变化，都必须重新计算`css_set`的hash，并添加到适当的hash数组中。

```c
/**
 * cgroup_load_subsys: load and register a modular subsystem at runtime
 * @ss: the subsystem to load
 *
 * This function should be called in a modular subsystem's initcall. If the
 * subsystem is built as a module, it will be assigned a new subsys_id and set
 * up for use. If the subsystem is built-in anyway, work is delegated to the
 * simpler cgroup_init_subsys.
 */
int __init_or_module cgroup_load_subsys(struct cgroup_subsys *ss)
{
	...
        write_lock(&css_set_lock);
        hash_for_each_safe(css_set_table, i, tmp, cg, hlist) {
                /* skip entries that we already rehashed */
                if (cg->subsys[ss->subsys_id])
                        continue;
                /* remove existing entry */
                hash_del(&cg->hlist); // 删除旧的
                /* set new value */
                cg->subsys[ss->subsys_id] = css;
                /* recompute hash and restore entry */
                key = css_set_hash(cg->subsys); // 添加新的
                hash_add(css_set_table, &cg->hlist, key);
        }
        write_unlock(&css_set_lock);
	...
}
```

`cgroup_unload_subsys`的情况跟`cgroup_load_subsys`类似。

### 删除css_set_table中的css_set

当一个`cgroup`的最后一个进程退出时，该进程对应的css_set就没有用了，需要从`css_set_table`中删除，其实现位于函数`__put_css_set`:

```c
static void __put_css_set(struct css_set *cg, int taskexit)                                                                                    
{
        struct cg_cgroup_link *link;
        struct cg_cgroup_link *saved_link;
        /*
         * Ensure that the refcount doesn't hit zero while any readers
         * can see it. Similar to atomic_dec_and_lock(), but for an
         * rwlock
         */
        if (atomic_add_unless(&cg->refcount, -1, 1))
                return;
        write_lock(&css_set_lock);
        if (!atomic_dec_and_test(&cg->refcount)) {
                write_unlock(&css_set_lock);
                return;
        }

        /* This css_set is dead. unlink it and release cgroup refcounts */
        hash_del(&cg->hlist);
        css_set_count--;
	...
	...
}
```

### 在css_set_table查找一个css_set

`find_existing_css_set`函数用于查找一个css_se是否存在，这个函数的参考有点怪，我们仔细分析一下：

* `oldcg`为该进程原来的`css_set`
* `cgrp`为要将进程添加进这个`cgroup`
* `template`为临时变量，用来传递进程最终的`cgroup`信息

```c
/*
 * find_existing_css_set() is a helper for
 * find_css_set(), and checks to see whether an existing
 * css_set is suitable.
 *
 * oldcg: the cgroup group that we're using before the cgroup
 * transition
 *
 * cgrp: the cgroup that we're moving into
 *
 * template: location in which to build the desired set of subsystem
 * state objects for the new cgroup group
 */
static struct css_set *find_existing_css_set(
        struct css_set *oldcg,
        struct cgroup *cgrp,
        struct cgroup_subsys_state *template[])
{
        int i;
        struct cgroupfs_root *root = cgrp->root;
        struct css_set *cg;
        unsigned long key;

        /*
         * Build the set of subsystem state objects that we want to see in the
         * new css_set. while subsystems can change globally, the entries here
         * won't change, so no need for locking.
         */
        for (i = 0; i < CGROUP_SUBSYS_COUNT; i++) {
                if (root->subsys_mask & (1UL << i)) {
                        /* Subsystem is in this hierarchy. So we want
                         * the subsystem state from the new
                         * cgroup */
                        template[i] = cgrp->subsys[i];
                } else {
                        /* Subsystem is not in this hierarchy, so we
                         * don't want to change the subsystem state */
                        template[i] = oldcg->subsys[i];
                }
        }

        key = css_set_hash(template);
        hash_for_each_possible(css_set_table, cg, hlist, key) {
                if (!compare_css_sets(cg, oldcg, cgrp, template))
                        continue;

                /* This css_set matches what we need */
                return cg;
        }

        /* No existing cgroup group matched */
        return NULL;
}
```

在查找过程中，如果判断两个css_set相等呢？这个重任就交给了函数`compare_css_sets`:

```c
/*
 * compare_css_sets - helper function for find_existing_css_set().
 * @cg: candidate css_set being tested
 * @old_cg: existing css_set for a task
 * @new_cgrp: cgroup that's being entered by the task
 * @template: desired set of css pointers in css_set (pre-calculated)
 *
 * Returns true if "cg" matches "old_cg" except for the hierarchy
 * which "new_cgrp" belongs to, for which it should match "new_cgrp".
 */
static bool compare_css_sets(struct css_set *cg,
                             struct css_set *old_cg,
                             struct cgroup *new_cgrp,
                             struct cgroup_subsys_state *template[])
{
        struct list_head *l1, *l2;
	// 判断cgroup_subsys_state是否完全相等
        if (memcmp(template, cg->subsys, sizeof(cg->subsys))) {
                /* Not all subsystems matched */
                return false;
        }

        /*
         * Compare cgroup pointers in order to distinguish between
         * different cgroups in heirarchies with no subsystems. We
         * could get by with just this check alone (and skip the
         * memcmp above) but on most setups the memcmp check will
         * avoid the need for this more expensive check on almost all
         * candidates.
         */
	// 进一步严格判断各个链表的长度和其指向的值是否一致
        l1 = &cg->cg_links;
        l2 = &old_cg->cg_links;
        while (1) {
                struct cg_cgroup_link *cgl1, *cgl2;
                struct cgroup *cg1, *cg2;

                l1 = l1->next;
                l2 = l2->next;
                /* See if we reached the end - both lists are equal length. */
                if (l1 == &cg->cg_links) {
                        BUG_ON(l2 != &old_cg->cg_links);
                        break;
                } else {
                        BUG_ON(l2 == &old_cg->cg_links);
                }
                /* Locate the cgroups associated with these links. */
                cgl1 = list_entry(l1, struct cg_cgroup_link, cg_link_list);
                cgl2 = list_entry(l2, struct cg_cgroup_link, cg_link_list);
                cg1 = cgl1->cgrp;
                cg2 = cgl2->cgrp;
                /* Hierarchies should be linked in the same order. */
                BUG_ON(cg1->root != cg2->root);

                /*
                 * If this hierarchy is the hierarchy of the cgroup
                 * that's changing, then we need to check that this
                 * css_set points to the new cgroup; if it's any other
                 * hierarchy, then this css_set should point to the
                 * same cgroup as the old css_set.
                 */
                if (cg1->root == new_cgrp->root) {
                        if (cg1 != new_cgrp)
                                return false;
                } else {
                        if (cg1 != cg2)
                                return false;
                }
        }
        return true;
}
```

### 通过crash可以查看css_set_table

```
crash> p css_set_count
css_set_count = $4 = 42
crash> p css_set_table
css_set_table = $5 = 
 {{
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d43c90c8
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d6915248
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b52042bb48
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d1862f08
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d6ac2008
  }, {
    first = 0xffffa0b5d43c9a88
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d18629c8
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5205e7cc8
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b612593008
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d1862188
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5bf085f08
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d1862548
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d6ac26c8
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d83cd308
  }, {
    first = 0xffffa0b5d09e4848
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b535d28cc8
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d185c6c8
  }, {
    first = 0xffffa0b616f0d488
  }, {
    first = 0xffffa0b5205e70c8
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d43c9248
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5cd167a88
  }, {
    first = 0xffffa0b5db76ce48
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d185c488
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d43c9d88
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5db59d788
  }, {
    first = 0xffffa0b616922248
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d43c93c8
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d1862d88
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d4332248
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d1862b48
  }, {
    first = 0xffffa0b5d18626c8
  }, {
    first = 0xffffa0b5d5d46308
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5bcbb23c8
  }, {
    first = 0xffffa0b5d43c9548
  }, {
    first = 0x0
  }, {
    first = 0xffffa0b5d1862848
  }, {
    first = 0x0
  }, {
    first = 0x0
  }}
```


