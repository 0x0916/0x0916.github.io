
`eventfd` 是`linux`特有的`API`，用于通知/等待机制的实现,该函数一般有两个使用场景：

* （1）用来实现用户态进程(线程)间的**等待/通知(`wait/notify`)** 机制
* （2）内核用来通知用户态应用程序某个事件的发生。

第一种场景，本文会给一个示例程序进行说明;第二种场景，可以通过cgroup中的事件通知机制进行了解和学习。

<!--more-->

### eventfd 函数
该函数的原型为：

```c
#include <sys/eventfd.h>

int eventfd(unsigned int initval, int flags);
```
这个函数会创建一个事件对象 (`eventfd object`), 用来实现进程(线程)间的等待/通知(`wait/notify`) 机制。 内核会为这个对象维护一个`64位`的计数器(`uint64_t`)。并且使用第一个参数(`initval`)初始化这个计数器`counter`，一般初始化设置为0。

调用这个函数就会返回一个新的文件描述符(`event object`)。2.6.27版本开始可以按位设置第二个参数(`flags`)。	

第二个参数`flags`可以设置如下参数`EFD_CLOECEX`、`EFD_NONBLOCK`、`EFD_SEMAPHORE`。

| flags | 含义|
| --- | ---|
|EFD_CLOEXEC|为新创建的描述符设置FD_CLOEXEC flag|
|EFD_NONBLOCK|为新创建的描述符设置O_NONBLOCK flag|
|EFD_SEMAPHORE|semaphore-like semantics for reads|

后面会重点介绍一下`EFD_SEMAPHORE`,它决定创建的事件对象 (`eventfd object`)的读的行为，

### read操作

如果计数值`counter`的值不为0，读取成功，获得到该值。如果`counter`的值为0，非阻塞模式，会直接返回失败，并把`errno`的值指纹`EINVAL`。如果为阻塞模式，一直会阻塞到`counter`为非0位置。

* 如果没有设置 `EFD_SEMAPHORE`标记，当`counter`不为`0`时，`read`操作会返回`counter`的值，并将`counter`的值重置为`0`.
* 如果设置了`EFD_SEMAPHORE`标记，当`counter`不为`0`时，`read`操作会返回`1`，并将`counter`的值减少`1`.
				 
				 
### write操作

`write`操作会增加`8字节`的整数在计数器`counter`上，如果`counter`的值达到`0xfffffffffffffffe`时，就会阻塞。直到`counter`的值被`read`。阻塞和非阻塞情况同上面`read`一样。


更详细的介绍，请参考：http://man7.org/linux/man-pages/man2/eventfd.2.html



### 示例程序

以下示例程序通过父进程`read`操作，子进程`write`操作来演示`eventfd`的行为，同时我们可以使用选项`-s`来控制是否设置标记`EFD_SEMAPHORE`。

> 该示例程序是根据`man`手册上的程序修改而来的。


```c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/eventfd.h>
#include <stdint.h>		/* Definitioin of uint64_t */

#define  handle_err(msg)  \
	do { perror(msg); exit(EXIT_FAILURE); } while (0)

static void usage(char *pname) {
	fprintf(stderr, "Usage: %s [options] <num>...\n", pname);
	fprintf(stderr, "Options can be:\n");
	fprintf(stderr, "    -s   semaphore-like semantics\n");
	exit(EXIT_FAILURE);
}

int main(int argc, char **argv) {
	int		efd, j;
	uint64_t	u;
	ssize_t		s;

	int flags = 0;
	int opt;

	while ((opt = getopt(argc, argv, "s")) != -1) {
		switch (opt) {
		case 's': flags |= EFD_SEMAPHORE;	break;
		default:  usage(argv[0]);
		}
	}
	if (optind >= argc)
		usage(argv[0]);

	efd = eventfd(0, flags);
	if (efd == -1)
		handle_err("eventfd");

	switch (fork()) {
	case -1:
		handle_err("fork");
	case 0: /*child */
		for (j = optind; j < argc; j++) {
			printf("Child writing %s to efd\n", argv[j]);
			u = strtoull(argv[j], NULL, 0);
			s = write(efd, &u, sizeof(uint64_t));
			if (s != sizeof(uint64_t))
				handle_err("write");
			sleep(1);
		}

		printf("Child completed write loop\n");
		exit(EXIT_SUCCESS);
	default: /* parent */
		while (1) {
			s = read(efd, &u, sizeof(uint64_t));
			if (s != sizeof(uint64_t))
				handle_err("read");
			printf("Parent read %llu (0x%llx) from efd\n",
				(unsigned long long)u, (unsigned long long)u);
			sleep(2);
		}
	}
}

```

未指定`EFD_SEMAPHORE`标记时：

```bash
# ./test_eventfd 1 2 3 4 5
Child writing 1 to efd
Parent read 1 (0x1) from efd
Child writing 2 to efd
Child writing 3 to efd
Parent read 2 (0x2) from efd
Child writing 4 to efd
Parent read 7 (0x7) from efd
Child writing 5 to efd
Child completed write loop
Parent read 5 (0x5) from efd
```
可以看出，每次`read`时都读取了`counter`的当前值，并将`counter`清`0`.


指定`EFD_SEMAPHORE`标记时：

```bash
# ./test_eventfd -s 1 2 3 4 5
Child writing 1 to efd
Parent read 1 (0x1) from efd
Child writing 2 to efd
Child writing 3 to efd
Parent read 1 (0x1) from efd
Child writing 4 to efd
Parent read 1 (0x1) from efd
Child writing 5 to efd
Child completed write loop
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
Parent read 1 (0x1) from efd
```

可以看出，每次读取到的值为`1`，只要`counter`不为`0`，就可以一直读取。

### 参考文档

http://man7.org/linux/man-pages/man2/eventfd.2.html
