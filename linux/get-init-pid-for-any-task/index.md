
本文题目为『**获取容器中init进程的pid**』，其实说的还不够详细。其实容器中的进程都单独运行在一个独立的`pid namespace`中，而我们有时需要在顶级的`pid namespace`中获取其`init`进程对应的在顶级`pid namespace`的`pid`。

本文简要介绍了完成这个任务的一种方法。

<!--more-->

### 实现方法

我们注意到[man 7 pid_namespaces](http://man7.org/linux/man-pages/man7/pid_namespaces.7.html)有如下一段描述：

```
   Miscellaneous
       When a process ID is passed over a UNIX domain socket to a process in
       a different PID namespace (see the description of SCM_CREDENTIALS in
       unix(7)), it is translated into the corresponding PID value in the
       receiving process's PID namespace.
```

什么意思呢？简单翻译一下：

当通过`Unix domain socket`进行发送`UNIX credentials`到不同的`pid namespace`中的进程时，对应的pid号会被转换成再接受进程所在的`pid namespace`中的进程号。

所以，我们可以使用如下办法完成任务：

* 新建一个进程A，建立一个`unix domain socket`
* fork 进程B，将B添加到目标`pid namespace`中
* B 通过`unix domain socket`发送`UNIX credentials`到A，发送的pid设置为1
* A解析出收到的pid号就是我们想要的

### 代码实现

```c
#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <stdbool.h>
#include <sys/epoll.h>
#include <wait.h>

#define SEND_CREDS_OK 0
#define SEND_CREDS_NOTSK 1
#define SEND_CREDS_FAIL 2
static bool recv_creds(int sock, struct ucred *cred, char *v);
static int wait_for_pid(pid_t pid);
static int send_creds(int sock, struct ucred *cred, char v, bool pingfirst);
static int send_creds_clone_wrapper(void *arg);


static int send_creds_clone_wrapper(void *arg)
{
	struct ucred cred;
	char v;
	int sock = *(int*)arg;

	cred.uid = 0;
	cred.gid = 0;
	cred.pid = 1;

	v = '1';
	if (send_creds(sock, &cred, v, true) != SEND_CREDS_OK)
		return 1;
	return 0;
}

static int wait_for_pid(pid_t pid)
{
	int status, ret;

	if (pid < 0)
		return -1;

again:
	ret = waitpid(pid, &status, 0);
	if (ret == -1) {
		if (errno = EINTR)
			goto again;
		return -1;
	}

	if (ret != pid)
		goto again;

	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		return -1;

	return 0;
}

/*
 * clone a task which switches to @task's namespace and writes '1'.
 * over a unix sock so we can read the task's reaper's pid in our
 * namespace
 *
 * Note: glibc's fork() does not respect pidns, which can lead to failed
 * assertions inside glibc (and thus failed forks) if the child's pid in
 * the pidns and the parent pid outside are identical. Using clone prevents
 * this issue.
 */
static void write_task_init_pid_exit(int sock, pid_t target)
{
	char fnam[100];
	pid_t pid;
	int fd, ret;
	size_t stack_size = sysconf(_SC_PAGESIZE);
	void *stack = alloca(stack_size);

	ret = snprintf(fnam, sizeof(fnam), "/proc/%d/ns/pid", (int)target);
	if (ret < 0 || ret >= sizeof(fnam))
		_exit(1);

	fd = open(fnam, O_RDONLY);
	if (fd < 0) {
		perror("write_task_init_pid_exit open of ns/pid" );
		_exit(1);
	}

	if (setns(fd, 0)) {
		perror("write_task_init_pid_exit setns 1");
		close(fd);
		_exit(1);
	}

	pid = clone(send_creds_clone_wrapper, stack+stack_size, SIGCHLD, &sock);
	if (pid < 0)
		_exit(1);

	if (pid != 0) {
		if (!wait_for_pid(pid))
			_exit(1);
		_exit(0);
	}
}

static pid_t get_init_pid_for_task(pid_t task)
{
	int sock[2];
	pid_t pid;
	pid_t ret = -1;
	char v = '0';
	struct ucred cred;

	if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sock) < 0 ) {
		perror("socketpair");
		return -1;
	}

	pid = fork();

	if (pid < 0)
		goto out;

	if (!pid) {
		// Child process
		close(sock[1]);
		write_task_init_pid_exit(sock[0], task);
		_exit(0);
	}

	if (!recv_creds(sock[1], &cred, &v))
		goto out;

	ret = cred.pid;

out:
	close(sock[0]);
	close(sock[1]);

	if (pid > 0)
		wait_for_pid(pid);

	return ret;
}

void usage(int argc, char **argv)
{
	printf("Usage:\n");
	printf("\t%s pid\n", argv[1]);
}

int main(int argc, char **argv)
{
	pid_t result;
	pid_t target;

	if (argc != 2) {
		usage(argc, argv);
		exit(0);
	}

	target = (pid_t)atoi(argv[1]);
	result = get_init_pid_for_task(target);

	printf("pid %d 's init pid is %d\n", (int)target, (int)result);
}



#define POLLIN_SET ( EPOLLIN | EPOLLHUP | EPOLLRDHUP )

static bool wait_for_sock(int sock, int timeout)
{
	struct epoll_event ev;
	int epfd, ret, now, starttime, deltatime, saved_errno;

	if ((starttime = time(NULL)) < 0)
		return false;

	if ((epfd = epoll_create(1)) < 0) {
		printf("%s\n", "Failed to create epoll socket: %m.");
		return false;
	}

	ev.events = POLLIN_SET;
	ev.data.fd = sock;
	if (epoll_ctl(epfd, EPOLL_CTL_ADD, sock, &ev) < 0) {
		printf("%s\n", "Failed adding socket to epoll: %m.");
		close(epfd);
		return false;
	}

again:
	if ((now = time(NULL)) < 0) {
		close(epfd);
		return false;
	}

	deltatime = (starttime + timeout) - now;
	if (deltatime < 0) { // timeout
		errno = 0;
		close(epfd);
		return false;
	}
	ret = epoll_wait(epfd, &ev, 1, 1000*deltatime + 1);
	if (ret < 0 && errno == EINTR)
		goto again;
	saved_errno = errno;
	close(epfd);

	if (ret <= 0) {
		errno = saved_errno;
		return false;
	}
	return true;
}

static int msgrecv(int sockfd, void *buf, size_t len)
{
	if (!wait_for_sock(sockfd, 2))
		return -1;
	return recv(sockfd, buf, len, MSG_DONTWAIT);
}

static int send_creds(int sock, struct ucred *cred, char v, bool pingfirst)
{
	struct msghdr msg = { 0 };
	struct iovec iov;
	struct cmsghdr *cmsg;
	char cmsgbuf[CMSG_SPACE(sizeof(*cred))];
	char buf[1];
	buf[0] = 'p';

	if (pingfirst) {
		if (msgrecv(sock, buf, 1) != 1) {
			printf("%s\n", "Error getting reply from server over socketpair.");
			return SEND_CREDS_FAIL;
		}
	}

	msg.msg_control = cmsgbuf;
	msg.msg_controllen = sizeof(cmsgbuf);

	cmsg = CMSG_FIRSTHDR(&msg);
	cmsg->cmsg_len = CMSG_LEN(sizeof(struct ucred));
	cmsg->cmsg_level = SOL_SOCKET;
	cmsg->cmsg_type = SCM_CREDENTIALS;
	memcpy(CMSG_DATA(cmsg), cred, sizeof(*cred));

	msg.msg_name = NULL;
	msg.msg_namelen = 0;

	buf[0] = v;
	iov.iov_base = buf;
	iov.iov_len = sizeof(buf);
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;

	if (sendmsg(sock, &msg, 0) < 0) {
		printf("Failed at sendmsg: %s.\n",strerror(errno));
		if (errno == 3)
			return SEND_CREDS_NOTSK;
		return SEND_CREDS_FAIL;
	}

	return SEND_CREDS_OK;
}

static bool recv_creds(int sock, struct ucred *cred, char *v)
{
	struct msghdr msg = { 0 };
	struct iovec iov;
	struct cmsghdr *cmsg;
	char cmsgbuf[CMSG_SPACE(sizeof(*cred))];
	char buf[1];
	int ret;
	int optval = 1;

	*v = '1';

	cred->pid = -1;
	cred->uid = -1;
	cred->gid = -1;

	if (setsockopt(sock, SOL_SOCKET, SO_PASSCRED, &optval, sizeof(optval)) == -1) {
		printf("Failed to set passcred: %s\n", strerror(errno));
		return false;
	}
	buf[0] = '1';
	if (write(sock, buf, 1) != 1) {
		printf("Failed to start write on scm fd: %s\n", strerror(errno));
		return false;
	}

	msg.msg_name = NULL;
	msg.msg_namelen = 0;
	msg.msg_control = cmsgbuf;
	msg.msg_controllen = sizeof(cmsgbuf);

	iov.iov_base = buf;
	iov.iov_len = sizeof(buf);
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;

	if (!wait_for_sock(sock, 2)) {
		printf("Timed out waiting for scm_cred: %s\n", strerror(errno));
		return false;
	}
	ret = recvmsg(sock, &msg, MSG_DONTWAIT);
	if (ret < 0) {
		printf("Failed to receive scm_cred: %s\n", strerror(errno));
		return false;
	}

	cmsg = CMSG_FIRSTHDR(&msg);

	if (cmsg && cmsg->cmsg_len == CMSG_LEN(sizeof(struct ucred)) &&
			cmsg->cmsg_level == SOL_SOCKET &&
			cmsg->cmsg_type == SCM_CREDENTIALS) {
		memcpy(cred, CMSG_DATA(cmsg), sizeof(*cred));
	}
	*v = buf[0];

	return true;
}
```

### 编译运行

```bash
# # 将源码保存为main.c
# gcc -o get_init_pid  main.c 
# docker top 9ce36bf4bb30
UID                 PID                 PPID                C                   STIME               TTY                 TIME                CMD
root                3244                3228                0                   14:22               pts/1               00:00:00            /bin/bash
root                3312                3286                0                   14:22               ?                   00:00:00            sleep 3400
root                3313                3286                0                   14:22               ?                   00:00:00            sleep 3400
root                3314                3286                0                   14:22               ?                   00:00:00            sleep 3400
root                3315                3286                0                   14:22               ?                   00:00:00            sleep 3400
# ./get_init_pid 3312
pid 3312 's init pid is 3244
# ./get_init_pid 3315
pid 3315 's init pid is 3244
# ./get_init_pid 3244
pid 3244 's init pid is 3244
# ./get_init_pid 1
pid 1 's init pid is 1
# ./get_init_pid 2
pid 2 's init pid is 1
```

### 参考文章

* http://man7.org/linux/man-pages/man7/unix.7.html
* http://man7.org/linux/man-pages/man7/pid_namespaces.7.html
