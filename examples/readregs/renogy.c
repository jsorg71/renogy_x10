
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <modbus.h>

static int g_debug = 0;
static int g_renogy_id = 1;

int
main(int argc, char** argv)
{
    modbus_t* ctx;
    uint32_t response_sec;
    uint32_t response_usec;
    modbus_error_recovery_mode er_mode;
    uint16_t tab_rp_registers[4];
    int error;

    ctx = modbus_new_rtu("/dev/ttyS0", 9600, 'N', 8, 1);
    if (ctx == NULL)
    {
        return 1;
    }
    printf("main: modbus_new_rtu ok\n");

    if (g_debug)
    {
        error = modbus_set_debug(ctx, TRUE);
        printf("modbus_set_debug error %d\n", error);
    }

    er_mode = MODBUS_ERROR_RECOVERY_LINK | MODBUS_ERROR_RECOVERY_PROTOCOL;
    error = modbus_set_error_recovery(ctx, er_mode);
    printf("modbus_set_error_recovery error %d\n", error);

    modbus_set_slave(ctx, g_renogy_id);

    error = modbus_get_response_timeout(ctx,
                                        &response_sec,
                                        &response_usec);
    printf("modbus_get_response_timeout error %d sec %d usec %d\n", error,
           response_sec, response_usec);
    //modbus_set_response_timeout(ctx, 2, 0);

    error = modbus_connect(ctx);
    if (error == -1)
    {
        printf("main: Connection failed: %s\n", modbus_strerror(errno));
        modbus_free(ctx);
        return 1;
    }
    printf("main: Connection ok\n");

    tab_rp_registers[0] = 0;
    modbus_read_registers(ctx, 0x100, 1, tab_rp_registers);
    printf("modbus_read_registers 0x100 error %d read 0x%4.4X %d\n", error,
           tab_rp_registers[0], tab_rp_registers[0]);

    tab_rp_registers[0] = 0;
    modbus_read_registers(ctx, 0x101, 1, tab_rp_registers);
    printf("modbus_read_registers 0x101 error %d read 0x%4.4X %d\n", error,
           tab_rp_registers[0], tab_rp_registers[0]);

    modbus_free(ctx);
    return 0;
}

