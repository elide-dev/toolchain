# RUN: %clang %cflags -no-pie %s -Wl,-q -o %t.exe
# RUN: llvm-dwarfdump --verify %t.exe
# RUN: llvm-bolt %t.exe -o %t.bolt --update-debug-sections --skip-funcs=main --cu-processing-batch-size=1 --debug-thread-count=1
# RUN: llvm-dwarfdump --verify %t.bolt
# RUN: llvm-bolt %t.exe -o %t.moved --update-debug-sections --cu-processing-batch-size=1 --debug-thread-count=1
# RUN: llvm-dwarfdump --verify %t.moved
# RUN: %clang %cflags -no-pie -Wa,--defsym,INVALID_REF=1 %s -Wl,-q -o %t.bad
# RUN: not llvm-dwarfdump --verify %t.bad 2>&1 | FileCheck %s --check-prefix=BAD
# RUN: llvm-bolt %t.bad -o %t.bad.bolt --update-debug-sections --skip-funcs=main --cu-processing-batch-size=1 --debug-thread-count=1
# RUN: not llvm-dwarfdump --verify %t.bad.bolt 2>&1 | FileCheck %s --check-prefix=BAD
# BAD: DIE contains invalid DWARF expression

## Location-list references must follow DIE layout, including nested expressions,
## expression branch targets, relative/absolute calls and the generic zero type.
## INVALID_REF deliberately names a subprogram as a type and must remain invalid.
.text
.globl main
.type main,@function
main:
  movl $18, %edi
.globl debug_quality_live
debug_quality_live:
  nop
  xorl %eax, %eax
  ret
.Lmain_end:
.size main, .Lmain_end-main
.section .note.GNU-stack,"",@progbits
.section .debug_abbrev,"",@progbits

.uleb128 1
.uleb128 17
.byte 1
.uleb128 17
.uleb128 1
.uleb128 18
.uleb128 7
.uleb128 3
.uleb128 8
.byte 0,0
.uleb128 2
.uleb128 36
.byte 0
.uleb128 3
.uleb128 8
.uleb128 11
.uleb128 11
.uleb128 62
.uleb128 11
.byte 0,0
.uleb128 3
.uleb128 46
.byte 1
.uleb128 3
.uleb128 8
.uleb128 17
.uleb128 1
.uleb128 18
.uleb128 7
.uleb128 63
.uleb128 25
.byte 0,0
.uleb128 4
.uleb128 52
.byte 0
.uleb128 3
.uleb128 8
.uleb128 73
.uleb128 19
.uleb128 2
.uleb128 23
.byte 0,0
.uleb128 5
.uleb128 54
.byte 0
.uleb128 2
.uleb128 24
.byte 0,0
.uleb128 6
.uleb128 17
.byte 1
.uleb128 3
.uleb128 8
.byte 0,0
.uleb128 7
.uleb128 5
.byte 0
.uleb128 3
.uleb128 8
.uleb128 73
.uleb128 19
.uleb128 2
.uleb128 24
.byte 0,0
.byte 0
.section .debug_info,"",@progbits
.Lcu0:
.long .Lcu0_end-.Lcu0_body
.Lcu0_body:
.short 5
.byte 1,8
.long 0
.uleb128 1
.quad main
.quad .Lmain_end-main
.asciz "loclist.c"
.Ltype:
.uleb128 2
.asciz "int"
.byte 4,5
.Lmain_die:
.uleb128 3
.asciz "main"
.quad main
.quad .Lmain_end-main
.Lparameter:
.uleb128 7
.asciz "argument"
.long .Ltype-.Lcu0
.uleb128 1
.byte 0x55
.uleb128 4
.asciz "gnu_parameter"
.long .Ltype-.Lcu0
.long .Lloc_gnu_parameter-.Lloclists
.uleb128 4
.asciz "gnu_converted"
.long .Ltype-.Lcu0
.long .Lloc_gnu_converted-.Lloclists
.uleb128 4
.asciz "gnu_reinterpreted"
.long .Ltype-.Lcu0
.long .Lloc_gnu_reinterpreted-.Lloclists
.uleb128 4
.asciz "gnu_generic"
.long .Ltype-.Lcu0
.long .Lloc_gnu_generic-.Lloclists
.uleb128 4
.asciz "gnu_constant"
.long .Ltype-.Lcu0
.long .Lloc_gnu_constant-.Lloclists
.uleb128 4
.asciz "gnu_register"
.long .Ltype-.Lcu0
.long .Lloc_gnu_register-.Lloclists
.uleb128 4
.asciz "converted"
.long .Ltype-.Lcu0
.long .Lloc_converted-.Lloclists
.uleb128 4
.asciz "reinterpreted"
.long .Ltype-.Lcu0
.long .Lloc_reinterpreted-.Lloclists
.uleb128 4
.asciz "generic"
.long .Ltype-.Lcu0
.long .Lloc_generic-.Lloclists
.uleb128 4
.asciz "nested"
.long .Ltype-.Lcu0
.long .Lloc_nested-.Lloclists
.uleb128 4
.asciz "relative_call"
.long .Ltype-.Lcu0
.long .Lloc_relative_call-.Lloclists
.uleb128 4
.asciz "absolute_call"
.long .Ltype-.Lcu0
.long .Lloc_absolute_call-.Lloclists
.uleb128 4
.asciz "branch"
.long .Ltype-.Lcu0
.long .Lloc_branch-.Lloclists
.uleb128 4
.asciz "typed_constant"
.long .Ltype-.Lcu0
.long .Lloc_typed_constant-.Lloclists
.byte 0
.Lprocedure:
.uleb128 5
.uleb128 1
.byte 0x42
.byte 0
.Lcu0_end:
.Lcu1:
.long .Lcu1_end-.Lcu1_body
.Lcu1_body:
.short 5
.byte 1,8
.long 0
.uleb128 6
.asciz "procedure.c"
.Lprocedure2:
.uleb128 5
.uleb128 1
.byte 0x42
.byte 0
.Lcu1_end:
.set .Ldebug_info_begin,.Lcu0
.ifdef INVALID_REF
.set TYPE_REF,.Lmain_die-.Lcu0
.set PARAM_REF,.Lmain_die-.Lcu0
.else
.set TYPE_REF,.Ltype-.Lcu0
.set PARAM_REF,.Lparameter-.Lcu0
.endif
.section .debug_loclists,"",@progbits
.Lloclists:
.long .Lloc_end-.Lloc_body
.Lloc_body:
.short 5
.byte 8,0
.long 0
.Lloc_gnu_parameter:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_gnu_parameter_end-.Lexpr_gnu_parameter
.Lexpr_gnu_parameter:
.byte 0xfa
.long PARAM_REF
.byte 0x9f
.Lexpr_gnu_parameter_end:
.byte 0
.Lloc_gnu_converted:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_gnu_converted_end-.Lexpr_gnu_converted
.Lexpr_gnu_converted:
.byte 0x75,0,0xf7
.uleb128 TYPE_REF
.byte 0x9f
.Lexpr_gnu_converted_end:
.byte 0
.Lloc_gnu_reinterpreted:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_gnu_reinterpreted_end-.Lexpr_gnu_reinterpreted
.Lexpr_gnu_reinterpreted:
.byte 0x75,0,0xf7
.uleb128 TYPE_REF
.byte 0xf9
.uleb128 TYPE_REF
.byte 0x9f
.Lexpr_gnu_reinterpreted_end:
.byte 0
.Lloc_gnu_generic:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_gnu_generic_end-.Lexpr_gnu_generic
.Lexpr_gnu_generic:
.byte 0x75,0,0xf7,0,0xf9,0,0x9f
.Lexpr_gnu_generic_end:
.byte 0
.Lloc_gnu_constant:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_gnu_constant_end-.Lexpr_gnu_constant
.Lexpr_gnu_constant:
.byte 0xf4
.uleb128 TYPE_REF
.byte 4
.long 18
.byte 0x9f
.Lexpr_gnu_constant_end:
.byte 0
.Lloc_gnu_register:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_gnu_register_end-.Lexpr_gnu_register
.Lexpr_gnu_register:
.byte 0xf5
.uleb128 5
.uleb128 TYPE_REF
.byte 0x9f
.Lexpr_gnu_register_end:
.byte 0
.Lloc_converted:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_converted_end-.Lexpr_converted
.Lexpr_converted:
.byte 0x75,0,0xa8
.uleb128 TYPE_REF
.byte 0x9f
.Lexpr_converted_end:
.byte 0
.Lloc_reinterpreted:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_reinterpreted_end-.Lexpr_reinterpreted
.Lexpr_reinterpreted:
.byte 0x75,0,0xa8
.uleb128 TYPE_REF
.byte 0xa9
.uleb128 TYPE_REF
.byte 0x9f
.Lexpr_reinterpreted_end:
.byte 0
.Lloc_generic:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_generic_end-.Lexpr_generic
.Lexpr_generic:
.byte 0x75,0,0xa8,0,0xa9,0,0x9f
.Lexpr_generic_end:
.byte 0
.Lloc_nested:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_nested_end-.Lexpr_nested
.Lexpr_nested:
.byte 0xa3
.uleb128 .Lnested_end-.Lnested_begin
.Lnested_begin:
.byte 0x42,0xa8
.uleb128 TYPE_REF
.byte 0xa9
.uleb128 TYPE_REF
.Lnested_end:
.byte 0x9f
.Lexpr_nested_end:
.byte 0
.Lloc_relative_call:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_relative_call_end-.Lexpr_relative_call
.Lexpr_relative_call:
.byte 0x99
.long .Lprocedure-.Lcu0
.byte 0x9f
.Lexpr_relative_call_end:
.byte 0
.Lloc_absolute_call:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_absolute_call_end-.Lexpr_absolute_call
.Lexpr_absolute_call:
.byte 0x9a
.long .Lprocedure2-.Ldebug_info_begin
.byte 0x9f
.Lexpr_absolute_call_end:
.byte 0
.Lloc_branch:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_branch_end-.Lexpr_branch
.Lexpr_branch:
.byte 0x31,0x28
.short .Lbranch_yes-.Lbranch_after
.Lbranch_after:
.byte 0x42,0xa8
.uleb128 TYPE_REF
.byte 0x2f
.short .Lbranch_end-.Lskip_after
.Lskip_after:
.Lbranch_yes:
.byte 0x75,0,0xa8
.uleb128 TYPE_REF
.Lbranch_end:
.byte 0x9f
.Lexpr_branch_end:
.byte 0
.Lloc_typed_constant:
.byte 7
.quad debug_quality_live
.quad .Lmain_end
.uleb128 .Lexpr_typed_constant_end-.Lexpr_typed_constant
.Lexpr_typed_constant:
.byte 0xa4
.uleb128 TYPE_REF
.byte 4
.long 18
.byte 0x9f
.Lexpr_typed_constant_end:
.byte 0
.Lloc_end:
