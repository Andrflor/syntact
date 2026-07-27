# First program

A complete Syntact program can be one line:

```syntact
-> 0
```

The file is a scope. The production `-> 0` says that the file-scope produces `0`. Running the program means collapsing the file-scope.

A slightly larger program:

```syntact
greeting -> "hello"
answer -> 42
-> answer
```

This program produces `42`. The binding `greeting` is never used, so there is no reason for it to appear in the final binary.

For example, compiled for Linux x86-64, the resulting program can be as small as:

```asm
_start:
    mov     edi, 42         ; exit code = 42
    mov     eax, 60         ; syscall: exit
    syscall
```

No string `"hello"` remains. No hidden runtime is needed. The compiler reduced the program to what it actually does.

---

---

[← Core rules](02-core-rules.md) · [Index](README.md) · [Scopes →](04-scopes.md)
