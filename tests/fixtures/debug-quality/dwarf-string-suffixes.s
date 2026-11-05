# Suffix-merged .debug_str references are valid, including the empty suffix.
# BAD_OFFSET and UNTERMINATED keep the verifier's corruption checks live.
.section .debug_abbrev,"",@progbits
.byte 1, 0x11, 0
.uleb128 0x03
.uleb128 0x25
.uleb128 0x72
.uleb128 0x17
.byte 0, 0, 0

.section .debug_info,"",@progbits
.long .Linfo_end-.Linfo_start
.Linfo_start:
.short 5
.byte 1, 8
.long 0
.byte 1, 1
.long 8
.Linfo_end:

.section .debug_str,"MS",@progbits,1
.ifndef EMPTY_STR
.ifdef UNTERMINATED_ZERO
.ascii "unsigned int"
.else
.asciz "unsigned int"
.endif
.endif
.ifdef UNTERMINATED
.ascii "broken"
.endif

.section .debug_str_offsets,"",@progbits
.long .Loffset_end-.Loffset_start
.Loffset_start:
.short 5, 0
.long 0, 9, 12
.ifdef BAD_OFFSET
.long 13
.endif
.ifdef UNTERMINATED
.long 13
.endif
.Loffset_end:
