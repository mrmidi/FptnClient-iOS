#ifndef ApiClientBridge_h
#define ApiClientBridge_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque pointer to hide C++ implementation
typedef void* ApiClientHandle;

// Response structure for C interface
typedef struct {
    char* body;
    int code;
    char* errmsg;
} CApiClientResponse;

typedef struct {
    bool reachable;
    int latency_ms;
    char* errmsg;
} CApiClientHandshakeResult;

// Create and destroy
ApiClientHandle apiClientCreate(const char* host,
                                int port,
                                const char* sni,
                                const char* md5_fingerprint,
                                const char* censorship_strategy);
void apiClientDestroy(ApiClientHandle handle);

// Methods
CApiClientResponse apiClientGet(ApiClientHandle handle, const char* handle_str, int timeout);
CApiClientResponse apiClientPost(ApiClientHandle handle,
                                 const char* handle_str,
                                 const char* request,
                                 int timeout);
CApiClientHandshakeResult apiClientTestHandshake(ApiClientHandle handle, int timeout);

// Memory management
void apiClientResponseFree(CApiClientResponse response);
void apiClientHandshakeResultFree(CApiClientHandshakeResult result);

#ifdef __cplusplus
}
#endif

#endif /* ApiClientBridge_h */
