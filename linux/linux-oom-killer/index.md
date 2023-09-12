
当 Linux 机器内存耗尽时，内核会调用 `Out of Memory（OOM）killer `来释放一些内存。在运行大量内存密集型进程的服务器上，经常会遇到这种情况。在这篇文章中，我们将深入探讨 `OOM killer`何时会被调用，它如何决定杀死哪个进程，以及我们能否阻止它杀死像数据库等重要进程。

<!--more-->

### OOM killer如何选择要杀死的进程？

Linux 内核会给每个正在运行的进程一个名为 `oom_score` 的分数，这个分数会显示进程在可用内存不足的情况下被终止的可能性。该分数与进程使用的内存量成正比。

内核里是通过函数`oom_badness`对进程进行打分的，其原型如下：
```c
/**
 * oom_badness - heuristic function to determine which candidate task to kill
 * @p: task struct of which task we should calculate
 * @totalpages: total present RAM allowed for page allocation
 *
 * The heuristic for determining which task to kill is made to be as simple and
 * predictable as possible.  The goal is to return the highest value for the
 * task consuming the most memory to avoid subsequent oom failures.
 */
long oom_badness(struct task_struct *p, unsigned long totalpages)
```

这个函数的实现可能会随着Linux内核的版本而有所不同，这里以5.10({{< linux "5.10" "mm/oom_kill.c" "192" "239" >}})为例说明其算法：
* （1）计算进程的`RSS`（Resident Set Size，常驻内存集大小）、页表和交换空间的总和，这个总和就是进程的基础OOM得分points。
* （2）通过oom_score_adj来调整得分：`points += （oom_score_adj* totalpages）/1000`。
* （3）最终返回评分：`points`。

注意：以下几种进程也是不会被OOM killer杀死的：
* 1号进程
* 内核线程
* 即将退出的进程，其task_struct->mm为空的情况。
* oom_score_adj设置为-1000
* mm->flags中设置了MMF_OOM_SKIP位
* 进程处于in_vfork中

进程的 `oom_score` 可以在 `/proc` 目录中找到。假设你的进程的进程 ID（pid）是 `42`，那么 `cat /proc/42/oom_score` 会给出该进程的得分。

### 我能确保一些重要进程不被 OOM Killer 杀掉吗？

可以！`OOM killer`会检查 `oom_score_adj`，以调整其最终计算得分。该文件位于 `/proc/$pid/oom_score_adj`。 您可以在该文件中添加一个较大的负分，以确保进程被 `OOM killer`选中并终止的几率较低。`oom_score_adj` 的范围从 `-1000` 到 `1000` 不等。如果给它赋值 `-1000`，那么它可以使用 `100%` 的内存，但仍能避免被 `OOM killer`终止。另一方面，如果给它赋值 `1000`，那么 `Linux` 内核将继续杀死该进程，即使它只占用了极少的内存。

更改 `oom_score_adj` 的方法比较简单，直接修改`proc`接口文件就可以：
```
echo -200 | sudo tee - /proc/42/oom_score_adj
```

我们需要以` root` 用户或 `sudo` 用户身份进行操作，因为 `Linux` 不允许普通用户降低 `OOM` 分数。您可以以普通用户身份增加 `OOM` 得分，无需任何特殊权限，例如：`echo 100 > /proc/42/oom_score_adj`。

>  还有另一个不那么精细的分数，称为 oom_adj，其范围在 -16 至 15 之间。它与 oom_score_adj 类似。 事实上，当你设置 oom_adj 时，内核会自动将其缩减并计算 oom_score_adj。oom_adj 有一个神奇的值 -17，表示给定进程永远不会被 OOM 杀手杀死。这个oom_adj是要被oom_score_adj替代的，只是为了兼容旧的内核版本，暂时保留，以后会被废弃。

### 显示所有运行进程的 OOM 分数

该脚本按 OOM 分数降序显示所有运行进程的 OOM 分数和 OOM 调整后分数

```
#!/bin/bash
# Displays running processes in descending order of OOM score
printf 'PID\tOOM Score\tOOM Adj\tCommand\n'

while read -r pid comm;
do
	if [ -f /proc/$pid/oom_score ]  && [ $(cat /proc/$pid/oom_score) != 0 ];
  then
	  printf '%d\t%d\t\t%d\t%s\n' "$pid" "$(cat /proc/$pid/oom_score)" "$(cat /proc/$pid/oom_score_adj)" "$comm"
	fi	
done < <(ps -e -o pid= -o comm=)
```

### 检查是否有进程被 OOM 杀掉

最简单的方法是搜索系统日志。

在 `Ubuntu` 中：`grep -i kill /var/log/syslog`。如果某个进程已被杀死，您可能会得到如下结果：`my_process invoked oom-killer: gfp_mask=0x201da, order=0, oom_score_adj=0`

### 调整 OOM 分数的注意事项

* 请记住，OOM 是更大问题（可用内存不足）的症状。解决这个问题的最好办法是增加可用内存（如更好的硬件），或将某些程序移到其他机器上，或减少程序的内存消耗（如尽可能少分配内存）。

* 过多调整 OOM 调整分数会导致随机进程被杀死，无法释放足够的内存。

