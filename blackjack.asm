; ================================================================
; blackjack.asm  -  BlackJack for 32-bit x86 Linux (NASM)
; ================================================================
; Build:
;   nasm -f elf32 blackjack.asm -o blackjack.o
;   ld -m elf_i386 blackjack.o -o blackjack
;
; No libc. All I/O goes through int 0x80 system calls.
;
; Notes on the implementation:
;  - Output is collected in obuf and written with a single sys_write
;    per screen update instead of one call per character.
;  - String lengths are assembler constants, so nothing scans for NUL.
;  - Cards come from an LCG seeded once with rdtsc. If the drawn card
;    is already used, the next free card is taken, so a draw always
;    finishes within deck_size steps.
;  - Functions save only the registers they change instead of pushad.
; ================================================================

section .data

welcome_msg         db  "Welcome to a game of BlackJack!", 0Ah
welcome_msg_len     equ $ - welcome_msg

money_msg           db  "Your balance: "
money_msg_len       equ $ - money_msg

bet_msg             db  "Enter your bet amount: "
bet_msg_len         equ $ - bet_msg

dealer_hand_msg     db  "Dealer's Hand: "
dealer_hand_msg_len equ $ - dealer_hand_msg

player_hand_msg     db  "Your Hand: "
player_hand_msg_len equ $ - player_hand_msg

hit_msg             db  "Hit (h) or Stand (s)? "
hit_msg_len         equ $ - hit_msg

replay_msg          db  "Would you like to play again? (y/n): "
replay_msg_len      equ $ - replay_msg

game_over_msg       db  "You ran out of balance. You lost the game.", 0Ah
game_over_msg_len   equ $ - game_over_msg

ending_msg          db  "Thank you for playing!", 0Ah
ending_msg_len      equ $ - ending_msg

invalid_bet_msg     db  "Please enter a valid number!", 0Ah
invalid_bet_msg_len equ $ - invalid_bet_msg

invalid_act_msg     db  "Please select an option!", 0Ah
invalid_act_msg_len equ $ - invalid_act_msg

natural_msg         db  "BlackJack! Natural 21! Pays 3:2.", 0Ah
natural_msg_len     equ $ - natural_msg

dealer_natural_msg  db  "Dealer has BlackJack! You lose.", 0Ah
dealer_natural_msg_len equ $ - dealer_natural_msg

push_natural_msg    db  "Both have BlackJack! Push.", 0Ah
push_natural_msg_len equ $ - push_natural_msg

six_card_msg        db  "Six-Card Charlie! You win.", 0Ah
six_card_msg_len    equ $ - six_card_msg

dealer_six_msg      db  "Dealer has Six-Card Charlie. You lose.", 0Ah
dealer_six_msg_len  equ $ - dealer_six_msg

; Standard 52-card deck (2..9 = face value, 10/J/Q/K = 10, A = 11)
deck_values db  2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,6,6,6,6
            db  7,7,7,7,8,8,8,8,9,9,9,9,10,10,10,10
            db  10,10,10,10,10,10,10,10,10,10,10,10
            db  11,11,11,11
deck_size   equ 52

input_size  equ 16

; ----------------------------------------------------------------
section .bss

    input             resb input_size  ; one line of user input
    drain_byte        resb 1     ; scratch byte for dropping the rest of a long line
    obuf              resb 512   ; output buffer, written with one sys_write
    obuf_len          resd 1     ; bytes waiting in obuf

    money             resd 1     ; player balance
    bet_amount        resd 1     ; bet of the current round

    deck_used         resb 52    ; 0 = still in the deck, 1 = drawn
    rng_state         resd 1     ; LCG state, seeded once from rdtsc

    player_cards      resb 12    ; player card values
    dealer_cards      resb 12    ; dealer card values
    player_card_count resd 1
    dealer_card_count resd 1
    player_ace_count  resd 1     ; number of aces, used to count them as 1
    dealer_ace_count  resd 1
    phase             resb 1     ; 0 = dealer hole card hidden, 1 = shown

    num_buf           resb 12    ; scratch space for uint_to_obuf

; ================================================================
section .text
global _start

; ----------------------------------------------------------------
; obuf_flush - write obuf to stdout and empty it
; Modifies: EAX, EBX, ECX, EDX
; ----------------------------------------------------------------
obuf_flush:
    mov edx, [obuf_len]
    test edx, edx
    jz .empty
    mov eax, 4
    mov ebx, 1
    lea ecx, [obuf]
    int 0x80
    mov dword [obuf_len], 0
.empty:
    ret

; ----------------------------------------------------------------
; obuf_write_raw - ECX = ptr, EDX = len, append len bytes to obuf
; Preserves all registers
; ----------------------------------------------------------------
obuf_write_raw:
    push esi
    push edi
    push ecx
    push edx
    mov esi, ecx                    ; source = ptr
    mov edi, [obuf_len]
    lea edi, [obuf + edi]           ; destination = obuf + current length
    mov ecx, edx                    ; count = len
    rep movsb
    pop edx                         ; EDX = original len
    pop ecx
    add [obuf_len], edx
    pop edi
    pop esi
    ret

; ----------------------------------------------------------------
; obuf_write_char - append the byte in AL to obuf
; Preserves all registers
; ----------------------------------------------------------------
obuf_write_char:
    push edi
    mov edi, [obuf_len]
    mov [obuf + edi], al
    inc dword [obuf_len]
    pop edi
    ret

; ----------------------------------------------------------------
; obuf_write_card - AL = card value (2..11), append '2'..'9', '10' or 'A'
; Modifies: AL
; ----------------------------------------------------------------
obuf_write_card:
    push edi
    mov edi, [obuf_len]
    cmp al, 11
    je .ace
    cmp al, 10
    je .ten
    add al, '0'                     ; 2..9 is a single character
    mov [obuf + edi], al
    inc edi
    jmp .done
.ten:
    ; little-endian word 0x3031 stores '1' then '0'
    mov word [obuf + edi], 0x3031
    add edi, 2
    jmp .done
.ace:
    mov byte [obuf + edi], 'A'
    inc edi
.done:
    mov [obuf_len], edi
    pop edi
    ret

; ----------------------------------------------------------------
; uint_to_obuf - EAX = unsigned integer, append its decimal digits to obuf
; Modifies: EAX, ECX, EDX
; ----------------------------------------------------------------
uint_to_obuf:
    push ebx
    lea ebx, [num_buf + 11]         ; fill the buffer from the end
    mov ecx, 10
.digit:
    dec ebx
    xor edx, edx
    div ecx                         ; EAX = quotient, EDX = remainder
    add dl, '0'
    mov [ebx], dl
    test eax, eax
    jnz .digit
    ; EBX = first digit
    lea eax, [num_buf + 11]
    sub eax, ebx                    ; EAX = number of digits
    mov edx, eax
    mov ecx, ebx
    call obuf_write_raw
    pop ebx
    ret

; ----------------------------------------------------------------
; low_high_to_obuf - ESI = cards, ECX = count
; Writes the score as "low", or as "low/high" while an ace can still count as 11
; Modifies: EAX, EBX, ECX, EDX
; ----------------------------------------------------------------
low_high_to_obuf:
    push ebp
    push esi
    ; raw sum with every ace as 11, and the number of aces
    xor eax, eax                    ; raw sum
    xor ebx, ebx                    ; card index
    xor edx, edx                    ; ace count
.sum:
    cmp ebx, ecx
    jge .compute
    movzx ebp, byte [esi + ebx]
    add eax, ebp
    cmp ebp, 11
    jne .next
    inc edx
.next:
    inc ebx
    jmp .sum

.compute:
    ; low = raw sum - 10 * aces, every ace counted as 1
    push edx
    mov ecx, edx
    imul ecx, 10
    sub eax, ecx                    ; EAX = low score
    pop edx

    test edx, edx
    jz .only_low                    ; no aces, only one score

    mov ecx, eax
    add ecx, 10                     ; ECX = high, one ace counted as 11
    cmp ecx, 21
    jg .only_low                    ; high would bust, show only low

    push ecx
    call uint_to_obuf               ; low
    mov al, '/'
    call obuf_write_char
    pop eax
    call uint_to_obuf               ; high
    jmp .lh_done

.only_low:
    call uint_to_obuf

.lh_done:
    pop esi
    pop ebp
    ret

; ----------------------------------------------------------------
; calculate_score - ESI = cards, ECX = count, EDX = ace count, returns EAX = score
; While the total is over 21, one ace at a time is counted as 1 instead of 11
; Modifies: EAX, EBX, EDX
; ----------------------------------------------------------------
calculate_score:
    push ebp
    xor eax, eax
    xor ebx, ebx
.sum:
    cmp ebx, ecx
    jge .reduce
    movzx ebp, byte [esi + ebx]
    add eax, ebp
    inc ebx
    jmp .sum
.reduce:
    cmp eax, 21
    jle .done
    test edx, edx
    jz .done
    sub eax, 10
    dec edx
    jmp .reduce
.done:
    pop ebp
    ret

; ----------------------------------------------------------------
; print_hand_state - write both hands to obuf and flush
; phase 0 shows the first dealer card and "?", phase 1 shows the whole hand
; Modifies: EAX, EBX, ECX, EDX, ESI
; ----------------------------------------------------------------
print_hand_state:
    ; dealer line
    lea ecx, [dealer_hand_msg]
    mov edx, dealer_hand_msg_len
    call obuf_write_raw

    movzx eax, byte [dealer_cards]  ; the first card is always visible
    call obuf_write_card
    mov al, ' '
    call obuf_write_char

    cmp byte [phase], 0
    jne .dealer_full

    ; hole card hidden
    mov al, '?'
    call obuf_write_char
    mov al, ' '
    call obuf_write_char
    jmp .dealer_paren

.dealer_full:
    mov ebx, 1
    mov ecx, [dealer_card_count]
.dealer_loop:
    cmp ebx, ecx
    jge .dealer_paren
    movzx eax, byte [dealer_cards + ebx]
    call obuf_write_card
    mov al, ' '
    call obuf_write_char
    inc ebx
    jmp .dealer_loop

.dealer_paren:
    mov al, '('
    call obuf_write_char
    lea esi, [dealer_cards]
    cmp byte [phase], 0
    jne .dp_full
    mov ecx, 1                      ; hidden hole card, score of the first card only
    jmp .dp_call
.dp_full:
    mov ecx, [dealer_card_count]
.dp_call:
    call low_high_to_obuf
    mov al, ')'
    call obuf_write_char
    mov al, 0Ah
    call obuf_write_char

    ; player line
    lea ecx, [player_hand_msg]
    mov edx, player_hand_msg_len
    call obuf_write_raw

    xor ebx, ebx
    mov ecx, [player_card_count]
.player_loop:
    cmp ebx, ecx
    jge .player_paren
    movzx eax, byte [player_cards + ebx]
    call obuf_write_card
    mov al, ' '
    call obuf_write_char
    inc ebx
    jmp .player_loop

.player_paren:
    mov al, '('
    call obuf_write_char
    lea esi, [player_cards]
    mov ecx, [player_card_count]
    call low_high_to_obuf
    mov al, ')'
    call obuf_write_char
    mov al, 0Ah
    call obuf_write_char

    call obuf_flush
    ret

; ----------------------------------------------------------------
; init_deck - clear deck_used and both card buffers
; Modifies: EAX, ECX, EDI
; ----------------------------------------------------------------
init_deck:
    xor eax, eax
    lea edi, [deck_used]
    mov ecx, deck_size
    rep stosb

    lea edi, [player_cards]
    mov ecx, 12
    rep stosb

    lea edi, [dealer_cards]
    mov ecx, 12
    rep stosb
    ret

; ----------------------------------------------------------------
; draw_card - returns EAX = value (2..11) of a card not drawn yet this round
; LCG step with the Numerical Recipes constants, then a linear probe over
; deck_used, so at most deck_size slots are checked
; Modifies: EAX, EBX, ECX, EDX
; ----------------------------------------------------------------
draw_card:
    ; state = state * 1664525 + 1013904223  (mod 2^32)
    mov eax, [rng_state]
    imul eax, 1664525
    add eax, 1013904223
    mov [rng_state], eax
    xor edx, edx
    mov ecx, deck_size
    div ecx                         ; EDX = starting index 0..51
    mov ebx, edx
    mov ecx, deck_size              ; slots left to check
.probe:
    cmp byte [deck_used + ebx], 0
    je .found
    inc ebx
    cmp ebx, deck_size
    jb .no_wrap
    xor ebx, ebx
.no_wrap:
    dec ecx
    jnz .probe
    xor eax, eax                    ; deck empty, cannot happen with 24 card slots
    ret
.found:
    mov byte [deck_used + ebx], 1
    movzx eax, byte [deck_values + ebx]
    ret

; ----------------------------------------------------------------
; player_hit - draw a card for the player and update the counters
; Returns: AL = card value
; Modifies: EAX, EBX, ECX, EDX
; ----------------------------------------------------------------
player_hit:
    call draw_card
    mov ecx, [player_card_count]
    mov [player_cards + ecx], al
    inc dword [player_card_count]
    cmp al, 11
    jne .done
    inc dword [player_ace_count]
.done:
    ret

; ----------------------------------------------------------------
; dealer_hit - draw a card for the dealer and update the counters
; Returns: AL = card value
; Modifies: EAX, EBX, ECX, EDX
; ----------------------------------------------------------------
dealer_hit:
    call draw_card
    mov ecx, [dealer_card_count]
    mov [dealer_cards + ecx], al
    inc dword [dealer_card_count]
    cmp al, 11
    jne .done
    inc dword [dealer_ace_count]
.done:
    ret

; ----------------------------------------------------------------
; read_line - read one line from stdin into input, NUL-terminated, without the newline
; The rest of a line longer than the buffer is read and dropped, so it does not
; answer the next prompt. End of input quits the game.
; Returns: EAX = length of the line
; Modifies: EAX, EBX, ECX, EDX
; ----------------------------------------------------------------
read_line:
    mov eax, 3
    xor ebx, ebx
    lea ecx, [input]
    mov edx, input_size - 1         ; keep one byte for the NUL
    int 0x80
    test eax, eax
    jle do_exit                     ; end of input or read error

    xor ecx, ecx
.scan:
    cmp ecx, eax
    jae .no_newline
    cmp byte [input + ecx], 0Ah
    je .terminate
    inc ecx
    jmp .scan

.no_newline:
    ; the line did not fit, drop bytes up to and including the newline
    push ecx
.drain:
    mov eax, 3
    xor ebx, ebx
    lea ecx, [drain_byte]
    mov edx, 1
    int 0x80
    test eax, eax
    jle .drained
    cmp byte [drain_byte], 0Ah
    jne .drain
.drained:
    pop ecx

.terminate:
    mov byte [input + ecx], 0
    mov eax, ecx
    ret

; ----------------------------------------------------------------
; get_hit_or_stand - prompt until the answer is h or s, returns AL = 'h' or 's'
; Upper case is accepted. The prompt is written directly so it shows before read blocks.
; Modifies: EAX, EBX, ECX, EDX
; ----------------------------------------------------------------
get_hit_or_stand:
    call obuf_flush
.read:
    mov eax, 4
    mov ebx, 1
    lea ecx, [hit_msg]
    mov edx, hit_msg_len
    int 0x80

    call read_line
    mov al, [input]
    cmp al, 'A'
    jb .check
    cmp al, 'Z'
    ja .check
    or al, 0x20                     ; to lower case
.check:
    cmp al, 'h'
    je .done
    cmp al, 's'
    je .done

    mov eax, 4
    mov ebx, 1
    lea ecx, [invalid_act_msg]
    mov edx, invalid_act_msg_len
    int 0x80
    jmp .read
.done:
    ret

; ----------------------------------------------------------------
; ask_replay - prompt until the answer is y or n, returns AL = 'y' or 'n'
; Modifies: EAX, EBX, ECX, EDX
; ----------------------------------------------------------------
ask_replay:
    call obuf_flush
.read:
    mov eax, 4
    mov ebx, 1
    lea ecx, [replay_msg]
    mov edx, replay_msg_len
    int 0x80

    call read_line
    mov al, [input]
    cmp al, 'A'
    jb .check
    cmp al, 'Z'
    ja .check
    or al, 0x20
.check:
    cmp al, 'y'
    je .done
    cmp al, 'n'
    je .done

    mov eax, 4
    mov ebx, 1
    lea ecx, [invalid_act_msg]
    mov edx, invalid_act_msg_len
    int 0x80
    jmp .read
.done:
    ret

; ----------------------------------------------------------------
; get_bet - prompt for a bet until it is a number from 1 to the balance,
; and store it in [bet_amount]
; The number is parsed against the balance digit by digit, so it cannot overflow
; Modifies: EAX, EBX, ECX, EDX, ESI
; ----------------------------------------------------------------
get_bet:
    call obuf_flush
.prompt:
    mov eax, 4
    mov ebx, 1
    lea ecx, [bet_msg]
    mov edx, bet_msg_len
    int 0x80

    call read_line
    test eax, eax
    jz .bad                         ; empty line

    ; every character must be a digit
    lea esi, [input]
    xor ecx, ecx
.validate:
    mov al, [esi + ecx]
    test al, al
    jz .parse_start
    cmp al, '0'
    jb .bad
    cmp al, '9'
    ja .bad
    inc ecx
    jmp .validate

.parse_start:
    ; limit = balance, keep limit / 10 in EBX and limit % 10 on the stack
    mov eax, [money]
    xor edx, edx
    mov ecx, 10
    div ecx                         ; EAX = limit / 10, EDX = limit % 10
    mov ebx, eax
    push edx

    xor eax, eax                    ; parsed value
    lea esi, [input]
.parse:
    movzx ecx, byte [esi]
    test cl, cl
    jz .parse_done
    sub cl, '0'

    cmp eax, ebx                    ; parsed > limit / 10, next digit would exceed
    ja .too_big
    jb .ok_digit
    cmp ecx, [esp]                  ; parsed == limit / 10, digit decides
    ja .too_big
.ok_digit:
    imul eax, 10
    add eax, ecx
    inc esi
    jmp .parse

.too_big:
    pop edx
.bad:
    mov eax, 4
    mov ebx, 1
    lea ecx, [invalid_bet_msg]
    mov edx, invalid_bet_msg_len
    int 0x80
    jmp .prompt

.parse_done:
    pop edx
    test eax, eax                   ; a bet of 0 is not allowed
    jz .bad
    mov [bet_amount], eax
    ret

; ----------------------------------------------------------------
; dealer_turn - show the hole card and draw until the score is 17 or more
; The dealer stands on every 17, soft 17 included
; ----------------------------------------------------------------
dealer_turn:
    mov byte [phase], 1
    call print_hand_state
.loop:
    lea esi, [dealer_cards]
    mov ecx, [dealer_card_count]
    mov edx, [dealer_ace_count]
    call calculate_score
    cmp eax, 17
    jge .done
    call dealer_hit
    call print_hand_state
    jmp .loop
.done:
    ret

; ----------------------------------------------------------------
; player_turn - hit or stand until the player stands, busts or holds six cards
; The dealer keeps the hole card hidden until the player has finished,
; even when the dealer holds a natural
; ----------------------------------------------------------------
player_turn:
.loop:
    call print_hand_state
    call get_hit_or_stand
    cmp al, 's'
    je .stand

    call player_hit
    lea esi, [player_cards]
    mov ecx, [player_card_count]
    mov edx, [player_ace_count]
    call calculate_score
    cmp eax, 21
    jg .bust
    cmp dword [player_card_count], 6
    jb .loop
    ; six cards without busting is a Six-Card Charlie, the player stands automatically

.stand:
    call dealer_turn
    jmp resolve_round

.bust:
    mov byte [phase], 1
    call print_hand_state
    jmp player_lost

; ----------------------------------------------------------------
; resolve_round - compare the hands after the dealer has played
; Order: player bust, dealer bust, dealer natural, Six-Card Charlie, higher score
; A player natural never gets here, it is settled right after the deal
; ----------------------------------------------------------------
resolve_round:
    lea esi, [player_cards]
    mov ecx, [player_card_count]
    mov edx, [player_ace_count]
    call calculate_score
    push eax                        ; player score

    lea esi, [dealer_cards]
    mov ecx, [dealer_card_count]
    mov edx, [dealer_ace_count]
    call calculate_score
    mov ebx, eax                    ; EBX = dealer score
    pop eax                         ; EAX = player score

    cmp eax, 21
    jg player_lost                  ; safety, a bust is handled in player_turn
    cmp ebx, 21
    jg player_won                   ; dealer bust

    ; a dealer natural beats every hand that is not a natural
    cmp dword [dealer_card_count], 2
    jne .no_dealer_natural
    cmp ebx, 21
    jne .no_dealer_natural
    lea ecx, [dealer_natural_msg]
    mov edx, dealer_natural_msg_len
    call obuf_write_raw
    call obuf_flush
    jmp player_lost

.no_dealer_natural:
    ; Six-Card Charlie, six or more cards without busting
    xor ecx, ecx
    cmp dword [player_card_count], 6
    setae cl
    xor edx, edx
    cmp dword [dealer_card_count], 6
    setae dl
    cmp cl, dl
    je .compare                     ; both or neither, the scores decide
    test cl, cl
    jz .dealer_six

    lea ecx, [six_card_msg]
    mov edx, six_card_msg_len
    call obuf_write_raw
    call obuf_flush
    jmp player_won

.dealer_six:
    lea ecx, [dealer_six_msg]
    mov edx, dealer_six_msg_len
    call obuf_write_raw
    call obuf_flush
    jmp player_lost

.compare:
    cmp eax, ebx
    ja player_won
    jb player_lost
    jmp player_push

; ----------------------------------------------------------------
; Round results
; ----------------------------------------------------------------
player_won:
    mov eax, [money]
    add eax, [bet_amount]
    jc .overflow                    ; unsigned overflow, saturate
    mov [money], eax
    jmp show_result
.overflow:
    mov dword [money], 0FFFFFFFFh
    jmp show_result

player_lost:
    mov eax, [money]
    sub eax, [bet_amount]
    jc .underflow                   ; borrow, clamp to zero
    mov [money], eax
    jmp show_result
.underflow:
    xor eax, eax
    mov [money], eax
    jmp show_result

player_natural_win:
    ; win = floor(3 * bet / 2) = bet + bet / 2, which avoids computing 3 * bet
    mov eax, [bet_amount]
    mov ecx, eax
    shr ecx, 1
    add eax, ecx
    jc .overflow
    add eax, [money]
    jc .overflow
    mov [money], eax
    jmp show_result
.overflow:
    mov dword [money], 0FFFFFFFFh
    jmp show_result

player_push:
    ; tie, the balance does not change

show_result:
    lea ecx, [money_msg]
    mov edx, money_msg_len
    call obuf_write_raw
    mov eax, [money]
    call uint_to_obuf
    mov al, 0Ah
    call obuf_write_char
    call obuf_flush

    cmp dword [money], 0
    jne .ask_replay

    lea ecx, [game_over_msg]
    mov edx, game_over_msg_len
    call obuf_write_raw
    call obuf_flush
    jmp do_exit

.ask_replay:
    call ask_replay
    cmp al, 'y'
    je start_round

do_exit:
    call obuf_flush
    mov eax, 4
    mov ebx, 1
    lea ecx, [ending_msg]
    mov edx, ending_msg_len
    int 0x80
    mov eax, 1
    xor ebx, ebx
    int 0x80

; ----------------------------------------------------------------
; _start - seed the RNG, set the starting balance and play the first round
; ----------------------------------------------------------------
_start:
    rdtsc                           ; read once, only as the seed
    mov [rng_state], eax
    mov dword [money], 100

; ----------------------------------------------------------------
; start_round - reset the deck and counters, deal, take the bet
; ----------------------------------------------------------------
start_round:
    call init_deck
    mov byte [phase], 0
    xor eax, eax
    mov [player_card_count], eax
    mov [dealer_card_count], eax
    mov [player_ace_count],  eax
    mov [dealer_ace_count],  eax

    call player_hit
    call player_hit
    call dealer_hit
    call dealer_hit

    lea ecx, [welcome_msg]
    mov edx, welcome_msg_len
    call obuf_write_raw

    lea ecx, [money_msg]
    mov edx, money_msg_len
    call obuf_write_raw

    mov eax, [money]
    call uint_to_obuf
    mov al, 0Ah
    call obuf_write_char
    call obuf_flush

    call get_bet

    ; a player natural (21 with the first two cards) is settled at once
    lea esi, [player_cards]
    mov ecx, 2
    mov edx, [player_ace_count]
    call calculate_score
    cmp eax, 21
    jne player_turn

    ; show the dealer hand, a dealer natural as well makes it a push
    mov byte [phase], 1
    lea esi, [dealer_cards]
    mov ecx, 2
    mov edx, [dealer_ace_count]
    call calculate_score
    cmp eax, 21
    je .both_natural

    call print_hand_state
    lea ecx, [natural_msg]
    mov edx, natural_msg_len
    call obuf_write_raw
    call obuf_flush
    jmp player_natural_win

.both_natural:
    call print_hand_state
    lea ecx, [push_natural_msg]
    mov edx, push_natural_msg_len
    call obuf_write_raw
    call obuf_flush
    jmp player_push
