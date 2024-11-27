
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <modbus.h>
#include <unistd.h>

/****************************************************************************/
static int
print_help(const char* app)
{
    printf("Usage: %s [OPTIONS]\n", app);
    printf("  Option                    Meaning\n");
    printf("  --id id                   The modbus address\n");
    printf("  --debug                   Set debug mode\n");
    printf("  --loop loopnum loopdelay  Set number of loops and delay in seconds\n");
    printf("  --slave                   Show slave parameters\n");
    printf("  --reset-energy            Reset the energy(Wh)\n");
    printf("  --set-id id               Set modbus address\n");
    printf("  --set-range code          Set the shun type\n");
    return 0;
}

/****************************************************************************/
int
main(int argc, char** argv)
{
    modbus_t* ctx;
    uint32_t response_sec;
    uint32_t response_usec;
    modbus_error_recovery_mode er_mode;
    uint16_t registers[8];
    int error;
    int index;
    int pzem_id;
    int debug;
    int loop;
    int loop_delay;
    int show_slave_params;
    int reset_energy;
    int set_id;
    int set_range;
    uint8_t rsp[MODBUS_TCP_MAX_ADU_LENGTH];

    if (argc < 2)
    {
        print_help(argv[0]);
        return 0;
    }
    pzem_id = 1;
    debug = 0;
    loop = 0;
    loop_delay = 0;
    show_slave_params = 0;
    reset_energy = 0;
    set_id = 0;
    set_range = -1;
    for (index = 1; index < argc; index++)
    {
        if (strcmp(argv[index], "--id") == 0)
        {
            if (index + 1 >= argc)
            {
                print_help(argv[0]);
                return 1;
            }
            index++;
            pzem_id = atoi(argv[index]);
        }
        else if (strcmp(argv[index], "--debug") == 0)
        {
            debug = 1;
        }
        else if (strcmp(argv[index], "--loop") == 0)
        {
            if (index + 2 >= argc)
            {
                print_help(argv[0]);
                return 1;
            }
            index++;
            loop = atoi(argv[index]);
            index++;
            loop_delay = atoi(argv[index]);
        }
        else if (strcmp(argv[index], "--slave") == 0)
        {
            show_slave_params = 1;
        }
        else if (strcmp(argv[index], "--reset-energy") == 0)
        {
            reset_energy = 1;
        }
        else if (strcmp(argv[index], "--set-id") == 0)
        {
            if (index + 1 >= argc)
            {
                print_help(argv[0]);
                return 1;
            }
            index++;
            set_id = atoi(argv[index]);
        }
        else if (strcmp(argv[index], "--set-range") == 0)
        {
            if (index + 1 >= argc)
            {
                print_help(argv[0]);
                return 1;
            }
            index++;
            set_range = atoi(argv[index]);
        }
        else
        {
            printf("unknown command line parameter\n");
            return 1;
        }
    }
    if (loop_delay < 1)
    {
        loop_delay = 1;
    }
    ctx = modbus_new_rtu("/dev/ttyUSB0", 9600, 'N', 8, 1);
    if (ctx == NULL)
    {
        return 1;
    }
    printf("main: modbus_new_rtu ok\n");

    if (debug)
    {
        error = modbus_set_debug(ctx, TRUE);
        printf("modbus_set_debug error %d\n", error);
    }

    er_mode = MODBUS_ERROR_RECOVERY_LINK | MODBUS_ERROR_RECOVERY_PROTOCOL;
    error = modbus_set_error_recovery(ctx, er_mode);
    printf("modbus_set_error_recovery error %d\n", error);
    error = modbus_set_slave(ctx, pzem_id);
    printf("modbus_set_slave error %d pzem_id %d\n", error, pzem_id);
    error = modbus_get_response_timeout(ctx,
                                        &response_sec,
                                        &response_usec);
    printf("modbus_get_response_timeout error %d sec %d usec %d\n", error,
           response_sec, response_usec);
    error = modbus_connect(ctx);
    if (error == -1)
    {
        printf("main: Connection failed: %s\n", modbus_strerror(errno));
        modbus_free(ctx);
        return 1;
    }
    printf("main: Connection ok\n");
    if (set_id > 0)
    {
        modbus_write_register(ctx, 0x0002, set_id);
        modbus_free(ctx);
        return 0;
    }
    if (set_range >= 0)
    {
        modbus_write_register(ctx, 0x0003, set_range);
        modbus_free(ctx);
        return 0;
    }
    if (reset_energy)
    {
        unsigned char raw[4];
        raw[0] = pzem_id;
        raw[1] = 0x42;
        error = modbus_send_raw_request(ctx, raw, 2);
        printf("modbus_send_raw_request error %d\n", error);
        error = modbus_receive(ctx, rsp);
        printf("modbus_receive error %d\n", error);
        usleep(1000 * 1000);
    }
    if (show_slave_params)
    {
        error = modbus_read_registers(ctx, 0x0000, 4, registers);
        if (error == 4)
        {
            printf("high volt alarm %f low volt alarm %f "
                   "modbus address %d cur range %d\n",
                   registers[0] / 100.0,
                   registers[1] / 100.0,
                   registers[2],
                   registers[3]);
        }
        else
        {
           printf("modbus_read_registers error %d\n", error);
        }
        usleep(1000 * 1000);
    }
    for (index = 0; index < loop; index++)
    {
        error = modbus_read_input_registers(ctx, 0x0000, 8, registers);
        if (error == 8)
        {
            printf("index %d volts %f current(A) %f power(W) %f enerrgy(Wh) %d "
                   "high alarm 0x%4.4X low alarm 0x%4.4X\n",
                   index,
                   registers[0] / 100.0,
                   registers[1] / 100.0,
                   (registers[2] | (registers[3] << 16)) / 10.0,
                   registers[4] | (registers[5] << 16),
                   registers[6],
                   registers[7]);
        }
        else
        {
            printf("modbus_read_input_registers error %d\n", error);
        }
        if (index + 1 < loop)
        {
            usleep(loop_delay * 1000* 1000);
        }
    }
    modbus_free(ctx);
    return 0;
}
