
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
static int g_renogy_id = 1;
static int g_renogy_voltage_reg = 0x0101;

static const char* g_influx_database = "voltages";
static const char* g_influx_token =
    "Wh4XF_BN120-dvfZiI0T6L7DIdG7Ma8JnSMW6GnMTpT5"
    "uG4qDlBFsEGS_jwo9eBD2pf2jtra7sgi0ajl5R-oEA==";
static const char* g_influx_hostname = "server3.xrdp.org";
static const int g_influx_port = 8086;
static const int g_secs = 60;

#if 0
static int
my_write(int sck, const void* data, int bytes)
{
    int sent;
    int error;
    const char* ldata;

    sent = 0;
    ldata = (const char*)data;
    while (sent < bytes)
    {
        error = write(sck, ldata + sent, bytes - sent);
        if (error < 1)
        {
            return 1;
        }
        sent += error;
    }
    return 0;
}
#endif

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

int
main(int argc, char** argv)
{
    modbus_t* ctx;
    modbus_error_recovery_mode er_mode;
    int error;
    int value;
    int sck;
    int buffer1_bytes;
    int buffer2_bytes;
    int buffer1_sent;
    int buffer2_sent;
    int buffer3_read;
    int now;
    int wait_mstime;
    int start_send_time;
    int end_send_time;
    int fatal;
    //int last_send_time;
    uint16_t tab_rp_registers[4];
    struct sockaddr_in serv_addr;
    char* buffer1;
    char* buffer2;
    char* buffer3;
    struct hostent *he;
    char influx_ip[64];
    fd_set rfds;
    fd_set wfds;
    struct timeval time;

    fatal = 0;
    now = 0;
    buffer1 = (char*)malloc(1024 * 3);
    if (buffer1 == NULL)
    {
        printf("main: malloc failed\n");
        return 1;
    }
    buffer2 = buffer1 + 1024;
    buffer3 = buffer2 + 1024;
    ctx = modbus_new_rtu RENOGY_SERIAL_INFO;
    if (ctx == NULL)
    {
        printf("main: modbus_new_rtu failed\n");
        free(buffer1);
        return 1;
    }
    printf("main: modbus_new_rtu ok\n");
    er_mode = MODBUS_ERROR_RECOVERY_LINK | MODBUS_ERROR_RECOVERY_PROTOCOL;
    error = modbus_set_error_recovery(ctx, er_mode);
    printf("modbus_set_error_recovery error %d\n", error);
    modbus_set_slave(ctx, g_renogy_id);
    error = modbus_connect(ctx);
    if (error == -1)
    {
        printf("main: Connection failed: %s\n", modbus_strerror(errno));
        modbus_free(ctx);
        free(buffer1);
        return 1;
    }
    printf("main: Connection ok\n");
    sck = socket(AF_INET, SOCK_STREAM, 0);
    if (sck == -1)
    {
        printf("main: tcp socket create failed\n");
        modbus_free(ctx);
        free(buffer1);
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
        free(buffer1);
        return 1;
    }
    strncpy(influx_ip, inet_ntoa(*(struct in_addr*)(he->h_addr_list[0])), 63);
    influx_ip[63] = 0;
    memset(&serv_addr, 0, sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_addr.s_addr = inet_addr(influx_ip);
    serv_addr.sin_port = htons(g_influx_port);
    printf("main: starting tcp connect\n");
    error = connect(sck, (struct sockaddr *) &serv_addr, sizeof(serv_addr));
    if (error < 0)
    {
        printf("main: tcp connect failed\n");
        close(sck);
        modbus_free(ctx);
        free(buffer1);
        return 1;
    }
    printf("main: tcp connected\n");
    for (;;)
    {
        get_mstime(&now);
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
        snprintf(buffer2, 1023, "renogy,host=serverA value=%d\n", value);
        buffer2_bytes = strlen(buffer2);
        snprintf(buffer1, 1023,
                 "POST /api/v2/write?org=org1&bucket=%s HTTP/1.1\r\n"
                 "Host: %s:%d\r\n"
                 "Authorization: Token %s\r\n"
                 "Content-Type: text/plain; charset=utf-8\r\n"
                 "Accept: application/json\r\n"
                 "Content-Length: %d\r\n\r\n",
                 g_influx_database,
                 g_influx_hostname,
                 g_influx_port,
                 g_influx_token,
                 buffer2_bytes);
        buffer1_bytes = strlen(buffer1);
#if 1
        /* send 2 buffers out */
        buffer1_sent = 0;
        buffer2_sent = 0;
        for (;;)
        {
            FD_ZERO(&wfds);
            FD_SET(sck, &wfds);
            error = select(sck + 1, NULL, &wfds, NULL, NULL);
            if (error < 1)
            {
                printf("main: 1 select failed\n");
                fatal = 1;
                break;
            }
            if (FD_ISSET(sck, &wfds))
            {
                if (buffer1_sent < buffer1_bytes)
                {
                    error = write(sck, buffer1 + buffer1_sent, buffer1_bytes - buffer1_sent);
                    if (error < 1)
                    {
                        printf("main: write failed\n");
                        fatal = 1;
                        break;
                    }
                    buffer1_sent += error;
                }
                else if (buffer2_sent < buffer2_bytes)
                {
                    error = write(sck, buffer2 + buffer2_sent, buffer2_bytes - buffer2_sent);
                    if (error < 1)
                    {
                        printf("main: write failed\n");
                        fatal = 1;
                        break;
                    }
                    buffer2_sent += error;
                }
            }
            if (buffer2_sent >= buffer2_bytes)
            {
                //get_mstime(&now);
                //printf("main: write ok %10.10d diff %10.10d\n", now, now - last_send_time);
                break;
            }
        }
        //get_mstime(&now);
        //last_send_time = now;
        end_send_time = start_send_time + g_secs * 1000;
        /* wait up to g_secs for response */
        buffer3_read = 0;
        memset(buffer3, 0, 1024);
        for (;;)
        {
            FD_ZERO(&rfds);
            FD_SET(sck, &rfds);
            get_mstime(&now);
            wait_mstime = end_send_time - now;
            if (wait_mstime < 1)
            {
                break;
            }
            time.tv_sec = wait_mstime / 1000;
            time.tv_usec = (wait_mstime * 1000) % 1000000;
            error = select(sck + 1, &rfds, NULL, NULL, &time);
            if (error < 1)
            {
                if (error == 0) /* timeout */
                {
                    if (strstr(buffer3, "204 No Content") == NULL)
                    {
                        printf("main: some http error [%s]\n", buffer3);
                        fatal = 1;
                        break;
                    }
                    /* all ok */
                    //get_mstime(&now);
                    //printf("main: read ok %10.10d\n", now);
                    break;
                }
                printf("main: 2 select failed\n");
                fatal = 1;
                break;
            }
            if (FD_ISSET(sck, &rfds))
            {
                if (buffer3_read >= 1023)
                {
                    printf("main: too big read\n");
                    fatal = 1;
                    break;
                }
                error = read(sck, buffer3 + buffer3_read, 1023 - buffer3_read);
                if (error < 1)
                {
                    printf("main: read failed\n");
                    fatal = 1;
                    break;
                }
                //printf(buffer3);
            }
        }


#endif
#if 0
        buffer1_sent = write(sck, buffer1, buffer1_bytes);
        if (buffer1_sent != buffer1_bytes)
        {
            printf("main: tcp buffer1_sent %d buffer1_bytes %d\n",
                   buffer1_sent, buffer1_bytes);
            break;
        }
        buffer2_sent = write(sck, buffer2, buffer2_bytes);
        if (buffer2_sent != buffer2_bytes)
        {
            printf("main: tcp buffer2_sent %d buffer2_bytes %d\n",
                   buffer2_sent, buffer2_bytes);
            break;
        }
#endif
#if 0
        memset(buffer3, 0, 1024);
        error = read(sck, buffer3, 1023);
        if (error < 1)
        {
            printf("main: tcp read error %d\n", error);
            break;
        }
        if (strstr(buffer3, "204 No Content") == NULL)
        {
            printf("main: some http error [%s]\n", buffer3);
            break;
        }
        usleep(g_secs * 1000 * 1000);
#endif
        if (fatal)
        {
            break;
        }
    }
    close(sck);
    modbus_free(ctx);
    free(buffer1);
    return 0;
}
