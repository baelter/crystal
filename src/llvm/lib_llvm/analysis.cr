require "./types"

lib LibLLVM
  fun verify_module = LLVMVerifyModule(m : ModuleRef, action : LLVM::VerifierFailureAction, out_message : Char**) : Bool
  fun verify_function = LLVMVerifyFunction(fn : ValueRef, action : LLVM::VerifierFailureAction) : Bool
end
