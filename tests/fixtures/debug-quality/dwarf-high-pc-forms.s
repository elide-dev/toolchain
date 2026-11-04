# RUN: %clang %cflags -no-pie %s -Wl,-q -o %t.exe
# RUN: llvm-dwarfdump --verify %t.exe
# RUN: llvm-bolt %t.exe -o %t.bolt --update-debug-sections --skip-funcs=main
# RUN: llvm-dwarfdump --verify %t.bolt
# RUN: llvm-dwarfdump --debug-info --show-form %t.bolt | FileCheck %s --check-prefix=ADDR
# RUN: %clang %cflags -no-pie -Wa,--defsym,OFFSET_FORM=1 %s -Wl,-q -o %t.offset.exe
# RUN: llvm-dwarfdump --verify %t.offset.exe
# RUN: llvm-bolt %t.offset.exe -o %t.offset.bolt --update-debug-sections --skip-funcs=main
# RUN: llvm-dwarfdump --verify %t.offset.bolt
# RUN: llvm-dwarfdump --debug-info --show-form %t.offset.bolt | FileCheck %s --check-prefix=OFFSET
# RUN: llvm-bolt %t.exe -o %t.moved.bolt --update-debug-sections --reorder-blocks=ext-tsp --split-functions
# RUN: llvm-dwarfdump --verify %t.moved.bolt

## Address high_pc is an absolute end, including for skipped functions and their
## inline scopes. Constant high_pc remains a length. The same executable has
## two non-CU address-form ranges; writing their size creates backwards ranges.
## BOLT legitimately replaces the compile-unit range with DW_AT_ranges.
# ADDR-COUNT-2: DW_AT_high_pc [DW_FORM_addr]
# OFFSET-COUNT-2: DW_AT_high_pc [DW_FORM_data8] (0x0000000000000003)

.text
.globl main
.type main,@function
main:
  xorl %eax,%eax
  ret
.Lmain_end:
.size main, .Lmain_end-main
.section .note.GNU-stack,"",@progbits
.section .debug_abbrev,"",@progbits
.uleb128 1
.uleb128 0x11
.byte 1
.uleb128 0x11
.uleb128 0x01
.uleb128 0x12
.ifdef OFFSET_FORM
.uleb128 0x07
.else
.uleb128 0x01
.endif
.byte 0,0
.uleb128 2
.uleb128 0x2e
.byte 1
.uleb128 0x03
.uleb128 0x08
.uleb128 0x11
.uleb128 0x01
.uleb128 0x12
.ifdef OFFSET_FORM
.uleb128 0x07
.else
.uleb128 0x01
.endif
.byte 0,0
.uleb128 3
.uleb128 0x2e
.byte 0
.uleb128 0x03
.uleb128 0x08
.uleb128 0x20
.uleb128 0x0b
.byte 0,0
.uleb128 4
.uleb128 0x1d
.byte 0
.uleb128 0x31
.uleb128 0x13
.uleb128 0x11
.uleb128 0x01
.uleb128 0x12
.ifdef OFFSET_FORM
.uleb128 0x07
.else
.uleb128 0x01
.endif
.uleb128 0x59
.uleb128 0x0b
.byte 0,0
.byte 0
.section .debug_info,"",@progbits
.Lcu_begin:
.long .Lcu_end-.Lcu_start
.Lcu_start:
.short 4
.long 0
.byte 8
.uleb128 1
.quad main
.ifdef OFFSET_FORM
.quad .Lmain_end-main
.else
.quad .Lmain_end
.endif
.Labstract_inner:
.uleb128 3
.asciz "inner"
.byte 1
.uleb128 2
.asciz "main"
.quad main
.ifdef OFFSET_FORM
.quad .Lmain_end-main
.else
.quad .Lmain_end
.endif
.uleb128 4
.long .Labstract_inner-.Lcu_begin
.quad main
.ifdef OFFSET_FORM
.quad .Lmain_end-main
.else
.quad .Lmain_end
.endif
.byte 42
.byte 0,0
.Lcu_end:
