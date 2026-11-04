# Host unit tests for the firmware's pure-C parts. Usage: make -C hardware/tests
SRC = ../hid_bridge/src
CFLAGS = -std=c11 -Wall -Wextra -g -fsanitize=address,undefined

# mbedtls 3.x (4.x dropped the ECP API): Homebrew's mbedtls@3, an older Homebrew mbedtls, or the system one (apt libmbedtls-dev)
BREW := $(shell brew --prefix 2>/dev/null)
MBEDTLS := $(firstword $(wildcard $(BREW)/opt/mbedtls@3 $(BREW)/opt/mbedtls) /usr)

test: test_main.c $(SRC)/bplist/bplist.c $(SRC)/video/gop.c $(SRC)/airplay/keystream.c $(SRC)/cli/cli_proto.c $(SRC)/hid/arbiter.c $(SRC)/log/logring.c $(SRC)/airplay/mdns.c
	$(CC) $(CFLAGS) -Istubs -I$(MBEDTLS)/include -o $@ $^ -L$(MBEDTLS)/lib -lmbedcrypto
	./test

clean:
	rm -f test

.PHONY: clean
