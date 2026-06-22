#include <llvm/Config/llvm-config.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/Module.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm-c/TargetMachine.h>
#include <algorithm>
#include <vector>

using namespace llvm;

#define LLVM_VERSION_GE(major, minor) \
  (LLVM_VERSION_MAJOR > (major) || LLVM_VERSION_MAJOR == (major) && LLVM_VERSION_MINOR >= (minor))

#if !LLVM_VERSION_GE(9, 0)
#include <llvm/IR/DIBuilder.h>
#endif

#if LLVM_VERSION_GE(16, 0)
#define makeArrayRef ArrayRef
#endif

#if !LLVM_VERSION_GE(18, 0)
typedef struct LLVMOpaqueOperandBundle *LLVMOperandBundleRef;
DEFINE_SIMPLE_CONVERSION_FUNCTIONS(OperandBundleDef, LLVMOperandBundleRef)
#endif

extern "C" {

// Sort a module's functions by name so object-file output is deterministic
// regardless of the order functions were emitted into the module. Incremental
// codegen's seed/force phases append pruned-but-live functions after the main
// walk, which otherwise perturbs `.text` and `.eh_frame` layout (and the FDE
// order) versus a cold build, breaking byte-for-byte incremental==cold identity.
// Function order is semantically irrelevant, so this is a safe normalization.
void LLVMExtSortModuleFunctions(LLVMModuleRef M) {
  unwrap(M)->getFunctionList().sort([](const Function &A, const Function &B) {
    return A.getName() < B.getName();
  });
}

// Likewise sort global variables by name. `.rodata` (string/constant globals) is
// laid out in global-list order, which the incremental seed perturbs the same way.
// All Crystal globals are named (string content / type), so this is deterministic.
void LLVMExtSortModuleGlobals(LLVMModuleRef M) {
  Module *Mod = unwrap(M);
#if LLVM_VERSION_GE(16, 0)
  // getGlobalList() is private since LLVM 16; insertGlobalVariable /
  // removeFromParent are the public replacements. Remove all globals and
  // re-insert them in sorted order.
  std::vector<GlobalVariable *> Globals;
  for (GlobalVariable &G : Mod->globals())
    Globals.push_back(&G);
  std::stable_sort(Globals.begin(), Globals.end(),
                   [](GlobalVariable *A, GlobalVariable *B) {
                     return A->getName() < B->getName();
                   });
  for (GlobalVariable *G : Globals)
    G->removeFromParent();
  for (GlobalVariable *G : Globals)
    Mod->insertGlobalVariable(G);
#else
  // Pre-16 the global list is public and directly sortable, like functions.
  Mod->getGlobalList().sort([](const GlobalVariable &A, const GlobalVariable &B) {
    return A.getName() < B.getName();
  });
#endif
}

#if !LLVM_VERSION_GE(9, 0)
LLVMMetadataRef LLVMExtDIBuilderCreateEnumerator(LLVMDIBuilderRef Builder,
                                                 const char *Name, size_t NameLen,
                                                 int64_t Value,
                                                 LLVMBool IsUnsigned) {
  return wrap(unwrap(Builder)->createEnumerator({Name, NameLen}, Value,
                                                IsUnsigned != 0));
}

void LLVMExtClearCurrentDebugLocation(LLVMBuilderRef B) {
  unwrap(B)->SetCurrentDebugLocation(DebugLoc::get(0, 0, nullptr));
}
#endif

#if !LLVM_VERSION_GE(18, 0)
LLVMOperandBundleRef LLVMExtCreateOperandBundle(const char *Tag, size_t TagLen,
                                                LLVMValueRef *Args,
                                                unsigned NumArgs) {
  return wrap(new OperandBundleDef(std::string(Tag, TagLen),
                                   makeArrayRef(unwrap(Args), NumArgs)));
}

void LLVMExtDisposeOperandBundle(LLVMOperandBundleRef Bundle) {
  delete unwrap(Bundle);
}

LLVMValueRef
LLVMExtBuildCallWithOperandBundles(LLVMBuilderRef B, LLVMTypeRef Ty,
                                   LLVMValueRef Fn, LLVMValueRef *Args,
                                   unsigned NumArgs, LLVMOperandBundleRef *Bundles,
                                   unsigned NumBundles, const char *Name) {
  FunctionType *FTy = unwrap<FunctionType>(Ty);
  SmallVector<OperandBundleDef, 8> OBs;
  for (auto *Bundle : makeArrayRef(Bundles, NumBundles)) {
    OperandBundleDef *OB = unwrap(Bundle);
    OBs.push_back(*OB);
  }
  return wrap(unwrap(B)->CreateCall(
      FTy, unwrap(Fn), makeArrayRef(unwrap(Args), NumArgs), OBs, Name));
}

LLVMValueRef LLVMExtBuildInvokeWithOperandBundles(
    LLVMBuilderRef B, LLVMTypeRef Ty, LLVMValueRef Fn, LLVMValueRef *Args,
    unsigned NumArgs, LLVMBasicBlockRef Then, LLVMBasicBlockRef Catch,
    LLVMOperandBundleRef *Bundles, unsigned NumBundles, const char *Name) {
  SmallVector<OperandBundleDef, 8> OBs;
  for (auto *Bundle : makeArrayRef(Bundles, NumBundles)) {
    OperandBundleDef *OB = unwrap(Bundle);
    OBs.push_back(*OB);
  }
  return wrap(unwrap(B)->CreateInvoke(
      unwrap<FunctionType>(Ty), unwrap(Fn), unwrap(Then), unwrap(Catch),
      makeArrayRef(unwrap(Args), NumArgs), OBs, Name));
}
#endif

#if !LLVM_VERSION_GE(18, 0)
static TargetMachine *unwrap(LLVMTargetMachineRef P) {
  return reinterpret_cast<TargetMachine *>(P);
}

void LLVMExtSetTargetMachineGlobalISel(LLVMTargetMachineRef T, LLVMBool Enable) {
  unwrap(T)->setGlobalISel(Enable);
}
#endif

} // extern "C"
