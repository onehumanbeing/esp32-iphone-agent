# Simulated board for the esp32agent CLI: make -C hardware/tests/sim (see cli_sim.cpp).
HB = ../../hid_bridge
# mbedtls 3.x (4.x dropped the ECP API): Homebrew's mbedtls@3, an older Homebrew mbedtls, or the system one (apt libmbedtls-dev)
BREW := $(shell brew --prefix 2>/dev/null)
MBEDTLS := $(firstword $(wildcard $(BREW)/opt/mbedtls@3 $(BREW)/opt/mbedtls) /usr)
FLAGS = -Wall -g -I. -I$(HB) -I$(MBEDTLS)/include
C_SRC = $(HB)/src/cli/cli_proto.c $(HB)/src/video/gop.c $(HB)/src/log/logring.c

cli_sim: cli_sim.cpp $(HB)/cli_link.cpp $(C_SRC)
	for f in $(C_SRC); do $(CC) $(FLAGS) -std=c11 -c $$f -o $$(basename $$f .c).o || exit 1; done
	$(CXX) $(FLAGS) -std=c++17 -o $@ cli_sim.cpp $(HB)/cli_link.cpp cli_proto.o gop.o logring.o -L$(MBEDTLS)/lib -lmbedcrypto

screen.h264:
	ffmpeg -loglevel error -y -f lavfi -i testsrc=size=480x1040:rate=5 -t 6 -c:v libx264 -profile:v baseline -g 1000 -bf 0 -pix_fmt yuv420p $@

clean:
	rm -f cli_sim screen.h264 *.o

.PHONY: clean
