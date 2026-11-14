# check blocks run after every plan and apply and warn (without blocking) when an invariant is
# violated.

# Without close_after the close step has nothing to wait for, so the bastion is deleted straight
# after it is created, before any role run gets through it.
check "close_after_is_set" {
  assert {
    condition     = !var.configure || var.close_after != null
    error_message = "configure is true but close_after is not set: the session closes as soon as it opens. Pass every role call that uses ansible_hosts, such as [module.python[*].run_ids]."
  }
}
