
OBJS=pzem.o

CFLAGS_LIBMODBUS=$(shell pkg-config --cflags libmodbus)
CFLAGS=-O2 -Wall $(CFLAGS_LIBMODBUS)

LDFLAGS=

LIBS_LIBMODBUS=$(shell pkg-config --libs libmodbus)
LIBS=$(LIBS_LIBMODBUS)

pzem: $(OBJS)
	$(CC) -o pzem $(OBJS) $(LDFLAGS) $(LIBS)

clean:
	rm -f pzem $(OBJS)

