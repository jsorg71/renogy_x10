
#ifndef __LIBCM11A_H
#define __LIBCM11A_H

#define LIBCM11A_VERSION 1

struct libcm11a_t
{
    int version;
    int fd;
	int want_crc;
	int crc;
	int data_sent;
	int data_bytes;
	unsigned char* data;
    void* port;
    char* port_name;
	void* user[16];
    /* app callbacks */
    int (*interface_ready)(struct libcm11a_t *libcm11a);
    int (*interface_poll)(struct libcm11a_t *libcm11a);
    int (*time_request)(struct libcm11a_t *libcm11a);
	int (*crc_ok)(struct libcm11a_t *libcm11a);
	int (*crc_not_ok)(struct libcm11a_t *libcm11a);
	int (*done_write)(struct libcm11a_t *libcm11a);
};

int
libcm11a_create(const char *port_name, struct libcm11a_t **libcm11a);
int
libcm11a_destroy(struct libcm11a_t *libcm11a);
int
libcm11a_get_wait_objs_rw(struct libcm11a_t *libcm11a,
                          int *robjs, int *robj_count,
                          int *wobjs, int *wobj_count,
                          int *timeout);
int
libcm11a_check_wait_objs(struct libcm11a_t *libcm11a);
int
libcm11a_write_data_crc(struct libcm11a_t *libcm11a,
                        const void* data, int data_bytes);
int
libcm11a_write_data(struct libcm11a_t *libcm11a,
                    const void* data, int data_bytes);


#endif
