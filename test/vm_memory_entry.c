#include <mach/mach.h>
#include <mach/mig_errors.h>
#include <mach/ndr.h>
#include <mach/vm_page_size.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Guest memory entries are deliberately unsupported until vm_map_64 can
 * preserve their sharing semantics. Check that callers receive an ordinary
 * MIG error and can fall back, without aborting or changing out parameters. */
struct __attribute__((packed, aligned(4))) request32 {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t parent;
    NDR_record_t ndr;
    uint64_t size;
    uint64_t offset;
    vm_prot_t permission;
};

_Static_assert(sizeof(struct request32) == 68,
    "unexpected ARM32 memory-entry request layout");

static int report(const char *name, int passed) {
    printf("vm-memory-entry-%s: %s\n", name, passed ? "PASS" : "FAIL");
    return passed;
}

static int raw_request(unsigned variant, kern_return_t expected) {
    union {
        struct request32 request;
        mig_reply_error_t reply;
        uint8_t bytes[128];
    } message = {0};
    mach_port_t replyPort = MACH_PORT_NULL;
    if(mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE,
            &replyPort) != KERN_SUCCESS) return 0;
    message.request.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
            MACH_MSG_TYPE_MAKE_SEND_ONCE);
    message.request.header.msgh_remote_port = mach_task_self();
    message.request.header.msgh_local_port = replyPort;
    message.request.header.msgh_id = 3825;
    message.request.body.msgh_descriptor_count = 1;
    message.request.parent.type = MACH_MSG_PORT_DESCRIPTOR;
    message.request.parent.disposition = MACH_MSG_TYPE_COPY_SEND;
    message.request.ndr = NDR_record;
    message.request.size = vm_page_size;
    message.request.permission = VM_PROT_READ;
    mach_msg_size_t sendSize = sizeof(struct request32);
    mach_msg_size_t receiveSize = sizeof(message);
    switch (variant) {
        case 1: --sendSize; break;
        case 2:
            message.request.header.msgh_bits &= ~MACH_MSGH_BITS_COMPLEX;
            break;
        case 3: message.request.body.msgh_descriptor_count = 0; break;
        case 4: message.request.parent.type = MACH_MSG_OOL_DESCRIPTOR; break;
        case 5:
            message.request.parent.disposition = MACH_MSG_TYPE_MOVE_SEND;
            break;
        case 6: receiveSize = sizeof(mach_msg_header_t); break;
    }
    mach_msg_return_t status = mach_msg(&message.request.header,
        MACH_SEND_MSG | MACH_RCV_MSG, sendSize, receiveSize,
        replyPort, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    int passed = variant == 6
        ? status == MACH_RCV_TOO_LARGE &&
            message.reply.Head.msgh_size == sizeof(mig_reply_error_t)
        : status == MACH_MSG_SUCCESS &&
            message.reply.Head.msgh_id == 3925 &&
            message.reply.Head.msgh_size == sizeof(mig_reply_error_t) &&
            !(message.reply.Head.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
            memcmp(&message.reply.NDR, &NDR_record, sizeof(NDR_record)) == 0 &&
            message.reply.RetCode == expected;
    return mach_port_destroy(mach_task_self(), replyPort) == KERN_SUCCESS &&
        passed;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    vm_address_t address = 0;
    if(vm_allocate(mach_task_self(), &address, vm_page_size,
            VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return 1;
    memset((void *)(uintptr_t)address, 0x6a, vm_page_size);
    const memory_object_size_t requestedSize = vm_page_size;
    memory_object_size_t size = requestedSize;
    const mach_port_t sentinel = 0x12345678;
    mach_port_t entry = sentinel;
    kern_return_t result = mach_make_memory_entry_64(mach_task_self(),
        &size, address, VM_PROT_READ, &entry, MACH_PORT_NULL);
    int passed = report("unsupported",
        result == KERN_NOT_SUPPORTED && size == requestedSize &&
        entry == sentinel && *(uint8_t *)(uintptr_t)address == 0x6a);

    const mach_port_t host = mach_host_self();
    result = mach_make_memory_entry_64(host, &size, address,
        VM_PROT_READ, &entry, MACH_PORT_NULL);
    passed &= report("nonself-target",
        result == KERN_INVALID_ARGUMENT && size == requestedSize &&
        entry == sentinel);
    passed &= mach_port_deallocate(mach_task_self(), host) == KERN_SUCCESS;
    passed &= report("raw-error-reply", raw_request(0, KERN_NOT_SUPPORTED));
    passed &= report("short-request", raw_request(1, MIG_BAD_ARGUMENTS));
    passed &= report("noncomplex-request", raw_request(2, MIG_BAD_ARGUMENTS));
    passed &= report("descriptor-count", raw_request(3, MIG_BAD_ARGUMENTS));
    passed &= report("descriptor-type", raw_request(4, MIG_BAD_ARGUMENTS));
    passed &= report("descriptor-disposition", raw_request(5, MIG_BAD_ARGUMENTS));
    passed &= report("short-receive", raw_request(6, MACH_RCV_TOO_LARGE));
    passed &= report("cleanup", vm_deallocate(mach_task_self(), address,
        vm_page_size) == KERN_SUCCESS);
    return passed ? 0 : 1;
}
