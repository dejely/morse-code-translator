CC ?= cc
NASM ?= nasm
CFLAGS ?= -O2 -g -Wall -Wextra -Wpedantic

translate: main.o decoder.o
	$(CC) $(LDFLAGS) -o $@ $^

decoder.o: decoder.asm
	$(NASM) -f elf64 -g -F dwarf -o $@ $<

.PHONY: clean
clean:
	rm -f translate main.o decoder.o
