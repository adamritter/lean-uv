import LeanUV.ProgressContract
import LeanUV.AdapterContract
import LeanUV.Machine
import LeanUV.Contract

#print axioms LeanUV.TCP.Contract.prefix_refl
#print axioms LeanUV.TCP.Contract.prefix_trans
#print axioms LeanUV.TCP.Contract.output_prefix
#print axioms LeanUV.TCP.Contract.closed_write_released
#print axioms LeanUV.TCP.Contract.graceful_exact_output
#print axioms LeanUV.TCP.Machine.replay_invariant
#print axioms LeanUV.TCP.Machine.replay_length
#print axioms LeanUV.TCP.Machine.scheduled_invariant
#print axioms LeanUV.TCP.Machine.execution_invariant
#print axioms LeanUV.TCP.Machine.execution_scheduled_invariant

#print axioms LeanUV.TCP.Machine.adapter_output_prefix
#print axioms LeanUV.TCP.Machine.adapter_graceful_output
#print axioms LeanUV.TCP.Machine.adapter_input_prefix
#print axioms LeanUV.TCP.Machine.finalizers_weight
#print axioms LeanUV.TCP.Machine.adapter_finalizer_weight

#print axioms LeanUV.TCP.Machine.responsive_descent

#print axioms LeanUV.TCP.Machine.acknowledged_command_prefix
