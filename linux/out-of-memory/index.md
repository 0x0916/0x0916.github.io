
本文简要介绍了`Linux OOM`机制，并详细分析了`OOM`机制的全局参数配置和进程级别的参数配置。

<!--more-->
### OOM机制

`OOM(Out Of Memory)`机制为`Linux`内核中一种自我保护机制，当系统分配不出内存时(触发条件)会触发这个机制，由系统在已有进程中挑选一个占用内存较多，回收内存收益最大的进程杀掉来释放内存。

### OOM全局内控制优参数

`panic_on_oom` : 用于决定在发生`oom`时，内核是否`panic`, 可以设置的值为`0`、`1`、`2`，默认为`0`

* `1`： 当`cpuset`、`mempolicy`、`memcg`等分配失败引起的`oom`，不进行`panic`
* `2`：任何情况的的`oom`，都进行`panic`

`oom_dump_tasks`: 如果启用，在内核执行`oom killer`时，会打印系统内进程的信息，这些信息可以帮助我们找出为什么`oom killer`被执行，找到导致`oom`的进程，以及了解为什么进程会被选中, 默认为`1`

* `非0`: 打印系统内进程的信息
* `0`: 不打印系统内进程的信息

`oom_kill_allocating_task`: 决定在`oom`时，`oom killer`杀哪些进程,默认设置为`0`

* `非0`: 它会扫描进程队列，将可能导致内存溢出的进程杀掉，也就是占用内存最大的进程
* `0`:  oom killer只杀导致oom的那个进程，避免了进程队列的扫描，但是释放的内存大小有限


### `OOM`进程级别的参数

`oom killer`机制提供了几个参数来调节进程在`oom killer`中的行为

* `/proc/<pid>/oom_score_adj` 可以设置`-1000`到`1000`，当设置为`-1000`时表示不会被`oom killer`选中

* `/proc/<pid>/oom_adj` 它的值从`-17`到`15`，值越大越容易被`oom killer`选中，值越小表示选中的可能性越小。当值为`-17`是，表示该进程永远不会被选中。这个`oom_adj`是要被`oom_score_adj`替代的，只是为了兼容旧的内核版本，暂时保留，以后会被废弃。

* `/proc/<pid>/oom_score`   表示当前进程的`oom`分数


### 宿主机上人为产生`oom`的方法

```bash
# echo f > /proc/sysrq-trigger
```

该操作在容器中不可用。

```c
static void moom_callback(struct work_struct *ignored)
{// echo f > /proc/sysrq-trigger 后执行的函数
        out_of_memory(node_zonelist(first_memory_node, GFP_KERNEL), GFP_KERNEL,                    
                      0, NULL, true);
}
```

#### 宿主机上完整的`oom`日志如下

```
[13933.589425] SysRq : Manual OOM execution
[13933.594196] kworker/2:1 invoked oom-killer: gfp_mask=0xd0, order=0, oom_score_adj=0
[13933.594216] kworker/2:1 cpuset=/ mems_allowed=0
[13933.594219] CPU: 2 PID: 14808 Comm: kworker/2:1 Not tainted 3.10.0-693.el7.x86_64.debug #1
[13933.594220] Hardware name: LENOVO 90GH000GCD/3102, BIOS M16KT34A 05/25/2017
[13933.594223] Workqueue: events moom_callback
[13933.594224] Call Trace:
[13933.594228]  [<ffffffff8178219b>] dump_stack+0x19/0x1b
[13933.594229]  [<ffffffff8177cf5b>] dump_header+0x8e/0x2ab
[13933.594232]  [<ffffffff81125e1d>] ? trace_hardirqs_on_caller+0xfd/0x1c0
[13933.594234]  [<ffffffff81125eed>] ? trace_hardirqs_on+0xd/0x10
[13933.594236]  [<ffffffff811ce4fe>] oom_kill_process+0x26e/0x3f0
[13933.594238]  [<ffffffff810ec575>] ? local_clock+0x25/0x30
[13933.594240]  [<ffffffff811ceeb1>] out_of_memory+0x601/0x670
[13933.594242]  [<ffffffff8148b51d>] moom_callback+0x4d/0x50
[13933.594244]  [<ffffffff810c5b66>] process_one_work+0x226/0x720
[13933.594245]  [<ffffffff810c5afa>] ? process_one_work+0x1ba/0x720
[13933.594247]  [<ffffffff810c6186>] worker_thread+0x126/0x3b0
[13933.594248]  [<ffffffff810c6060>] ? process_one_work+0x720/0x720
[13933.594251]  [<ffffffff810cec3d>] kthread+0xed/0x100
[13933.594253]  [<ffffffff810ceb50>] ? insert_kthread_work+0x80/0x80
[13933.594255]  [<ffffffff81797e5d>] ret_from_fork+0x5d/0xb0
[13933.594257]  [<ffffffff810ceb50>] ? insert_kthread_work+0x80/0x80
[13933.594258] Mem-Info:
[13933.594261] active_anon:26728 inactive_anon:2191 isolated_anon:0
 active_file:21362 inactive_file:46137 isolated_file:0
 unevictable:5409 dirty:24 writeback:0 unstable:0
 slab_reclaimable:16619 slab_unreclaimable:14290
 mapped:15288 shmem:2373 pagetables:1969 bounce:0
 free:3870360 free_pcp:2330 free_cma:0
[13933.594263] Node 0 DMA free:15872kB min:64kB low:80kB high:96kB active_anon:0kB inactive_anon:0kB active_file:0kB inactive_file:0kB unevictable:0kB isolated(anon):0kB isolated(file):0kB present:15980kB managed:15896kB mlocked:0kB dirty:0kB writeback:0kB mapped:0kB shmem:0kB slab_reclaimable:0kB slab_unreclaimable:24kB kernel_stack:0kB pagetables:0kB unstable:0kB bounce:0kB free_pcp:0kB local_pcp:0kB free_cma:0kB writeback_tmp:0kB pages_scanned:0 all_unreclaimable? no
[13933.594266] lowmem_reserve[]: 0 3269 15780 15780
[13933.594269] Node 0 DMA32 free:3231692kB min:13988kB low:17484kB high:20980kB active_anon:22544kB inactive_anon:240kB active_file:20476kB inactive_file:39852kB unevictable:4232kB isolated(anon):0kB isolated(file):0kB present:3616468kB managed:3354772kB mlocked:4232kB dirty:8kB writeback:0kB mapped:10032kB shmem:432kB slab_reclaimable:11044kB slab_unreclaimable:5940kB kernel_stack:688kB pagetables:1836kB unstable:0kB bounce:0kB free_pcp:5024kB local_pcp:652kB free_cma:0kB writeback_tmp:0kB pages_scanned:0 all_unreclaimable? no
[13933.594272] lowmem_reserve[]: 0 0 12511 12511
[13933.594274] Node 0 Normal free:12233876kB min:53528kB low:66908kB high:80292kB active_anon:84368kB inactive_anon:8524kB active_file:64972kB inactive_file:144696kB unevictable:17404kB isolated(anon):0kB isolated(file):0kB present:13090816kB managed:12811508kB mlocked:17404kB dirty:88kB writeback:0kB mapped:51120kB shmem:9060kB slab_reclaimable:55432kB slab_unreclaimable:51196kB kernel_stack:3392kB pagetables:6040kB unstable:0kB bounce:0kB free_pcp:4296kB local_pcp:296kB free_cma:0kB writeback_tmp:0kB pages_scanned:0 all_unreclaimable? no
[13933.594276] lowmem_reserve[]: 0 0 0 0
[13933.594279] Node 0 DMA: 0*4kB 0*8kB 0*16kB 0*32kB 2*64kB (U) 1*128kB (U) 1*256kB (U) 0*512kB 1*1024kB (U) 1*2048kB (M) 3*4096kB (M) = 15872kB
[13933.594291] Node 0 DMA32: 569*4kB (UEM) 459*8kB (UEM) 325*16kB (UEM) 226*32kB (UEM) 128*64kB (UEM) 78*128kB (UEM) 35*256kB (UM) 21*512kB (UEM) 9*1024kB (M) 0*2048kB 773*4096kB (M) = 3231692kB
[13933.594301] Node 0 Normal: 1509*4kB (UEM) 1740*8kB (UEM) 1028*16kB (UEM) 545*32kB (UEM) 445*64kB (UEM) 254*128kB (UM) 144*256kB (UEM) 76*512kB (UM) 53*1024kB (UEM) 68*2048kB (UM) 2893*4096kB (UM) = 12233876kB
[13933.594311] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=1048576kB
[13933.594312] Node 0 hugepages_total=0 hugepages_free=0 hugepages_surp=0 hugepages_size=2048kB
[13933.594313] 71731 total pagecache pages
[13933.594313] 0 pages in swap cache
[13933.594314] Swap cache stats: add 156702, delete 156702, find 301/390
[13933.594315] Free swap  = 8191996kB
[13933.594316] Total swap = 8191996kB
[13933.594354] 4180816 pages RAM
[13933.594355] 0 pages HighMem/MovableOnly
[13933.594355] 135272 pages reserved
[13933.594356] [ pid ]   uid  tgid total_vm      rss nr_ptes swapents oom_score_adj name
[13933.594363] [  411]     0   411     9499     2021      22        0             0 systemd-journal
[13933.594366] [  433]     0   433    68627      877      31        0             0 lvmetad
[13933.594368] [  450]     0   450    11123      585      23        0         -1000 systemd-udevd
[13933.594371] [  622]     0   622    13863      222      26        0         -1000 auditd
[13933.594372] [  624]     0   624    21125      223      12        0             0 audispd
[13933.594374] [  626]     0   626     6013      231      16        0             0 sedispatch
[13933.594376] [  647]   999   647   134054     3017      58        0             0 polkitd
[13933.594378] [  648]     0   648    10513      619      23        0             0 bluetoothd
[13933.594380] [  649]     0   649     6096      593      18        0             0 smartd
[13933.594382] [  654]     0   654     1618      161       9        0             0 rngd
[13933.594384] [  657]     0   657   106488     1368      76        0             0 ModemManager
[13933.594386] [  660]     0   660     6051      424      15        0             0 systemd-logind
[13933.594388] [  662]    70   662     7549      435      20        0             0 avahi-daemon
[13933.594390] [  664]     0   664     4210      361      14        0             0 alsactl
[13933.594392] [  665]   998   665     2133      200       9        0             0 lsmd
[13933.594394] [  668]     0   668    53030     1512      42        0             0 rsyslogd
[13933.594396] [  672]     0   672     5402      314      16        0             0 irqbalance
[13933.594398] [  673]    70   673     7518       60      19        0             0 avahi-daemon
[13933.594400] [  675]    81   675     6696      531      19        0          -900 dbus-daemon
[13933.594402] [  685]     0   685    50314      315      41        0             0 gssproxy
[13933.594404] [  701]     0   701   156024     2525      91        0             0 NetworkManager
[13933.594406] [  710]     0   710    54782     1366      61        0             0 abrtd
[13933.594408] [  713]     0   713    54227     1176      63        0             0 abrt-watch-log
[13933.594410] [  716]     0   716    54227     1179      59        0             0 abrt-watch-log
[13933.594412] [  722]   994   722    28910      444      27        0             0 chronyd
[13933.594414] [  733]     0   733     1770       70       8        0             0 mcelog
[13933.594415] [  781]     0   781    28814      233      12        0             0 ksmtuned
[13933.594417] [  797]     0   797    13680     1223      32        0             0 wpa_supplicant
[13933.594420] [  820]     0   820    30940     5397      39        0         -1000 dmeventd
[13933.594422] [ 1061]     0  1061    48409     1030      51        0             0 cupsd
[13933.594424] [ 1062]     0  1062    26499     1021      55        0         -1000 sshd
[13933.594426] [ 1065]     0  1065   140581     4162      91        0             0 tuned
[13933.594428] [ 1067]     0  1067   239560     8517      87        0          -500 dockerd-current
[13933.594430] [ 1096]     0  1096   167866     3111      40        0          -500 docker-containe
[13933.594432] [ 1107]     0  1107   153098     3424     141        0             0 libvirtd
[13933.594434] [ 1131]     0  1131    31558      398      20        0             0 crond
[13933.594436] [ 1136]     0  1136     6464      234      18        0             0 atd
[13933.594438] [ 1208]     0  1208    27511      210      12        0             0 agetty
[13933.594440] [ 1213]     0  1213    27511      208      10        0             0 agetty
[13933.594442] [ 1812]    99  1812     3901      232      13        0             0 dnsmasq
[13933.594444] [ 1813]     0  1813     3894       48      12        0             0 dnsmasq
[13933.594446] [ 2604]     0  2604    28344     3981      57        0             0 dhclient
[13933.594448] [13068]     0 13068    37600     1386      74        0             0 sshd
[13933.594450] [13070]     0 13070    29201      889      14        0             0 bash
[13933.594452] [13138]     0 13138     4999      272      14        0             0 tmux
[13933.594454] [13140]     0 13140     5609      475      15        0             0 tmux
[13933.594456] [13141]     0 13141    29177      843      15        0             0 bash
[13933.594458] [13606]     0 13606    37600     1386      77        0             0 sshd
[13933.594460] [13608]     0 13608    29233      909      16        0             0 bash
[13933.594462] [14253]     0 14253    37600     1387      75        0             0 sshd
[13933.594464] [14255]     0 14255    29304      966      15        0             0 bash
[13933.594477] [14450]     0 14450     4447      328      13        0             0 systemd-machine
[13933.594479] [14627]     0 14627    37600     1387      76        0             0 sshd
[13933.594481] [14629]     0 14629    29201      902      16        0             0 bash
[13933.594483] [14901]     0 14901    26976      153      12        0             0 sleep
[13933.594485] Out of memory: Kill process 1065 (tuned) score 0 or sacrifice child
[13933.602190] Killed process 1065 (tuned) total-vm:562324kB, anon-rss:10760kB, file-rss:5888kB, shmem-rss:0kB
```

### 容器内产生`oom`的方法

```bash
 root@15e3eaa960e4:/# stress -m 8 -t 30
stress: info: [31] dispatching hogs: 0 cpu, 0 io, 8 vm, 0 hdd
stress: FAIL: [31] (415) <-- worker 39 got signal 9
stress: WARN: [31] (417) now reaping child worker processes
stress: FAIL: [31] (451) failed run completed in 0s
```


#### 容器内完整的`oom`日志

```
[13449.623801] stress invoked oom-killer: gfp_mask=0xd0, order=0, oom_score_adj=0
[13449.623806] stress cpuset=docker-15e3eaa960e4ac016d47ea7247961a70254bbbaaaec3981a9090f68606623b50.scope mems_allowed=0
[13449.623808] CPU: 0 PID: 14726 Comm: stress Not tainted 3.10.0-693.el7.x86_64.debug #1
[13449.623809] Hardware name: LENOVO 90GH000GCD/3102, BIOS M16KT34A 05/25/2017
[13449.623810] Call Trace:
[13449.623815]  [<ffffffff8178219b>] dump_stack+0x19/0x1b
[13449.623816]  [<ffffffff8177cf5b>] dump_header+0x8e/0x2ab
[13449.623819]  [<ffffffff81125e1d>] ? trace_hardirqs_on_caller+0xfd/0x1c0
[13449.623821]  [<ffffffff81125eed>] ? trace_hardirqs_on+0xd/0x10
[13449.623823]  [<ffffffff811ce4fe>] oom_kill_process+0x26e/0x3f0
[13449.623826]  [<ffffffff81249f20>] ? mem_cgroup_iter+0x2b0/0x3e0
[13449.623828]  [<ffffffff8124ed71>] mem_cgroup_oom_synchronize+0x551/0x580
[13449.623830]  [<ffffffff8124de10>] ? mem_cgroup_charge_common+0xf0/0xf0
[13449.623831]  [<ffffffff811cef34>] pagefault_out_of_memory+0x14/0x90
[13449.623833]  [<ffffffff81779ea1>] mm_fault_error+0x68/0x12b
[13449.623835]  [<ffffffff81792c8b>] __do_page_fault+0x42b/0x4d0
[13449.623838]  [<ffffffff810de3c4>] ? finish_task_switch+0x44/0x180
[13449.623839]  [<ffffffff81792d65>] do_page_fault+0x35/0x90
[13449.623841]  [<ffffffff8178e828>] page_fault+0x28/0x30
[13449.623844] Task in /system.slice/docker-15e3eaa960e4ac016d47ea7247961a70254bbbaaaec3981a9090f68606623b50.scope killed as a result of limit of /system.slice/docker-15e3eaa960e4ac016d47ea7247961a70254bbbaaaec3981a9090f68606623b50.scope
[13449.623846] memory: usage 53824kB, limit 102400kB, failcnt 20427
[13449.623847] memory+swap: usage 204800kB, limit 204800kB, failcnt 608
[13449.623848] kmem: usage 0kB, limit 9007199254740988kB, failcnt 0
[13449.623848] Memory cgroup stats for /system.slice/docker-15e3eaa960e4ac016d47ea7247961a70254bbbaaaec3981a9090f68606623b50.scope: cache:64KB rss:53760KB rss_huge:20480KB mapped_file:0KB dirty:0KB writeback:0KB swap:150976KB inactive_anon:37708KB active_anon:16052KB inactive_file:8KB active_file:8KB unevictable:0KB
[13449.623857] [ pid ]   uid  tgid total_vm      rss nr_ptes swapents oom_score_adj name
[13449.623956] [14575]     0 14575     4556        0      14      119             0 bash
[13449.623963] [14720]     0 14720     1867        3       9       23             0 stress
[13449.623966] [14721]     0 14721    67404      102       9       15             0 stress
[13449.623969] [14722]     0 14722    67404      163       9       15             0 stress
[13449.623973] [14723]     0 14723    67404        1       9      183             0 stress
[13449.623976] [14724]     0 14724    67404      102       9      369             0 stress
[13449.623979] [14725]     0 14725    67404      101      12     1524             0 stress
[13449.623982] [14726]     0 14726    67404     2711      15      333             0 stress
[13449.623986] [14727]     0 14727    67404      177      22     6906             0 stress
[13449.623989] [14728]     0 14728    67404     6605      83    31751             0 stress
[13449.623991] Memory cgroup out of memory: Kill process 14728 (stress) score 750 or sacrifice child
[13449.633291] Killed process 14728 (stress) total-vm:269616kB, anon-rss:24064kB, file-rss:4kB, shmem-rss:0kB
```

关闭`oom_dump_tasks`后，日志如下：

```
[13603.131330] stress invoked oom-killer: gfp_mask=0xd0, order=0, oom_score_adj=0
[13603.131335] stress cpuset=docker-15e3eaa960e4ac016d47ea7247961a70254bbbaaaec3981a9090f68606623b50.scope mems_allowed=0
[13603.131337] CPU: 6 PID: 14806 Comm: stress Not tainted 3.10.0-693.42.el7.x86_64.debug #1
[13603.131338] Hardware name: LENOVO 90GH000GCD/3102, BIOS M16KT34A 05/25/2017
[13603.131339] Call Trace:
[13603.131344]  [<ffffffff8178219b>] dump_stack+0x19/0x1b
[13603.131346]  [<ffffffff8177cf5b>] dump_header+0x8e/0x2ab
[13603.131349]  [<ffffffff81125e1d>] ? trace_hardirqs_on_caller+0xfd/0x1c0
[13603.131351]  [<ffffffff81125eed>] ? trace_hardirqs_on+0xd/0x10
[13603.131353]  [<ffffffff811ce4fe>] oom_kill_process+0x26e/0x3f0
[13603.131356]  [<ffffffff81249f20>] ? mem_cgroup_iter+0x2b0/0x3e0
[13603.131358]  [<ffffffff8124ed71>] mem_cgroup_oom_synchronize+0x551/0x580
[13603.131367]  [<ffffffff8124de10>] ? mem_cgroup_charge_common+0xf0/0xf0
[13603.131369]  [<ffffffff811cef34>] pagefault_out_of_memory+0x14/0x90
[13603.131372]  [<ffffffff81779ea1>] mm_fault_error+0x68/0x12b
[13603.131375]  [<ffffffff81792c8b>] __do_page_fault+0x42b/0x4d0
[13603.131377]  [<ffffffff81792d65>] do_page_fault+0x35/0x90
[13603.131380]  [<ffffffff8178e828>] page_fault+0x28/0x30
[13603.131383] Task in /system.slice/docker-15e3eaa960e4ac016d47ea7247961a70254bbbaaaec3981a9090f68606623b50.scope killed as a result of limit of /system.slice/docker-15e3eaa960e4ac016d47ea7247961a70254bbbaaaec3981a9090f68606623b50.scope
[13603.131387] memory: usage 101716kB, limit 102400kB, failcnt 30881
[13603.131388] memory+swap: usage 204800kB, limit 204800kB, failcnt 6749
[13603.131391] kmem: usage 0kB, limit 9007199254740988kB, failcnt 0
[13603.131392] Memory cgroup stats for /system.slice/docker-15e3eaa960e4ac016d47ea7247961a70254bbbaaaec3981a9090f68606623b50.scope: cache:0KB rss:101716KB rss_huge:2048KB mapped_file:0KB dirty:0KB writeback:36KB swap:103084KB inactive_anon:50892KB active_anon:50256KB inactive_file:0KB active_file:0KB unevictable:0KB
[13603.131405] Memory cgroup out of memory: Kill process 14806 (stress) score 634 or sacrifice child
[13603.140754] Killed process 14806 (stress) total-vm:269616kB, anon-rss:55384kB, file-rss:4kB, shmem-rss:0kB
```

### 建议宿主机上的配置

最优配置要看具体使用场景:

* 对于`panic_on_oom`，如果是嵌入式场景，可以配置成`2`，当出现oom时，通过自动重启将系统恢复正常。但对于服务器系统来说，`panic`就不太友好了，建议配置为默认的0即可。

* 对于`oom_dump_tasks`,如果是调试阶段，建议配置为`1`,如果在生产环境下，特别是系统上进程较多的情况下，建议配置为`0`。内核文档中也建议配置为`0`(参考：{{< linux tag="4.16" file="Documentation/sysctl/vm.txt" from="595" to="615" >}}).

* 对于`oom_kill_allocating_task`,建议设置为默认值即可。


### 参考文章

* https://github.com/torvalds/linux/blob/v4.16/Documentation/sysctl/vm.txt
