BITS 64

; Try to force NASM to use 32-bit immediate
sub rdx, strict dword 0xFFFFFFFF
