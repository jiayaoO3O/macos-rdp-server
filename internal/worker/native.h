#ifndef RDP_NATIVE_H
#define RDP_NATIVE_H
int rdp_serve(const char *address, int port, const char *cert, const char *key, const char *sam, const char *agent_socket, int test_pattern, int clipboard);
int rdp_probe(const char *address, int port, const char *user, const char *domain, const char *password, int mode, int width, int height);
int rdp_nt_hash(const char *password, unsigned char *hash);
#endif
