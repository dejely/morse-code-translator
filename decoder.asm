default rel
global decode_morse

; struct decoder field offsets (all fields occupy eight bytes)
%define PCM        0
%define FRAMES     8
%define RATE      16
%define CHANNELS  24
%define WINDOW    32
%define WPM       40
%define ENERGY    48
%define RUNS      56
%define OUTPUT    64
%define CANDIDATE 72

section .text
; int decode_morse(const struct decoder *input)
; Returns 0 on success, 1 for silence, 2 for ambiguous timing.
decode_morse:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov r12, rdi
    call measure_windows
    call collect_runs
    mov r13, rax
    mov eax, 1
    test r13, r13
    jz .done

    ; xmm0 holds frames per dot throughout scoring and rendering.
    mov rax, [r12 + WPM]
    test rax, rax
    jz .infer
    cvtsi2sd xmm0, qword [r12 + RATE]
    mulsd xmm0, [seconds_per_word]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    jmp .render

.infer:
    cmp r13, 1
    je .ambiguous
    movsd xmm1, [infinity]
    movsd [rsp], xmm1
    mov r14d, 40
.score_speed:
    call milliseconds_to_frames
    call score_runs
    ucomisd xmm1, [rsp]
    jae .next_speed
    movsd [rsp], xmm1
    mov r15d, r14d
.next_speed:
    inc r14d
    cmp r14d, 240
    jle .score_speed

    mov r14d, r15d
    call milliseconds_to_frames
    mov rdi, [r12 + OUTPUT]
    call render_runs

    movsd xmm1, [rsp]
    addsd xmm1, [ambiguity_margin]
    movsd [rsp], xmm1
    mov r14d, 40
.compare_speed:
    cmp r14d, r15d
    je .next_candidate
    call milliseconds_to_frames
    call score_runs
    ucomisd xmm1, [rsp]
    ja .next_candidate
    mov rdi, [r12 + CANDIDATE]
    call render_runs
    mov rsi, [r12 + CANDIDATE]
    mov rdi, [r12 + OUTPUT]
.compare_text:
    lodsb
    scasb
    jne .ambiguous
    test al, al
    jnz .compare_text
.next_candidate:
    inc r14d
    cmp r14d, 240
    jle .compare_speed
    jmp .success

.render:
    mov rdi, [r12 + OUTPUT]
    call render_runs
.success:
    xor eax, eax
    jmp .done
.ambiguous:
    mov eax, 2
.done:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; Returns the window count in rax and peak RMS in xmm0.
measure_windows:
    mov rdi, [r12 + PCM]
    mov rsi, [r12 + FRAMES]
    mov r8, [r12 + ENERGY]
    mov r9, [r12 + CHANNELS]
    xor edx, edx
    pxor xmm0, xmm0
.window:
    mov r10, [r12 + WINDOW]
    cmp r10, rsi
    cmova r10, rsi
    cvtsi2sd xmm4, r10
    pxor xmm3, xmm3
    xor r11d, r11d
.channel:
    lea rcx, [rdi + r11 * 2]
    mov r14, r10
    xor eax, eax
    xor r15d, r15d
.sample:
    movsx r13, word [rcx]
    add rax, r13
    imul r13, r13
    add r15, r13
    lea rcx, [rcx + r9 * 2]
    dec r14
    jnz .sample

    ; RMS after subtracting the mean is sqrt(E[x²] - E[x]²).
    cvtsi2sd xmm1, rax
    divsd xmm1, xmm4
    mulsd xmm1, xmm1
    cvtsi2sd xmm2, r15
    divsd xmm2, xmm4
    subsd xmm2, xmm1
    maxsd xmm3, xmm2
    inc r11
    cmp r11, r9
    jb .channel

    sqrtsd xmm3, xmm3
    movsd [r8 + rdx * 8], xmm3
    maxsd xmm0, xmm3
    inc rdx
    mov rax, r10
    imul rax, r9
    lea rdi, [rdi + rax * 2]
    sub rsi, r10
    jnz .window
    mov rax, rdx
    ret

; Store alternating tone/gap run lengths in frames. Return count in rax.
collect_runs:
    pxor xmm1, xmm1
    ucomisd xmm0, xmm1
    jbe .empty
    mulsd xmm0, [threshold]
    mov r8, [r12 + ENERGY]
    mov r9, [r12 + RUNS]
    mov r10, [r12 + FRAMES]
    xor edx, edx
    xor esi, esi
    xor edi, edi
.window:
    mov rcx, [r12 + WINDOW]
    cmp rcx, r10
    cmova rcx, r10
    xor r11d, r11d
    ucomisd xmm0, [r8]
    setb r11b
    test rdx, rdx
    jnz .active
    test r11d, r11d
    jz .advance
    inc rdx
    mov esi, 1
.active:
    cmp esi, r11d
    je .extend
    mov [r9 + rdx * 8 - 8], rdi
    inc rdx
    xor edi, edi
    mov esi, r11d
.extend:
    add rdi, rcx
.advance:
    add r8, 8
    sub r10, rcx
    jnz .window
    test esi, esi
    jz .trim_gap
    mov [r9 + rdx * 8 - 8], rdi
    mov rax, rdx
    ret
.trim_gap:
    lea rax, [rdx - 1]
    ret
.empty:
    xor eax, eax
    ret

milliseconds_to_frames:
    cvtsi2sd xmm0, r14d
    cvtsi2sd xmm1, qword [r12 + RATE]
    mulsd xmm0, xmm1
    divsd xmm0, [milliseconds_per_second]
    ret

; Convert run rcx to dot units in xmm2 and pick its closest length in xmm3.
; Even run indices are tones. Midpoints are 2 and 5 dot units.
classify_run:
    mov rax, [r12 + RUNS]
    cvtsi2sd xmm2, qword [rax + rcx * 8]
    divsd xmm2, xmm0
    movsd xmm3, [one]
    ucomisd xmm2, [two]
    jb .classified
    movsd xmm3, [three]
    test cl, 1
    jz .classified
    ucomisd xmm2, [five]
    jb .classified
    movsd xmm3, [seven]
.classified:
    ret

score_runs:
    xor ecx, ecx
    pxor xmm1, xmm1
.run:
    call classify_run
    subsd xmm2, xmm3
    divsd xmm2, xmm3
    mulsd xmm2, xmm2
    addsd xmm1, xmm2
    inc rcx
    cmp rcx, r13
    jb .run
    cvtsi2sd xmm2, r13
    divsd xmm1, xmm2
    ret

; Prefix the Morse bit string with 1, then append 0 for dot or 1 for dash.
; The prefix distinguishes symbols of different lengths.
render_runs:
    xor ecx, ecx
    mov r8d, 1
    lea r9, [morse_table]
.run:
    call classify_run
    cvttsd2si eax, xmm3
    test cl, 1
    jnz .gap
    cmp r8d, 128
    jae .next
    shr eax, 1
    lea r8d, [r8 * 2 + rax]
    jmp .next
.gap:
    cmp eax, 1
    je .next
    mov r10d, eax
    call emit_symbol
    cmp r10d, 7
    jne .next
    mov al, ' '
    stosb
.next:
    inc rcx
    cmp rcx, r13
    jb .run
    call emit_symbol
    xor eax, eax
    stosb
    ret

emit_symbol:
    mov al, [r9 + r8]
    stosb
    mov r8d, 1
    ret

section .rodata
align 8
one:                     dq 1.0
two:                     dq 2.0
three:                   dq 3.0
five:                    dq 5.0
seven:                   dq 7.0
seconds_per_word:         dq 1.2
milliseconds_per_second:  dq 1000.0
threshold:               dq 0.2
ambiguity_margin:        dq 0.02
infinity:                dq 0x7ff0000000000000

; Fill sparse slots with the unknown-symbol marker.
%macro morse 2
    times (%1 - ($ - morse_table)) db '?'
    db %2
%endmacro

morse_table:
    morse  2,  69 ; E .
    morse  3,  84 ; T -
    morse  4,  73 ; I ..
    morse  5,  65 ; A .-
    morse  6,  78 ; N -.
    morse  7,  77 ; M --
    morse  8,  83 ; S ...
    morse  9,  85 ; U ..-
    morse 10,  82 ; R .-.
    morse 11,  87 ; W .--
    morse 12,  68 ; D -..
    morse 13,  75 ; K -.-
    morse 14,  71 ; G --.
    morse 15,  79 ; O ---
    morse 16,  72 ; H ....
    morse 17,  86 ; V ...-
    morse 18,  70 ; F ..-.
    morse 20,  76 ; L .-..
    morse 22,  80 ; P .--.
    morse 23,  74 ; J .---
    morse 24,  66 ; B -...
    morse 25,  88 ; X -..-
    morse 26,  67 ; C -.-.
    morse 27,  89 ; Y -.--
    morse 28,  90 ; Z --..
    morse 29,  81 ; Q --.-
    morse 32,  53 ; 5 .....
    morse 33,  52 ; 4 ....-
    morse 35,  51 ; 3 ...--
    morse 39,  50 ; 2 ..---
    morse 42,  43 ; + .-.-.
    morse 47,  49 ; 1 .----
    morse 48,  54 ; 6 -....
    morse 49,  61 ; = -...-
    morse 50,  47 ; / -..-.
    morse 54,  40 ; ( -.--.
    morse 56,  55 ; 7 --...
    morse 60,  56 ; 8 ---..
    morse 62,  57 ; 9 ----.
    morse 63,  48 ; 0 -----
    morse 76,  63 ; ? ..--..
    morse 82,  34 ; " .-..-.
    morse 85,  46 ; . .-.-.-
    morse 90,  64 ; @ .--.-.
    morse 94,  39 ; ' .----.
    morse 97,  45 ; - -....-
    morse 109,  41 ; ) -.--.-
    morse 115,  44 ; , --..--
    morse 120,  58 ; : ---...
    times (256 - ($ - morse_table)) db '?'

section .note.GNU-stack noalloc noexec nowrite progbits
