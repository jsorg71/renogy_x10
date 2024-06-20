
OBJS=renogy_influx.o renogy_influx_log.o

CFLAGS_LIBMODBUS=$(shell pkg-config --cflags libmodbus)
CFLAGS=-O2 -Wall $(CFLAGS_LIBMODBUS)

LDFLAGS=

LIBS_LIBMODBUS=$(shell pkg-config --libs libmodbus)
LIBS=$(LIBS_LIBMODBUS)

renogy_influx: $(OBJS)
	$(CC) -o renogy_influx $(OBJS) $(LDFLAGS) $(LIBS)

clean:
	rm -f renogy_influx $(OBJS)
