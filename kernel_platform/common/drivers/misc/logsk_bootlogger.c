// SPDX-License-Identifier: GPL-2.0-only
/*
 * LOGSK boot logger.
 *
 * Debug-only helper for devices that freeze before Android userspace can
 * collect pstore/logcat. It writes printk snapshots to /cache/LOGSK once the
 * cache partition is mounted. It intentionally treats /sdcard as userspace
 * territory; a host/ADB script can copy /cache/LOGSK there later.
 */

#define pr_fmt(fmt) "logsk: " fmt

#include <linux/atomic.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/fcntl.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kmsg_dump.h>
#include <linux/mount.h>
#include <linux/mutex.h>
#include <linux/namei.h>
#include <linux/slab.h>
#include <linux/timekeeping.h>
#include <linux/user_namespace.h>
#include <linux/vmalloc.h>
#include <linux/workqueue.h>

#define LOGSK_DIR			"/cache/LOGSK"
#define LOGSK_LIVE_PATH			LOGSK_DIR "/kmsg-live.txt"
#define LOGSK_STATUS_PATH		LOGSK_DIR "/status.txt"
#define LOGSK_DUMP_PATH			LOGSK_DIR "/kmsg-dump.txt"
#define LOGSK_BUF_SIZE			(512 * 1024)
#define LOGSK_INITIAL_DELAY_MS		1000
#define LOGSK_INTERVAL_MS		5000
#define LOGSK_MAX_ATTEMPTS		72

static DEFINE_MUTEX(logsk_lock);
static unsigned int logsk_attempts;
static atomic_t logsk_dump_requested = ATOMIC_INIT(0);
static atomic_t logsk_dump_reason = ATOMIC_INIT(KMSG_DUMP_UNDEF);

static void logsk_work_fn(struct work_struct *work);
static DECLARE_DELAYED_WORK(logsk_work, logsk_work_fn);

static int logsk_mkdir(const char *path, umode_t mode)
{
	struct dentry *dentry;
	struct path parent;
	int ret;

	dentry = kern_path_create(AT_FDCWD, path, &parent, LOOKUP_DIRECTORY);
	if (IS_ERR(dentry)) {
		ret = PTR_ERR(dentry);
		return ret == -EEXIST ? 0 : ret;
	}

	ret = vfs_mkdir(&init_user_ns, d_inode(parent.dentry), dentry, mode);
	done_path_create(&parent, dentry);

	return ret == -EEXIST ? 0 : ret;
}

static bool logsk_dir_ready(void)
{
	struct path path;
	int ret;

	ret = kern_path(LOGSK_DIR, LOOKUP_DIRECTORY, &path);
	if (!ret) {
		path_put(&path);
		return true;
	}

	ret = logsk_mkdir(LOGSK_DIR, 0700);
	if (!ret)
		return true;

	if (ret != -ENOENT && ret != -EROFS && ret != -EACCES)
		pr_debug("directory unavailable: %d\n", ret);

	return false;
}

static int logsk_write_file(const char *path, const char *buf, size_t len)
{
	struct file *file;
	loff_t pos = 0;
	ssize_t written;
	int ret = 0;

	file = filp_open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (IS_ERR(file))
		return PTR_ERR(file);

	written = kernel_write(file, buf, len, &pos);
	if (written < 0) {
		ret = written;
	} else if ((size_t)written != len) {
		ret = -EIO;
	} else {
		ret = vfs_fsync(file, 0);
	}

	filp_close(file, NULL);
	return ret;
}

static int logsk_write_status(void)
{
	char status[256];
	int len;
	int reason = atomic_read(&logsk_dump_reason);

	len = scnprintf(status, sizeof(status),
			"LOGSK_BOOTLOGGER=1\n"
			"target=%s\n"
			"attempt=%u\n"
			"boottime_sec=%lld\n"
			"dump_requested=%d\n"
			"last_dump_reason=%s\n",
			LOGSK_DIR, logsk_attempts,
			(long long)ktime_get_boottime_seconds(),
			atomic_read(&logsk_dump_requested),
			kmsg_dump_reason_str(reason));

	return logsk_write_file(LOGSK_STATUS_PATH, status, len);
}

static int logsk_write_kmsg(const char *path)
{
	struct kmsg_dump_iter iter;
	char *buf;
	size_t len = 0;
	int ret;

	buf = vzalloc(LOGSK_BUF_SIZE);
	if (!buf)
		return -ENOMEM;

	kmsg_dump_rewind(&iter);
	if (!kmsg_dump_get_buffer(&iter, true, buf, LOGSK_BUF_SIZE, &len) ||
	    !len) {
		ret = -ENODATA;
		goto out;
	}

	ret = logsk_write_file(path, buf, len);

out:
	vfree(buf);
	return ret;
}

static void logsk_work_fn(struct work_struct *work)
{
	int ret = 0;

	mutex_lock(&logsk_lock);

	if (logsk_dir_ready()) {
		ret = logsk_write_status();
		if (ret)
			pr_debug("status write failed: %d\n", ret);

		ret = logsk_write_kmsg(LOGSK_LIVE_PATH);
		if (ret)
			pr_debug("kmsg live write failed: %d\n", ret);

		if (atomic_xchg(&logsk_dump_requested, 0)) {
			ret = logsk_write_kmsg(LOGSK_DUMP_PATH);
			if (ret)
				pr_debug("kmsg dump write failed: %d\n", ret);
		}
	}

	logsk_attempts++;
	if (logsk_attempts < LOGSK_MAX_ATTEMPTS)
		schedule_delayed_work(&logsk_work,
				      msecs_to_jiffies(LOGSK_INTERVAL_MS));

	mutex_unlock(&logsk_lock);
}

static void logsk_kmsg_dump(struct kmsg_dumper *dumper,
			    enum kmsg_dump_reason reason)
{
	/*
	 * Do not perform filesystem I/O from panic context. Pstore/ramoops is
	 * the right backend there; LOGSK is for periodic snapshots on /cache.
	 */
	if (reason == KMSG_DUMP_PANIC)
		return;

	atomic_set(&logsk_dump_reason, reason);
	atomic_set(&logsk_dump_requested, 1);
	schedule_delayed_work(&logsk_work, 0);
}

static struct kmsg_dumper logsk_dumper = {
	.dump = logsk_kmsg_dump,
	.max_reason = KMSG_DUMP_SHUTDOWN,
};

static int __init logsk_init(void)
{
	int ret;

	ret = kmsg_dump_register(&logsk_dumper);
	if (ret)
		pr_warn("kmsg dumper registration failed: %d\n", ret);

	schedule_delayed_work(&logsk_work,
			      msecs_to_jiffies(LOGSK_INITIAL_DELAY_MS));
	pr_info("enabled, writing printk snapshots to %s\n", LOGSK_DIR);
	return 0;
}
late_initcall(logsk_init);
