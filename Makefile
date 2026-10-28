# st - native macOS build (Cocoa frontend instead of X11)

CC = clang
CFLAGS = -O2 -Wall -D_DARWIN_C_SOURCE -DVERSION=\"0.9-mac\"
LDFLAGS = -framework Cocoa -lutil
OBJS = st.o mac.o

st: $(OBJS)
	$(CC) -o $@ $(OBJS) $(LDFLAGS)

st.o: st.c st.h win.h
	$(CC) $(CFLAGS) -c st.c

mac.o: mac.m st.h win.h
	$(CC) $(CFLAGS) -fobjc-arc -c mac.m

clean:
	rm -f st $(OBJS)

.PHONY: clean
