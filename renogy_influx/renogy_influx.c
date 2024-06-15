
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <netdb.h>
#include <sys/errno.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <modbus.h>

/*
POST /write?db=voltages&u=&p= HTTP/1.1
Host: 205.5.60.14:8086
Content-Length: 37

renogy,host=serverA value=203.000
*/

static int g_renogy_id = 1;
static int g_renogy_voltage_reg = 0x0101;

static const char* g_influx_database = "voltages";
static const char* g_influx_token = "Wh4XF_BN120-dvfZiI0T6L7DIdG7Ma8JnSMW6GnMTpT5uG4qDlBFsEGS_jwo9eBD2pf2jtra7sgi0ajl5R-oEA==";
static const char* g_influx_hostname = "205.5.60.14";
static const int g_influx_port = 8086;
static const int g_secs = 60;

int
main(int argc, char** argv)
{
    modbus_t* ctx;
    modbus_error_recovery_mode er_mode;
    int error;
    int value;
    int sck;
    int to_send;
    int sent;
    uint16_t tab_rp_registers[4];
    struct sockaddr_in serv_addr;
    char* buffer1;
    char* buffer2;
    char* buffer3;

    buffer1 = (char*)malloc(1024 * 3);
    if (buffer1 == NULL)
    {
        printf("main: malloc failed\n");
        return 1;
    }
    buffer2 = buffer1 + 1024;
    buffer3 = buffer2 + 1024;

    ctx = modbus_new_rtu("/dev/ttyS0", 9600, 'N', 8, 1);
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
    memset(&serv_addr, 0, sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_addr.s_addr = inet_addr(g_influx_hostname);
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
        memset(tab_rp_registers, 0, sizeof(tab_rp_registers));
        error = modbus_read_registers(ctx, g_renogy_voltage_reg, 1,
                                      tab_rp_registers);
        if (error == -1)
        {
            break;
        }
        value = tab_rp_registers[0];
        snprintf(buffer2, 1023, "renogy,host=serverA value=%d\n", value);
        snprintf(buffer1, 1023, "POST /api/v2/write?org=org1&bucket=%s HTTP/1.1\r\n"
                 "Host: %s:%d\r\n"
                 "Authorization: Token %s\r\n"
                 "Content-Type: text/plain; charset=utf-8\r\n"
                 "Accept: application/json\r\n"
                 "Content-Length: %d\r\n\r\n",
                 g_influx_database,
                 g_influx_hostname,
                 g_influx_port,
                 g_influx_token,
                 strlen(buffer2));
        to_send = strlen(buffer1);
        sent = write(sck, buffer1, to_send);
        if (to_send != sent)
        {
            printf("main: 1 tcp to_send %d sent %d\n", to_send, sent);
            break;
        }
        to_send = strlen(buffer2);
        sent = write(sck, buffer2, to_send);
        if (to_send != sent)
        {
            printf("main: 2 tcp to_send %d sent %d\n", to_send, sent);
            break;
        }
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
    }
    close(sck);
    modbus_free(ctx);
    free(buffer1);
    return 0;
}
