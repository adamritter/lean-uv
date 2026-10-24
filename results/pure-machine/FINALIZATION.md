# Finalization at a cooperative yield

A pure machine may relinquish ownership and emit a cleanup command when its fuel reaches zero. Ordinary `perform` can yield before invoking work; closure then discards that pending work. This is valid cancellation for ordinary jobs but invalid for cleanup whose ownership has already been relinquished.

`finalize` executes prompt one-shot work immediately, including at zero fuel, and commits its reply before yielding. It must return `some` synchronously. Returning `none` is a failed finalizer rather than a polling job. External application cleanup must itself return promptly; the contract proves invocation ordering, not the application's resource-release implementation.

The socket regression acquires exactly 255 resources, signals readiness, allows SIGTERM to queue, and reaches finalization at zero fuel. All 255 resources must be reported as released exactly once. An explicitly labelled diagnostic control using ordinary `perform` instead loses the cleanup; `finalizer-negative-control.json` preserves this negative result. ASan/UBSan runs cover the fixed path.
