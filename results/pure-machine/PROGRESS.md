# Generic conditional progress

`Machine.ResponsiveContract` states that every pending write, polling job or
finalizer eventually has a next matching reactor dispatch at a later abstract
observation. The dispatch may report failure or closure. It assumes native
scheduler/network fairness and termination/resolution of external work. It does
not promise progress for an unresolved application promise or a stopped process.

`responsive_descent` is a kernel proof: an application-proved decreasing natural
rank, combined with that generic responsiveness premise, eventually reaches the
application-specified terminal event. The application must prove descent; the
native contract contains no parser, HTTP response or completion predicate.

Fresh audits on Lean 4.26.0 and 4.35.0 check 16 kernel theorems. This addition
changes no C FFI or adapter execution behavior.
