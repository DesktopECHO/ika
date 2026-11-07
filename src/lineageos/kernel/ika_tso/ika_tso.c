// SPDX-License-Identifier: GPL-2.0
/*
 * ika_tso: runs the threads of chosen apps with Apple's TSO memory model.
 *
 * Apple CPUs have an implementation-defined ACTLR_EL1 bit that switches a core
 * to x86-style total store ordering. An Asahi Linux host lets a KVM guest own
 * ACTLR_EL1 (each vCPU has its own copy), so the guest can set the bit itself.
 * This module sets it when a CPU switches to a task whose UID is in "uids" and
 * clears it for every other task, so only those apps pay for TSO (about half
 * the single-thread speed of an M1 Pro). Some apps race on the Arm memory
 * model: 3DMark Sling Shot Extreme livelocks in its lock-free task queue.
 *
 * ika_tso_apps.sh writes the UIDs. On other CPUs, where the bit means
 * something else, the module loads but does nothing.
 */
#include <linux/cred.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/sched.h>
#include <linux/smp.h>
#include <linux/uidgid.h>
#include <asm/cputype.h>
#include <asm/sysreg.h>
#include <trace/events/sched.h>

#define ACTLR_APPLE_TSO (1UL << 1)
#define MAX_UIDS 16

static unsigned int uids[MAX_UIDS];
static int nr_uids;
module_param_array(uids, uint, &nr_uids, 0644);
MODULE_PARM_DESC(uids, "UIDs whose threads run with the TSO memory model");

static bool active;

static bool wants_tso(struct task_struct *t)
{
	int i, n = min(READ_ONCE(nr_uids), MAX_UIDS);
	unsigned int uid;

	if (!n || !t->mm)
		return false;
	uid = __kuid_val(task_uid(t));
	for (i = 0; i < n; i++)
		if (READ_ONCE(uids[i]) == uid)
			return true;
	return false;
}

static void set_tso(bool on)
{
	u64 v = read_sysreg(actlr_el1);

	if (!!(v & ACTLR_APPLE_TSO) == on)
		return;
	write_sysreg(on ? v | ACTLR_APPLE_TSO : v & ~ACTLR_APPLE_TSO, actlr_el1);
	isb();
}

static void probe_sched_switch(void *data, bool preempt, struct task_struct *prev,
			       struct task_struct *next, unsigned int prev_state)
{
	set_tso(wants_tso(next));
}

static void clear_tso(void *unused)
{
	set_tso(false);
}

static int __init ika_tso_init(void)
{
	int ret;

	if (MIDR_IMPLEMENTOR(read_cpuid_id()) != ARM_CPU_IMP_APPLE)
		return 0;
	ret = register_trace_sched_switch(probe_sched_switch, NULL);
	if (ret)
		return ret;
	active = true;
	return 0;
}

static void __exit ika_tso_exit(void)
{
	if (!active)
		return;
	unregister_trace_sched_switch(probe_sched_switch, NULL);
	tracepoint_synchronize_unregister();
	on_each_cpu(clear_tso, NULL, 1);
}

module_init(ika_tso_init);
module_exit(ika_tso_exit);
MODULE_DESCRIPTION("Apple TSO memory model for chosen apps");
MODULE_LICENSE("GPL");
