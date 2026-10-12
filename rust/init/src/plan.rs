// The boot plan: vrxinit's decisions, pure and host-testable. The
// side-effecting half (mounts, exec) lives in main and runs only on
// the target; THIS module answers, for a kernel cmdline, exactly what
// PID 1 does and in what order.

/// One step vrxinit takes before handing the system to systemd.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Mount proc at /proc.
    MountProc,
    /// Mount sysfs at /sys.
    MountSys,
    /// Mount devtmpfs at /dev.
    MountDev,
    /// Ensure /tmp/vrx exists (the runtime directory: sockets, pipes).
    RuntimeDir,
    /// Run a shell on the console (VRX_DEBUG only: no getty ships).
    DebugConsole,
}

/// The boot plan derived from the kernel command line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootPlan {
    pub steps: Vec<Step>,
    /// vrx.debug was on the cmdline.
    pub debug: bool,
}

/// Derive the plan from a kernel command line (the contents of
/// /proc/cmdline).
pub fn plan(cmdline: &str) -> BootPlan {
    let debug = cmdline
        .split_whitespace()
        .any(|token| token == "vrx.debug" || token.starts_with("vrx.debug="));
    let mut steps = vec![
        Step::MountProc,
        Step::MountSys,
        Step::MountDev,
        Step::RuntimeDir,
    ];
    if debug {
        steps.push(Step::DebugConsole);
    }
    BootPlan { steps, debug }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plain_boot_mounts_the_basics_in_order() {
        let plan = plan("console=ttyS0 root=/dev/mmcblk0p2");
        assert!(!plan.debug);
        assert_eq!(
            plan.steps,
            vec![
                Step::MountProc,
                Step::MountSys,
                Step::MountDev,
                Step::RuntimeDir,
            ]
        );
    }

    #[test]
    fn vrx_debug_enables_the_console() {
        let plan = plan("console=ttyS0 vrx.debug root=/dev/mmcblk0p2");
        assert!(plan.debug);
        assert_eq!(plan.steps.last(), Some(&Step::DebugConsole));
    }

    #[test]
    fn vrx_debug_with_a_value_still_counts() {
        assert!(plan("vrx.debug=1").debug);
        assert!(plan("vrx.debug").debug);
        assert!(
            !plan("root=vrx.debuggy").debug,
            "prefix alone is not the flag"
        );
    }
}
