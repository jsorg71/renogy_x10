
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <netdb.h>
#include <time.h>
#include <sys/errno.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <modbus.h>

#define RENOGY_SERIAL_INFO ("/dev/ttyS0", 9600, 'N', 8, 1)
static const int g_renogy_id = 1;
static const int g_renogy_voltage_reg = 0x0101;

static const char* g_influx_database = "voltages";
static const char* g_influx_token =
    "Wh4XF_BN120-dvfZiI0T6L7DIdG7Ma8JnSMW6GnMTpT5"
    "uG4qDlBFsEGS_jwo9eBD2pf2jtra7sgi0ajl5R-oEA==";
static const char* g_influx_hostname = "server3.xrdp.org";
static const int g_influx_port = 8086;
static const int g_secs = 60;

struct buffers_t
{
    char buffer_out[2048];
    char buffer_con[64];
    char buffer_in[1024];
    char influx_ip[64];
};

/*****************************************************************************/
int
get_mstime(int* mstime)
{
    struct timespec ts;
    int the_tick;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    {
        return 1;
    }
    the_tick = ts.tv_nsec / 1000000;
    the_tick += ts.tv_sec * 1000;
    *mstime = the_tick;
    return 0;
}

/*****************************************************************************/
int
main(int argc, char** argv)
{
    modbus_t* ctx;
    modbus_error_recovery_mode er_mode;
    int error;
    int value;
    int sck;
    int buffer_out_bytes;
    int buffer_con_bytes;
    int buffer_out_sent;
    int buffer_in_read;
    int now;
    int wait_mstime;
    int start_send_time;
    int end_send_time;
    int fatal;
    int bm1;
    uint16_t tab_rp_registers[4];
    struct sockaddr_in serv_addr;
    struct hostent *he;
    fd_set rfds;
    fd_set wfds;
    struct timeval time;
    struct buffers_t* buffers;

    fatal = 0;
    now = 0;
    buffers = (struct buffers_t*)malloc(sizeof(struct buffers_t));
    if (buffers == NULL)
    {
        printf("main: malloc failed\n");
        return 1;
    }
    ctx = modbus_new_rtu RENOGY_SERIAL_INFO;
    if (ctx == NULL)
    {
        printf("main: modbus_new_rtu failed\n");
        free(buffers);
        return 1;
    }
    printf("main: modbus_new_rtu ok\n");
    er_mode = MODBUS_ERROR_RECOVERY_LINK | MODBUS_ERROR_RECOVERY_PROTOCOL;
    error = modbus_set_error_recovery(ctx, er_mode);
    printf("main: modbus_set_error_recovery error %d\n", error);
    modbus_set_slave(ctx, g_renogy_id);
    error = modbus_connect(ctx);
    if (error == -1)
    {
        printf("main: Connection failed: %s\n", modbus_strerror(errno));
        modbus_free(ctx);
        free(buffers);
        return 1;
    }
    printf("main: Connection ok\n");
    sck = socket(AF_INET, SOCK_STREAM, 0);
    if (sck == -1)
    {
        printf("main: tcp socket create failed\n");
        modbus_free(ctx);
        free(buffers);
        return 1;
    }
    printf("main: tcp sck created ok\n");
    he = gethostbyname(g_influx_hostname);
    if ((he == NULL) ||
        (he->h_addr_list == NULL) ||
        (he->h_addr_list[0] == NULL))
    {
        printf("main: gethostbyname failed\n");
        modbus_free(ctx);
        free(buffers);
        return 1;
    }
    strncpy(buffers->influx_ip,
            inet_ntoa(*((struct in_addr*)(he->h_addr_list[0]))),
            sizeof(buffers->influx_ip) - 1);
    buffers->influx_ip[sizeof(buffers->influx_ip) - 1] = 0;
    memset(&serv_addr, 0, sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_addr.s_addr = inet_addr(buffers->influx_ip);
    serv_addr.sin_port = htons(g_influx_port);
    printf("main: starting tcp connect\n");
    error = connect(sck, (struct sockaddr *) &serv_addr, sizeof(serv_addr));
    if (error < 0)
    {
        printf("main: tcp connect failed\n");
        close(sck);
        modbus_free(ctx);
        free(buffers);
        return 1;
    }
    printf("main: tcp connected\n");
    for (;;)
    {
        if (get_mstime(&now) != 0)
        {
            printf("main: get_mstime failed\n");
            break;
        }
        start_send_time = now;
        memset(tab_rp_registers, 0, sizeof(tab_rp_registers));
        error = modbus_read_registers(ctx, g_renogy_voltage_reg, 1,
                                      tab_rp_registers);
        if (error == -1)
        {
            printf("main: modbus_read_registers failed\n");
            break;
        }
        value = tab_rp_registers[0];
        snprintf(buffers->buffer_con, sizeof(buffers->buffer_con),
                 "renogy,host=serverA value=%d\n", value);
        buffer_con_bytes = strlen(buffers->buffer_con);
        snprintf(buffers->buffer_out, sizeof(buffers->buffer_out),
                 "POST /api/v2/write?org=org1&bucket=%s HTTP/1.1\r\n"
                 "Host: %s:%d\r\n"
                 "Authorization: Token %s\r\n"
                 "Content-Type: text/plain; charset=utf-8\r\n"
                 "Accept: application/json\r\n"
                 "Content-Length: %d\r\n\r\n%s",
                 g_influx_database,
                 g_influx_hostname,
                 g_influx_port,
                 g_influx_token,
                 buffer_con_bytes, buffers->buffer_con);
        buffer_out_bytes = strlen(buffers->buffer_out);
        buffer_out_sent = 0;
        buffer_in_read = 0;
        end_send_time = start_send_time + g_secs * 1000;
        memset(buffers->buffer_in, 0, sizeof(buffers->buffer_in));
        for (;;)
        {
            FD_ZERO(&rfds);
            FD_ZERO(&wfds);
            FD_SET(sck, &rfds);
            if (buffer_out_sent < buffer_out_bytes)
            {
                FD_SET(sck, &wfds);
            }
            if (get_mstime(&now) != 0)
            {
                printf("main: get_mstime failed\n");
                fatal = 1;
                break;
            }
            wait_mstime = end_send_time - now;
            if (wait_mstime < 0)
            {
                break;
            }
            time.tv_sec = wait_mstime / 1000;
            time.tv_usec = (wait_mstime * 1000) % 1000000;
            error = select(sck + 1, &rfds, &wfds, NULL, &time);
            if (error < 1)
            {
                if (error == 0)
                {
                    /* timeout */
                    if (strstr(buffers->buffer_in, "204 No Content") == NULL)
                    {
                        printf("main: some http error [%s]\n",
                               buffers->buffer_in);
                        fatal = 1;
                        break;
                    }
                    /* all ok */
                    //printf("ok\n");
                    break;
                }
                printf("main: select failed\n");
                fatal = 1;
                break;
            }
            if (FD_ISSET(sck, &rfds))
            {
                bm1 = sizeof(buffers->buffer_in) - 1;
                if (buffer_in_read >= bm1)
                {
                    printf("main: too big read\n");
                    fatal = 1;
                    break;
                }
                error = read(sck, buffers->buffer_in + buffer_in_read,
                             bm1 - buffer_in_read);
                if (error < 1)
                {
                    printf("main: read failed\n");
                    fatal = 1;
                    break;
                }
                buffer_in_read += error;
                //printf("read %d\n", error);
            }
            if (FD_ISSET(sck, &wfds))
            {
                if (buffer_out_sent < buffer_out_bytes)
                {
                    error = write(sck, buffers->buffer_out + buffer_out_sent,
                                  buffer_out_bytes - buffer_out_sent);
                    if (error < 1)
                    {
                        printf("main: write failed\n");
                        fatal = 1;
                        break;
                    }
                    buffer_out_sent += error;
                    //printf("write %d\n", error);
                }
            }
        }
        if (fatal)
        {
            break;
        }
    }
    close(sck);
    modbus_free(ctx);
    free(buffers);
    return 0;
}
