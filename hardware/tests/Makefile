# Host unit tests for the firmware's pure-C parts. Usage: make -C hardware/tests
SRC = ../hid_bridge/src
CFLAGS = -std=c11 -Wall -Wextra -g -fsanitize=address,undefined

MBEDTLS = $(shell brew --prefix mbedtls 2>/dev/null || echo /opt/homebrew)

test: test_main.c $(SRC)/bplist/bplist.c $(SRC)/video/gop.c $(SRC)/airplay/keystream.c $(SRC)/cli/cli_proto.c $(SRC)/hid/arbiter.c $(SRC)/log/logring.c
	$(CC) $(CFLAGS) -I$(MBEDTLS)/include -o $@ $^ -L$(MBEDTLS)/lib -lmbedcrypto
	./test

clean:
	rm -f test

.PHONY: clean
