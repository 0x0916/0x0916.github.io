
在内核`panic`时，会打印出出问题的调用栈信息，同时也可以通过`kdump`结合`crash`进行更深入的分析定位问题。

本文分析了`x86-64`的栈帧结构，为分析问题提供帮助。

<!--more-->

### 关于x86架构下栈的基础知识

英特尔的 `x86`架构把它的栈**头朝下**。它从某个地址开始，逐渐发展到一个较低的地址。下面是它的样子:

<center>
![][1]
</center>

因此，当我们说 `x86`上的**栈顶部**时，我们实际上指的是栈占用的内存区域中的最低地址。

`x86`架构保留了一个特殊的寄存器——`ESP (Extended Stack Pointer)`，来指向栈的顶部。

<center>
![][2]
</center>

如上图所示，地址`0x9080ABCC`是栈的顶部，ESP寄存器保存了指向栈顶的地址`0x9080ABCC`。

我们使用`push`指令将新数据放入栈中，`push`所做的首先递减`ESP（ESP-4）`，然后将其操作数放到`ESP`指向的位置，所以

```
push eax
```
等价于
```
sub esp 4
mov [esp], exa
```

假设`exa`保存的值为`0xDEADBEEF`，那么`push`后，栈就会变成如下：

<center>
![][3]
</center>

类似的，`pop`指令从栈顶获取一个值将其放到操作数中，然后增加`ESP（ESP+4`），也就是说
```
pop eax
```
等价于
```
mov eax, [esp]
add esp + 4
```
`pop exa`执行后，栈的情况如下：

<center>
![][4]
</center>

值`0xDEADBEEF` 将被写入` eax`。注意，`0xDEADBEEF` 也保留在地址`0x9080ABC8`，因为我们还没有覆盖它。

> 注意：上面主要以x86架构，介绍了关于栈的基础知识，下面会以x86-64架构，来介绍函数参数的传递约定。

### x86_64通用寄存器

`x86` 有`8`个通用的寄存器 (`eax, ebx, ecx, edx, ebp, esp, esi, edi`).`x86_64`对他们进行扩展，变成了`64`位 (前缀由`e`变成了`r`) ，并且增加了另外`8`个寄存器  (`r8, r9, r10, r11, r12, r13, r14, r15`). 


### x86_64函数调用传递参数使用的寄存器

`x86_64`了提高性能速度，将前`6`个参数通过寄存器传递，其顺序为`rdi`、`rsi`、`rdx`、`rcx`、`r8`、`r9`，第`7`个及以后的参数通过栈进行传递。

考虑如下的代码：

```c
long utilfunc(long a, long b, long c)
{
	long xx = a + 2;
	long yy = b + 3;
	long zz = c + 4;
	long sum = xx + yy + zz;

	return xx * yy * zz + sum;
}

long myfunc(long a, long b, long c, long d,
            long e, long f, long g, long h)
{
	long xx = a * b * c * d * e * f * g * h;
	long yy = a + b + c + d + e + f + g + h;
	long zz = utilfunc(xx, yy, xx % yy);

	return zz + 20;
}

int main(int argc, char **argv) {
	myfunc(1,2,3,4,5,6,7,8);

	return 0;
}
```

编译
```
# gcc -o a.out -g  main.c 
```
调用函数`myfunc`时，其栈如下：

<center>
![][5]
</center>

使用gdb调试如下：
```
[root@localhost stack]# gdb a.out 
GNU gdb (GDB) Red Hat Enterprise Linux 7.6.1-100.el7_4.1
Copyright (C) 2013 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.  Type "show copying"
and "show warranty" for details.
This GDB was configured as "x86_64-redhat-linux-gnu".
For bug reporting instructions, please see:
<http://www.gnu.org/software/gdb/bugs/>...
Reading symbols from /root/work/stack/a.out...done.
//查看代码行数信息
(gdb) l
16	{
17		long xx = a * b * c * d * e * f * g * h;
18		long yy = a + b + c + d + e + f + g + h;
19		long zz = utilfunc(xx, yy, xx % yy);
20	
21		return zz + 20;
22	}
23	
24	int main(int argc, char **argv) {
25		myfunc(1,2,3,4,5,6,7,8);
//在myfunc入口处设置断点
(gdb) b 25
Breakpoint 1 at 0x4005ef: file main.c, line 25.
(gdb) r
Starting program: /root/work/stack/a.out 

Breakpoint 1, main (argc=1, argv=0x7fffffffe358) at main.c:25
25		myfunc(1,2,3,4,5,6,7,8);
Missing separate debuginfos, use: debuginfo-install glibc-2.17-307.el7.1.x86_64
//进入到myfunc的入口处
(gdb) s 
myfunc (a=1, b=2, c=3, d=4, e=5, f=6, g=7, h=8) at main.c:17
17		long xx = a * b * c * d * e * f * g * h;
(gdb) bt
#0  myfunc (a=1, b=2, c=3, d=4, e=5, f=6, g=7, h=8) at main.c:17
#1  0x0000000000400625 in main (argc=1, argv=0x7fffffffe358) at main.c:25
//此时查看寄存器的值，rdi、rsi、rdx、rcx、r8、r9分别用于传递前6个参数。
(gdb) info reg
rax            0x4005e0	4195808
rbx            0x0	0
rcx            0x4	4
rdx            0x3	3
rsi            0x2	2
rdi            0x1	1
rbp            0x7fffffffe240	0x7fffffffe240
rsp            0x7fffffffe1f0	0x7fffffffe1f0
r8             0x5	5
r9             0x6	6
r10            0x7fffffffdda0	140737488346528
r11            0x7ffff7a2f460	140737348039776
r12            0x4003e0	4195296
r13            0x7fffffffe350	140737488347984
r14            0x0	0
r15            0x0	0
rip            0x400551	0x400551 <myfunc+32>
eflags         0x206	[ PF IF ]
cs             0x33	51
ss             0x2b	43
ds             0x0	0
es             0x0	0
fs             0x0	0
gs             0x0	0
//第7、8个参数通过栈来传递，
(gdb) x/40g $rbp
0x7fffffffe240:	0x00007fffffffe270	0x0000000000400625
0x7fffffffe250:	0x0000000000000007	0x0000000000000008 //第七个、第八个参数
0x7fffffffe260:	0x00007fffffffe358	0x0000000100000000
0x7fffffffe270:	0x0000000000000000	0x00007ffff7a2f555
0x7fffffffe280:	0x0000000000000000	0x00007fffffffe358
0x7fffffffe290:	0x0000000100000000	0x00000000004005e0
0x7fffffffe2a0:	0x0000000000000000	0xa8f1c884e4a0e964
0x7fffffffe2b0:	0x00000000004003e0	0x00007fffffffe350
0x7fffffffe2c0:	0x0000000000000000	0x0000000000000000
0x7fffffffe2d0:	0x570e377b21a0e964	0x570e27c10ebae964
0x7fffffffe2e0:	0x0000000000000000	0x0000000000000000
0x7fffffffe2f0:	0x0000000000000000	0x0000000000000000
0x7fffffffe300:	0x00007ffff7ffe150	0x0000000000000003
0x7fffffffe310:	0x0000000000000000	0x0000000000000000
0x7fffffffe320:	0x00000000004003e0	0x00007fffffffe350
0x7fffffffe330:	0x0000000000000000	0x0000000000400409
0x7fffffffe340:	0x00007fffffffe348	0x000000000000001c
0x7fffffffe350:	0x0000000000000001	0x00007fffffffe5c9
0x7fffffffe360:	0x0000000000000000	0x00007fffffffe5e0
0x7fffffffe370:	0x00007fffffffe5f1	0x00007fffffffe610
(gdb) x/40g $rsp
0x7fffffffe1f0:	0x0000000000000006	0x0000000000000005
0x7fffffffe200:	0x0000000000000004	0x0000000000000003
0x7fffffffe210:	0x0000000000000002	0x0000000000000001
0x7fffffffe220:	0x0000000000000000	0x0000000000000000
0x7fffffffe230:	0x0000000000000001	0x000000000040067d
0x7fffffffe240:	0x00007fffffffe270	0x0000000000400625
0x7fffffffe250:	0x0000000000000007	0x0000000000000008
0x7fffffffe260:	0x00007fffffffe358	0x0000000100000000
0x7fffffffe270:	0x0000000000000000	0x00007ffff7a2f555
0x7fffffffe280:	0x0000000000000000	0x00007fffffffe358
0x7fffffffe290:	0x0000000100000000	0x00000000004005e0
0x7fffffffe2a0:	0x0000000000000000	0xa8f1c884e4a0e964
0x7fffffffe2b0:	0x00000000004003e0	0x00007fffffffe350
0x7fffffffe2c0:	0x0000000000000000	0x0000000000000000
0x7fffffffe2d0:	0x570e377b21a0e964	0x570e27c10ebae964
0x7fffffffe2e0:	0x0000000000000000	0x0000000000000000
0x7fffffffe2f0:	0x0000000000000000	0x0000000000000000
0x7fffffffe300:	0x00007ffff7ffe150	0x0000000000000003
0x7fffffffe310:	0x0000000000000000	0x0000000000000000
0x7fffffffe320:	0x00000000004003e0	0x00007fffffffe350
(gdb) disas myfunc
Dump of assembler code for function myfunc:
   0x0000000000400531 <+0>:	push   %rbp
   0x0000000000400532 <+1>:	mov    %rsp,%rbp
   0x0000000000400535 <+4>:	sub    $0x50,%rsp
   0x0000000000400539 <+8>:	mov    %rdi,-0x28(%rbp)
   0x000000000040053d <+12>:	mov    %rsi,-0x30(%rbp)
   0x0000000000400541 <+16>:	mov    %rdx,-0x38(%rbp)
   0x0000000000400545 <+20>:	mov    %rcx,-0x40(%rbp)
   0x0000000000400549 <+24>:	mov    %r8,-0x48(%rbp)
   0x000000000040054d <+28>:	mov    %r9,-0x50(%rbp)
=> 0x0000000000400551 <+32>:	mov    -0x28(%rbp),%rax //还没有执行
   0x0000000000400555 <+36>:	imul   -0x30(%rbp),%rax
   0x000000000040055a <+41>:	imul   -0x38(%rbp),%rax
   0x000000000040055f <+46>:	imul   -0x40(%rbp),%rax
   0x0000000000400564 <+51>:	imul   -0x48(%rbp),%rax
   0x0000000000400569 <+56>:	imul   -0x50(%rbp),%rax
   0x000000000040056e <+61>:	imul   0x10(%rbp),%rax
   0x0000000000400573 <+66>:	imul   0x18(%rbp),%rax
   0x0000000000400578 <+71>:	mov    %rax,-0x8(%rbp)
   0x000000000040057c <+75>:	mov    -0x30(%rbp),%rax
   0x0000000000400580 <+79>:	mov    -0x28(%rbp),%rdx
   0x0000000000400584 <+83>:	add    %rax,%rdx
   0x0000000000400587 <+86>:	mov    -0x38(%rbp),%rax
   0x000000000040058b <+90>:	add    %rax,%rdx
   0x000000000040058e <+93>:	mov    -0x40(%rbp),%rax
   0x0000000000400592 <+97>:	add    %rax,%rdx
   0x0000000000400595 <+100>:	mov    -0x48(%rbp),%rax
   0x0000000000400599 <+104>:	add    %rax,%rdx
   0x000000000040059c <+107>:	mov    -0x50(%rbp),%rax
   0x00000000004005a0 <+111>:	add    %rax,%rdx
   0x00000000004005a3 <+114>:	mov    0x10(%rbp),%rax
   0x00000000004005a7 <+118>:	add    %rax,%rdx
   0x00000000004005aa <+121>:	mov    0x18(%rbp),%rax
   0x00000000004005ae <+125>:	add    %rdx,%rax
   0x00000000004005b1 <+128>:	mov    %rax,-0x10(%rbp)
   0x00000000004005b5 <+132>:	mov    -0x8(%rbp),%rax
   0x00000000004005b9 <+136>:	cqto   
   0x00000000004005bb <+138>:	idivq  -0x10(%rbp)
   0x00000000004005bf <+142>:	mov    -0x10(%rbp),%rcx
   0x00000000004005c3 <+146>:	mov    -0x8(%rbp),%rax
   0x00000000004005c7 <+150>:	mov    %rcx,%rsi
   0x00000000004005ca <+153>:	mov    %rax,%rdi
   0x00000000004005cd <+156>:	callq  0x4004cd <utilfunc>
   0x00000000004005d2 <+161>:	mov    %rax,-0x18(%rbp)
   0x00000000004005d6 <+165>:	mov    -0x18(%rbp),%rax
   0x00000000004005da <+169>:	add    $0x14,%rax
   0x00000000004005de <+173>:	leaveq 
   0x00000000004005df <+174>:	retq   
End of assembler dump.
```

### red zone


对于`leaf function`，`x86`下有一个优化，其特性依赖于 `red zone`,其官方解释为：

```
The 128-byte area beyond the location pointed to by %rsp is considered
to be reserved and shall not be modified by signal or interrupt handlers.
Therefore, functions may use this area for temporary data that is not
needed across function calls. In particular, leaf functions may use this
area for their entire stack frame, rather than adjusting the stack pointer
in the prologue and epilogue. This area is known as the red zone.
```

`leaf function`就是不会再调用其它函数的函数，上面的例子中，`utilfunc`就是一个`leaf function`。对于`leaf function`函数，由于它不会在调用其他函数，所以就不需要更改其`rsp`寄存器，免得函数返回时还要恢复`rsp`寄存器。

```
[root@localhost stack]# gdb a.out 
GNU gdb (GDB) Red Hat Enterprise Linux 7.6.1-100.el7_4.1
Copyright (C) 2013 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.  Type "show copying"
and "show warranty" for details.
This GDB was configured as "x86_64-redhat-linux-gnu".
For bug reporting instructions, please see:
<http://www.gnu.org/software/gdb/bugs/>...
Reading symbols from /root/work/stack/a.out...done.
(gdb) l 1
1	#include <stdio.h>
2	
3	long utilfunc(long a, long b, long c)
4	{
5		long xx = a + 2;
6		long yy = b + 3;
7		long zz = c + 4;
8		long sum = xx + yy + zz;
9	
10		return xx * yy * zz + sum;
(gdb) b 3
Breakpoint 1 at 0x4004dd: file main.c, line 3.
(gdb) r
Starting program: /root/work/stack/a.out 

Breakpoint 1, utilfunc (a=40320, b=36, c=0) at main.c:5
5		long xx = a + 2;
Missing separate debuginfos, use: debuginfo-install glibc-2.17-307.el7.1.x86_64
//通过rdi、rsi、rdx传递函数的三个参数
(gdb) info reg
rax            0x9d80	40320
rbx            0x0	0
rcx            0x24	36
rdx            0x0	0
rsi            0x24	36
rdi            0x9d80	40320
rbp            0x7fffffffe1e0	0x7fffffffe1e0
rsp            0x7fffffffe1e0	0x7fffffffe1e0
r8             0x5	5
r9             0x6	6
r10            0x7fffffffdda0	140737488346528
r11            0x7ffff7a2f460	140737348039776
r12            0x4003e0	4195296
r13            0x7fffffffe350	140737488347984
r14            0x0	0
r15            0x0	0
rip            0x4004dd	0x4004dd <utilfunc+16>
eflags         0x216	[ PF AF IF ]
cs             0x33	51
ss             0x2b	43
ds             0x0	0
es             0x0	0
fs             0x0	0
gs             0x0	0
//可以看到起汇编代码中没有用到rsp寄存器
(gdb) disas utilfunc
Dump of assembler code for function utilfunc:
   0x00000000004004cd <+0>:	push   %rbp
   0x00000000004004ce <+1>:	mov    %rsp,%rbp
   0x00000000004004d1 <+4>:	mov    %rdi,-0x28(%rbp)
   0x00000000004004d5 <+8>:	mov    %rsi,-0x30(%rbp)
   0x00000000004004d9 <+12>:	mov    %rdx,-0x38(%rbp)
=> 0x00000000004004dd <+16>:	mov    -0x28(%rbp),%rax
   0x00000000004004e1 <+20>:	add    $0x2,%rax
   0x00000000004004e5 <+24>:	mov    %rax,-0x8(%rbp)
   0x00000000004004e9 <+28>:	mov    -0x30(%rbp),%rax
   0x00000000004004ed <+32>:	add    $0x3,%rax
   0x00000000004004f1 <+36>:	mov    %rax,-0x10(%rbp)
   0x00000000004004f5 <+40>:	mov    -0x38(%rbp),%rax
   0x00000000004004f9 <+44>:	add    $0x4,%rax
   0x00000000004004fd <+48>:	mov    %rax,-0x18(%rbp)
   0x0000000000400501 <+52>:	mov    -0x10(%rbp),%rax
   0x0000000000400505 <+56>:	mov    -0x8(%rbp),%rdx
   0x0000000000400509 <+60>:	add    %rax,%rdx
   0x000000000040050c <+63>:	mov    -0x18(%rbp),%rax
   0x0000000000400510 <+67>:	add    %rdx,%rax
   0x0000000000400513 <+70>:	mov    %rax,-0x20(%rbp)
   0x0000000000400517 <+74>:	mov    -0x8(%rbp),%rax
   0x000000000040051b <+78>:	imul   -0x10(%rbp),%rax
   0x0000000000400520 <+83>:	imul   -0x18(%rbp),%rax
   0x0000000000400525 <+88>:	mov    %rax,%rdx
   0x0000000000400528 <+91>:	mov    -0x20(%rbp),%rax
   0x000000000040052c <+95>:	add    %rdx,%rax
   0x000000000040052f <+98>:	pop    %rbp
   0x0000000000400530 <+99>:	retq   
End of assembler dump.
```

当调用该叶子函数时，其栈如下：

<center>
![][6]
</center>


### -fomit-frame-pointer

实际上`rbp`不是必须的，如果编译器进行了优化，代码中就不会使用`rbp`寄存器了。

```
~/work/stack  # gcc -g -fomit-frame-pointer main.c  -o omit-frame-pointer
root@127.0.0.1::[08:18:07]::[Exit Code: 0] ->
~/work/stack  # gdb omit-frame-pointer 
GNU gdb (GDB) Red Hat Enterprise Linux 7.6.1-100.el7
Copyright (C) 2013 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.  Type "show copying"
and "show warranty" for details.
This GDB was configured as "x86_64-redhat-linux-gnu".
For bug reporting instructions, please see:
<http://www.gnu.org/software/gdb/bugs/>...
Reading symbols from /root/work/stack/omit-frame-pointer...done.
(gdb) l
15	            long e, long f, long g, long h)
16	{
17		long xx = a * b * c * d * e * f * g * h;
18		long yy = a + b + c + d + e + f + g + h;
19		long zz = utilfunc(xx, yy, xx % yy);
20	
21		return zz + 20;
22	}
23	
24	int main(int argc, char **argv) {
//通过传递-fomit-frame-pointer编译器参数，汇编代码中就不会用到rbp寄存器了。
(gdb) disas myfunc
Dump of assembler code for function myfunc:
   0x000000000040055d <+0>:	sub    $0x50,%rsp
   0x0000000000400561 <+4>:	mov    %rdi,0x28(%rsp)
   0x0000000000400566 <+9>:	mov    %rsi,0x20(%rsp)
   0x000000000040056b <+14>:	mov    %rdx,0x18(%rsp)
   0x0000000000400570 <+19>:	mov    %rcx,0x10(%rsp)
   0x0000000000400575 <+24>:	mov    %r8,0x8(%rsp)
   0x000000000040057a <+29>:	mov    %r9,(%rsp)
   0x000000000040057e <+33>:	mov    0x28(%rsp),%rax
   0x0000000000400583 <+38>:	imul   0x20(%rsp),%rax
   0x0000000000400589 <+44>:	imul   0x18(%rsp),%rax
   0x000000000040058f <+50>:	imul   0x10(%rsp),%rax
   0x0000000000400595 <+56>:	imul   0x8(%rsp),%rax
   0x000000000040059b <+62>:	imul   (%rsp),%rax
   0x00000000004005a0 <+67>:	imul   0x58(%rsp),%rax
   0x00000000004005a6 <+73>:	imul   0x60(%rsp),%rax
   0x00000000004005ac <+79>:	mov    %rax,0x48(%rsp)
   0x00000000004005b1 <+84>:	mov    0x20(%rsp),%rax
   0x00000000004005b6 <+89>:	mov    0x28(%rsp),%rdx
   0x00000000004005bb <+94>:	add    %rax,%rdx
   0x00000000004005be <+97>:	mov    0x18(%rsp),%rax
   0x00000000004005c3 <+102>:	add    %rax,%rdx
   0x00000000004005c6 <+105>:	mov    0x10(%rsp),%rax
   0x00000000004005cb <+110>:	add    %rax,%rdx
   0x00000000004005ce <+113>:	mov    0x8(%rsp),%rax
   0x00000000004005d3 <+118>:	add    %rax,%rdx
   0x00000000004005d6 <+121>:	mov    (%rsp),%rax
   0x00000000004005da <+125>:	add    %rax,%rdx
   0x00000000004005dd <+128>:	mov    0x58(%rsp),%rax
   0x00000000004005e2 <+133>:	add    %rax,%rdx
   0x00000000004005e5 <+136>:	mov    0x60(%rsp),%rax
   0x00000000004005ea <+141>:	add    %rdx,%rax
   0x00000000004005ed <+144>:	mov    %rax,0x40(%rsp)
   0x00000000004005f2 <+149>:	mov    0x48(%rsp),%rax
   0x00000000004005f7 <+154>:	cqto   
   0x00000000004005f9 <+156>:	idivq  0x40(%rsp)
   0x00000000004005fe <+161>:	mov    0x40(%rsp),%rcx
   0x0000000000400603 <+166>:	mov    0x48(%rsp),%rax
   0x0000000000400608 <+171>:	mov    %rcx,%rsi
   0x000000000040060b <+174>:	mov    %rax,%rdi
   0x000000000040060e <+177>:	callq  0x4004ed <utilfunc>
   0x0000000000400613 <+182>:	mov    %rax,0x38(%rsp)
   0x0000000000400618 <+187>:	mov    0x38(%rsp),%rax
   0x000000000040061d <+192>:	add    $0x14,%rax
   0x0000000000400621 <+196>:	add    $0x50,%rsp
   0x0000000000400625 <+200>:	retq   
End of assembler dump.
(gdb) disas utilfunc
Dump of assembler code for function utilfunc:
   0x00000000004004ed <+0>:	mov    %rdi,-0x28(%rsp)
   0x00000000004004f2 <+5>:	mov    %rsi,-0x30(%rsp)
   0x00000000004004f7 <+10>:	mov    %rdx,-0x38(%rsp)
   0x00000000004004fc <+15>:	mov    -0x28(%rsp),%rax
   0x0000000000400501 <+20>:	add    $0x2,%rax
   0x0000000000400505 <+24>:	mov    %rax,-0x8(%rsp)
   0x000000000040050a <+29>:	mov    -0x30(%rsp),%rax
   0x000000000040050f <+34>:	add    $0x3,%rax
   0x0000000000400513 <+38>:	mov    %rax,-0x10(%rsp)
   0x0000000000400518 <+43>:	mov    -0x38(%rsp),%rax
   0x000000000040051d <+48>:	add    $0x4,%rax
   0x0000000000400521 <+52>:	mov    %rax,-0x18(%rsp)
   0x0000000000400526 <+57>:	mov    -0x10(%rsp),%rax
   0x000000000040052b <+62>:	mov    -0x8(%rsp),%rdx
   0x0000000000400530 <+67>:	add    %rax,%rdx
   0x0000000000400533 <+70>:	mov    -0x18(%rsp),%rax
   0x0000000000400538 <+75>:	add    %rdx,%rax
   0x000000000040053b <+78>:	mov    %rax,-0x20(%rsp)
   0x0000000000400540 <+83>:	mov    -0x8(%rsp),%rax
   0x0000000000400545 <+88>:	imul   -0x10(%rsp),%rax
   0x000000000040054b <+94>:	imul   -0x18(%rsp),%rax
   0x0000000000400551 <+100>:	mov    %rax,%rdx
   0x0000000000400554 <+103>:	mov    -0x20(%rsp),%rax
   0x0000000000400559 <+108>:	add    %rdx,%rax
   0x000000000040055c <+111>:	retq   
End of assembler dump.
```



### 对于浮点数

函数参数中有浮点数的情况下，对于浮点数使用`xmm0`,`xmm1`,`xmm2`,`xmm3`到`xmm7`来传递。


考虑如下函数

```c
~/work/stack  # cat float.c 
#include <stdio.h>

long myfunc(long a, long b, long c,
	double d, long e, long f, double g, long h, long i, long j)
{
	long xx = a + 2 + e;
	long yy = b + 3 + f;
	long zz = c + 4 + h;
	long ww = i + j;
	double vv = d + g;
	long sum = xx + yy + zz + ww + vv;

	return xx * yy * zz + sum;
}

int main(int argc, char **argv) {
	myfunc(1,2,3,4.0,5,6,7.0,8, 9, 10);

	return 0;
}
r
```
gdb 效果如下：

```
~/work/stack  # gcc float.c -o float -g
root@127.0.0.1::[08:30:35]::[Exit Code: 0] ->
~/work/stack  # gdb float
GNU gdb (GDB) Red Hat Enterprise Linux 7.6.1-100.el7
Copyright (C) 2013 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.  Type "show copying"
and "show warranty" for details.
This GDB was configured as "x86_64-redhat-linux-gnu".
For bug reporting instructions, please see:
<http://www.gnu.org/software/gdb/bugs/>...
Reading symbols from /root/work/stack/float...done.
(gdb) l
8		long zz = c + 4 + h;
9		long ww = i + j;
10		double vv = d + g;
11		long sum = xx + yy + zz + ww + vv;
12	
13		return xx * yy * zz + sum;
14	}
15	
16	int main(int argc, char **argv) {
17		myfunc(1,2,3,4.0,5,6,7.0,8, 9, 10);
(gdb) l
18	
19		return 0;
20	}
(gdb) b myfunc
Breakpoint 1 at 0x400513: file float.c, line 6.
(gdb) r
Starting program: /root/work/stack/float 

Breakpoint 1, myfunc (a=1, b=2, c=3, d=4, e=5, f=6, g=7, h=8, i=9, j=10) at float.c:6
6		long xx = a + 2 + e;
Missing separate debuginfos, use: debuginfo-install glibc-2.17-196.el7.x86_64
可以看出rdi、rsi、rdx、rcx、r8、r9分别传递了前8个非浮点类型的参数。
(gdb) info reg
rax            0x4010000000000000	4616189618054758400
rbx            0x0	0
rcx            0x5	5
rdx            0x3	3
rsi            0x2	2
rdi            0x1	1
rbp            0x7fffffffe2f8	0x7fffffffe2f8
rsp            0x7fffffffe2f8	0x7fffffffe2f8
r8             0x6	6
r9             0x8	8
r10            0x7fffffffe110	140737488347408
r11            0x7ffff7a39b10	140737348082448
r12            0x400400	4195328
r13            0x7fffffffe410	140737488348176
r14            0x0	0
r15            0x0	0
rip            0x400513	0x400513 <myfunc+38>
eflags         0x212	[ AF IF ]
cs             0x33	51
ss             0x2b	43
ds             0x0	0
es             0x0	0
fs             0x0	0
gs             0x0	0
//而第四个参数和第七个参数为浮点数类型，他们分别通过寄存器xmm0和xmm1来传递。
(gdb) p /x $xmm0
$2 = {v4_float = {0x0, 0x2, 0x0, 0x0}, v2_double = {0x4, 0x0}, v16_int8 = {0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x10, 0x40, 0x0, 0x0, 0x0, 0x0, 0x0, 
    0x0, 0x0, 0x0}, v8_int16 = {0x0, 0x0, 0x0, 0x4010, 0x0, 0x0, 0x0, 0x0}, v4_int32 = {0x0, 0x40100000, 0x0, 0x0}, v2_int64 = {
    0x4010000000000000, 0x0}, uint128 = 0x00000000000000004010000000000000}
(gdb) p /x $xmm1
$3 = {v4_float = {0x0, 0x2, 0x0, 0x0}, v2_double = {0x7, 0x0}, v16_int8 = {0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x1c, 0x40, 0x0, 0x0, 0x0, 0x0, 0x0, 
    0x0, 0x0, 0x0}, v8_int16 = {0x0, 0x0, 0x0, 0x401c, 0x0, 0x0, 0x0, 0x0}, v4_int32 = {0x0, 0x401c0000, 0x0, 0x0}, v2_int64 = {
    0x401c000000000000, 0x0}, uint128 = 0x0000000000000000401c000000000000}
(gdb) p /x $xmm2
$4 = {v4_float = {0x0, 0x0, 0x0, 0x0}, v2_double = {0x0, 0x0}, v16_int8 = {0x0 <repeats 16 times>}, v8_int16 = {0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 
    0x0, 0x0}, v4_int32 = {0x0, 0x0, 0x0, 0x0}, v2_int64 = {0x0, 0x0}, uint128 = 0x00000000000000000000000000000000}
(gdb) p /x $xmm3
$5 = {v4_float = {0x0, 0x0, 0x0, 0x0}, v2_double = {0x0, 0x8000000000000000}, v16_int8 = {0x0 <repeats 15 times>, 0xff}, v8_int16 = {0x0, 
    0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0xff00}, v4_int32 = {0x0, 0x0, 0x0, 0xff000000}, v2_int64 = {0x0, 0xff00000000000000}, 
  uint128 = 0xff000000000000000000000000000000}
(gdb) disas myfunc
Dump of assembler code for function myfunc:
   0x00000000004004ed <+0>:	push   %rbp
   0x00000000004004ee <+1>:	mov    %rsp,%rbp
   0x00000000004004f1 <+4>:	mov    %rdi,-0x38(%rbp)
   0x00000000004004f5 <+8>:	mov    %rsi,-0x40(%rbp)
   0x00000000004004f9 <+12>:	mov    %rdx,-0x48(%rbp)
   0x00000000004004fd <+16>:	movsd  %xmm0,-0x50(%rbp)
   0x0000000000400502 <+21>:	mov    %rcx,-0x58(%rbp)
   0x0000000000400506 <+25>:	mov    %r8,-0x60(%rbp)
   0x000000000040050a <+29>:	movsd  %xmm1,-0x68(%rbp)
   0x000000000040050f <+34>:	mov    %r9,-0x70(%rbp)
=> 0x0000000000400513 <+38>:	mov    -0x38(%rbp),%rax
   0x0000000000400517 <+42>:	lea    0x2(%rax),%rdx
   0x000000000040051b <+46>:	mov    -0x58(%rbp),%rax
   0x000000000040051f <+50>:	add    %rdx,%rax
   0x0000000000400522 <+53>:	mov    %rax,-0x8(%rbp)
   0x0000000000400526 <+57>:	mov    -0x40(%rbp),%rax
   0x000000000040052a <+61>:	lea    0x3(%rax),%rdx
   0x000000000040052e <+65>:	mov    -0x60(%rbp),%rax
   0x0000000000400532 <+69>:	add    %rdx,%rax
   0x0000000000400535 <+72>:	mov    %rax,-0x10(%rbp)
   0x0000000000400539 <+76>:	mov    -0x48(%rbp),%rax
   0x000000000040053d <+80>:	lea    0x4(%rax),%rdx
   0x0000000000400541 <+84>:	mov    -0x70(%rbp),%rax
   0x0000000000400545 <+88>:	add    %rdx,%rax
   0x0000000000400548 <+91>:	mov    %rax,-0x18(%rbp)
   0x000000000040054c <+95>:	mov    0x18(%rbp),%rax
   0x0000000000400550 <+99>:	mov    0x10(%rbp),%rdx
   0x0000000000400554 <+103>:	add    %rdx,%rax
   0x0000000000400557 <+106>:	mov    %rax,-0x20(%rbp)
   0x000000000040055b <+110>:	movsd  -0x50(%rbp),%xmm0
   0x0000000000400560 <+115>:	addsd  -0x68(%rbp),%xmm0
   0x0000000000400565 <+120>:	movsd  %xmm0,-0x28(%rbp)
   0x000000000040056a <+125>:	mov    -0x10(%rbp),%rax
   0x000000000040056e <+129>:	mov    -0x8(%rbp),%rdx
   0x0000000000400572 <+133>:	add    %rax,%rdx
   0x0000000000400575 <+136>:	mov    -0x18(%rbp),%rax
   0x0000000000400579 <+140>:	add    %rax,%rdx
   0x000000000040057c <+143>:	mov    -0x20(%rbp),%rax
   0x0000000000400580 <+147>:	add    %rdx,%rax
   0x0000000000400583 <+150>:	cvtsi2sd %rax,%xmm0
   0x0000000000400588 <+155>:	addsd  -0x28(%rbp),%xmm0
   0x000000000040058d <+160>:	cvttsd2si %xmm0,%rax
   0x0000000000400592 <+165>:	mov    %rax,-0x30(%rbp)
   0x0000000000400596 <+169>:	mov    -0x8(%rbp),%rax
   0x000000000040059a <+173>:	imul   -0x10(%rbp),%rax
   0x000000000040059f <+178>:	imul   -0x18(%rbp),%rax
   0x00000000004005a4 <+183>:	mov    %rax,%rdx
   0x00000000004005a7 <+186>:	mov    -0x30(%rbp),%rax
   0x00000000004005ab <+190>:	add    %rdx,%rax
   0x00000000004005ae <+193>:	pop    %rbp
   0x00000000004005af <+194>:	retq   
End of assembler dump.

```

### 参考文档：

* https://eli.thegreenplace.net/2011/09/06/stack-frame-layout-on-x86-64/
* https://software.intel.com/sites/default/files/article/402129/mpx-linux64-abi.pdf


  [1]: ./stack1.png "stack1"
  [2]: ./stack2.png "stack2"
  [3]: ./stack3.png "stack3"
  [4]: ./stack4.png "stack4"
  [5]: ./stack-x86-64.png "stack-x86-64"
  [6]: ./stack-x86-64-redzone.png "stack-x86-64-redzone"

