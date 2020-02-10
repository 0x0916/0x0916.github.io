
本文继续该系列文章，分析了`cgroup`各个子系统的`mount`流程，当然也包括`umount/remount`流程。

> 注意：本文基于`3.10.0-862.el7.x86_64`版本`kernel`进行分析。

<!--more-->

### mount流程整体流程介绍

当我们mount `cgroup`文件系统时，一般输入命令如下：

```
# mount -t cgroup -o cpu,cpuacct   none  /sys/fs/cgroup/cpu,cpuacct
# mount -t cgroup -o pids none /sysfs/cgroup/cpu,cpuacct
```

在内核中，执行的函数为`cgroup_mount`，其主要完成了如下工作：

* 执行`parse_cgroupfs_options` 解析`mount`时的`options`选项
* 执行`cgroup_root_from_opts` 分配一个新的`cgroupfs_root`
* 通过`sget`查找对应的`super_block`是否存在，如果不存在就创建一个新的`super_block` 
* 如果`cgroupfs_root`已经存在，则说明已经挂载了，这次不需要做什么。
* 如果是新创建的`cgroupfs_root`，则说明没有挂载，需要做如下事情：
 - 获取挂载点对应的`inode`
 - 分配`css_set_count`个`cg_cgroup_link`结构
 - `rebind_subsystem`
 - 将该`cgroupfs_root`添加到链表`roots`中
 - 根据该层级的配置，使用`cgroup_populate_dir`创建对应的`cgroup`控制文件

代码如下：

```c
static struct dentry *cgroup_mount(struct file_system_type *fs_type,
			 int flags, const char *unused_dev_name,
			 void *data)
{
	struct cgroup_sb_opts opts;
	struct cgroupfs_root *root;
	int ret = 0;
	struct super_block *sb;
	struct cgroupfs_root *new_root;
	struct inode *inode;

	/* First find the desired set of subsystems */
	mutex_lock(&cgroup_mutex);
	ret = parse_cgroupfs_options(data, &opts);
	mutex_unlock(&cgroup_mutex);
	if (ret)
		goto out_err;

	/*
	 * Allocate a new cgroup root. We may not need it if we're
	 * reusing an existing hierarchy.
	 */
	new_root = cgroup_root_from_opts(&opts); // 解析mount时的options选项
	if (IS_ERR(new_root)) {
		ret = PTR_ERR(new_root);
		goto drop_modules;
	}
	opts.new_root = new_root;

	/* Locate an existing or new sb for this hierarchy */// 分配一个新的cgroupfs_root
	sb = sget(fs_type, cgroup_test_super, cgroup_set_super, 0, &opts);
	if (IS_ERR(sb)) {
		ret = PTR_ERR(sb);
		cgroup_drop_root(opts.new_root);
		goto drop_modules;
	}

	root = sb->s_fs_info;
	BUG_ON(!root);
	if (root == opts.new_root) { // 新的挂载，说明这是一个新的层级
		/* We used the new root structure, so this is a new hierarchy */
		struct list_head tmp_cg_links;
		struct cgroup *root_cgrp = &root->top_cgroup;
		struct cgroupfs_root *existing_root;
		const struct cred *cred;
		int i;
		struct css_set *cg;

		BUG_ON(sb->s_root != NULL);
		// 获取挂载点的inode
		ret = cgroup_get_rootdir(sb);
		if (ret)
			goto drop_new_super;
		inode = sb->s_root->d_inode;

		mutex_lock(&inode->i_mutex);
		mutex_lock(&cgroup_mutex);
		mutex_lock(&cgroup_root_mutex);

		/* Check for name clashes with existing mounts */
		ret = -EBUSY;
		if (strlen(root->name))
			for_each_active_root(existing_root)
				if (!strcmp(existing_root->name, root->name))
					goto unlock_drop;

		/*
		 * We're accessing css_set_count without locking
		 * css_set_lock here, but that's OK - it can only be
		 * increased by someone holding cgroup_lock, and
		 * that's us. The worst that can happen is that we
		 * have some link structures left over
		 */// 分配css_set_count个cg_cgroup_link结构
		ret = allocate_cg_links(css_set_count, &tmp_cg_links);
		if (ret)
			goto unlock_drop;

		ret = rebind_subsystems(root, root->subsys_mask);
		if (ret == -EBUSY) {
			free_cg_links(&tmp_cg_links);
			goto unlock_drop;
		}
		/*
		 * There must be no failure case after here, since rebinding
		 * takes care of subsystems' refcounts, which are explicitly
		 * dropped in the failure exit path.
		 */

		/* EBUSY should be the only error here */
		BUG_ON(ret);
		// 将该cgroupfs_root添加到链表roots中
		list_add(&root->root_list, &roots);
		root_count++;

		sb->s_root->d_fsdata = root_cgrp;
		root->top_cgroup.dentry = sb->s_root;

		/* Link the top cgroup in this hierarchy into all
		 * the css_set objects */
		write_lock(&css_set_lock);
		hash_for_each(css_set_table, i, cg, hlist)
			link_css_set(&tmp_cg_links, cg, root_cgrp);
		write_unlock(&css_set_lock);

		free_cg_links(&tmp_cg_links);

		BUG_ON(!list_empty(&root_cgrp->children));
		BUG_ON(root->number_of_cgroups != 1);

		cred = override_creds(&init_cred);
		// 创建对应的cgroup控制文件
		cgroup_populate_dir(root_cgrp, true, root->subsys_mask);
		revert_creds(cred);
		mutex_unlock(&cgroup_root_mutex);
		mutex_unlock(&cgroup_mutex);
		mutex_unlock(&inode->i_mutex);
	} else { // 已经挂载了，不需要做什么
		/*
		 * We re-used an existing hierarchy - the new root (if
		 * any) is not needed
		 */
		cgroup_drop_root(opts.new_root);

		if (root->flags != opts.flags) {
			if ((root->flags | opts.flags) & CGRP_ROOT_SANE_BEHAVIOR) {
				pr_err("cgroup: sane_behavior: new mount options should match the existing superblock\n");
				ret = -EINVAL;
				goto drop_new_super;
			} else {
				pr_warning("cgroup: new mount options do not match the existing superblock, will be ignored\n");
			}
		}

		/* no subsys rebinding, so refcounts don't change */
		drop_parsed_module_refcounts(opts.subsys_mask);
	}

	kfree(opts.release_agent);
	kfree(opts.name);
	return dget(sb->s_root);

 unlock_drop:
	mutex_unlock(&cgroup_root_mutex);
	mutex_unlock(&cgroup_mutex);
	mutex_unlock(&inode->i_mutex);
 drop_new_super:
	deactivate_locked_super(sb);
 drop_modules:
	drop_parsed_module_refcounts(opts.subsys_mask);
 out_err:
	kfree(opts.release_agent);
	kfree(opts.name);
	return ERR_PTR(ret);
}

```

在`centos 7 `系统启动时，默认会挂载所有的`cgroup`子系统，这些子系统是由`systemd`来负责挂载的，其代码为：[mount_cgroup_controllers](https://github.com/systemd/systemd/blob/v219/src/core/mount-setup.c#L222L316)

### mount中的一些细节

#### 解析mount选项

`parse_cgroupfs_options` 函数对mount时的options进行了解析，最后将结果保存到了一个cgroup_sb_opts类型的结构，并返回。

该版本的kernel支持的选项包括：

* none
* all
* \__DEVEL\__sane_behavior
* noprefix
* clone_children
* cpuset_v2_mode
* xattr
* release_agent=
* name=
* cgroup子系统的名称

这些选项受如下约束：

* 只能指定一个`release_agent=`
* `name=`的值中只允许为字母、数字和符号`.`, `-`, `_`等
* `all和`cgroup`子系统的名互斥，指定了`all`，就不能在指定`cgroup`子系统的名称了
* `none`和`cgroup`子系统的名互斥，指定了`none`，就不能在指定`cgroup`子系统的名称了
* 当指定了`__DEVEL__sane_behavior`后，就不能再指定`clone_children`和`noprefix`了
* 指定`noprefix`时，必须是在mount  `cpuset`这个控制器

在`parse_cgroupfs_options`的最后，会将这些需要挂载的`cgroup`控制器的模块引用计数**加1**，防止被别人意外卸载。

#### init_root_id 获取分配的层级的id

`cgroup_root_from_opts`函数根据挂载选项的要求，创建新的`cgroupfs_root`结构，如下：

```c
static struct cgroupfs_root *cgroup_root_from_opts(struct cgroup_sb_opts *opts)
{
	struct cgroupfs_root *root;

	if (!opts->subsys_mask && !opts->none)
		return NULL;

	root = kzalloc(sizeof(*root), GFP_KERNEL);
	if (!root)
		return ERR_PTR(-ENOMEM);

	if (!init_root_id(root)) { // 重点
		kfree(root);
		return ERR_PTR(-ENOMEM);
	}
	init_cgroup_root(root);

	root->subsys_mask = opts->subsys_mask;
	root->flags = opts->flags;
	ida_init(&root->cgroup_ida);
	if (opts->release_agent)
		strcpy(root->release_agent_path, opts->release_agent);
	if (opts->name)
		strcpy(root->name, opts->name);
	if (opts->cpuset_clone_children)
		set_bit(CGRP_CPUSET_CLONE_CHILDREN, &root->top_cgroup.flags);
	return root;
}
```

`init_root_id` 用来为该`cgroupfs_root`分配一个唯一的id。其利用了内核基础设置`IDA`机制，对应到cgroup里有以下几个全局变量：

```
static DEFINE_IDA(hierarchy_ida);
static int next_hierarchy_id;
static DEFINE_SPINLOCK(hierarchy_id_lock);
```
`hierarchy_id_lock` 用来包含对`next_hierarchy_id` 和 `hierarchy_ida`的访问，`next_hierarchy_id`表示下一次需要分配的`id`号。

```c
static bool init_root_id(struct cgroupfs_root *root)
{
	int ret = 0;

	do {
		if (!ida_pre_get(&hierarchy_ida, GFP_KERNEL))
			return false;
		spin_lock(&hierarchy_id_lock);
		/* Try to allocate the next unused ID */
		ret = ida_get_new_above(&hierarchy_ida, next_hierarchy_id,
					&root->hierarchy_id);
		if (ret == -ENOSPC)
			/* Try again starting from 0 */
			ret = ida_get_new(&hierarchy_ida, &root->hierarchy_id);
		if (!ret) {
			next_hierarchy_id = root->hierarchy_id + 1;
		} else if (ret != -EAGAIN) {
			/* Can only get here if the 31-bit IDR is full ... */
			BUG_ON(ret);
		}
		spin_unlock(&hierarchy_id_lock);
	} while (ret);
	return true;
}
```

#### sget 查找对应的super_block是否存在

sget 查找对应的super_block是否存时，用到了两个方法`cgroup_test_super`和`cgroup_set_super`:

* `cgroup_test_super`用于判断super_block是否相等

当有name时，name必须相等，此外cgroupfs_root上挂载的cgroup子系统也完全相同时，这两个super_block才相等

```c
static int cgroup_test_super(struct super_block *sb, void *data)
{
	struct cgroup_sb_opts *opts = data;
	struct cgroupfs_root *root = sb->s_fs_info;

	/* If we asked for a name then it must match */
	if (opts->name && strcmp(opts->name, root->name))
		return 0;

	/*
	 * If we asked for subsystems (or explicitly for no
	 * subsystems) then they must match
	 */
	if ((opts->subsys_mask || opts->none)
	    && (opts->subsys_mask != root->subsys_mask))
		return 0;

	return 1;
}
```


* `cgroup_set_super`的目的是设置新创建的`super_block`的一些属性

```
static int cgroup_set_super(struct super_block *sb, void *data)
{
	int ret;
	struct cgroup_sb_opts *opts = data;

	/* If we don't have a new root, we can't set up a new sb */
	if (!opts->new_root)
		return -EINVAL;

	BUG_ON(!opts->subsys_mask && !opts->none);

	ret = set_anon_super(sb, NULL);
	if (ret)
		return ret;

	sb->s_fs_info = opts->new_root;
	opts->new_root->sb = sb;

	sb->s_blocksize = PAGE_CACHE_SIZE;
	sb->s_blocksize_bits = PAGE_CACHE_SHIFT;
	sb->s_magic = CGROUP_SUPER_MAGIC;
	sb->s_op = &cgroup_ops;

	return 0;
}
``` 

看这里的`cgroup_ops`：

```c
static const struct super_operations cgroup_ops = {
	.statfs = simple_statfs,
	.drop_inode = generic_delete_inode,
	.show_options = cgroup_show_options,
	.remount_fs = cgroup_remount,
};
```

后续remount操作时，调用的就是这里的钩子函数`cgroup_remount`。

### rebind_subsystem

`rebind_subsystem`比较关键，其实现的功能时：

* 计算这次`mount`时，需要添加的`cgroup`子系统和要删除的`cgroup`子系统
* 检查要添加的`cgroup`子系统是否是空闲的，如果不是，则返回EBUSY`
* 检查`cgroupfs_root`是否只有一个`cgroup`，即只有`root cgroup`。否则返回`EBUSY`
* 然后处理每一个`cgroup子系统`
 - 需要添加`cgroup子系统`的话：将`cgroup_subsys`从`rootnode`的`subsys_list`中移动到新创建的`cgroupfs_root`的subsys_list中等；
 - 需要删除`cgroup子系统`的话：将`cgroup_subsys`从`cgroupfs_root`的`subsys_list`移动到`rootnode`的`subsys_list`中；
 - 不添加也不删除`cgroup`子系统的话：减少模块的引用计数，因为`parse_cgroupfs_options`中已经将其引用计数`加1`了
 - 其他：不做任何操作

当然，在添加和删除`cgroup子系统`时，会调整一下`cgroup_subsys`的`root`成员的值和`root cgroup`的成员`subsys`的值。

```c
/*
 * Call with cgroup_mutex held. Drops reference counts on modules, including
 * any duplicate ones that parse_cgroupfs_options took. If this function
 * returns an error, no reference counts are touched.
 */
static int rebind_subsystems(struct cgroupfs_root *root,
			      unsigned long final_subsys_mask)
{
	unsigned long added_mask, removed_mask;
	struct cgroup *cgrp = &root->top_cgroup;
	int i;

	BUG_ON(!mutex_is_locked(&cgroup_mutex));
	BUG_ON(!mutex_is_locked(&cgroup_root_mutex));

	removed_mask = root->actual_subsys_mask & ~final_subsys_mask;
	added_mask = final_subsys_mask & ~root->actual_subsys_mask;
	/* Check that any added subsystems are currently free */
	for (i = 0; i < CGROUP_SUBSYS_COUNT; i++) {
		unsigned long bit = 1UL << i;
		struct cgroup_subsys *ss = subsys[i];
		if (!(bit & added_mask))
			continue;
		/*
		 * Nobody should tell us to do a subsys that doesn't exist:
		 * parse_cgroupfs_options should catch that case and refcounts
		 * ensure that subsystems won't disappear once selected.
		 */
		BUG_ON(ss == NULL);
		if (ss->root != &rootnode) {
			/* Subsystem isn't free */
			return -EBUSY;
		}
	}

	/* Currently we don't handle adding/removing subsystems when
	 * any child cgroups exist. This is theoretically supportable
	 * but involves complex error handling, so it's being left until
	 * later */
	if (root->number_of_cgroups > 1)
		return -EBUSY;

	/* Process each subsystem */
	for (i = 0; i < CGROUP_SUBSYS_COUNT; i++) {
		struct cgroup_subsys *ss = subsys[i];
		unsigned long bit = 1UL << i;
		if (bit & added_mask) {
			/* We're binding this subsystem to this hierarchy */
			BUG_ON(ss == NULL);
			BUG_ON(cgrp->subsys[i]);
			BUG_ON(!dummytop->subsys[i]);
			BUG_ON(dummytop->subsys[i]->cgroup != dummytop);
			cgrp->subsys[i] = dummytop->subsys[i];
			cgrp->subsys[i]->cgroup = cgrp;
			list_move(&ss->sibling, &root->subsys_list);
			ss->root = root;
			if (ss->bind)
				ss->bind(cgrp);
			/* refcount was already taken, and we're keeping it */
		} else if (bit & removed_mask) {
			/* We're removing this subsystem */
			BUG_ON(ss == NULL);
			BUG_ON(cgrp->subsys[i] != dummytop->subsys[i]);
			BUG_ON(cgrp->subsys[i]->cgroup != cgrp);
			if (ss->bind)
				ss->bind(dummytop);
			dummytop->subsys[i]->cgroup = dummytop;
			cgrp->subsys[i] = NULL;
			subsys[i]->root = &rootnode;
			list_move(&ss->sibling, &rootnode.subsys_list);
			/* subsystem is now free - drop reference on module */
			module_put(ss->module);
		} else if (bit & final_subsys_mask) {
			/* Subsystem state should already exist */
			BUG_ON(ss == NULL);
			BUG_ON(!cgrp->subsys[i]);
			/*
			 * a refcount was taken, but we already had one, so
			 * drop the extra reference.
			 */
			module_put(ss->module);
#ifdef CONFIG_MODULE_UNLOAD
			BUG_ON(ss->module && !module_refcount(ss->module));
#endif
		} else {
			/* Subsystem state shouldn't exist */
			BUG_ON(cgrp->subsys[i]);
		}
	}
	root->subsys_mask = root->actual_subsys_mask = final_subsys_mask;

	return 0;
}

```

#### 创建对应的cgroup控制文件

`cgroup_populate_dir`用来创建对应的cgroup控制文件。

```c
/**
 * cgroup_populate_dir - selectively creation of files in a directory
 * @cgrp: target cgroup
 * @base_files: true if the base files should be added
 * @subsys_mask: mask of the subsystem ids whose files should be added
 */
static int cgroup_populate_dir(struct cgroup *cgrp, bool base_files,
			       unsigned long subsys_mask)
{
	int err;
	struct cgroup_subsys *ss;

	if (base_files) { // files 定义了cgroup的基本文件, true代表添加文件
		err = cgroup_addrm_files(cgrp, NULL, files, true);
		if (err < 0)
			return err;
	}

	/* process cftsets of each subsystem */
	for_each_subsys(cgrp->root, ss) { // 对于该层级上挂载的每一个cgroup子系统，创建控制文件
		struct cftype_set *set;
		if (!test_bit(ss->subsys_id, &subsys_mask))
			continue;

		list_for_each_entry(set, &ss->cftsets, node)
			cgroup_addrm_files(cgrp, ss, set->cfts, true);
	}

	/* This cgroup is ready now */
	for_each_subsys(cgrp->root, ss) {
		struct cgroup_subsys_state *css = cgrp->subsys[ss->subsys_id];
		/*
		 * Update id->css pointer and make this css visible from
		 * CSS ID functions. This pointer will be dereferened
		 * from RCU-read-side without locks.
		 */
		if (css->id)
			rcu_assign_pointer(css->id->css, css);
	}

	return 0;
}
```

`err = cgroup_addrm_files(cgrp, NULL, files, true);`创建cgroup基本的控制文件，这些文件的信息定义在一个`files`的全局变量中。

```c
/*
 * for the common functions, 'private' gives the type of file
 */
/* for hysterical raisins, we can't put this on the older files */
#define CGROUP_FILE_GENERIC_PREFIX "cgroup."
static struct cftype files[] = {
	{
		.name = "tasks",
		.open = cgroup_tasks_open,
		.write_u64 = cgroup_tasks_write,
		.release = cgroup_pidlist_release,
		.mode = S_IRUGO | S_IWUSR,
	},
	{
		.name = CGROUP_FILE_GENERIC_PREFIX "procs",
		.open = cgroup_procs_open,
		.write_u64 = cgroup_procs_write,
		.release = cgroup_pidlist_release,
		.mode = S_IRUGO | S_IWUSR,
	},
	{
		.name = "notify_on_release",
		.read_u64 = cgroup_read_notify_on_release,
		.write_u64 = cgroup_write_notify_on_release,
	},
	{
		.name = CGROUP_FILE_GENERIC_PREFIX "event_control",
		.write_string = cgroup_write_event_control,
		.mode = S_IWUGO,
	},
	{
		.name = "cgroup.clone_children",
		.flags = CFTYPE_INSANE,
		.read_u64 = cgroup_clone_children_read,
		.write_u64 = cgroup_clone_children_write,
	},
	{
		.name = "cgroup.sane_behavior",
		.flags = CFTYPE_ONLY_ON_ROOT,
		.read_seq_string = cgroup_sane_behavior_show,
	},
	{
		.name = "release_agent",
		.flags = CFTYPE_ONLY_ON_ROOT,
		.read_seq_string = cgroup_release_agent_show,
		.write_string = cgroup_release_agent_write,
		.max_write_len = PATH_MAX,
	},
	{ }	/* terminate */
};
```

### remount的一些限制

`cgroup_remount`执行对cgroup挂载点remount的操作：

```c
static int cgroup_remount(struct super_block *sb, int *flags, char *data)
{
	int ret = 0;
	struct cgroupfs_root *root = sb->s_fs_info;
	struct cgroup *cgrp = &root->top_cgroup;
	struct cgroup_sb_opts opts;
	unsigned long added_mask, removed_mask;
	// __DEVEL__sane_behavior 指定后，不允许进行remount操作
	if (root->flags & CGRP_ROOT_SANE_BEHAVIOR) {
		pr_err("cgroup: sane_behavior: remount is not allowed\n");
		return -EINVAL;
	}

	mutex_lock(&cgrp->dentry->d_inode->i_mutex);
	mutex_lock(&cgroup_mutex);
	mutex_lock(&cgroup_root_mutex);

	/* See what subsystems are wanted */ // 解析remount的选项
	ret = parse_cgroupfs_options(data, &opts);
	if (ret)
		goto out_unlock;
	// 不建议remount时修改层级的子系统或者其他选项，该功能已经废弃
	if (opts.subsys_mask != root->actual_subsys_mask || opts.release_agent)
		pr_warning("cgroup: option changes via remount are deprecated (pid=%d comm=%s)\n",
			   task_tgid_nr(current), current->comm);

	added_mask = opts.subsys_mask & ~root->subsys_mask;
	removed_mask = root->subsys_mask & ~opts.subsys_mask;

	// flags和name在remount时不允许改变
	/* Don't allow flags or name to change at remount */
	if (opts.flags != root->flags ||
	    (opts.name && strcmp(opts.name, root->name))) {
		ret = -EINVAL;
		drop_parsed_module_refcounts(opts.subsys_mask);
		goto out_unlock;
	}

	/*
	 * Clear out the files of subsystems that should be removed, do
	 * this before rebind_subsystems, since rebind_subsystems may
	 * change this hierarchy's subsys_list.
	 *///删除 要删除的cgroup子系统的控制文件
	cgroup_clear_directory(cgrp->dentry, false, removed_mask);

	ret = rebind_subsystems(root, opts.subsys_mask);
	if (ret) {
		/* rebind_subsystems failed, re-populate the removed files */
		cgroup_populate_dir(cgrp, false, removed_mask);
		drop_parsed_module_refcounts(opts.subsys_mask);
		goto out_unlock;
	}

	/* re-populate subsystem files */
	// 添加 要添加的cgroup子系统的控制文件
	cgroup_populate_dir(cgrp, false, added_mask);

	if (opts.release_agent)
		strcpy(root->release_agent_path, opts.release_agent);
 out_unlock:
	kfree(opts.release_agent);
	kfree(opts.name);
	mutex_unlock(&cgroup_root_mutex);
	mutex_unlock(&cgroup_mutex);
	mutex_unlock(&cgrp->dentry->d_inode->i_mutex);
	return ret;
}

```

### umount

`cgroup_kill_sb`是执行umount `cgroup`文件系统的内核方法：

```c
static void cgroup_kill_sb(struct super_block *sb) {
	struct cgroupfs_root *root = sb->s_fs_info;
	struct cgroup *cgrp = &root->top_cgroup;
	int ret;
	struct cg_cgroup_link *link;
	struct cg_cgroup_link *saved_link;

	BUG_ON(!root);
	// umount时，该层级上的cgroup个数必须为1
	BUG_ON(root->number_of_cgroups != 1);
	// umount时，该层级的root cgroup必须没有子cgroup
	BUG_ON(!list_empty(&cgrp->children));

	mutex_lock(&cgroup_mutex);
	mutex_lock(&cgroup_root_mutex);

	/* Rebind all subsystems back to the default hierarchy */
	// 删除该层级上所有附加的cgroup子系统
	ret = rebind_subsystems(root, 0);
	/* Shouldn't be able to fail ... */
	BUG_ON(ret);

	/*
	 * Release all the links from css_sets to this hierarchy's
	 * root cgroup
	 */
	write_lock(&css_set_lock);

	list_for_each_entry_safe(link, saved_link, &cgrp->css_sets,
				 cgrp_link_list) {
		list_del(&link->cg_link_list);
		list_del(&link->cgrp_link_list);
		kfree(link);
	}
	write_unlock(&css_set_lock);
	// 在roots链表中删除该cgroupfs_root
	if (!list_empty(&root->root_list)) {
		list_del(&root->root_list);
		root_count--;
	}

	mutex_unlock(&cgroup_root_mutex);
	mutex_unlock(&cgroup_mutex);

	simple_xattrs_free(&cgrp->xattrs);

	kill_litter_super(sb);
	cgroup_drop_root(root);
}
```

 

### 参考文章

