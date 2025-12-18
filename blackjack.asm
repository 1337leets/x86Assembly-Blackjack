section .data
    welcome_msg db "Welcome to a game of BlackJack!", 0Ah, 0   ; Hoş geldiniz mesajı
    welcome_msg_len equ $ - welcome_msg                         ; Mesajın uzunluğu
    money_msg db "Your balance: ", 0                             ; Bakiye mesajı
    money_msg_len equ $ - money_msg                               ; Mesajın uzunluğu
    bet_msg db "Enter your bet amount: ", 0                        ; Bahis mesajı
    bet_msg_len equ $ - bet_msg                                     ; Mesajın uzunluğu
    newline db 0Ah, 0                                                   ; Newline
	deck_values db 2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,6,6,6,6
             db 7,7,7,7,8,8,8,8,9,9,9,9,10,10,10,10
             db 10,10,10,10,10,10,10,10,10,10,10,10
             db 11,11,11,11
	deck_size equ 52
	dealer_hand_msg db "Dealer's Hand: ",0
	dealer_hand_msg_len equ $ - dealer_hand_msg

	player_hand_msg db "Your Hand: ",0
	player_hand_msg_len equ $ - player_hand_msg

	hit_msg db "Hit (h) or Stand (s)? ",0
	hit_msg_len equ $ - hit_msg

	replay_msg db "Would you like to play again? (y/n): ",0
	replay_msg_len equ $ - replay_msg

	game_over_msg db "You ran out of balance. You lost the game.",0Ah,0
	game_over_msg_len equ $ - game_over_msg

	ending_msg db "Thank you for playing!",0Ah,0
	ending_msg_len equ $ - ending_msg

	open_par db " (",0
	close_par db ")",0
	qmark db "?",0
	space_char db " ",0

	invalid_bet_msg db "Please enter a valid number!",0Ah,0
	invalid_bet_msg_len equ $ - invalid_bet_msg

	invalid_action_msg db "Please select an option!",0Ah,0
	invalid_action_msg_len equ $ - invalid_action_msg

	; optional: clear screen ANSI (kullanmak istersen)
	clear_screen db 0x1B, "[2J", 0x1B, "[H", 0
	clear_screen_len equ $ - clear_screen

section .bss
    input resb 16         ; Kullanıcının bahis miktarını girebileceği alan (16 byte)
    bet_amount resd 1     ; Kullanıcının bahis miktarını tutacak değişken (dword)
    money resd 1          ; Kullanıcının parası
    money_str resb 12     ; int to ascii sonucu tutulacak buffer
	player_score resd 1
    dealer_score resd 1
	deck_used resb 52             ; Kartların kullanılıp kullanılmadığını takip eder
    card_index resb 1             ; Sıradaki kart için indeks
    player_cards resb 13          ; Oyuncu kartları
    dealer_cards resb 13          ; Krupiye kartları
    player_card_count resd 1
    dealer_card_count resd 1
    player_ace_count resd 1
    dealer_ace_count resd 1
	tmp_buf resb 8        ; Geçici yazdırma alanı
	phase resb 1          ; 0 = dealer partial, 1 = dealer full
	player_natural    resb 1
    dealer_natural    resb 1
    player_six        resb 1
    dealer_six        resb 1

section .text
    global _start

init_deck:
    mov ecx, deck_size
    mov edi, deck_used
    xor eax, eax
.init_loop:
    mov byte [edi], 0
    inc edi
    loop .init_loop

    ; sıfırla: player_cards (13 byte)
    mov ecx, 13
    lea edi, [player_cards]
    xor al, al
    rep stosb

    ; sıfırla: dealer_cards (13 byte)
    mov ecx, 13
    lea edi, [dealer_cards]
    xor al, al
    rep stosb

    mov byte [card_index], 0
    ret

int_to_ascii:
    ; Girdi: eax = sayı, edi = hedef buffer sonundan 1 önce
    mov byte [edi], 0
    dec edi
    mov ecx, 10
.int_to_ascii_loop:
    xor edx, edx
    div ecx
    add dl, '0'
    mov [edi], dl
    dec edi
    test eax, eax
    jnz .int_to_ascii_loop
    inc edi
    ret

ascii_to_int:
    ; Girdi: esi = string başlangıcı, eax = 0 dönecek sayı
    xor eax, eax
    xor ebx, ebx
.ascii_loop:
    movzx ecx, byte [esi + ebx]
    cmp ecx, 0
    je .done
    cmp ecx, 10
    je .done
    cmp ecx, '0'
    jl .done
    cmp ecx, '9'
    jg .done
    sub ecx, '0'
    imul eax, eax, 10
    add eax, ecx
    inc ebx
    jmp .ascii_loop
.done:
    ret

draw_card:
    rdtsc                   ; EDX:EAX = time‐stamp counter
    ; → sadece EAX’in alt yarısını kullanılacak:
    xor edx, edx            ; EDX = 0
    mov ecx, deck_size      ; bölen = 52
    div ecx                 ; EAX = quotient, EDX = remainder (0..51)
    mov ebx, edx            ; EBX = kart indeksi

    ; eğer kart kullanıldıysa yeniden dene
    mov al, [deck_used + ebx]
    cmp al, 1
    je draw_card            ; recursive retry (ya da .retry etiketi)
    ; kartı işaretle ve değeri döndür
    mov byte [deck_used + ebx], 1
    movzx eax, byte [deck_values + ebx]
    ret

calculate_score:
    xor eax, eax          ; toplam = 0
    xor ebx, ebx          ; index = 0
    push edx              ; ace count'ı yedekle

.sum_cards:
    cmp ebx, ecx
    jge .chk_aces
    movzx edi, byte [esi + ebx]   ; kart değeri edi'ye
    add eax, edi             ; toplam += kart
    inc ebx
    jmp .sum_cards

.chk_aces:
    pop edx                  ; ace_count'ı geri al

.check_loop:
    cmp eax, 21
    jle .done_score
    cmp edx, 0
    jle .done_score
    sub eax, 10              ; bir Ace'i 1 yap
    dec edx
    jmp .check_loop

.done_score:
    ret

; -----------------------------
; calc_set_player_flags
; Inputs: ESI=player_cards, ECX=player_card_count, EDX=player_ace_count
; sets [player_score], [player_natural], [player_six]
; -----------------------------
calc_set_player_flags:
    push ecx
    push edx
    call calculate_score        ; EAX = score
    mov [player_score], eax
    pop edx
    pop ecx

    mov ebx, ecx                ; ebx = card_count

    ; NATURAL? (2 kart && score==21)
    cmp ebx, 2
    jne .p_nat0
    cmp eax, 21
    jne .p_nat0
    mov byte [player_natural], 1
    jmp .p_nat_done
.p_nat0:
    mov byte [player_natural], 0
.p_nat_done:

    ; SIX-CARD? (>=6 kart && score <= 21)
    cmp ebx, 6
    jb .p_six0
    cmp eax, 21
    ja .p_six0
    mov byte [player_six], 1
    jmp .p_six_done
.p_six0:
    mov byte [player_six], 0
.p_six_done:
    ret

; -----------------------------
; calc_set_dealer_flags
; Inputs: ESI=dealer_cards, ECX=dealer_card_count, EDX=dealer_ace_count
; sets [dealer_score], [dealer_natural], [dealer_six]
; -----------------------------
calc_set_dealer_flags:
    push ecx
    push edx
    call calculate_score
    mov [dealer_score], eax
    pop edx
    pop ecx

    mov ebx, ecx

    cmp ebx, 2
    jne .d_nat0
    cmp eax, 21
    jne .d_nat0
    mov byte [dealer_natural], 1
    jmp .d_nat_done
.d_nat0:
    mov byte [dealer_natural], 0
.d_nat_done:

    cmp ebx, 6
    jb .d_six0
    cmp eax, 21
    ja .d_six0
    mov byte [dealer_six], 1
    jmp .d_six_done
.d_six0:
    mov byte [dealer_six], 0
.d_six_done:
    ret

; ----------------------------
; print_low_high_from_cards
; Inputs: ESI = pointer to cards (bytes), ECX = count
; Uses: print_number_in_money_str (EAX->print), small_write (DL->print char)
; Preserves regs via pushad/popad
; Prints either "low" or "low/high"
; ----------------------------
print_low_high_from_cards:
    pushad

    xor eax, eax        ; raw_sum
    xor ebx, ebx        ; index
    xor edx, edx        ; ace_count

.pl_loop:
    cmp ebx, ecx
    jge .pl_done
    movzx edi, byte [esi + ebx]  ; card value
    add eax, edi
    cmp edi, 11
    jne .pl_next
    inc edx
.pl_next:
    inc ebx
    jmp .pl_loop

.pl_done:
    ; raw_sum in EAX, ace_count in EDX
    mov esi, edx        ; tmp = ace_count
    mov ebx, eax        ; ebx = raw_sum

    ; low = raw_sum - ace_count*10
    mov eax, ebx
    mov ecx, esi
    imul ecx, 10        ; ecx = ace_count*10
    sub eax, ecx        ; eax = low

    ; if no ace -> print low
    cmp esi, 0
    je .print_low

    ; high = low + 10 ; check <= 21
    mov ecx, eax
    add ecx, 10
    cmp ecx, 21
    jg .print_low

    ; print low
    mov eax, eax        ; low already in EAX
    call print_number_in_money_str

    ; print '/'
    mov dl, '/'
    call small_write

    ; print high (low + 10)
    mov eax, eax
    add eax, 10
    call print_number_in_money_str

    jmp .pl_finish

.print_low:
    mov eax, eax
    call print_number_in_money_str

.pl_finish:
    popad
    ret

; ---------- print_cstr (EAX = pointer to NUL-terminated string) ----------
print_cstr:
    pushad
    mov esi, eax
    xor ecx, ecx
.pc_len:
    mov al, [esi + ecx]     ; read byte
    cmp al, 0
    je .pc_have_len
    inc ecx
    jmp .pc_len
.pc_have_len:
    mov eax, 4
    mov ebx, 1
    mov edx, ecx
    mov ecx, esi
    int 0x80
    popad
    ret

; ---------- small_write: write single byte in tmp_buf (DL = char) ----------
; usage: mov dl, 'X' ; call small_write
small_write:
    pushad
    lea eax, [tmp_buf]
    mov byte [eax], dl
    mov byte [eax+1], 0
    lea eax, [tmp_buf]
    call print_cstr
    popad
    ret

; ---------- print_number_in_money_str: EAX = number; uses money_str buffer ----------
; (sonuna NUL koyup sys_write ile yazdır)
print_number_in_money_str:
    pushad
    lea edi, [money_str + 11]
    ; int_to_ascii expects EAX = number, EDI = end pointer
    ; our int_to_ascii uses: eax = number, edi = end, and returns with edi pointing to start
    call int_to_ascii
    ; edi -> start of ASCII, money_str+11 - start = length-1 ...
    mov eax, money_str
    add eax, 11
    sub eax, edi
    mov edx, eax   ; length
    mov ecx, edi   ; pointer
    mov eax, 4
    mov ebx, 1
    int 0x80
    popad
    ret

; ---------- print_hand_state: prints Dealer's and Player's hands ----------
; uses byte [input] as phase: 0 = dealer partial (show first card + '?'), 1 = full dealer
print_hand_state:
    pushad
    mov bl, byte [phase]        ; phase

    ; print "Dealer's Hand: "
    lea eax, [dealer_hand_msg]
    call print_cstr

    ; --- print first dealer card ---
    movzx ecx, byte [dealer_cards]               ; cl = value
    cmp cl, 11
    je .dealer_first_A
    cmp cl, 10
    je .dealer_first_10
    ; digit 2..9
    add cl, '0'
    mov dl, cl
    call small_write
    jmp .dealer_after_first

.dealer_first_10:
    mov dl, '1'
    call small_write
    ; write '0' separately (small_write writes one char; we want "10")
    mov dl, '0'
    call small_write
    jmp .dealer_after_first

.dealer_first_A:
    mov dl, 'A'
    call small_write

.dealer_after_first:
    ; print space
    mov dl, ' '
    call small_write

    ; if partial -> print '?'
    cmp bl, 0
    je .dealer_print_qmark

    ; else print remaining dealer cards
    mov esi, 1
    mov ecx, [dealer_card_count]
.dealer_loop:
    cmp esi, ecx
    jge .dealer_paren
    movzx edx, byte [dealer_cards + esi]
    cmp dl, 11
    je .dealer_mid_A
    cmp dl, 10
    je .dealer_mid_10
    add dl, '0'
    call small_write
    jmp .dealer_mid_after

.dealer_mid_10:
    mov dl, '1'
    call small_write
    mov dl, '0'
    call small_write
    jmp .dealer_mid_after

.dealer_mid_A:
    mov dl, 'A'
    call small_write

.dealer_mid_after:
    mov dl, ' '
    call small_write
    inc esi
    jmp .dealer_loop

.dealer_print_qmark:
    mov dl, '?'
    call small_write
    mov dl, ' '
    call small_write
    jmp .dealer_paren

.dealer_paren:
    ; print " ("
    lea eax, [open_par]
    call print_cstr

    cmp bl, 0
	je .dealer_partial_compute

    ; full: compute dealer score and print
    lea esi, [dealer_cards]
    mov ecx, [dealer_card_count]
	call print_low_high_from_cards
    jmp .dealer_close_paren

.dealer_partial_compute:
	lea esi, [dealer_cards]
	mov ecx, 1
	call print_low_high_from_cards
	jmp .dealer_close_paren

.dealer_close_paren:
    lea eax, [close_par]
    call print_cstr
    lea eax, [newline]
    call print_cstr

    ; --- Player line ---
    lea eax, [player_hand_msg]
    call print_cstr

    mov esi, 0
    mov ecx, [player_card_count]
.ploop:
    cmp esi, ecx
    jge .player_paren
    movzx edx, byte [player_cards + esi]
    cmp dl, 11
    je .player_A
    cmp dl, 10
    je .player_10
    add dl, '0'
    mov dl, dl
    call small_write
    jmp .player_after_print

.player_10:
    mov dl, '1'
    call small_write
    mov dl, '0'
    call small_write
    jmp .player_after_print

.player_A:
    mov dl, 'A'
    call small_write

.player_after_print:
    mov dl, ' '
    call small_write
    inc esi
    jmp .ploop

.player_paren:
    ; print " ("
    lea eax, [open_par]
    call print_cstr

    ; compute player score and print
    lea esi, [player_cards]
    mov ecx, [player_card_count]
	call print_low_high_from_cards

    ; print ")"
    lea eax, [close_par]
    call print_cstr
    lea eax, [newline]
    call print_cstr

    popad
    ret

_start:
    mov dword [money], 100     ; Oyuncunun parası
	jmp start_round

start_round:
    call init_deck             ; Deste hazırla

	mov byte [phase], 0

	mov byte [player_natural], 0
    mov byte [dealer_natural], 0
    mov byte [player_six], 0
    mov byte [dealer_six], 0

    ; Kart sayacı / ace sayacı sıfırla
    xor eax, eax
    mov [player_card_count], eax
    mov [dealer_card_count], eax
    mov [player_ace_count], eax
    mov [dealer_ace_count], eax

    ; Bakiye stringe çevir → int_to_ascii kullan
    mov eax, [money]
    lea edi, [money_str + 11]
    call int_to_ascii

    ; 1. Hoş geldiniz mesajını yazdır
    mov eax, 4          ; sys_write
    mov ebx, 1          ; stdout
    lea ecx, [welcome_msg]  ; mesajın adresi
    mov edx, welcome_msg_len  ; mesajın uzunluğu
    int 0x80            ; sistem çağrısını yap

    ; 2. Para mesajını yazdır
    mov eax, 4          ; sys_write
    mov ebx, 1          ; stdout
    lea ecx, [money_msg]  ; mesajın adresi
    mov edx, money_msg_len  ; mesajın uzunluğu
    int 0x80

    ; 3. Para miktarını yazdır
    mov eax, 4
    mov ebx, 1
    mov ecx, edi

    mov eax, money_str
    add eax, 11      ; money_str + 12 - 1
    sub eax, edi     ; (money_str + 11) - edi
    mov edx, eax     ; edx = yazdırılacak karakter sayısı

    mov eax, 4
    int 0x80

    ; 4. Newline yazdır
    mov eax, 4
    mov ebx, 1
    lea ecx, [newline]
    mov edx, 1
    int 0x80

; -----------------------------------------
; GET_BET_LOOP
; -----------------------------------------
get_bet_loop:
    ; (opsiyonel) ekranı temizle
    ; lea eax, [clear_screen]
    ; call print_cstr

    ; prompt
    lea eax, [bet_msg]
    call print_cstr

    ; read input
    mov eax, 3
    mov ebx, 0
    lea ecx, [input]
    mov edx, 16
    int 0x80

    ; nothing read -> retry
    test eax, eax
    jz .bad_bet_input

    ; sanitize newline -> replace first newline or NUL with 0
    mov esi, input
    mov ecx, eax            ; bytes read
.sanitize_loop2:
    mov al, [esi]
    cmp al, 0x0A
    je .found_nl2
    cmp al, 0
    je .found_nl2
    inc esi
    dec ecx
    jnz .sanitize_loop2
.found_nl2:
    mov byte [esi], 0

    ; validate characters: must be at least 1 digit, all '0'..'9'
    mov esi, input
    xor edi, edi            ; digit_count = 0
.validate_chars2:
    mov al, [esi]
    cmp al, 0
    je .validate_done2
    cmp al, '0'
    jb .bad_bet_input
    cmp al, '9'
    ja .bad_bet_input
    inc edi
    inc esi
    jmp .validate_chars2
.validate_done2:
    cmp edi, 1
    jl .bad_bet_input

    ; ---------- SAFE PARSE with clear registers ----------
    pushad

    ; prepare limits: EBX = money, ECX = money_div10, EDI = money_mod
    mov ebx, [money]        ; EBX = money
    mov eax, ebx
    xor edx, edx
    mov ecx, 10
    div ecx                 ; EAX = money_div10, EDX = money_mod
    mov ecx, eax            ; ECX = money_div10
    mov edi, edx            ; EDI = money_mod

    ; parse digits into EAX
    xor eax, eax            ; parsed = 0
    lea esi, [input]

.safe_parse2:
    mov dl, [esi]           ; char -> DL (EAX korunur)
    cmp dl, 0
    je .safe_done2
    sub dl, '0'             ; dl = digit (0..9)
    movzx edx, dl           ; edx = digit (zero-extended)

    ; check overflow condition:
    ; if parsed > money_div10 -> overflow
    cmp eax, ecx
    ja .parse_overflow2
    ; if parsed == money_div10 and digit > money_mod -> overflow
    cmp eax, ecx
    jne .safe_update2
    cmp edx, edi
    ja .parse_overflow2

.safe_update2:
    ; parsed = parsed*10 + digit
    imul eax, eax, 10       ; eax *= 10
    add eax, edx
    inc esi
    jmp .safe_parse2

.safe_done2:
    ; reject zero
    cmp eax, 0
    jle .parse_overflow2

    mov [bet_amount], eax
    popad
    jmp .bet_ok2

.parse_overflow2:
    popad
    lea eax, [invalid_bet_msg]
    call print_cstr
    jmp get_bet_loop

.bad_bet_input:
    lea eax, [invalid_bet_msg]
    call print_cstr
    jmp get_bet_loop

.bet_ok2:
    call draw_card
    mov byte [player_cards + 0], al
    cmp al, 11
    jne .skip1
    inc dword [player_ace_count]
.skip1:
    call draw_card
    mov byte [player_cards + 1], al
    cmp al, 11
    jne .skip2
    inc dword [player_ace_count]
.skip2:
    mov dword [player_card_count], 2

    ; Krupiyeye 2 kart
    call draw_card
    mov byte [dealer_cards + 0], al
    cmp al, 11
    jne .skip3
    inc dword [dealer_ace_count]
.skip3:
    call draw_card
    mov byte [dealer_cards + 1], al
    cmp al, 11
    jne .skip4
    inc dword [dealer_ace_count]
.skip4:
    mov dword [dealer_card_count], 2

    ; hesaplama zaten var — sonra player turn
    jmp player_turn

player_turn:
    ; player turn loop
.player_turn_loop:
    ; show hand
    call print_hand_state

    ; get h/s
    call get_hit_or_stand_loop
    ; returned char in AL (lowercase)
    cmp al, 'h'
    je .player_do_hit
    cmp al, 's'
    je .player_done

.player_do_hit:
    call player_hit
    ; after hit, compute player score
    lea esi, [player_cards]
    mov ecx, [player_card_count]
    mov edx, [player_ace_count]
    call calculate_score
    cmp eax, 21
    jg .player_bust  ; >21 -> lost
    ; else continue loop
    jmp .player_turn_loop

.player_bust:
    mov byte [phase], 1
	call print_hand_state
    jmp player_lost   ; label exists already

.player_done:
    ; player stands -> dealer turn
    call dealer_turn

    ; hesaplamaları ve flag'leri al (calc_set_* fonksiyonları score+flags ayarlamalı)
    lea esi, [player_cards]
    mov ecx, [player_card_count]
    mov edx, [player_ace_count]
    call calc_set_player_flags    ; doldurur: [player_score], [player_natural], [player_six]

    lea esi, [dealer_cards]
    mov ecx, [dealer_card_count]
    mov edx, [dealer_ace_count]
    call calc_set_dealer_flags    ; doldurur: [dealer_score], [dealer_natural], [dealer_six]

    ; --- 1) Player bust? (safety) ---
    mov eax, [player_score]
    cmp eax, 21
    jg player_lost        ; player zaten patlamışsa kaybet

    ; --- 2) Dealer busted? özel durum: player natural önceliği ---
    mov ebx, [dealer_score]
    cmp ebx, 21
    ja .dealer_busted

    ; --- 3) Neither busted: NATURAL kontrolü ---
    mov al, [player_natural]
    mov bl, [dealer_natural]
    cmp al, bl
    jne .nat_diff
    cmp al, 1
    je player_push         ; her ikisi de natural -> push
    jmp .check_six         ; ikisi de değil -> six-card kontrolüne geç

.nat_diff:
    cmp al, 1
    je .player_nat_only
    cmp bl, 1
    je .dealer_nat_only

.player_nat_only:
    call player_natural_win
    jmp show_result

.dealer_nat_only:
    jmp player_lost

    ; --- 4) Six-card-charlie kontrolü ---
.check_six:
    mov al, [player_six]
    mov bl, [dealer_six]
    cmp al, bl
    jne .six_diff
    cmp al, 1
    je .both_six_compare   ; her ikisi de six-card ise puana bak
    ; ikisi de değil -> normal karşılaştır
    jmp .normal_compare

.six_diff:
    cmp al, 1
    je player_won
    jmp player_lost

.both_six_compare:
    mov eax, [player_score]
    mov ebx, [dealer_score]
    cmp eax, ebx
    ja player_won
    jb player_lost
    jmp player_push

    ; --- 5) Normal skor karşılaştırması ---
.normal_compare:
    mov eax, [player_score]
    mov ebx, [dealer_score]
    cmp eax, ebx
    ja player_won
    jb player_lost
    jmp player_push

    ; --- 2a) branch: dealer busted ---
.dealer_busted:
    ; dealer patladı, player patlamamıştı (player patlaması zaten elenmişti)
    mov al, [player_natural]
    cmp al, 1
    jne .dealer_busted_no_nat

    ; player natural ise natural payout al
    call player_natural_win
    jmp show_result

.dealer_busted_no_nat:
    ; player natural değil -> normal win
    jmp player_won
; -----------------------------------------

	mov byte [phase], 0    ; phase = 0 (dealer partial)

; ---------------------------
; get_hit_or_stand_loop
; - döngüyle 'h' veya 's' okur (küçük harf veya büyük harf kabul)
; - return: AL = 'h' veya 's' (ascii)
; ---------------------------
get_hit_or_stand_loop:
    pushad
.read_loop:
    ; prompt
    lea eax, [hit_msg]
    call print_cstr

    ; read 2 byte (char + newline)
    mov eax, 3
    mov ebx, 0
    lea ecx, [input]
    mov edx, 4
    int 0x80
    test eax, eax
    jz .read_loop

    ; sanitize: first char in [input]
    mov al, [input]
    cmp al, 0
    je .read_loop

    ; normalize to lowercase if uppercase A-Z
    cmp al, 'A'
    jb .chk_char_a
    cmp al, 'Z'
    ja .chk_char_a
    add al, 32  ; make lowercase

.chk_char_a:
    cmp al, 'h'
    je .got_h
    cmp al, 's'
    je .got_s
    ; invalid -> loop
    lea eax, [invalid_action_msg] ; invalid action message
    call print_cstr
    jmp .read_loop

.got_h:
    mov byte [tmp_buf], al   ; seçimi belleğe kaydet (tmp_buf zaten bss'de var)
    popad
    mov al, [tmp_buf]       ; bellekteki sonucu geri al
    ret

.got_s:
    mov byte [tmp_buf], al
    popad
    mov al, [tmp_buf]
    ret

; ask_replay: prompt replay_msg, read input, normalize to lowercase, accept 'y' or 'n'
; returns: tmp_buf[0] = 'y' or 'n'
ask_replay:
    pushad
.ask_loop:
    lea eax, [replay_msg]
    call print_cstr

    ; read up to 4 bytes (char + newline); reuse input buffer
    mov eax, 3
    mov ebx, 0
    lea ecx, [input]
    mov edx, 4
    int 0x80
    test eax, eax
    jz .ask_loop

    ; take first byte
    mov al, [input]
    cmp al, 0
    je .ask_loop

    ; normalize uppercase A-Z -> a-z
    cmp al, 'A'
    jb .ask_chk
    cmp al, 'Z'
    ja .ask_chk
    add al, 32

.ask_chk:
    cmp al, 'y'
    je .ask_yes
    cmp al, 'n'
    je .ask_no

    ; invalid -> mesaj ve tekrar sor
    lea eax, [invalid_action_msg]
    call print_cstr
    jmp .ask_loop

.ask_yes:
    mov byte [tmp_buf], 'y'
    popad
    ret

.ask_no:
    mov byte [tmp_buf], 'n'
    popad
    ret

; ---------------------------
; player_hit: draw card for player, update counts and ace count
; uses AL = card value returned by draw_card
; ---------------------------
player_hit:
    pushad
    call draw_card           ; AL = card (8-bit)
    movzx eax, al            ; EAX = card value
    ; store into player_cards[ player_card_count ]
    mov ecx, [player_card_count]
    mov edx, ecx
    mov ebx, player_cards
    add ebx, edx
    mov byte [ebx], al
    ; increment player_card_count
    inc dword [player_card_count]
    ; if Ace (11) then inc player_ace_count
    cmp al, 11
    jne .ph_noace
    inc dword [player_ace_count]
.ph_noace:
    popad
    ret

; ---------------------------
; dealer_hit: draw card for dealer, update counts and ace count
; ---------------------------
dealer_hit:
    pushad
    call draw_card
    movzx eax, al
    mov ecx, [dealer_card_count]
    mov edx, ecx
    mov ebx, dealer_cards
    add ebx, edx
    mov byte [ebx], al
    inc dword [dealer_card_count]
    cmp al, 11
    jne .dh_noace
    inc dword [dealer_ace_count]
.dh_noace:
    popad
    ret

; ---------------------------
; dealer_turn: reveal and draw until >=17 (soft rules: ace handling via calculate_score)
; ---------------------------
dealer_turn:
    pushad
    ; reveal dealer
    mov byte [phase], 1
    call print_hand_state

.dealer_loop_start:
    ; compute dealer score
    lea esi, [dealer_cards]
    mov ecx, [dealer_card_count]
    mov edx, [dealer_ace_count]
    call calculate_score    ; EAX = dealer score
    cmp eax, 17
    jb .dealer_do_hit
    ; if 17 or more, stop (note: this treats 17 as stand; if you want soft 17 hit, change)
    jmp .dealer_done

.dealer_do_hit:
    call dealer_hit
    ; print new state
    call print_hand_state
    jmp .dealer_loop_start

.dealer_done:
    popad
    ret

player_won:
    ; money += bet_amount (overflow kontrolü)
    mov eax, [money]
    add eax, [bet_amount]
    jc .pw_overflow   ; unsigned overflow -> saturate to 0xFFFFFFFF
    mov [money], eax
    jmp show_result

.pw_overflow:
    mov eax, 0FFFFFFFFh
    mov [money], eax
    jmp show_result

player_lost:
    ; money -= bet_amount (underflow kontrolü)
    mov eax, [money]
    sub eax, [bet_amount]
    jc .pl_underflow  ; borrow => negative in unsigned => set to 0
    mov [money], eax
    jmp show_result

.pl_underflow:
    xor eax, eax
    mov [money], eax
    jmp show_result

player_natural_win:
    pushad

    ; yükle bet
    mov eax, [bet_amount]    ; EAX = bet
    mov ecx, eax             ; ECX = bet (kopya)

    ; eax = 3 * bet  (eax = bet + 2*bet)
    add eax, ecx             ; eax = 2*bet
    add eax, ecx             ; eax = 3*bet

    ; böl 2'ye: floor(3*bet/2)
    shr eax, 1               ; eax = floor(3*bet/2)

    ; money += eax  (overflow kontrolü)
    mov ebx, [money]
    add ebx, eax
    jc .pnw_overflow         ; carry -> overflow

    mov [money], ebx
    popad
    ret

.pnw_overflow:
    mov dword [money], 0FFFFFFFFh
    popad
    ret

player_push:
    ; beraberlik - para değişmez
    jmp show_result

show_result:
    ; money → ASCII (money_str) dönüşümü
    mov eax, [money]
    lea edi, [money_str + 11]
    call int_to_ascii

    ; "Bakiyeniz: " mesajı
    mov eax, 4
    mov ebx, 1
    lea ecx, [money_msg]
    mov edx, money_msg_len
    int 0x80

    ; money_str yazdır
    mov eax, money_str
    add eax, 11
    sub eax, edi
    mov edx, eax
	mov ecx, edi

    mov eax, 4
	mov ebx, 1
    int 0x80

    ; newline
    mov eax, 4
    mov ebx, 1
    lea ecx, [newline]
    mov edx, 1
    int 0x80

    ; money güncellendikten sonra: para 0 mı kontrol et
    cmp dword [money], 0
    jne .ask_replay_label   ; para > 0 ise yeniden oynama sorusuna git

    ; para 0 ise oyun bitti mesajı göster ve çık
    lea eax, [game_over_msg]
    call print_cstr
    je .do_exit             ; veya senin exit etiketin neyse ona git

.ask_replay_label:
    ; ask replay
    call ask_replay
    mov al, [tmp_buf]
    cmp al, 'y'
    je start_round
    cmp al, 'n'
    je .do_exit
    jmp ask_replay

.do_exit:
	lea eax, [ending_msg]
	call print_cstr
    mov eax,1
    xor ebx,ebx
    int 0x80
