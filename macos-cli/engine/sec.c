#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include "sec.h"
#include <unistd.h>
#include <fcntl.h>
#include <grp.h>

#include "params.h"

#ifdef __linux__

#include <sys/prctl.h>
#include <sys/syscall.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
// __X32_SYSCALL_BIT defined in linux/unistd.h
#include <linux/unistd.h>
#include <syscall.h>
#include <errno.h>

/************ SECCOMP ************/

// block most of the undesired syscalls to harden against code execution
static long blocked_syscalls[] = {
#ifdef SYS_execv
SYS_execv,
#endif
SYS_execve,
#ifdef SYS_execveat
SYS_execveat,
#endif
#ifdef SYS_exec_with_loader
SYS_exec_with_loader,
#endif
#ifdef SYS_clone
SYS_clone,
#endif
#ifdef SYS_clone2
SYS_clone2,
#endif
#ifdef SYS_clone3
SYS_clone3,
#endif
#ifdef SYS_osf_execve
SYS_osf_execve,
#endif
#ifdef SYS_fork
SYS_fork,
#endif
#ifdef SYS_vfork
SYS_vfork,
#endif
#ifdef SYS_uselib
SYS_uselib,
#endif
#ifdef SYS_unlink
SYS_unlink,
#endif
SYS_unlinkat,
#ifdef SYS_chmod
SYS_chmod,
#endif
SYS_fchmod,SYS_fchmodat,
#ifdef SYS_chown
SYS_chown,
#endif
#ifdef SYS_chown32
SYS_chown32,
#endif
SYS_fchown,
#ifdef SYS_fchown32
SYS_fchown32,
#endif
#ifdef SYS_lchown
SYS_lchown,
#endif
#ifdef SYS_lchown32
SYS_lchown32,
#endif
SYS_fchownat,
#ifdef SYS_symlink
SYS_symlink,
#endif
SYS_symlinkat,
#ifdef SYS_link
SYS_link,
#endif
SYS_linkat,
SYS_truncate,
#ifdef SYS_truncate64
SYS_truncate64,
#endif
SYS_ftruncate,
#ifdef SYS_ftruncate64
SYS_ftruncate64,
#endif
#ifdef SYS_mknod
SYS_mknod,
#endif
SYS_mknodat,
#ifdef SYS_mkdir
SYS_mkdir,
#endif
SYS_mkdirat,
#ifdef SYS_rmdir
SYS_rmdir,
#endif
#ifdef SYS_rename
SYS_rename,
#endif
#ifdef SYS_renameat2
SYS_renameat2,
#endif
#ifdef SYS_renameat
SYS_renameat,
#endif
#ifdef SYS_readdir
SYS_readdir,
#endif
#ifdef SYS_getdents
SYS_getdents,
#endif
#ifdef SYS_getdents64
SYS_getdents64,
#endif
#ifdef SYS_process_vm_readv
SYS_process_vm_readv,
#endif
#ifdef SYS_process_vm_writev
SYS_process_vm_writev,
#endif
#ifdef SYS_process_madvise
SYS_process_madvise,
#endif
#ifdef SYS_tkill
SYS_tkill,
#endif
#ifdef SYS_tgkill
SYS_tgkill,
#endif
SYS_kill, SYS_ptrace
};
#define BLOCKED_SYSCALL_COUNT (sizeof(blocked_syscalls)/sizeof(*blocked_syscalls))

static void set_filter(struct sock_filter *filter, __u16 code, __u8 jt, __u8 jf, __u32 k)
{
	filter->code = code;
	filter->jt = jt;
	filter->jf = jf;
	filter->k = k;
}
// deny all blocked syscalls
static bool set_seccomp(void)
{
#ifdef __X32_SYSCALL_BIT
 #define SECCOMP_PROG_SIZE (6 + BLOCKED_SYSCALL_COUNT)
#else
 #define SECCOMP_PROG_SIZE (5 + BLOCKED_SYSCALL_COUNT)
#endif
	struct sock_filter sockf[SECCOMP_PROG_SIZE];
	struct sock_fprog prog = { .len = SECCOMP_PROG_SIZE, .filter = sockf };
	int i,idx=0;

	set_filter(&prog.filter[idx++], BPF_LD + BPF_W + BPF_ABS, 0, 0, arch_nr);
#ifdef __X32_SYSCALL_BIT
	// x86 only
	set_filter(&prog.filter[idx++], BPF_JMP + BPF_JEQ + BPF_K, 0, 3 + BLOCKED_SYSCALL_COUNT, ARCH_NR); // fail
	set_filter(&prog.filter[idx++], BPF_LD + BPF_W + BPF_ABS, 0, 0, syscall_nr);
	set_filter(&prog.filter[idx++], BPF_JMP + BPF_JGT + BPF_K, 1 + BLOCKED_SYSCALL_COUNT, 0, __X32_SYSCALL_BIT - 1); // fail
#else
	set_filter(&prog.filter[idx++], BPF_JMP + BPF_JEQ + BPF_K, 0, 2 + BLOCKED_SYSCALL_COUNT, ARCH_NR); // fail
	set_filter(&prog.filter[idx++], BPF_LD + BPF_W + BPF_ABS, 0, 0, syscall_nr);
#endif

/*
	// ! THIS IS NOT WORKING BECAUSE perror() in glibc dups() stderr
	set_filter(&prog.filter[idx++], BPF_JMP + BPF_JEQ + BPF_K, 0, 3, SYS_write); // special check for write call
	set_filter(&prog.filter[idx++], BPF_LD + BPF_W + BPF_ABS, 0, 0, syscall_arg(0)); // fd
	set_filter(&prog.filter[idx++], BPF_JMP + BPF_JGT + BPF_K, 2 + BLOCKED_SYSCALL_COUNT, 0, 2); // 1 - stdout, 2 - stderr. greater are bad
	set_filter(&prog.filter[idx++], BPF_LD + BPF_W + BPF_ABS, 0, 0, syscall_nr); // reload syscall_nr
*/
	for(i=0 ; i<BLOCKED_SYSCALL_COUNT ; i++)
	{
		set_filter(&prog.filter[idx++], BPF_JMP + BPF_JEQ + BPF_K, BLOCKED_SYSCALL_COUNT-i, 0, blocked_syscalls[i]);
	}
	set_filter(&prog.filter[idx++], BPF_RET + BPF_K, 0, 0, SECCOMP_RET_ALLOW); // success case
	set_filter(&prog.filter[idx++], BPF_RET + BPF_K, 0, 0, SECCOMP_RET_KILL); // fail case
	return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) >= 0;
}

bool sec_harden(void)
{
	bool bRes = true;
	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
	{
		DLOG_PERROR("PR_SET_NO_NEW_PRIVS(prctl)");
		bRes = false;
	}
#if ARCH_NR!=0
	if (!set_seccomp())
	{
		DLOG_PERROR("seccomp");
		if (errno==EINVAL) DLOG_ERR("seccomp: this can be safely ignored if kernel does not support seccomp\n");
		bRes = false;
	}
#endif
	return bRes;
}




bool checkpcap(uint64_t caps)
{
	if (!caps) return true; // no special caps reqd

	struct __user_cap_header_struct ch = {_LINUX_CAPABILITY_VERSION_3, getpid()};
	struct __user_cap_data_struct cd[2];
	uint32_t c0 = (uint32_t)caps;
	uint32_t c1 = (uint32_t)(caps>>32);

	return !capget(&ch,cd) && (cd[0].effective & c0)==c0 && (cd[1].effective & c1)==c1;
}
bool setpcap(uint64_t caps)
{
	struct __user_cap_header_struct ch = {_LINUX_CAPABILITY_VERSION_3, getpid()};
	struct __user_cap_data_struct cd[2];

	cd[0].effective = cd[0].permitted = (uint32_t)caps;
	cd[0].inheritable = 0;
	cd[1].effective = cd[1].permitted = (uint32_t)(caps>>32);
	cd[1].inheritable = 0;

	return !capset(&ch,cd);
}
int getmaxcap(void)
{
	int maxcap = CAP_LAST_CAP;
	FILE *F = fopen("/proc/sys/kernel/cap_last_cap", "r");
	if (F)
	{
		int n = fscanf(F, "%d", &maxcap);
		fclose(F);
	}
	return maxcap;

}
bool dropcaps(void)
{
	uint64_t caps = (1<<CAP_NET_ADMIN)|(1<<CAP_NET_RAW);
	int maxcap = getmaxcap();

	if (setpcap(caps|(1<<CAP_SETPCAP)))
	{
		for (int cap = 0; cap <= maxcap; cap++)
		{
			if (prctl(PR_CAPBSET_DROP, cap)<0)
			{
				DLOG_ERR("could not drop bound cap %d\n", cap);
				DLOG_PERROR("cap_drop_bound");
			}
		}
	}
	// now without CAP_SETPCAP
	if (!setpcap(caps))
	{
		DLOG_PERROR("setpcap");
		return checkpcap(caps);
	}
	return true;
}

#endif // __linux__

#ifndef __CYGWIN__

#ifndef __linux__
bool sec_harden(void)
{
	// noop
	return true;
}
#endif

bool can_drop_root(void)
{
#ifdef __linux__
	// has some caps
	return checkpcap((1<<CAP_SETUID)|(1<<CAP_SETGID));
#else
	// effective root
	return !geteuid();
#endif
}

bool droproot(uid_t uid, const char *user, const gid_t *gid, int gid_count)
{
	if (gid_count<1)
	{
		DLOG_ERR("droproot: no groups specified");
		return false;
	}
#ifdef __linux__
	if (prctl(PR_SET_KEEPCAPS, 1L))
	{
		DLOG_PERROR("prctl(PR_SET_KEEPCAPS)");
		return false;
	}
#endif
	if (user)
	{
		// macos has strange supp gid handling. they cache only 16 groups and fail setgroups if more than 16 gids specified.
		// better to leave it to the os
		if (initgroups(user,gid[0]))
		{
			DLOG_PERROR("initgroups");
			return false;
		}
	}
	else
	{
		if (setgroups(gid_count,gid))
		{
			DLOG_PERROR("setgroups");
			return false;
		}
	}
	if (setgid(gid[0]))
	{
		DLOG_PERROR("setgid");
		return false;
	}
	if (setuid(uid))
	{
		DLOG_PERROR("setuid");
		return false;
	}
	return true;
}

void print_id(void)
{
 int i,N;
 gid_t g[128];

 DLOG_CONDUP("Running as UID=%u GID=",getuid());
 N=getgroups(sizeof(g)/sizeof(*g),g);
 if (N>0)
 {
	for(i=0;i<N;i++)
		DLOG_CONDUP(i==(N-1) ? "%u" : "%u,", g[i]);
	DLOG_CONDUP("\n");
 }
 else
	DLOG_CONDUP("%u\n",getgid());
}

#endif



void daemonize(void)
{
	int pid;
#ifdef __CYGWIN__
	char *cwd = get_current_dir_name();
#endif

	pid = fork();
	if (pid == -1)
	{
		DLOG_PERROR("fork");
		exit(2);
	}
	else if (pid != 0)
		exit(0);

#ifdef __CYGWIN__
	chdir(get_current_dir_name());
#endif

	if (setsid() == -1)
		exit(2);
	if (chdir("/") == -1)
		exit(2);
	close(STDIN_FILENO);
	close(STDOUT_FILENO);
	close(STDERR_FILENO);
	/* redirect fd's 0,1,2 to /dev/null */
	open("/dev/null", O_RDWR);
	int fd;
	/* stdin */
	fd = dup(0);
	/* stdout */
	fd = dup(0);
	/* stderror */
}

bool writepid(const char *filename)
{
	FILE *F;
	if (!(F = fopen(filename, "w")))
		return false;
	fprintf(F, "%d", getpid());
	fclose(F);
	return true;
}
