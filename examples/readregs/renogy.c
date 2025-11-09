
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <modbus.h>

// now set to change shun type for id 6 pzem

static int g_debug = 1;
//static int g_renogy_id = 10;
static int g_renogy_id = 12;

int
main(int argc, char** argv)
{
    modbus_t* ctx;
    uint32_t response_sec;
    uint32_t response_usec;
    modbus_error_recovery_mode er_mode;
    uint16_t tab_rp_registers[4];
    int error;

    //ctx = modbus_new_rtu("/dev/ttyS0", 9600, 'N', 8, 1);
    ctx = modbus_new_rtu("/dev/ttyUSB0", 9600, 'N', 8, 1);
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

    // tab_rp_registers[0] = 12;
    // modbus_write_registers(ctx, 2, 1, tab_rp_registers);

    //modbus_write_register(ctx, 2, 12);

    //tab_rp_registers[0] = 0;
    //memset(tab_rp_registers, 0, sizeof(tab_rp_registers));
    //modbus_read_registers(ctx, 0x100, 4, tab_rp_registers);
    //printf("modbus_read_registers 0x100 error %d read 0x%4.4X %d\n", error,
    //       tab_rp_registers[0], tab_rp_registers[0]);

    // tab_rp_registers[0] = 0;

    int index;
    for (index = 0; index < 10; index++)
    {
        error = modbus_read_input_registers(ctx, index, 1, tab_rp_registers);
        printf("modbus_read_input_registers index %d error %d read 0x%4.4X %d\n", index, error,
               tab_rp_registers[0], tab_rp_registers[0]);
        usleep(1000 * 1000 * 1);
    }

    // int index;
    // for (index = 1; index < 3; index++)
    // {
    //     error = modbus_read_registers(ctx, index, 1, tab_rp_registers);
    //     printf("modbus_read_registers index %d error %d read 0x%4.4X %d\n", index, error,
    //            tab_rp_registers[0], tab_rp_registers[0]);
    //     usleep(1000 * 1000 * 1);
    // }

    //modbus_write_register(ctx, 2, 10);

    modbus_free(ctx);
    return 0;
}

