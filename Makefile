NAME = snake
OBJS = main.o

CC = wla-6502
LD = wlalink

CFLAGS =
LDFLAGS =

all: $(NAME).nes

$(NAME).nes: $(NAME).rom header.bin
	cat header.bin $< > $@

$(NAME).rom: $(OBJS) linkfile
	$(LD) $(LDFLAGS) linkfile $@

%.o: %.s
	$(CC) $(CFLAGS) -o $<

main.o: sprites.chr

run: $(NAME).nes
	nestopia $(NAME).nes

clean:
	rm -f $(OBJS) $(NAME).rom $(NAME).nes

.PHONY: all clean run
