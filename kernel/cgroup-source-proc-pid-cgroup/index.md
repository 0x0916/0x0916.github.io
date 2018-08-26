本文详细分析了`/proc/pid/cgroup`文件的内核实现。

> 注意：本文基于`3.10.0-862.el7.x86_64`版本`kernel`进行分析。

<!--more-->

### /proc/pid/cgroup 实现 

该文件描述了指定进程的cgroup信息，其信息包行多行，每一行描述了一个cgroup控制器的信息，每一行的格式如下：

```
           hierarchy-ID:controller-list:cgroup-path
```

例如：

```bash
# cat /proc/1/cgroup 
12:blkio:/
11:memory:/
10:hugetlb:/
9:devices:/
8:net_prio,net_cls:/
7:cpuacct,cpu:/
6:cpuset:/
5:perf_event:/
4:pids:/
3:freezer:/
2:debug:/
1:name=systemd:/
```

更详细的信息，请参考man手册：http://man7.org/linux/man-pages/man7/cgroups.7.html。

了解了如上信息，该接口的内核实现就比较简单了：

* 使用`for_each_active_root`遍历所有的层级(hierarchy)
* 对于每个层级：
 - 获取`hierarchy-ID`和对应的`controller-list`。
 - 通过`task_cgroup_from_root`和`cgroup_path`获取`cgroup-path`

代码实现如下：

```c
/*
 * proc_cgroup_show()
 *  - Print task's cgroup paths into seq_file, one line for each hierarchy
 *  - Used for /proc/<pid>/cgroup.
 *  - No need to task_lock(tsk) on this tsk->cgroup reference, as it
 *    doesn't really matter if tsk->cgroup changes after we read it,
 *    and we take cgroup_mutex, keeping cgroup_attach_task() from changing it
 *    anyway.  No need to check that tsk->cgroup != NULL, thanks to
 *    the_top_cgroup_hack in cgroup_exit(), which sets an exiting tasks
 *    cgroup to top_cgroup.
 */

/* TODO: Use a proper seq_file iterator */
int proc_cgroup_show(struct seq_file *m, void *v)
{
        struct pid *pid;
        struct task_struct *tsk;
        char *buf;
        int retval;
        struct cgroupfs_root *root;

        retval = -ENOMEM;
        buf = kmalloc(PAGE_SIZE, GFP_KERNEL);
        if (!buf)
                goto out;

        retval = -ESRCH;
        pid = m->private;
        tsk = get_pid_task(pid, PIDTYPE_PID);
        if (!tsk)
                goto out_free;

        retval = 0;

        mutex_lock(&cgroup_mutex);

        for_each_active_root(root) {
                struct cgroup_subsys *ss;
                struct cgroup *cgrp;
                int count = 0;

                seq_printf(m, "%d:", root->hierarchy_id);
                for_each_subsys(root, ss)
                        seq_printf(m, "%s%s", count++ ? "," : "", ss->name);
                if (strlen(root->name))
                        seq_printf(m, "%sname=%s", count ? "," : "",
                                   root->name);
                seq_putc(m, ':');
                cgrp = task_cgroup_from_root(tsk, root);
                retval = cgroup_path(cgrp, buf, PAGE_SIZE);
                if (retval < 0)
                        goto out_unlock;
                seq_puts(m, buf);
                seq_putc(m, '\n');
        }

out_unlock:
        mutex_unlock(&cgroup_mutex);
        put_task_struct(tsk);
out_free:
        kfree(buf);
out:
        return retval;
}
```

### 参考文章

* http://man7.org/linux/man-pages/man7/cgroups.7.html

