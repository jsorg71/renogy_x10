
OBJS=libcm11a.o

CFLAGS=-O2 -Wall -Wextra

LIBS=-lserialport

LDFLAGS=

libcm11a.so: $(OBJS)
	$(CC) --shared -o libcm11a.so $(OBJS) $(LDFLAGS) $(LIBS)

clean:
	rm -f libcm11a.so $(OBJS)
	
test1: test1.o
	$(CC) -o test1 test1.o -L. -lcm11a
