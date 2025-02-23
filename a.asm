format ELF64 executable 3

segment readable executable
entry main
main:
    mov rax, 1          ; syscall: sys_write
    mov rdi, 1          ; stdout file descriptor
    mov rsi, message    ; pointer to message
    mov rdx, message_len ; message length
    syscall             ; invoke kernel

    mov rax, 60         ; syscall: sys_exit
    xor rdi, rdi        ; exit code 0
    syscall


segment readable writable
message db 20  ; String with newline
message_len = $ - message       ; Compute string length
