
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <libserialport.h>

static const char* g_desired_port = "/dev/ttyS0";

/*****************************************************************************/
/* print a hex dump to stdout*/
void
hexdump(const void* p, int len)
{
    const unsigned char* line;
    int i;
    int thisline;
    int offset;

    line = (const unsigned char *)p;
    offset = 0;

    while (offset < len)
    {
        printf("%04x ", offset);
        thisline = len - offset;

        if (thisline > 16)
        {
            thisline = 16;
        }

        for (i = 0; i < thisline; i++)
        {
            printf("%02x ", line[i]);
        }

        for (; i < 16; i++)
        {
            printf("   ");
        }

        for (i = 0; i < thisline; i++)
        {
            printf("%c", (line[i] >= 0x20 && line[i] < 0x7f) ? line[i] : '.');
        }

        printf("%s", "\n");
        offset += thisline;
        line += thisline;
    }
}

/*****************************************************************************/
int
main_loop(struct sp_port* port, int fd)
{
    enum sp_return error;
    int max_fd;
    int lerror;
    int wait_mstime;
    fd_set rfds;
    struct timeval time;
    unsigned char in_buff[16];
    unsigned char out_buff[16];
    int loop_count;

    loop_count = 0;
    for (;;)
    {
        printf("main_loop: loop\n");
        max_fd = fd;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        wait_mstime = 5000;
        time.tv_sec = wait_mstime / 1000;
        time.tv_usec = (wait_mstime * 1000) % 1000000;
        lerror = select(max_fd + 1, &rfds, NULL, NULL, &time);
        //lerror = select(max_fd + 1, &rfds, NULL, NULL, NULL);
        if (lerror < 1)
        {
            if (lerror == 0) /* timeout */
            {
                printf("main_loop: select timeout loop_count %d\n", loop_count);
                if (loop_count == 0)
                {
                    for (;;)
                    {
                        out_buff[0] = 0x04;
                        out_buff[1] = 0x6E;
                        error = sp_blocking_write(port, out_buff, 2, 0);
                        printf("main_loop: sp_blocking_write 0x04 0x66 error %d\n",
                               error);
                        error = sp_blocking_read(port, in_buff, 1, 0);
                        printf("main_loop: sp_blocking_read error %d in_buff[0] %2.2X\n", error, in_buff[0]);
                        if ((error == 1) && (in_buff[0] == ((out_buff[0] + out_buff[1]) & 0xFF)))
                        {
                            out_buff[0] = 0x00;
                            error = sp_blocking_write(port, out_buff, 1, 0);
                            printf("main_loop: sp_blocking_write 0x00 error %d\n",
                                   error);
                            break;
                        }
                    }
                    error = sp_blocking_read(port, in_buff, 1, 0);
                    printf("main_loop: -- sp_blocking_read error %d in_buff[0] %2.2X\n", error, in_buff[0]);
                    for (;;)
                    {
                        out_buff[0] = 0x06;
                        //out_buff[1] = loop_count & 1 ? 0x62 : 0x63;
                        out_buff[1] = 0x62; /* on */
                        //out_buff[1] = 0x63; /* off */
                        error = sp_blocking_write(port, out_buff, 2, 0);
                        printf("main_loop: sp_blocking_write 0x86 0x64 error %d\n",
                               error);
                        error = sp_blocking_read(port, in_buff, 1, 0);
                        printf("main_loop: sp_blocking_read error %d in_buff[0] %2.2X\n", error, in_buff[0]);
                        if ((error == 1) && (in_buff[0] == ((out_buff[0] + out_buff[1]) & 0xFF)))
                        {
                            out_buff[0] = 0x00;
                            error = sp_blocking_write(port, out_buff, 1, 0);
                            printf("main_loop: sp_blocking_write 0x00 error %d\n",
                                   error);
                            break;
                        }
                    }
                    error = sp_blocking_read(port, in_buff, 1, 0);
                    printf("main_loop: -- sp_blocking_read error %d in_buff[0] %2.2X\n", error, in_buff[0]);
                }
                loop_count++;
            }
        }
        if (FD_ISSET(fd, &rfds))
        {
            printf("main_loop: fd is set\n");
            error = sp_blocking_read(port, in_buff, 1, 0);
            printf("main_loop: sp_blocking_read error %d\n", error);
            if (error > 0)
            {
                //hexdump(in_buff, error);
                switch (in_buff[0])
                {
                    case 0x55: /* Interface ready */
                        printf("main_loop: got 0x55, Interface ready\n");
                        break;
                    case 0x5A: /* Interface Poll Signal */
                        printf("main_loop: got 0x5A, Interface Poll Signal, "
                               "returning 0xC3\n");
                        out_buff[0] = 0xC3;
                        error = sp_blocking_write(port, out_buff, 1, 0);
                        printf("main_loop: sp_blocking_write 0xC3 error %d\n",
                               error);
                        break;
                    case 0xA5: /* time request */
                        printf("main_loop: got 0xA5, time request, returning "
                               "0x9B with 10 ms wait\n");
                        out_buff[0] = 0x9B;
                        error = sp_blocking_write(port, out_buff, 1, 0);
                        printf("main_loop: sp_blocking_write 0x9B error %d\n",
                               error);
                        usleep(10 * 1000); /* 10 milliseconds */
                        break;
                    default:
                        break;
                }
            }
        }
    }
    return 0;
}

/*****************************************************************************/
int
main(int argc, char** argv)
{
    enum sp_return error;
    struct sp_port* port;
    int fd;

    error = sp_get_port_by_name(g_desired_port, &port);
    printf("main: sp_get_port_by_name rv %d\n", error);
    if (error == SP_OK)
    {
        error = sp_open(port, SP_MODE_READ_WRITE);
        printf("main: sp_open rv %d\n", error);
        if (error == SP_OK)
        {
            error = sp_set_baudrate(port, 4800);
            printf("main: sp_set_baudrate rv %d\n", error);
            if (error == SP_OK)
            {
                error = sp_set_stopbits(port, 1);
                printf("main: sp_set_stopbits rv %d\n", error);
                if (error == SP_OK)
                {
                    error = sp_set_parity(port, SP_PARITY_NONE);
                    printf("main: sp_set_parity rv %d\n", error);
                    if (error == SP_OK)
                    {
                        error = sp_set_bits(port, 8);
                        printf("main: sp_set_bits rv %d\n", error);
                        if (error == SP_OK)
                        {
                            error = sp_get_port_handle(port, &fd);
                            printf("main: sp_get_port_handle rv %d fd %d\n",
                                   error, fd);
                            if (error == SP_OK)
                            {
                                main_loop(port, fd);
                            }
                        }
                    }
                }
            }
        }
    }
    return 0;
}
