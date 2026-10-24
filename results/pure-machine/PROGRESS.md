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

`Machine.CompletionContract` separately states what an actual `written`
acknowledgment means: the complete preceding logical writes have reached the
TCP stack, including native queue-limit splits. This applies to prefixes without
an interrupted native write; failed writes retain the weaker ordered-prefix
guarantee. It does not mean that a peer application consumed the response.
The completion-contract audits check 17 theorems on both Lean versions.

The final history contract strengthens `Dispatch` with
`histories next = histories first ++ [event]`. Each progress event is therefore
the actual next observed event, with neither omitted intermediate events nor
hypothetical substitutions. Both-version history-contract audit results preserve
the exact strengthened source hashes.
